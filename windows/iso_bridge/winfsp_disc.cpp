#include "winfsp_disc.h"

#include <windows.h>
using PNTSTATUS = LONG*;
#include <winfsp/winfsp.h>
#include <sddl.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <sstream>

namespace streampath::iso_bridge {

struct WinFspDisc::Impl {
  BlockCache& cache;
  const std::uint64_t size;
  const std::uint64_t generation;
  const bool prefetch;
  std::atomic<unsigned> read_ahead_seconds = 60;
  HMODULE module = nullptr;
  FSP_FILE_SYSTEM* fs = nullptr;
  PSECURITY_DESCRIPTOR security = nullptr;
  FSP_FILE_SYSTEM_INTERFACE callbacks{};
  std::atomic<bool> failed = false;
  std::atomic<bool> stopping = false;
  std::atomic<std::uint64_t> reads = 0, bytes = 0, read_us = 0;
  std::array<std::atomic<std::uint64_t>, 4> sizes{};

  decltype(&FspFileSystemCreate) create = nullptr;
  decltype(&FspFileSystemDelete) destroy = nullptr;
  decltype(&FspFileSystemSetMountPoint) mount = nullptr;
  decltype(&FspFileSystemRemoveMountPoint) unmount = nullptr;
  decltype(&FspFileSystemStartDispatcher) start = nullptr;
  decltype(&FspFileSystemStopDispatcher) halt = nullptr;
  decltype(&FspFileSystemAddDirInfo) add_dir = nullptr;

  struct File {
    bool directory;
    std::mutex mutex;
    std::uint64_t next = 0, sequential = 0;
    std::chrono::steady_clock::time_point sequential_started{};
    bool expanded_read_ahead = false;
  };

  Impl(BlockCache& cache_value, std::uint64_t size_value, bool prefetch_value)
      : cache(cache_value), size(size_value), generation(cache.begin_playback()),
        prefetch(prefetch_value) {}

  ~Impl() {
    stop();
    if (fs) destroy(fs);
    if (security) LocalFree(security);
    if (module) FreeLibrary(module);
  }

  void stop() {
    if (stopping.exchange(true)) return;
    // 先解除网络/缓存等待，再等待 dispatcher 回调退出。
    cache.shutdown();
    if (fs) {
      unmount(fs);
      halt(fs);
    }
  }

  template <typename T> void load(T& target, const char* name) {
    const auto symbol = GetProcAddress(module, name);
    if (!symbol) throw std::runtime_error("Incomplete WinFsp runtime");
    static_assert(sizeof(target) == sizeof(symbol));
    std::memcpy(&target, &symbol, sizeof(target));
  }

