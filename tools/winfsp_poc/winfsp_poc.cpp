#include "winfsp_disc.h"
#include <windows.h>
#include <imapi2fs.h>
#include <wrl/client.h>
#include <algorithm>
#include <fstream>
#include <future>
#include <iostream>
#include <random>

namespace bridge = streampath::iso_bridge;
using Microsoft::WRL::ComPtr;

void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}

struct ComScope {
  ComScope() { require(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)), "Cannot initialize COM"); }
  ~ComScope() { CoUninitialize(); }
};

// 仅用于测试：按需组合 BDMV 的 UDF 镜像，不复制完整媒体数据。
class BdmvSource : public bridge::BlockSource {
 public:
  explicit BdmvSource(const std::filesystem::path& path) {
    require(SUCCEEDED(CoCreateInstance(__uuidof(MsftFileSystemImage), nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&image_))), "Cannot create IMAPI image");
    require(SUCCEEDED(image_->put_FileSystemsToCreate(FsiFileSystemUDF)) &&
            SUCCEEDED(image_->put_UDFRevision(0x250)) &&
            SUCCEEDED(image_->put_FreeMediaBlocks(0x7fffffff)) &&
            SUCCEEDED(image_->put_StageFiles(VARIANT_FALSE)), "Cannot configure UDF image");
    ComPtr<IFsiDirectoryItem> root;
    require(SUCCEEDED(image_->get_Root(&root)), "Cannot access image root");
    BSTR directory = SysAllocString(path.c_str());
    require(directory != nullptr, "Cannot allocate image path");
    const auto added = root->AddTree(directory, VARIANT_FALSE);
    SysFreeString(directory);
    require(SUCCEEDED(added), "Cannot add BDMV source tree");
    require(SUCCEEDED(image_->CreateResultImage(&result_)) &&
            SUCCEEDED(result_->get_ImageStream(&stream_)), "Cannot create UDF image stream");
    STATSTG stat{};
    require(SUCCEEDED(stream_->Stat(&stat, STATFLAG_NONAME)), "Cannot size UDF stream");
    size_ = stat.cbSize.QuadPart;
  }
  std::uint64_t size() const override { return size_; }
  std::vector<std::uint8_t> fetch(std::uint64_t offset, std::uint64_t end) override {
    ComScope com;
    std::lock_guard lock(mutex_);
    LARGE_INTEGER position{};
    position.QuadPart = static_cast<LONGLONG>(offset);
    require(SUCCEEDED(stream_->Seek(position, STREAM_SEEK_SET, nullptr)), "Cannot seek UDF stream");
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - offset + 1));
    ULONG actual = 0;
    require(SUCCEEDED(stream_->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &actual)) &&
            actual == bytes.size(), "Cannot read UDF stream");
    return bytes;
  }
 private:
  ComPtr<IFileSystemImage> image_;
  ComPtr<IFileSystemImageResult> result_;
  ComPtr<IStream> stream_;
  std::mutex mutex_;
  std::uint64_t size_ = 0;
};

class PatternSource : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 32ULL * 1024 * 1024 + 777; }
  std::vector<std::uint8_t> fetch(std::uint64_t offset, std::uint64_t end) override {
    const auto length = static_cast<std::size_t>(end - offset + 1);
    {
      std::unique_lock lock(mutex);
      if (blocking) {
        entered = true;
        ready.notify_all();
        ready.wait(lock, [this] { return released; });
        throw bridge::FetchCancelled(0);
      }
    }
    if (fail) throw std::runtime_error("Injected source failure");
    std::vector<std::uint8_t> result(length);
    for (std::size_t i = 0; i < length; ++i) result[i] = value(offset + i);
    return result;
  }
  static std::uint8_t value(std::uint64_t position) {
    return static_cast<std::uint8_t>((position ^ (position >> 11)) & 255);
  }
  std::atomic<bool> fail = false;
  std::mutex mutex;
  std::condition_variable ready;
  bool blocking = false, entered = false, released = false;
  void cancel_pending() override {
    std::lock_guard lock(mutex);
    released = true;
    ready.notify_all();
  }
};

class LocalSource : public bridge::BlockSource {
 public:
  explicit LocalSource(const std::filesystem::path& path) {
    file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                        OPEN_EXISTING, FILE_FLAG_OVERLAPPED | FILE_FLAG_RANDOM_ACCESS, nullptr);
    require(file_ != INVALID_HANDLE_VALUE, "Cannot open source ISO");
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file_, &size)) { CloseHandle(file_); throw std::runtime_error("Cannot size ISO"); }
    size_ = static_cast<std::uint64_t>(size.QuadPart);
  }
  ~LocalSource() override { CloseHandle(file_); }
  std::uint64_t size() const override { return size_; }
  std::vector<std::uint8_t> fetch(std::uint64_t offset, std::uint64_t end) override {
    const auto length = static_cast<std::size_t>(end - offset + 1);
    std::vector<std::uint8_t> result(length);
    OVERLAPPED io{};
    io.Offset = static_cast<DWORD>(offset);
    io.OffsetHigh = static_cast<DWORD>(offset >> 32);
    io.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(io.hEvent != nullptr, "Cannot create read event");
    DWORD bytes = 0;
    BOOL ok = ReadFile(file_, result.data(), static_cast<DWORD>(length), nullptr, &io);
    if (!ok && GetLastError() != ERROR_IO_PENDING) {
      CloseHandle(io.hEvent);
      throw std::runtime_error("Source read failed");
    }
    ok = GetOverlappedResult(file_, &io, &bytes, TRUE);
    CloseHandle(io.hEvent);
    require(ok && bytes == length, "Incomplete source read");
    return result;
  }
  void cancel_pending() override { CancelIoEx(file_, nullptr); }
 private:
  HANDLE file_ = INVALID_HANDLE_VALUE;
  std::uint64_t size_ = 0;
};

void read_pattern(const std::filesystem::path& path, std::uint64_t offset,
                  DWORD length, std::uint64_t total) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_FLAG_RANDOM_ACCESS, nullptr);
  require(file != INVALID_HANDLE_VALUE, "Cannot open virtual ISO");
  LARGE_INTEGER position{};
  position.QuadPart = static_cast<LONGLONG>(offset);
  bool ok = SetFilePointerEx(file, position, nullptr, FILE_BEGIN) != FALSE;
  std::vector<std::uint8_t> bytes(length);
  DWORD actual = 0;
  ok = ok && ReadFile(file, bytes.data(), length, &actual, nullptr);
  CloseHandle(file);
  require(ok, "Virtual read failed");
  const auto wanted = offset < total ? std::min<std::uint64_t>(length, total - offset) : 0;
  require(actual == wanted, "Wrong EOF or read length");
  for (DWORD i = 0; i < actual; ++i)
    require(bytes[i] == PatternSource::value(offset + i), "Virtual byte mismatch");
}