  void initialize(const std::filesystem::path& path) {
    // 使用已安装运行时的绝对路径，避免从当前目录加载 DLL。
    wchar_t directory[32768]{};
    DWORD count = sizeof(directory);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinFsp", L"InstallDir",
                    RRF_RT_REG_SZ | RRF_SUBKEY_WOW6432KEY, nullptr, directory,
                    &count) != ERROR_SUCCESS) {
      throw std::runtime_error("WinFsp runtime is not installed");
    }
    const auto dll = std::filesystem::path(directory) / L"bin" / L"winfsp-x64.dll";
    module = LoadLibraryExW(dll.c_str(), nullptr,
                           LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                           LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) throw std::runtime_error("Cannot load WinFsp runtime");
    load(create, "FspFileSystemCreate");
    load(destroy, "FspFileSystemDelete");
    load(mount, "FspFileSystemSetMountPoint");
    load(unmount, "FspFileSystemRemoveMountPoint");
    load(start, "FspFileSystemStartDispatcher");
    load(halt, "FspFileSystemStopDispatcher");
    load(add_dir, "FspFileSystemAddDirInfo");

    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
      throw std::runtime_error("Cannot query file system owner");
    DWORD needed = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &needed);
    std::vector<std::uint8_t> owner(needed);
    const bool found = GetTokenInformation(token, TokenUser, owner.data(), needed,
                                           &needed) != FALSE;
    CloseHandle(token);
    if (!found) throw std::runtime_error("Cannot read file system owner");
    LPWSTR sid = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(owner.data())->User.Sid,
                                &sid))
      throw std::runtime_error("Cannot encode file system owner");
    const std::wstring descriptor = L"O:" + std::wstring(sid) +
        L"G:SYD:P(A;;FA;;;SY)(A;;FRFX;;;" + std::wstring(sid) + L")";
    LocalFree(sid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor.c_str(), SDDL_REVISION_1, &security, nullptr))
      throw std::runtime_error("Cannot create file system security");

    callbacks.GetVolumeInfo = volume;
    callbacks.GetSecurityByName = security_by_name;
    callbacks.Open = open;
    callbacks.Create = [](FSP_FILE_SYSTEM*, PWSTR, UINT32, UINT32, UINT32,
                           PSECURITY_DESCRIPTOR, UINT64, PVOID*, FSP_FSCTL_FILE_INFO*) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    };
    callbacks.Overwrite = [](FSP_FILE_SYSTEM*, PVOID, UINT32, BOOLEAN, UINT64,
                              FSP_FSCTL_FILE_INFO*) { return STATUS_MEDIA_WRITE_PROTECTED; };
    callbacks.Close = close;
    callbacks.Read = read;
    callbacks.GetFileInfo = file_info;
    callbacks.GetSecurity = get_security;
    callbacks.ReadDirectory = read_directory;
    FSP_FSCTL_VOLUME_PARAMS params{};
    params.Version = sizeof(params);
    params.SectorSize = 512;
    params.SectorsPerAllocationUnit = 8;
    params.MaxComponentLength = 255;
    params.FileInfoTimeout = 1000;
    params.CasePreservedNames = 1;
    params.UnicodeOnDisk = 1;
    params.PersistentAcls = 1;
    params.ReadOnlyVolume = 1;
    params.PostCleanupWhenModifiedOnly = 1;
    params.FlushAndPurgeOnCleanup = 1;
    params.UmFileContextIsUserContext2 = 1;
    wcscpy_s(params.FileSystemName, L"StreamPathISO");
    check(create(const_cast<PWSTR>(L"" FSP_FSCTL_DISK_DEVICE_NAME), &params,
                 &callbacks, &fs), "create");
    fs->UserContext = this;
    check(mount(fs, const_cast<PWSTR>(path.c_str())), "mount");
    check(start(fs, 4), "dispatcher");
  }

  static void check(NTSTATUS status, const char* stage) {
    if (NT_SUCCESS(status)) return;
    std::ostringstream error;
    error << "WinFsp " << stage << " failed: 0x" << std::hex
          << static_cast<unsigned long>(status);
    throw std::runtime_error(error.str());
  }
  static Impl& self(FSP_FILE_SYSTEM* fs) {
    return *static_cast<Impl*>(fs->UserContext);
  }
  static int kind(PCWSTR name) {
    if (wcscmp(name, L"\\") == 0) return 1;
    return _wcsicmp(name, L"\\disc.iso") == 0 ? 2 : 0;
  }
  static void info(Impl& state, bool directory, FSP_FSCTL_FILE_INFO* out) {
    *out = {};
    out->FileAttributes = directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_READONLY;
    out->FileSize = directory ? 0 : state.size;
    out->AllocationSize = directory ? 0 : (state.size + 4095) / 4096 * 4096;
    out->IndexNumber = directory ? 1 : 2;
  }
  static NTSTATUS volume(FSP_FILE_SYSTEM* fs, FSP_FSCTL_VOLUME_INFO* out) {
    *out = {};
    out->TotalSize = self(fs).size;
    return STATUS_SUCCESS;
  }
  static NTSTATUS copy_security(Impl& state, PSECURITY_DESCRIPTOR out, SIZE_T* size) {
    if (!size) return STATUS_SUCCESS;
    const auto needed = GetSecurityDescriptorLength(state.security);
    const auto capacity = *size;
    *size = needed;
    if (capacity < needed) return STATUS_BUFFER_OVERFLOW;
    if (out) std::memcpy(out, state.security, needed);
    return STATUS_SUCCESS;
  }
  static NTSTATUS security_by_name(FSP_FILE_SYSTEM* fs, PWSTR name, PUINT32 attrs,
                                    PSECURITY_DESCRIPTOR out, SIZE_T* size) {
    const int type = kind(name);
    if (!type) return STATUS_OBJECT_NAME_NOT_FOUND;
    if (attrs) *attrs = type == 1 ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_READONLY;
    return copy_security(self(fs), out, size);
  }
  static NTSTATUS open(FSP_FILE_SYSTEM* fs, PWSTR name, UINT32 options,
                       UINT32 access, PVOID* context, FSP_FSCTL_FILE_INFO* out) {
    const int type = kind(name);
    if (!type) return STATUS_OBJECT_NAME_NOT_FOUND;
    if (access & (FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
                  FILE_WRITE_ATTRIBUTES | DELETE | WRITE_DAC | WRITE_OWNER))
      return STATUS_MEDIA_WRITE_PROTECTED;
    if (type == 1 && (options & FILE_NON_DIRECTORY_FILE)) return STATUS_FILE_IS_A_DIRECTORY;
    if (type == 2 && (options & FILE_DIRECTORY_FILE)) return STATUS_NOT_A_DIRECTORY;
    auto* file = new (std::nothrow) File{type == 1};
    if (!file) return STATUS_INSUFFICIENT_RESOURCES;
    *context = file;
    info(self(fs), file->directory, out);
    return STATUS_SUCCESS;
  }
  static void close(FSP_FILE_SYSTEM*, PVOID context) { delete static_cast<File*>(context); }
  static NTSTATUS file_info(FSP_FILE_SYSTEM* fs, PVOID context, FSP_FSCTL_FILE_INFO* out) {
    info(self(fs), static_cast<File*>(context)->directory, out);
    return STATUS_SUCCESS;
  }
  static NTSTATUS get_security(FSP_FILE_SYSTEM* fs, PVOID,
                               PSECURITY_DESCRIPTOR out, SIZE_T* size) {
    return copy_security(self(fs), out, size);
  }
  static NTSTATUS read(FSP_FILE_SYSTEM* fs, PVOID context, PVOID buffer,
                       UINT64 offset, ULONG length, PULONG transferred) {
    auto& state = self(fs);
    auto& file = *static_cast<File*>(context);
    *transferred = 0;
    if (file.directory) return STATUS_FILE_IS_A_DIRECTORY;
    if (state.stopping) return STATUS_CANCELLED;
    if (state.failed) return STATUS_IO_DEVICE_ERROR;
    if (length == 0) return STATUS_SUCCESS;
    if (offset >= state.size) return STATUS_END_OF_FILE;
    const auto wanted = static_cast<std::size_t>(std::min<std::uint64_t>(length, state.size - offset));
    const auto began = std::chrono::steady_clock::now();
    ++state.reads;
    ++state.sizes[length <= 4096 ? 0 : length <= 65536 ? 1 : length <= 262144 ? 2 : 3];
    try {
      std::size_t ahead = 0;
      {
        std::lock_guard lock(file.mutex);
        if (offset != file.next && file.expanded_read_ahead)
          state.cache.reset_read_ahead();
        if (offset != file.next || file.sequential == 0) {
          file.sequential_started = began;
          file.expanded_read_ahead = false;
        }
        file.sequential = offset == file.next ? file.sequential + wanted : wanted;
        file.next = offset + wanted;
        if (state.prefetch && file.sequential >= kIsoDemandBlockSize) {
          std::size_t blocks = 2;
          const auto seconds = state.read_ahead_seconds.load();
          const double elapsed = std::chrono::duration<double>(
              began - file.sequential_started).count();
          // 连续读取稳定后按消费速度估算时长，并逐步扩大窗口。
          if (seconds != 0 && elapsed >= 2.0) {
            const auto growing = 2 + file.sequential / (4ULL * 1024 * 1024);
            const double target = static_cast<double>(file.sequential) /
                elapsed * seconds / (4ULL * 1024 * 1024);
            blocks = static_cast<std::size_t>(std::max(2.0,
                std::min(static_cast<double>(growing), target + 1)));
          }
          ahead = state.cache.limit_read_ahead(blocks);
          file.expanded_read_ahead = blocks > 2;
        }
      }
      const auto count = state.cache.read(offset, static_cast<std::uint8_t*>(buffer),
                                          wanted, ahead, state.generation);
      if (count != wanted) {
        if (state.stopping) return STATUS_CANCELLED;
        state.failed = true;
        return STATUS_IO_DEVICE_ERROR;
      }
      *transferred = static_cast<ULONG>(count);
      state.bytes += count;
      state.read_us += static_cast<std::uint64_t>(std::chrono::duration_cast<
          std::chrono::microseconds>(std::chrono::steady_clock::now() - began).count());
      return STATUS_SUCCESS;
    } catch (...) {
      // C 回调不能传播异常；读取失败终止会话，不补零或伪造成功短读。
      if (state.stopping) return STATUS_CANCELLED;
      state.failed = true;
      return STATUS_IO_DEVICE_ERROR;
    }
  }
  static NTSTATUS read_directory(FSP_FILE_SYSTEM* fs, PVOID context, PWSTR,
                                 PWSTR marker, PVOID buffer, ULONG length,
                                 PULONG transferred) {
    auto& state = self(fs);
    *transferred = 0;
    if (!static_cast<File*>(context)->directory) return STATUS_NOT_A_DIRECTORY;
    if (!marker || _wcsicmp(marker, L"disc.iso") < 0) {
      alignas(FSP_FSCTL_DIR_INFO) std::array<std::uint8_t,
          sizeof(FSP_FSCTL_DIR_INFO) + sizeof(L"disc.iso")> storage{};
      auto* entry = reinterpret_cast<FSP_FSCTL_DIR_INFO*>(storage.data());
      entry->Size = static_cast<UINT16>(sizeof(FSP_FSCTL_DIR_INFO) + sizeof(L"disc.iso") - sizeof(wchar_t));
      info(state, false, &entry->FileInfo);
      std::memcpy(entry->FileNameBuf, L"disc.iso", sizeof(L"disc.iso") - sizeof(wchar_t));
      if (!state.add_dir(entry, buffer, length, transferred)) return STATUS_SUCCESS;
    }
    state.add_dir(nullptr, buffer, length, transferred);
    return STATUS_SUCCESS;
  }
};

WinFspDisc::WinFspDisc(BlockCache& cache, std::uint64_t size,
                     const std::filesystem::path& path, bool prefetch)
    : impl_(std::make_unique<Impl>(cache, size, prefetch)) {
  if (size == 0 || size > INT64_MAX || !path.is_absolute() || std::filesystem::exists(path))
    throw std::invalid_argument("Expected a new absolute mount path and positive disc size");
  impl_->initialize(path);
}
WinFspDisc::~WinFspDisc() = default;
void WinFspDisc::stop() { impl_->stop(); }
void WinFspDisc::configure_read_ahead(unsigned seconds) {
  impl_->read_ahead_seconds = seconds;
}
bool WinFspDisc::failed() const { return impl_->failed; }
bool WinFspDisc::available() {
  wchar_t directory[32768]{};
  DWORD size = sizeof(directory);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinFsp", L"InstallDir",
                  RRF_RT_REG_SZ | RRF_SUBKEY_WOW6432KEY, nullptr, directory,
                  &size) != ERROR_SUCCESS) return false;
  const auto dll = std::filesystem::path(directory) / L"bin" / L"winfsp-x64.dll";
  HMODULE module = LoadLibraryExW(dll.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!module) return false;
  const bool result = GetProcAddress(module, "FspFileSystemCreate") != nullptr;
  FreeLibrary(module);
  return result;
}
std::string WinFspDisc::metrics_json() const {
  std::ostringstream out;
  out << "{\"schema\":1,\"readCalls\":" << impl_->reads
      << ",\"readBytes\":" << impl_->bytes << ",\"readUs\":" << impl_->read_us
      << ",\"failed\":" << (impl_->failed ? "true" : "false")
      << ",\"readSizeBuckets\":[";
  for (std::size_t i = 0; i < impl_->sizes.size(); ++i)
    out << (i ? "," : "") << impl_->sizes[i];
  return out.str() + "]}";
}

}  // namespace streampath::iso_bridge