int wmain(int argc, wchar_t** argv) {
  try {
    ComScope com;
    require(argc >= 2 && argc <= 4, "Usage: streampath_winfsp_poc <new-mount-path> [source.iso|bdmv-root] [seconds]");
    const auto mount = std::filesystem::absolute(argv[1]);
    const auto path = mount / L"disc.iso";
    std::shared_ptr<bridge::BlockSource> source;
    if (argc == 2) source = std::make_shared<PatternSource>();
    else if (std::filesystem::is_directory(argv[2])) source = std::make_shared<BdmvSource>(argv[2]);
    else source = std::make_shared<LocalSource>(argv[2]);
    bridge::BlockCache cache(source, bridge::kIsoDemandBlockSize, 4, 16, 16, 16);
    cache.configure(4, 4);
    bridge::WinFspDisc disc(cache, source->size(), mount);
    if (argc >= 3) {
      std::cout << "Mounted read-only ISO; press Enter to stop." << std::endl;
      if (argc == 4) {
        const int seconds = _wtoi(argv[3]);
        require(seconds > 0 && seconds <= 600, "Invalid mount lifetime");
        for (int i = 0; i < seconds && !std::filesystem::exists(mount.parent_path() / L"stop-poc"); ++i)
          std::this_thread::sleep_for(std::chrono::seconds(1));
      } else std::cin.get();
    } else {
      require(std::filesystem::file_size(path) == source->size(), "Wrong virtual file size");
      std::size_t entries = 0;
      for (const auto& entry : std::filesystem::directory_iterator(mount)) {
        require(entry.path().filename() == L"disc.iso", "Unexpected virtual file");
        ++entries;
      }
      require(entries == 1, "Directory enumeration failed");
      for (auto offset : {0ULL, 1ULL, 2047ULL, 262143ULL, 1048573ULL, source->size() - 5, source->size()})
        read_pattern(path, offset, 65539, source->size());
      std::vector<std::future<void>> readers;
      for (unsigned seed = 1; seed <= 4; ++seed) {
        readers.push_back(std::async(std::launch::async, [&, seed] {
          std::mt19937 random(seed);
          for (int i = 0; i < 40; ++i)
            read_pattern(path, random() % source->size(), 1 + random() % 300001, source->size());
        }));
      }
      for (auto& reader : readers) reader.get();
      HANDLE write = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                 OPEN_EXISTING, 0, nullptr);
      if (write != INVALID_HANDLE_VALUE) CloseHandle(write);
      require(write == INVALID_HANDLE_VALUE, "Write access unexpectedly allowed");
      require(!DeleteFileW(path.c_str()), "Delete unexpectedly allowed");
      require(!MoveFileW(path.c_str(), (mount / L"other.iso").c_str()), "Rename unexpectedly allowed");
      require(cache.metrics().playback_requests == 1, "Random reads advanced playback generation");
    }
    disc.stop();
    require(!std::filesystem::exists(mount), "Mount remains after shutdown");
    std::cout << disc.metrics_json() << '\n';
    require(cache.metrics().resident_bytes <= 16ULL * 1024 * 1024, "Cache budget exceeded");
    if (argc == 2) {
      auto broken = std::make_shared<PatternSource>();
      broken->fail = true;
      bridge::BlockCache broken_cache(broken, bridge::kIsoDemandBlockSize, 64);
      bridge::WinFspDisc broken_disc(broken_cache, broken->size(), mount);
      bool rejected = false;
      try { read_pattern(path, 0, 1, broken->size()); }
      catch (const std::runtime_error&) { rejected = true; }
      require(rejected && broken_disc.failed(), "Source failure was hidden");
      broken_disc.stop();

      auto stalled = std::make_shared<PatternSource>();
      bridge::BlockCache stalled_cache(stalled, bridge::kIsoDemandBlockSize, 64);
      bridge::WinFspDisc stalled_disc(stalled_cache, stalled->size(), mount);
      stalled->blocking = true;
      stalled->released = false;
      auto reader = std::async(std::launch::async, [&] {
        try { read_pattern(path, 0, 1, stalled->size()); return false; }
        catch (const std::runtime_error&) { return true; }
      });
      {
        std::unique_lock lock(stalled->mutex);
        require(stalled->ready.wait_for(lock, std::chrono::seconds(2), [&] { return stalled->entered; }),
                "Blocking source was not entered");
      }
      stalled_disc.stop();
      require(reader.wait_for(std::chrono::seconds(2)) == std::future_status::ready && reader.get(),
              "Shutdown did not cancel blocked read");
      require(!std::filesystem::exists(mount), "Cancelled mount remains");
      std::cout << "PASS: bytes, concurrency, EOF, read-only, generation, source failure and blocked-read shutdown\n";
    } else std::cout << "PASS: media fixture unmounted\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
