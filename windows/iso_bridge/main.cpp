#include <winsock2.h>
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <ws2tcpip.h>

#include <libbluray/bluray.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <iomanip>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "bridge_core.h"
#include "iso_structure_cache.h"
#include "remote_disc_endpoint.h"
#include "winfsp_disc.h"

namespace bridge = streampath::iso_bridge;
using bridge::ChapterInfo;
using bridge::TitleInfo;

namespace {

constexpr int kMaximumRedirects = 5;
constexpr DWORD kNetworkTimeoutMilliseconds = 30000;
constexpr std::size_t kMaximumHttpHeaderBytes = 16U * 1024U;
constexpr std::uint64_t kMaximumIsoRangeBytes =
    bridge::kIsoBlockSize * bridge::kPlaybackPrefetchBatchBlocks;
constexpr std::size_t kIsoDemandBlockScale = static_cast<std::size_t>(
    bridge::kIsoBlockSize / bridge::kIsoDemandBlockSize);
constexpr std::size_t kIsoMetadataBlockCount =
    bridge::kIsoBlockCount * kIsoDemandBlockScale;
static_assert(bridge::kIsoBlockSize % bridge::kIsoDemandBlockSize == 0);

class BridgeException final : public std::runtime_error {
 public:
  BridgeException(std::string code, std::string message, DWORD http_status = 0)
      : std::runtime_error(std::move(message)),
        code_(std::move(code)),
        http_status_(http_status) {}

  const std::string& code() const noexcept { return code_; }
  DWORD http_status() const noexcept { return http_status_; }

 private:
  std::string code_;
  DWORD http_status_ = 0;
};

struct MediaRangePlan {
  std::uint64_t packet_start = 0;
  std::uint64_t skip_prefix = 0;
  std::uint64_t response_length = 0;
  std::uint64_t source_end_exclusive = 0;
};

MediaRangePlan identity_media_range_plan(std::uint64_t start,
                                         std::uint64_t end,
                                         std::uint64_t total) {
  if (total == 0 || start > end || end >= total) {
    throw BridgeException("internal_error", "The media byte range is invalid");
  }
  const std::uint64_t packet_start =
      start - (start % bridge::kM2tsPacketSize);
  return {
      packet_start,
      start - packet_start,
      end - start + 1,
      end + 1,
  };
}

void validate_time_seek_redirect_option(bool enabled) {
  if (enabled) {
    throw BridgeException(
        "protocol_error",
        "Time seek redirect is disabled because it cannot preserve byte ranges");
  }
}

struct GenerationFailureSnapshot {
  std::uint64_t generation = 0;
  std::string code;
};

class GenerationFailureState final {
 public:
  void record(std::uint64_t generation, std::string code) {
    std::lock_guard lock(mutex_);
    generation_ = generation;
    code_ = std::move(code);
  }

  GenerationFailureSnapshot snapshot() const {
    std::lock_guard lock(mutex_);
    return {generation_, code_};
  }

  bool applies_to(std::uint64_t generation) const {
    std::lock_guard lock(mutex_);
    return generation != 0 && generation_ == generation;
  }

 private:
  mutable std::mutex mutex_;
  std::uint64_t generation_ = 0;
  std::string code_;
};

template <typename Callback>
class ScopeExit final {
 public:
  explicit ScopeExit(Callback callback)
      : callback_(std::move(callback)) {}
  ~ScopeExit() { callback_(); }
  ScopeExit(const ScopeExit&) = delete;
  ScopeExit& operator=(const ScopeExit&) = delete;

 private:
  Callback callback_;
};

struct NetworkMetricsSnapshot {
  std::uint64_t request_count = 0;
  std::uint64_t redirect_count = 0;
  std::uint64_t redirect_resolve_count = 0;
  std::uint64_t resolved_url_reuse_count = 0;
  std::uint64_t response_header_latency_us_total = 0;
  std::uint64_t response_body_active_us_total = 0;
  std::uint64_t remote_body_bytes = 0;
  std::uint64_t probe_body_bytes = 0;
  std::uint64_t active_request_peak = 0;
  std::uint64_t remote_transfer_wall_clock_us = 0;
  std::uint64_t concurrent_transfer_wall_clock_us = 0;
  std::uint64_t request_context_created_count = 0;
  std::uint64_t request_context_closed_count = 0;
  std::uint64_t request_context_live = 0;
  std::uint64_t request_context_peak = 0;
};

struct NetworkPhaseMetricsSnapshot {
  std::uint64_t request_count = 0;
  std::uint64_t redirect_count = 0;
  std::uint64_t response_header_latency_us_total = 0;
  std::uint64_t response_body_active_us_total = 0;
  std::uint64_t remote_body_bytes = 0;
  std::uint64_t remote_transfer_wall_clock_us = 0;
  std::uint64_t concurrent_transfer_wall_clock_us = 0;
  std::uint64_t request_context_created_count = 0;
  std::uint64_t request_context_closed_count = 0;
};

std::uint64_t counter_delta(std::uint64_t current,
                            std::uint64_t previous) {
  return current >= previous ? current - previous : 0;
}

NetworkPhaseMetricsSnapshot network_phase_metrics(
    const NetworkMetricsSnapshot& current,
    const NetworkMetricsSnapshot& previous) {
  return {
      counter_delta(current.request_count, previous.request_count),
      counter_delta(current.redirect_count, previous.redirect_count),
      counter_delta(current.response_header_latency_us_total,
                    previous.response_header_latency_us_total),
      counter_delta(current.response_body_active_us_total,
                    previous.response_body_active_us_total),
      counter_delta(current.remote_body_bytes, previous.remote_body_bytes),
      counter_delta(current.remote_transfer_wall_clock_us,
                    previous.remote_transfer_wall_clock_us),
      counter_delta(current.concurrent_transfer_wall_clock_us,
                    previous.concurrent_transfer_wall_clock_us),
      counter_delta(current.request_context_created_count,
                    previous.request_context_created_count),
      counter_delta(current.request_context_closed_count,
                    previous.request_context_closed_count),
  };
}

struct CacheMetricsSnapshot {
  bridge::BlockCacheMetrics metadata;
  bridge::BlockCacheMetrics playback;
  std::uint64_t metadata_retained_bytes = 0;

  bridge::BlockCacheMetrics aggregate() const {
    return bridge::combine_sequential_cache_metrics(metadata, playback);
  }
};

class InternetHandle final {
 public:
  InternetHandle() = default;
  explicit InternetHandle(HINTERNET value) : value_(value) {}
  ~InternetHandle() { reset(); }
  InternetHandle(const InternetHandle&) = delete;
  InternetHandle& operator=(const InternetHandle&) = delete;
  InternetHandle(InternetHandle&& other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}
  InternetHandle& operator=(InternetHandle&& other) noexcept {
    if (this != &other) reset(std::exchange(other.value_, nullptr));
    return *this;
  }
  HINTERNET get() const { return value_; }
  explicit operator bool() const { return value_ != nullptr; }
  void reset(HINTERNET value = nullptr) {
    if (value_ != nullptr) WinHttpCloseHandle(value_);
    value_ = value;
  }

 private:
  HINTERNET value_ = nullptr;
};

class KernelHandle final {
 public:
  KernelHandle() = default;
  explicit KernelHandle(HANDLE value) : value_(value) {}
  ~KernelHandle() { reset(); }
  KernelHandle(const KernelHandle&) = delete;
  KernelHandle& operator=(const KernelHandle&) = delete;
  KernelHandle(KernelHandle&& other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}
  KernelHandle& operator=(KernelHandle&& other) noexcept {
    if (this != &other) reset(std::exchange(other.value_, nullptr));
    return *this;
  }
  HANDLE get() const { return value_; }
  explicit operator bool() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }
  HANDLE release() { return std::exchange(value_, nullptr); }
  void reset(HANDLE value = nullptr) {
    if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
    value_ = value;
  }

 private:
  HANDLE value_ = nullptr;
};

class SocketHandle final {
 public:
  SocketHandle() = default;
  explicit SocketHandle(SOCKET value) : value_(value) {}
  ~SocketHandle() { reset(); }
  SocketHandle(const SocketHandle&) = delete;
  SocketHandle& operator=(const SocketHandle&) = delete;
  SocketHandle(SocketHandle&& other) noexcept
      : value_(std::exchange(other.value_, INVALID_SOCKET)) {}
  SocketHandle& operator=(SocketHandle&& other) noexcept {
    if (this != &other) reset(std::exchange(other.value_, INVALID_SOCKET));
    return *this;
  }
  SOCKET get() const { return value_; }
  explicit operator bool() const { return value_ != INVALID_SOCKET; }
  SOCKET release() { return std::exchange(value_, INVALID_SOCKET); }
  void reset(SOCKET value = INVALID_SOCKET) {
    if (value_ != INVALID_SOCKET) closesocket(value_);
    value_ = value;
  }

 private:
  SOCKET value_ = INVALID_SOCKET;
};

std::wstring wide_from_utf8(std::string_view value) {
  if (value.empty()) return {};
  if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    throw BridgeException("protocol_error", "Text field is too large");
  }
  const int source_length = static_cast<int>(value.size());
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(), source_length, nullptr, 0);
  if (length <= 0) {
    throw BridgeException("protocol_error", "Text field is not valid UTF-8");
  }
  std::wstring output(static_cast<std::size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          source_length, output.data(), length) != length) {
    throw BridgeException("protocol_error", "Text field conversion failed");
  }
  return output;
}

std::string utf8_from_wide(std::wstring_view value) {
  if (value.empty()) return {};
  if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    throw BridgeException("internal_error", "Windows text field is too large");
  }
  const int source_length = static_cast<int>(value.size());
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         value.data(), source_length, nullptr, 0,
                                         nullptr, nullptr);
  if (length <= 0) {
    throw BridgeException("internal_error", "Windows text conversion failed");
  }
  std::string output(static_cast<std::size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          source_length, output.data(), length, nullptr,
                          nullptr) != length) {
    throw BridgeException("internal_error", "Windows text conversion failed");
  }
  return output;
}

std::string lowercase_ascii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](char ch) {
    return ch >= 'A' && ch <= 'Z' ? static_cast<char>(ch - 'A' + 'a') : ch;
  });
  return value;
}

std::wstring lowercase_wide(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
    return static_cast<wchar_t>(towlower(ch));
  });
  return value;
}

std::string base64_encode(std::string_view value) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  output.reserve(((value.size() + 2U) / 3U) * 4U);
  for (std::size_t index = 0; index < value.size(); index += 3U) {
    const std::uint32_t first =
        static_cast<unsigned char>(value[index]);
    const std::uint32_t second = index + 1U < value.size()
                                     ? static_cast<unsigned char>(value[index + 1U])
                                     : 0U;
    const std::uint32_t third = index + 2U < value.size()
                                    ? static_cast<unsigned char>(value[index + 2U])
                                    : 0U;
    const std::uint32_t combined = (first << 16U) | (second << 8U) | third;
    output.push_back(kAlphabet[(combined >> 18U) & 0x3fU]);
    output.push_back(kAlphabet[(combined >> 12U) & 0x3fU]);
    output.push_back(index + 1U < value.size()
                         ? kAlphabet[(combined >> 6U) & 0x3fU]
                         : '=');
    output.push_back(index + 2U < value.size() ? kAlphabet[combined & 0x3fU]
                                               : '=');
  }
  return output;
}

std::wstring combine_url(const std::wstring& base,
                         const std::wstring& location) {
  DWORD length = 0;
  const HRESULT first = UrlCombineW(base.c_str(), location.c_str(), nullptr,
                                    &length, URL_DONT_ESCAPE_EXTRA_INFO);
  if (first != E_POINTER || length == 0) {
    throw BridgeException("network_error", "Redirect location is invalid");
  }
  std::vector<wchar_t> buffer(static_cast<std::size_t>(length));
  if (FAILED(UrlCombineW(base.c_str(), location.c_str(), buffer.data(), &length,
                         URL_DONT_ESCAPE_EXTRA_INFO))) {
    throw BridgeException("network_error", "Redirect location is invalid");
  }
  return std::wstring(buffer.data());
}

struct ParsedUrl {
  bool secure = false;
  INTERNET_PORT port = 0;
  std::wstring host;
  std::wstring path;
};

ParsedUrl parse_url(const std::wstring& url) {
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.dwSchemeLength = static_cast<DWORD>(-1);
  components.dwHostNameLength = static_cast<DWORD>(-1);
  components.dwUrlPathLength = static_cast<DWORD>(-1);
  components.dwExtraInfoLength = static_cast<DWORD>(-1);
  if (WinHttpCrackUrl(url.c_str(), 0, 0, &components) == FALSE ||
      (components.nScheme != INTERNET_SCHEME_HTTP &&
       components.nScheme != INTERNET_SCHEME_HTTPS) ||
      components.lpszHostName == nullptr || components.dwHostNameLength == 0) {
    throw BridgeException("network_error", "Only HTTP and HTTPS URLs are supported");
  }
  ParsedUrl result;
  result.secure = components.nScheme == INTERNET_SCHEME_HTTPS;
  result.port = components.nPort;
  result.host.assign(components.lpszHostName, components.dwHostNameLength);
  if (components.lpszUrlPath != nullptr && components.dwUrlPathLength > 0) {
    result.path.assign(components.lpszUrlPath, components.dwUrlPathLength);
  }
  if (components.lpszExtraInfo != nullptr && components.dwExtraInfoLength > 0) {
    result.path.append(components.lpszExtraInfo, components.dwExtraInfoLength);
  }
  if (result.path.empty()) result.path = L"/";
  return result;
}

bool same_origin(const ParsedUrl& first, const ParsedUrl& second) {
  return first.secure == second.secure && first.port == second.port &&
         lowercase_wide(first.host) == lowercase_wide(second.host);
}

std::optional<std::wstring> query_header(HINTERNET request, DWORD query,
                                         const wchar_t* name = nullptr) {
  DWORD length = 0;
  if (WinHttpQueryHeaders(request, query, name, nullptr, &length, nullptr) !=
          FALSE ||
      GetLastError() != ERROR_INSUFFICIENT_BUFFER || length < sizeof(wchar_t)) {
    return std::nullopt;
  }
  std::vector<wchar_t> buffer(length / sizeof(wchar_t));
  if (WinHttpQueryHeaders(request, query, name, buffer.data(), &length,
                          nullptr) == FALSE) {
    return std::nullopt;
  }
  return std::wstring(buffer.data());
}

std::optional<std::uint64_t> parse_uint64(std::wstring_view value) {
  if (value.empty()) return std::nullopt;
  const std::string utf8 = utf8_from_wide(value);
  std::uint64_t result = 0;
  const auto parsed =
      std::from_chars(utf8.data(), utf8.data() + utf8.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != utf8.data() + utf8.size()) {
    return std::nullopt;
  }
  return result;
}

struct HttpResponse {
  DWORD status = 0;
  std::wstring effective_url;
  std::optional<std::uint64_t> content_length;
  std::optional<std::string> content_range;
  std::optional<std::wstring> etag;
  std::optional<std::wstring> last_modified;
  std::vector<std::uint8_t> body;
};

class WinHttpRangeSource final : public bridge::BlockSource {
 private:
  class ActiveRequest;
  struct RequestLifecycleCounters {
    std::atomic<std::uint64_t> created = 0;
    std::atomic<std::uint64_t> closed = 0;
    std::atomic<std::uint64_t> live = 0;
    std::atomic<std::uint64_t> peak = 0;
  };

 public:
  WinHttpRangeSource(std::string url, std::string base_origin,
                     std::string username, std::string password)
      : auth_origin_(parse_url(wide_from_utf8(base_origin))),
        initial_url_(wide_from_utf8(url)),
        current_url_(initial_url_) {
    if (!username.empty()) {
      authorization_ = wide_from_utf8(
          "Basic " + base64_encode(username + ":" + password));
    }
    session_.reset(WinHttpOpen(L"StreamPath ISO Bridge/1",
                               WINHTTP_ACCESS_TYPE_NO_PROXY,
                               WINHTTP_NO_PROXY_NAME,
                               WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC));
    if (!session_) {
      throw BridgeException("network_error", "Unable to initialize WinHTTP");
    }
    WinHttpSetTimeouts(session_.get(), kNetworkTimeoutMilliseconds,
                       kNetworkTimeoutMilliseconds, kNetworkTimeoutMilliseconds,
                       kNetworkTimeoutMilliseconds);
    probe();
  }

  ~WinHttpRangeSource() = default;

  std::uint64_t size() const override { return size_; }

  bridge::StructureCacheValidatorKind structure_cache_validator_kind() const {
    return validator_is_etag_
               ? bridge::StructureCacheValidatorKind::strong_etag
               : bridge::StructureCacheValidatorKind::last_modified;
  }

  const std::wstring& validator() const { return validator_; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    return fetch_impl(start, end, {});
  }

  std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const bridge::BlockSource::CancellationProbe& cancelled) override {
    return fetch_impl(start, end, cancelled);
  }

  void fetch_stream(std::uint64_t start, std::uint64_t end,
                    const bridge::BlockSource::CancellationProbe& cancelled,
                    const bridge::BlockSource::ChunkConsumer& consume) override {
    static_cast<void>(fetch_impl(start, end, cancelled, consume));
  }

  void cancel_pending() override {
    std::vector<std::shared_ptr<ActiveRequest>> active;
    {
      std::lock_guard lock(active_requests_mutex_);
      auto iterator = active_requests_.begin();
      while (iterator != active_requests_.end()) {
        if (auto request = iterator->lock()) {
          active.push_back(std::move(request));
          ++iterator;
        } else {
          iterator = active_requests_.erase(iterator);
        }
      }
    }
    for (const auto& request : active) request->cancel();
  }

  std::uint64_t remote_transfer_bytes() const {
    return remote_transfer_bytes_.load();
  }

  std::uint64_t remote_transfer_active_microseconds() const {
    return remote_transfer_active_microseconds_.load();
  }

  NetworkMetricsSnapshot metrics() const {
    std::uint64_t transfer_wall_clock_us = 0;
    std::uint64_t concurrent_wall_clock_us = 0;
    {
      std::lock_guard lock(transfer_wall_mutex_);
      transfer_wall_clock_us = transfer_wall_clock_us_;
      concurrent_wall_clock_us = concurrent_transfer_wall_clock_us_;
      const auto now = std::chrono::steady_clock::now();
      if (transfer_wall_started_.has_value()) {
        transfer_wall_clock_us += static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now - *transfer_wall_started_)
                .count());
      }
      if (concurrent_transfer_started_.has_value()) {
        concurrent_wall_clock_us += static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now - *concurrent_transfer_started_)
                .count());
      }
    }
    return {
        request_count_.load(),
        redirect_count_.load(),
        redirect_resolve_count_.load(),
        resolved_url_reuse_count_.load(),
        response_header_latency_us_total_.load(),
        response_body_active_us_total_.load(),
        remote_transfer_bytes_.load(),
        probe_body_bytes_.load(),
        active_request_peak_.load(),
        transfer_wall_clock_us,
        concurrent_wall_clock_us,
        request_lifecycle_->created.load(),
        request_lifecycle_->closed.load(),
        request_lifecycle_->live.load(),
        request_lifecycle_->peak.load(),
    };
  }

 private:
  void record_transfer_started(std::chrono::steady_clock::time_point now) {
    std::lock_guard lock(transfer_wall_mutex_);
    if (active_transfer_count_ == 0) transfer_wall_started_ = now;
    if (active_transfer_count_ == 1) concurrent_transfer_started_ = now;
    ++active_transfer_count_;
  }

  void record_transfer_finished(std::chrono::steady_clock::time_point now) {
    std::lock_guard lock(transfer_wall_mutex_);
    if (active_transfer_count_ == 0) return;
    if (active_transfer_count_ == 2 &&
        concurrent_transfer_started_.has_value()) {
      concurrent_transfer_wall_clock_us_ += static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::microseconds>(
              now - *concurrent_transfer_started_)
              .count());
      concurrent_transfer_started_.reset();
    }
    if (active_transfer_count_ == 1 && transfer_wall_started_.has_value()) {
      transfer_wall_clock_us_ += static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::microseconds>(
              now - *transfer_wall_started_)
              .count());
      transfer_wall_started_.reset();
    }
    --active_transfer_count_;
  }

  class ActiveRequest final {
   public:
    ActiveRequest(InternetHandle connection, HINTERNET handle,
                  std::shared_ptr<RequestLifecycleCounters> lifecycle)
        : connection_(std::move(connection)),
          handle_(handle),
          lifecycle_(std::move(lifecycle)) {
      if (handle_ == nullptr) {
        throw BridgeException("network_error",
                              "Unable to create the WebDAV request");
      }
      DWORD_PTR context = reinterpret_cast<DWORD_PTR>(this);
      if (WinHttpSetOption(handle_, WINHTTP_OPTION_CONTEXT_VALUE, &context,
                           sizeof(context)) == FALSE ||
          WinHttpSetStatusCallback(
              handle_, status_callback,
              WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS |
                  WINHTTP_CALLBACK_FLAG_HANDLES,
              0) == WINHTTP_INVALID_STATUS_CALLBACK) {
        WinHttpCloseHandle(handle_);
        handle_ = nullptr;
        throw BridgeException("network_error",
                              "Unable to initialize the WebDAV request");
      }
      callback_registered_ = true;
      lifecycle_->created.fetch_add(1);
      const auto live = lifecycle_->live.fetch_add(1) + 1;
      auto peak = lifecycle_->peak.load();
      while (live > peak &&
             !lifecycle_->peak.compare_exchange_weak(peak, live)) {
      }
    }

    ~ActiveRequest() {
      close_handle_now();
      if (callback_registered_) {
        std::unique_lock lock(operation_mutex_);
        handle_closed_.wait(lock, [this] { return handle_closed_notified_; });
      }
      lifecycle_->closed.fetch_add(1);
      lifecycle_->live.fetch_sub(1);
    }

    ActiveRequest(const ActiveRequest&) = delete;
    ActiveRequest& operator=(const ActiveRequest&) = delete;

    template <typename Callback>
    auto use(Callback callback) -> decltype(callback(HINTERNET{})) {
      std::lock_guard lock(handle_mutex_);
      if (handle_ == nullptr) throw bridge::FetchCancelled(0);
      return callback(handle_);
    }

    void send(const bridge::BlockSource::CancellationProbe& cancelled) {
      begin_operation(WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE);
      DWORD start_error = ERROR_SUCCESS;
      const BOOL started = use([this, &start_error](HINTERNET handle) {
        const BOOL result = WinHttpSendRequest(
            handle, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
            WINHTTP_NO_REQUEST_DATA, 0, 0,
            reinterpret_cast<DWORD_PTR>(this));
        if (result == FALSE) start_error = GetLastError();
        return result;
      });
      finish_start(started, start_error);
      wait_for_operation(cancelled, "The WebDAV request failed");
    }

    void receive(const bridge::BlockSource::CancellationProbe& cancelled) {
      begin_operation(WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE);
      DWORD start_error = ERROR_SUCCESS;
      const BOOL started = use([&start_error](HINTERNET handle) {
        const BOOL result = WinHttpReceiveResponse(handle, nullptr);
        if (result == FALSE) start_error = GetLastError();
        return result;
      });
      finish_start(started, start_error);
      wait_for_operation(cancelled, "The WebDAV request failed");
    }

    DWORD read(void* buffer, DWORD length,
               const bridge::BlockSource::CancellationProbe& cancelled) {
      // 读入成员缓冲，等待异步操作完成后再拷贝给调用方。
      if (length > read_buffer_.size()) {
        length = static_cast<DWORD>(read_buffer_.size());
      }
      begin_operation(WINHTTP_CALLBACK_STATUS_READ_COMPLETE);
      DWORD start_error = ERROR_SUCCESS;
      const BOOL started = use([this, length, &start_error](HINTERNET handle) {
        const BOOL result = WinHttpReadData(handle, read_buffer_.data(),
                                            length, nullptr);
        if (result == FALSE) start_error = GetLastError();
        return result;
      });
      finish_start(started, start_error);
      const DWORD bytes =
          wait_for_operation(cancelled, "The WebDAV response was interrupted");
      std::memcpy(buffer, read_buffer_.data(), bytes);
      return bytes;
    }

    void cancel() {
      {
        std::lock_guard lock(handle_mutex_);
        cancelled_ = true;
      }
      // use() 与本函数使用同一把锁，关闭只会发生在异步 API 调用返回后。
      close_handle_now();
    }

    bool cancelled() const {
      std::lock_guard lock(handle_mutex_);
      return cancelled_;
    }

   private:
    static void CALLBACK status_callback(HINTERNET, DWORD_PTR context,
                                         DWORD status, void* information,
                                         DWORD information_length) noexcept {
      if (context == 0) return;
      reinterpret_cast<ActiveRequest*>(context)->on_status(
          status, information, information_length);
    }

    void on_status(DWORD status, void* information,
                   DWORD information_length) noexcept {
      std::lock_guard lock(operation_mutex_);
      if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        handle_closed_notified_ = true;
        if (!operation_finished_) {
          operation_error_ = ERROR_WINHTTP_OPERATION_CANCELLED;
          operation_finished_ = true;
        }
        operation_ready_.notify_all();
        handle_closed_.notify_all();
        return;
      }
      if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) {
        const auto* result = static_cast<const WINHTTP_ASYNC_RESULT*>(information);
        operation_error_ = result == nullptr ? ERROR_WINHTTP_INTERNAL_ERROR
                                             : result->dwError;
        operation_finished_ = true;
        operation_ready_.notify_all();
        return;
      }
      if (status == expected_status_) {
        operation_bytes_ = information_length;
        operation_finished_ = true;
        operation_ready_.notify_all();
      }
    }

    void begin_operation(DWORD expected_status) {
      std::lock_guard lock(operation_mutex_);
      expected_status_ = expected_status;
      operation_error_ = ERROR_SUCCESS;
      operation_bytes_ = 0;
      operation_finished_ = false;
    }

    void finish_start(BOOL started, DWORD error) {
      if (started != FALSE) return;
      if (error == ERROR_IO_PENDING) return;
      std::lock_guard lock(operation_mutex_);
      operation_error_ = error;
      operation_finished_ = true;
      operation_ready_.notify_all();
    }

    DWORD wait_for_operation(
        const bridge::BlockSource::CancellationProbe& cancelled,
        const char* error_message) {
      std::unique_lock lock(operation_mutex_);
      while (!operation_finished_) {
        operation_ready_.wait_for(lock, std::chrono::milliseconds(10));
        if (operation_finished_) break;
        lock.unlock();
        if (this->cancelled() || (cancelled && cancelled())) {
          cancel();
          throw bridge::FetchCancelled(0);
        }
        lock.lock();
      }
      const DWORD error = operation_error_;
      const DWORD bytes = operation_bytes_;
      lock.unlock();
      if (error != ERROR_SUCCESS) {
        if (this->cancelled() || (cancelled && cancelled())) {
          throw bridge::FetchCancelled(0);
        }
        throw BridgeException("network_error", error_message);
      }
      return bytes;
    }

    void notify_handle_closed() {
      std::lock_guard lock(operation_mutex_);
      handle_closed_notified_ = true;
      if (!operation_finished_) {
        operation_error_ = ERROR_WINHTTP_OPERATION_CANCELLED;
        operation_finished_ = true;
      }
      operation_ready_.notify_all();
      handle_closed_.notify_all();
    }

   private:
    void close_handle_now() {
      HINTERNET handle = nullptr;
      {
        std::lock_guard lock(handle_mutex_);
        handle = std::exchange(handle_, nullptr);
      }
      if (handle != nullptr && WinHttpCloseHandle(handle) == FALSE) {
        notify_handle_closed();
      }
    }

    // request 必须先收到 HANDLE_CLOSING，随后才能释放父 connection。
    InternetHandle connection_;
    mutable std::mutex handle_mutex_;
    HINTERNET handle_ = nullptr;
    bool cancelled_ = false;
    bool callback_registered_ = false;
    std::shared_ptr<RequestLifecycleCounters> lifecycle_;
    std::array<std::uint8_t, 64U * 1024U> read_buffer_{};
    std::mutex operation_mutex_;
    std::condition_variable operation_ready_;
    std::condition_variable handle_closed_;
    DWORD expected_status_ = 0;
    DWORD operation_error_ = ERROR_SUCCESS;
    DWORD operation_bytes_ = 0;
    bool operation_finished_ = true;
    bool handle_closed_notified_ = false;
  };

  std::shared_ptr<ActiveRequest> track_request(InternetHandle connection,
                                               HINTERNET handle) {
    auto request = std::make_shared<ActiveRequest>(
        std::move(connection), handle, request_lifecycle_);
    std::lock_guard lock(active_requests_mutex_);
    active_requests_.erase(
        std::remove_if(active_requests_.begin(), active_requests_.end(),
                       [](const auto& item) { return item.expired(); }),
        active_requests_.end());
    active_requests_.push_back(request);
    return request;
  }

  std::vector<std::uint8_t> fetch_impl(
      std::uint64_t start, std::uint64_t end,
      const bridge::BlockSource::CancellationProbe& cancelled,
      const bridge::BlockSource::ChunkConsumer& consume = {}) {
    if (start > end || end >= size_) {
      throw BridgeException("internal_error", "Requested ISO range is invalid");
    }
    const auto transfer_started = std::chrono::steady_clock::now();
    record_transfer_started(transfer_started);
    ScopeExit transfer_finished([this] {
      record_transfer_finished(std::chrono::steady_clock::now());
    });
    HttpResponse response;
    try {
      response = request("GET", start, end, validator_, cancelled, consume);
    } catch (...) {
      remote_transfer_active_microseconds_.fetch_add(
          static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::microseconds>(
                  std::chrono::steady_clock::now() - transfer_started)
                  .count()));
      throw;
    }
    remote_transfer_active_microseconds_.fetch_add(
        static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - transfer_started)
                .count()));
    if (!consume) {
      validate_range_headers(response, start, end);
      if (response.body.size() != static_cast<std::size_t>(end - start + 1)) {
        throw BridgeException("network_error", "The ISO range body is incomplete", response.status);
      }
    }
    return response.body;
  }

  void validate_range_headers(const HttpResponse& response,
                              std::uint64_t start, std::uint64_t end) const {
    if (response.status == HTTP_STATUS_OK) {
      throw BridgeException("remote_changed",
                            "The remote ISO changed during playback",
                            response.status);
    }
    if (response.status != HTTP_STATUS_PARTIAL_CONTENT) {
      throw BridgeException("network_error", "The ISO range request failed",
                            response.status);
    }
    const auto content_range = response.content_range.has_value()
                                   ? bridge::parse_content_range(*response.content_range)
                                   : std::nullopt;
    if (!content_range.has_value() || content_range->start != start ||
        content_range->end != end || content_range->total != size_) {
      throw BridgeException("remote_changed", "The remote ISO range changed",
                            response.status);
    }
    const std::uint64_t expected = end - start + 1;
    if (response.content_length != expected) {
      throw BridgeException("network_error", "The ISO range body is incomplete",
                            response.status);
    }
    verify_validator(response);
  }

  void probe() {
    std::optional<std::uint64_t> head_length;
    std::optional<std::wstring> head_etag;
    std::optional<std::wstring> head_last_modified;
    try {
      const HttpResponse head = request("HEAD", std::nullopt, std::nullopt, {});
      if (head.status >= 200 && head.status < 300) {
        head_length = head.content_length;
        head_etag = strong_etag(head.etag);
        head_last_modified = head.last_modified;
      }
    } catch (const BridgeException&) {
      // HEAD 只提供提示，Range GET 才是能力判定依据。
    }

    const HttpResponse probe = request("GET", 0, 0, {});
    if (probe.status != HTTP_STATUS_PARTIAL_CONTENT) {
      throw BridgeException("range_unsupported", "The WebDAV source does not support byte ranges");
    }
    const auto range = probe.content_range.has_value()
                           ? bridge::parse_content_range(*probe.content_range)
                           : std::nullopt;
    if (!range.has_value() || range->start != 0 || range->end != 0 ||
        probe.content_length != 1 || probe.body.size() != 1) {
      throw BridgeException("range_unsupported", "The WebDAV Range response is invalid");
    }
    if (head_length.has_value() && *head_length != range->total) {
      throw BridgeException("length_unavailable", "The ISO length is inconsistent");
    }
    size_ = range->total;
    const auto response_etag = strong_etag(probe.etag);
    if (response_etag.has_value()) {
      validator_ = *response_etag;
      validator_is_etag_ = true;
    } else if (head_etag.has_value()) {
      validator_ = *head_etag;
      validator_is_etag_ = true;
    } else if (probe.last_modified.has_value()) {
      validator_ = *probe.last_modified;
    } else if (head_last_modified.has_value()) {
      validator_ = *head_last_modified;
    }
    if (validator_.empty()) {
      throw BridgeException(
          "range_unsupported",
          "The WebDAV source does not provide a stable ISO validator");
    }
  }

  static std::optional<std::wstring> strong_etag(
      const std::optional<std::wstring>& value) {
    if (!value.has_value() || value->empty()) return std::nullopt;
    const std::wstring lower = lowercase_wide(*value);
    if (lower.rfind(L"w/", 0) == 0) return std::nullopt;
    return value;
  }

  void verify_validator(const HttpResponse& response) const {
    if (validator_.empty()) return;
    if (validator_is_etag_) {
      const auto response_etag = strong_etag(response.etag);
      if (!response_etag.has_value() || *response_etag != validator_) {
        throw BridgeException("remote_changed", "The remote ISO validator changed");
      }
    } else if (!response.last_modified.has_value() ||
               *response.last_modified != validator_) {
      throw BridgeException("remote_changed", "The remote ISO validator changed");
    }
  }

  HttpResponse request(std::string_view method,
                       std::optional<std::uint64_t> range_start,
                       std::optional<std::uint64_t> range_end,
                       const std::wstring& if_range,
                       const bridge::BlockSource::CancellationProbe& cancelled = {},
                       const bridge::BlockSource::ChunkConsumer& consume = {}) {
    std::wstring current;
    {
      std::lock_guard lock(url_mutex_);
      current = current_url_;
    }
    if (current != initial_url_) resolved_url_reuse_count_.fetch_add(1);
    bool redirected = false;
    for (int redirect = 0; redirect <= kMaximumRedirects; ++redirect) {
      if (cancelled && cancelled()) {
        throw bridge::FetchCancelled(0);
      }
      request_count_.fetch_add(1);
      const auto active = active_request_count_.fetch_add(1) + 1;
      auto peak = active_request_peak_.load();
      while (active > peak &&
             !active_request_peak_.compare_exchange_weak(peak, active)) {
      }
      ScopeExit active_request_finished(
          [this] { active_request_count_.fetch_sub(1); });
      const auto header_started = std::chrono::steady_clock::now();
      const ParsedUrl parsed = parse_url(current);
      InternetHandle connection(
          WinHttpConnect(session_.get(), parsed.host.c_str(), parsed.port, 0));
      if (!connection) {
        throw BridgeException("network_error", "Unable to connect to the WebDAV source");
      }
      const std::wstring method_wide = wide_from_utf8(method);
      const HINTERNET raw_request = WinHttpOpenRequest(
          connection.get(), method_wide.c_str(), parsed.path.c_str(), nullptr,
          WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
          parsed.secure ? WINHTTP_FLAG_SECURE : 0);
      auto request_handle =
          track_request(std::move(connection), raw_request);
      DWORD redirect_policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
      request_handle->use([&redirect_policy](HINTERNET handle) {
        return WinHttpSetOption(handle, WINHTTP_OPTION_REDIRECT_POLICY,
                                &redirect_policy, sizeof(redirect_policy));
      });

      std::wstring headers = L"Accept-Encoding: identity\r\n";
      if (!authorization_.empty() && same_origin(parsed, auth_origin_)) {
        headers += L"Authorization: " + authorization_ + L"\r\n";
      }
      if (range_start.has_value() && range_end.has_value()) {
        headers += L"Range: bytes=" + std::to_wstring(*range_start) + L"-" +
                   std::to_wstring(*range_end) + L"\r\n";
      }
      if (!if_range.empty()) headers += L"If-Range: " + if_range + L"\r\n";
      if (request_handle->use([&headers](HINTERNET handle) {
            return WinHttpAddRequestHeaders(
                handle, headers.c_str(), static_cast<DWORD>(-1L),
                WINHTTP_ADDREQ_FLAG_ADD);
          }) == FALSE) {
        throw BridgeException("network_error", "The WebDAV request failed");
      }
      request_handle->send(cancelled);
      request_handle->receive(cancelled);
      response_header_latency_us_total_.fetch_add(
          static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::microseconds>(
                  std::chrono::steady_clock::now() - header_started)
                  .count()));
      if (cancelled && cancelled()) {
        throw bridge::FetchCancelled(0);
      }

      DWORD status = 0;
      DWORD status_size = sizeof(status);
      if (request_handle->use([&status, &status_size](HINTERNET handle) {
            return WinHttpQueryHeaders(
                handle,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
                WINHTTP_NO_HEADER_INDEX);
          }) == FALSE) {
        throw BridgeException("network_error", "The WebDAV response has no status");
      }
      if (status >= 300 && status < 400) {
        redirect_count_.fetch_add(1);
        redirected = true;
        if (redirect == kMaximumRedirects) {
          throw BridgeException("network_error", "The WebDAV redirect limit was exceeded");
        }
        const auto location = request_handle->use([](HINTERNET handle) {
          return query_header(handle, WINHTTP_QUERY_LOCATION);
        });
        if (!location.has_value() || location->empty()) {
          throw BridgeException("network_error", "The WebDAV redirect has no location");
        }
        current = combine_url(current, *location);
        continue;
      }

      HttpResponse response;
      response.status = status;
      response.effective_url = current;
      const auto content_length = request_handle->use([](HINTERNET handle) {
        return query_header(handle, WINHTTP_QUERY_CONTENT_LENGTH);
      });
      if (content_length.has_value()) {
        response.content_length = parse_uint64(*content_length);
      }
      const auto content_range = request_handle->use([](HINTERNET handle) {
        return query_header(handle, WINHTTP_QUERY_CUSTOM, L"Content-Range");
      });
      if (content_range.has_value()) {
        response.content_range = utf8_from_wide(*content_range);
      }
      response.etag = request_handle->use([](HINTERNET handle) {
        return query_header(handle, WINHTTP_QUERY_CUSTOM, L"ETag");
      });
      response.last_modified = request_handle->use([](HINTERNET handle) {
        return query_header(handle, WINHTTP_QUERY_LAST_MODIFIED);
      });

      if (method != "HEAD") {
        const std::uint64_t expected =
            range_start.has_value() && range_end.has_value()
                ? *range_end - *range_start + 1
                : response.content_length.value_or(0);
        if (expected > kMaximumIsoRangeBytes) {
          throw BridgeException("network_error", "The WebDAV response is too large");
        }
        if (consume) {
          validate_range_headers(response, *range_start, *range_end);
        } else {
          response.body.reserve(static_cast<std::size_t>(expected));
        }
        std::size_t body_bytes = 0;
        std::array<std::uint8_t, 64U * 1024U> buffer{};
        const auto body_started = std::chrono::steady_clock::now();
        ScopeExit body_finished([this, body_started] {
          response_body_active_us_total_.fetch_add(
              static_cast<std::uint64_t>(
                  std::chrono::duration_cast<std::chrono::microseconds>(
                      std::chrono::steady_clock::now() - body_started)
                      .count()));
        });
        while (true) {
          if (cancelled && cancelled()) {
            throw bridge::FetchCancelled(body_bytes);
          }
          DWORD received = 0;
          try {
            received = request_handle->read(
                buffer.data(), static_cast<DWORD>(buffer.size()), cancelled);
          } catch (const bridge::FetchCancelled&) {
            throw bridge::FetchCancelled(body_bytes);
          }
          if (received == 0) break;
          if (!if_range.empty()) {
            remote_transfer_bytes_.fetch_add(received);
          } else {
            probe_body_bytes_.fetch_add(received);
          }
          if (cancelled && cancelled()) {
            throw bridge::FetchCancelled(body_bytes + received);
          }
          if (body_bytes + received > kMaximumIsoRangeBytes ||
              (consume && body_bytes + received > expected)) {
            throw BridgeException("network_error", "The WebDAV response is too large");
          }
          body_bytes += received;
          if (consume) {
            consume(buffer.data(), received);
          } else {
            response.body.insert(response.body.end(), buffer.begin(),
                                 buffer.begin() + received);
          }
        }
        if (consume && body_bytes != expected) {
          throw BridgeException("network_error", "The ISO range body is incomplete", response.status);
        }
      }
      {
        std::lock_guard lock(url_mutex_);
        current_url_ = current;
      }
      if (redirected) redirect_resolve_count_.fetch_add(1);
      return response;
    }
    throw BridgeException("network_error", "The WebDAV request failed");
  }

  InternetHandle session_;
  ParsedUrl auth_origin_;
  std::wstring authorization_;
  std::wstring validator_;
  bool validator_is_etag_ = false;
  std::uint64_t size_ = 0;
  const std::wstring initial_url_;
  std::mutex url_mutex_;
  std::wstring current_url_;
  std::mutex active_requests_mutex_;
  std::vector<std::weak_ptr<ActiveRequest>> active_requests_;
  const std::shared_ptr<RequestLifecycleCounters> request_lifecycle_ =
      std::make_shared<RequestLifecycleCounters>();
  std::atomic<std::uint64_t> remote_transfer_bytes_ = 0;
  std::atomic<std::uint64_t> remote_transfer_active_microseconds_ = 0;
  std::atomic<std::uint64_t> request_count_ = 0;
  std::atomic<std::uint64_t> redirect_count_ = 0;
  std::atomic<std::uint64_t> redirect_resolve_count_ = 0;
  std::atomic<std::uint64_t> resolved_url_reuse_count_ = 0;
  std::atomic<std::uint64_t> response_header_latency_us_total_ = 0;
  std::atomic<std::uint64_t> response_body_active_us_total_ = 0;
  std::atomic<std::uint64_t> probe_body_bytes_ = 0;
  std::atomic<std::uint64_t> active_request_count_ = 0;
  std::atomic<std::uint64_t> active_request_peak_ = 0;
  mutable std::mutex transfer_wall_mutex_;
  std::uint64_t active_transfer_count_ = 0;
  std::uint64_t transfer_wall_clock_us_ = 0;
  std::uint64_t concurrent_transfer_wall_clock_us_ = 0;
  std::optional<std::chrono::steady_clock::time_point> transfer_wall_started_;
  std::optional<std::chrono::steady_clock::time_point>
      concurrent_transfer_started_;
};

struct DiscReadContext {
  bridge::BlockCache* cache = nullptr;
  std::size_t read_ahead_blocks = 0;
  std::uint64_t playback_generation = 0;
  std::exception_ptr read_error;

  void bind_playback(std::size_t read_ahead,
                     std::uint64_t generation) {
    if (playback_generation != generation) read_error = {};
    read_ahead_blocks = read_ahead;
    playback_generation = generation;
  }
};

struct MediaGetTiming {
  std::uint64_t sequence = 0;
  std::uint64_t generation = 0;
  std::uint64_t playlist = 0;
  std::uint64_t request_byte = 0;
  std::uint64_t started_us = 0;
  std::int64_t context_ready_us = -1;
  std::int64_t seek_ready_us = -1;
  std::int64_t headers_ready_us = -1;
  std::int64_t first_body_us = -1;
  std::uint64_t discard_bytes = 0;
  bool superseded = false;
};

struct BlurayMetricsSnapshot {
  std::uint64_t context_create_count = 0;
  std::uint64_t context_create_us_total = 0;
  std::uint64_t title_enumeration_us = 0;
  std::uint64_t media_get_count = 0;
  std::uint64_t persistent_context_reuse_count = 0;
  std::uint64_t time_seek_redirect_count = 0;
  std::uint64_t maximum_time_seek_byte_delta = 0;
  std::uint64_t last_time_seek_request_byte = 0;
  std::uint64_t last_time_seek_target_ticks = 0;
  std::uint64_t last_time_seek_title_byte = 0;
  std::uint64_t media_failure_count = 0;
  std::uint64_t last_media_failure_sequence = 0;
  std::uint64_t last_media_failure_generation = 0;
  DWORD last_media_failure_http_status = 0;
  std::uint64_t terminal_rejected_media_get_count = 0;
  bool structure_cache_hit = false;
  std::vector<MediaGetTiming> media_get_timings;
};

class BlurayMetrics final {
 public:
  BlurayMetrics() { timings_.reserve(128); }
  void record_context_create(std::uint64_t microseconds) {
    context_create_count_.fetch_add(1);
    context_create_us_total_.fetch_add(microseconds);
  }
  void record_title_enumeration(std::uint64_t microseconds) {
    title_enumeration_us_.fetch_add(microseconds);
  }
  void record_media_get() { media_get_count_.fetch_add(1); }
  void record_persistent_context_reuse() {
    persistent_context_reuse_count_.fetch_add(1);
  }
  void record_time_seek_redirect(std::uint64_t request_byte,
                                 std::uint64_t target_ticks,
                                 std::uint64_t title_byte) {
    time_seek_redirect_count_.fetch_add(1);
    last_time_seek_request_byte_.store(request_byte);
    last_time_seek_target_ticks_.store(target_ticks);
    last_time_seek_title_byte_.store(title_byte);
    const std::uint64_t delta = request_byte > title_byte
                                    ? request_byte - title_byte
                                    : title_byte - request_byte;
    auto maximum = maximum_time_seek_byte_delta_.load();
    while (delta > maximum &&
           !maximum_time_seek_byte_delta_.compare_exchange_weak(maximum,
                                                                 delta)) {
    }
  }
  void record_media_failure(std::uint64_t request_sequence,
                            std::uint64_t playback_generation,
                            DWORD http_status) {
    media_failure_count_.fetch_add(1);
    last_media_failure_sequence_.store(request_sequence);
    last_media_failure_generation_.store(playback_generation);
    last_media_failure_http_status_.store(http_status);
  }
  void record_terminal_rejected_media_get() {
    terminal_rejected_media_get_count_.fetch_add(1);
  }
  void record_structure_cache_hit() { structure_cache_hit_.store(true); }
  void record_media_timing(const MediaGetTiming& timing) {
    std::lock_guard lock(timings_mutex_);
    // 仅保留最近 128 个 GET，不保存 URL 或凭据。
    if (timings_.size() == 128) timings_.erase(timings_.begin());
    timings_.push_back(timing);
  }

  BlurayMetricsSnapshot snapshot() const {
    std::lock_guard lock(timings_mutex_);
    return {
        context_create_count_.load(),
        context_create_us_total_.load(),
        title_enumeration_us_.load(),
        media_get_count_.load(),
        persistent_context_reuse_count_.load(),
        time_seek_redirect_count_.load(),
        maximum_time_seek_byte_delta_.load(),
        last_time_seek_request_byte_.load(),
        last_time_seek_target_ticks_.load(),
        last_time_seek_title_byte_.load(),
        media_failure_count_.load(),
        last_media_failure_sequence_.load(),
        last_media_failure_generation_.load(),
        last_media_failure_http_status_.load(),
        terminal_rejected_media_get_count_.load(),
        structure_cache_hit_.load(),
        timings_,
    };
  }

 private:
  mutable std::mutex timings_mutex_;
  std::vector<MediaGetTiming> timings_;
  std::atomic<std::uint64_t> context_create_count_ = 0;
  std::atomic<std::uint64_t> context_create_us_total_ = 0;
  std::atomic<std::uint64_t> title_enumeration_us_ = 0;
  std::atomic<std::uint64_t> media_get_count_ = 0;
  std::atomic<std::uint64_t> persistent_context_reuse_count_ = 0;
  std::atomic<std::uint64_t> time_seek_redirect_count_ = 0;
  std::atomic<std::uint64_t> maximum_time_seek_byte_delta_ = 0;
  std::atomic<std::uint64_t> last_time_seek_request_byte_ = 0;
  std::atomic<std::uint64_t> last_time_seek_target_ticks_ = 0;
  std::atomic<std::uint64_t> last_time_seek_title_byte_ = 0;
  std::atomic<std::uint64_t> media_failure_count_ = 0;
  std::atomic<std::uint64_t> last_media_failure_sequence_ = 0;
  std::atomic<std::uint64_t> last_media_failure_generation_ = 0;
  std::atomic<DWORD> last_media_failure_http_status_ = 0;
  std::atomic<std::uint64_t> terminal_rejected_media_get_count_ = 0;
  std::atomic<bool> structure_cache_hit_ = false;
};

int read_disc_blocks(void* opaque, void* destination, int lba,
                     int number_of_blocks) {
  if (opaque == nullptr || destination == nullptr || lba < 0 ||
      number_of_blocks <= 0) {
    return 0;
  }
  auto* context = static_cast<DiscReadContext*>(opaque);
  constexpr std::uint64_t kSectorSize = 2048;
  const std::uint64_t offset = static_cast<std::uint64_t>(lba) * kSectorSize;
  const std::uint64_t requested =
      static_cast<std::uint64_t>(number_of_blocks) * kSectorSize;
  if (requested > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
    return 0;
  }
  try {
    const std::size_t bytes = context->cache->read(
        offset, static_cast<std::uint8_t*>(destination),
        static_cast<std::size_t>(requested), context->read_ahead_blocks,
        context->playback_generation);
    return static_cast<int>(bytes / kSectorSize);
  } catch (...) {
    if (!context->read_error) context->read_error = std::current_exception();
    return 0;
  }
}

class LibblurayApi final {
 public:
  explicit LibblurayApi(const std::filesystem::path& directory) {
    const std::filesystem::path dll = directory / L"bluray-4.dll";
    module_ = LoadLibraryExW(
        dll.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
            LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module_ == nullptr) {
      throw BridgeException("libbluray_unavailable", "libbluray 1.5.1 is unavailable");
    }
    load(bd_get_version_, "bd_get_version");
    load(bd_init_, "bd_init");
    load(bd_open_stream_, "bd_open_stream");
    load(bd_close_, "bd_close");
    load(bd_get_disc_info_, "bd_get_disc_info");
    load(bd_get_titles_, "bd_get_titles");
    load(bd_get_title_info_, "bd_get_title_info");
    load(bd_free_title_info_, "bd_free_title_info");
    load(bd_select_playlist_, "bd_select_playlist");
    load(bd_read_, "bd_read");
    load(bd_seek_, "bd_seek");
    load(bd_get_title_size_, "bd_get_title_size");
    int major = 0;
    int minor = 0;
    int micro = 0;
    bd_get_version_(&major, &minor, &micro);
    if (major != 1 || minor != 5 || micro != 1) {
      throw BridgeException("libbluray_unavailable", "Unexpected libbluray version");
    }
  }

  ~LibblurayApi() {
    if (module_ != nullptr) FreeLibrary(module_);
  }
  LibblurayApi(const LibblurayApi&) = delete;
  LibblurayApi& operator=(const LibblurayApi&) = delete;

  class Disc final {
   public:
    Disc(const LibblurayApi& api, bridge::BlockCache& cache,
         BlurayMetrics& metrics, std::uint64_t playback_generation = 0)
        : api_(api) {
      const auto started = std::chrono::steady_clock::now();
      ScopeExit record_create([&metrics, started] {
        metrics.record_context_create(static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - started)
                .count()));
      });
      context_.cache = &cache;
      context_.playback_generation = playback_generation;
      std::lock_guard lifecycle_lock(api_.lifecycle_mutex_);
      value_ = api_.bd_init_();
      if (value_ == nullptr ||
          api_.bd_open_stream_(value_, &context_, read_disc_blocks) == 0) {
        if (value_ != nullptr) api_.bd_close_(value_);
        value_ = nullptr;
        rethrow_read_error();
        throw BridgeException("invalid_disc", "The remote ISO is not a readable Blu-ray disc");
      }
    }
    ~Disc() {
      if (value_ != nullptr) {
        std::lock_guard lifecycle_lock(api_.lifecycle_mutex_);
        api_.bd_close_(value_);
      }
    }
    Disc(const Disc&) = delete;
    Disc& operator=(const Disc&) = delete;

    BLURAY* get() const { return value_; }

    void rethrow_read_error() {
      if (!context_.read_error) return;
      const auto error = std::exchange(context_.read_error, {});
      std::rethrow_exception(error);
    }

    void set_playback_read_ahead(std::size_t value,
                                 std::uint64_t playback_generation) {
      context_.bind_playback(value, playback_generation);
    }

   private:
    const LibblurayApi& api_;
    DiscReadContext context_;
    BLURAY* value_ = nullptr;
  };

  std::vector<TitleInfo> enumerate(bridge::BlockCache& cache,
                                   BlurayMetrics& metrics) const {
    const auto started = std::chrono::steady_clock::now();
    ScopeExit record_enumeration([&metrics, started] {
      metrics.record_title_enumeration(static_cast<std::uint64_t>(
          std::chrono::duration_cast<std::chrono::microseconds>(
              std::chrono::steady_clock::now() - started)
              .count()));
    });
    Disc disc(*this, cache, metrics);
    const BLURAY_DISC_INFO* info = bd_get_disc_info_(disc.get());
    if (info == nullptr || info->bluray_detected == 0) {
      disc.rethrow_read_error();
      throw BridgeException("invalid_disc", "No Blu-ray structure was found in the ISO");
    }
    if (info->aacs_detected != 0 || info->bdplus_detected != 0) {
      throw BridgeException("encrypted_disc", "Encrypted AACS or BD+ discs are not supported");
    }
    const std::uint32_t count = bd_get_titles_(disc.get(), TITLES_ALL, 0);
    std::vector<TitleInfo> result;
    std::map<std::uint32_t, bool> seen;
    for (std::uint32_t index = 0; index < count; ++index) {
      BLURAY_TITLE_INFO* title = bd_get_title_info_(disc.get(), index, 0);
      if (title == nullptr) {
        disc.rethrow_read_error();
        continue;
      }
      std::unique_ptr<BLURAY_TITLE_INFO, std::function<void(BLURAY_TITLE_INFO*)>>
          owned(title, [this](BLURAY_TITLE_INFO* value) {
            bd_free_title_info_(value);
          });
      if (title->duration == 0 || title->playlist > 99999U ||
          !seen.emplace(title->playlist, true).second) {
        continue;
      }
      if (bd_select_playlist_(disc.get(), title->playlist) == 0) {
        disc.rethrow_read_error();
        continue;
      }
      TitleInfo converted;
      converted.title_index = title->idx;
      converted.playlist = title->playlist;
      converted.duration_milliseconds = title->duration / 90U;
      converted.size = bd_get_title_size_(disc.get());
      if (converted.size == 0) {
        disc.rethrow_read_error();
        continue;
      }
      // 为开头解码时间戳预留空间，避免 B 帧 DTS 下溢到 33 位高端。
      constexpr std::int64_t kTimelineEpoch90kHz = 60LL * 90000LL;
      std::uint64_t clip_begin = 0;
      converted.clips.reserve(title->clip_count);
      for (std::uint32_t clip_index = 0; clip_index < title->clip_count;
           ++clip_index) {
        const BLURAY_CLIP_INFO& clip = title->clips[clip_index];
        const std::uint64_t clip_bytes =
            static_cast<std::uint64_t>(clip.pkt_count) * bridge::kM2tsPacketSize;
        bridge::M2tsClipTimeline timeline;
        timeline.begin_byte = clip_begin;
        timeline.end_byte = clip_begin + clip_bytes;
        timeline.timestamp_offset_90khz =
            kTimelineEpoch90kHz + static_cast<std::int64_t>(clip.start_time) -
            static_cast<std::int64_t>(clip.in_time);
        converted.clips.push_back(timeline);
        clip_begin = timeline.end_byte;
      }
      if (converted.clips.empty() || clip_begin != converted.size) continue;
      converted.chapters.reserve(title->chapter_count);
      for (std::uint32_t chapter_index = 0;
           chapter_index < title->chapter_count; ++chapter_index) {
        const BLURAY_TITLE_CHAPTER& chapter = title->chapters[chapter_index];
        ChapterInfo converted_chapter;
        converted_chapter.start_milliseconds = chapter.start / 90U;
        converted_chapter.duration_milliseconds = chapter.duration / 90U;
        if (chapter.chapter_name != nullptr) {
          converted_chapter.name = chapter.chapter_name;
        }
        converted.chapters.push_back(std::move(converted_chapter));
      }
      result.push_back(std::move(converted));
    }
    std::sort(result.begin(), result.end(),
              [](const TitleInfo& first, const TitleInfo& second) {
                return first.title_index < second.title_index;
              });
    disc.rethrow_read_error();
    if (result.empty()) {
      throw BridgeException("invalid_disc", "No playable Blu-ray title was found");
    }
    return result;
  }

  void require_hdmv(bridge::BlockCache& cache, BlurayMetrics& metrics) const {
    for (const char* symbol : {"bd_play", "bd_read_ext", "bd_menu_call",
                               "bd_register_overlay_proc", "bd_user_input"}) {
      if (GetProcAddress(module_, symbol) == nullptr) {
        throw BridgeException("menu_unavailable", "HDMV API is incomplete");
      }
    }
    Disc disc(*this, cache, metrics);
    const auto* info = bd_get_disc_info_(disc.get());
    disc.rethrow_read_error();
    if (info == nullptr || !info->bluray_detected) {
      throw BridgeException("menu_unknown", "Unable to identify disc navigation");
    }
    if (info->aacs_detected || info->bdplus_detected) {
      throw BridgeException("encrypted_disc", "Encrypted discs are not supported");
    }
    if (info->bdj_detected || info->num_bdj_titles != 0) {
      throw BridgeException("bdj_unsupported", "Only HDMV menus are supported");
    }
    if (!info->first_play_supported || !info->top_menu_supported ||
        info->num_hdmv_titles == 0 || info->num_unsupported_titles != 0) {
      throw BridgeException("menu_unknown", "No supported HDMV menu entry");
    }
  }

  std::unique_ptr<Disc> open_title(bridge::BlockCache& cache,
                                   std::uint32_t playlist,
                                   BlurayMetrics& metrics,
                                   std::uint64_t playback_generation) const {
    auto disc = std::make_unique<Disc>(*this, cache, metrics,
                                       playback_generation);
    if (bd_select_playlist_(disc->get(), playlist) == 0) {
      disc->rethrow_read_error();
      throw BridgeException("invalid_disc", "The Blu-ray playlist could not be selected");
    }
    return disc;
  }

  std::uint64_t title_size(BLURAY* disc) const {
    return bd_get_title_size_(disc);
  }
  std::int64_t seek(BLURAY* disc, std::uint64_t position) const {
    return bd_seek_(disc, position);
  }
  int read(BLURAY* disc, std::uint8_t* destination, int length) const {
    return bd_read_(disc, destination, length);
  }

 private:
  template <typename Function>
  void load(Function& destination, const char* name) {
    destination = reinterpret_cast<Function>(GetProcAddress(module_, name));
    if (destination == nullptr) {
      throw BridgeException("libbluray_unavailable", "libbluray API is incomplete");
    }
  }

  using GetVersion = void (*)(int*, int*, int*);
  using Init = BLURAY* (*)();
  using OpenStream = int (*)(BLURAY*, void*, int (*)(void*, void*, int, int));
  using Close = void (*)(BLURAY*);
  using GetDiscInfo = const BLURAY_DISC_INFO* (*)(BLURAY*);
  using GetTitles = std::uint32_t (*)(BLURAY*, std::uint8_t, std::uint32_t);
  using GetTitleInfo = BLURAY_TITLE_INFO* (*)(BLURAY*, std::uint32_t, unsigned);
  using FreeTitleInfo = void (*)(BLURAY_TITLE_INFO*);
  using SelectPlaylist = int (*)(BLURAY*, std::uint32_t);
  using Read = int (*)(BLURAY*, unsigned char*, int);
  using Seek = std::int64_t (*)(BLURAY*, std::uint64_t);
  using GetTitleSize = std::uint64_t (*)(BLURAY*);

  HMODULE module_ = nullptr;
  GetVersion bd_get_version_ = nullptr;
  Init bd_init_ = nullptr;
  OpenStream bd_open_stream_ = nullptr;
  Close bd_close_ = nullptr;
  GetDiscInfo bd_get_disc_info_ = nullptr;
  GetTitles bd_get_titles_ = nullptr;
  GetTitleInfo bd_get_title_info_ = nullptr;
  FreeTitleInfo bd_free_title_info_ = nullptr;
  SelectPlaylist bd_select_playlist_ = nullptr;
  Read bd_read_ = nullptr;
  Seek bd_seek_ = nullptr;
  GetTitleSize bd_get_title_size_ = nullptr;
  // bd_init/bd_close 会进入 libbluray 的全局注册状态；切集时旧实例的
  // bd_close 与新实例的 bd_init 在不同线程并发，必须串行化。
  mutable std::mutex lifecycle_mutex_;
};

std::string random_token() {
  std::array<std::uint8_t, 16> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    throw BridgeException("internal_error", "Unable to create a session token");
  }
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const std::uint8_t byte : bytes) {
    output << std::setw(2) << static_cast<unsigned>(byte);
  }
  return output.str();
}

bool send_all(SOCKET socket, const char* data, std::size_t length) {
  while (length > 0) {
    const int chunk = static_cast<int>(std::min<std::size_t>(
        length, static_cast<std::size_t>(std::numeric_limits<int>::max())));
    const int sent = send(socket, data, chunk, 0);
    if (sent <= 0) return false;
    data += sent;
    length -= static_cast<std::size_t>(sent);
  }
  return true;
}

void send_http_error(SOCKET socket, int status, std::string_view reason,
                     std::optional<std::uint64_t> resource_size = std::nullopt) {
  std::ostringstream response;
  response << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
           << "Connection: close\r\n"
           << "Content-Length: 0\r\n";
  if (resource_size.has_value()) {
    response << "Content-Range: bytes */" << *resource_size << "\r\n";
  }
  response << "\r\n";
  const std::string text = response.str();
  send_all(socket, text.data(), text.size());
}

template <typename Context>
class PersistentContextSlot final {
 public:
  class Lease final {
   public:
    Lease(PersistentContextSlot& owner, bool reused)
        : owner_(&owner), reused_(reused) {}
    ~Lease() {
      if (owner_ != nullptr) owner_->release(reusable_);
    }
    Lease(const Lease&) = delete;
    Lease& operator=(const Lease&) = delete;
    Lease(Lease&& other) noexcept
        : owner_(std::exchange(other.owner_, nullptr)),
          reused_(other.reused_),
          reusable_(other.reusable_) {}

    Context* operator->() const { return owner_->context_.get(); }
    bool reused() const { return reused_; }
    void invalidate() { reusable_ = false; }

   private:
    PersistentContextSlot* owner_;
    bool reused_ = false;
    bool reusable_ = true;
  };

  template <typename Factory>
  std::optional<Lease> acquire(
      std::uint32_t key,
      std::chrono::milliseconds timeout,
      const std::function<bool()>& cancelled, Factory factory) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    std::unique_ptr<Context> previous;
    bool reused = false;
    {
      std::unique_lock lock(mutex_);
      while (leased_) {
        if (cancelled()) return std::nullopt;
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) return std::nullopt;
        ready_.wait_for(
            lock, std::min(std::chrono::milliseconds(50),
                           std::chrono::duration_cast<std::chrono::milliseconds>(
                               deadline - now)));
      }
      if (cancelled()) return std::nullopt;
      leased_ = true;
      reused = context_ != nullptr && key_.has_value() && *key_ == key;
      if (!reused) {
        previous = std::move(context_);
        key_.reset();
      }
    }
    previous.reset();

    if (!reused) {
      try {
        auto created = factory();
        std::lock_guard lock(mutex_);
        context_ = std::move(created);
        key_ = key;
      } catch (...) {
        finish_release();
        throw;
      }
    }
    return std::optional<Lease>(Lease(*this, reused));
  }

 private:
  void release(bool reusable) {
    std::unique_ptr<Context> discarded;
    if (!reusable) {
      std::lock_guard lock(mutex_);
      discarded = std::move(context_);
      key_.reset();
    }
    discarded.reset();
    finish_release();
  }

  void finish_release() {
    {
      std::lock_guard lock(mutex_);
      leased_ = false;
    }
    ready_.notify_all();
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::unique_ptr<Context> context_;
  std::optional<std::uint32_t> key_;
  bool leased_ = false;
};

void configure_loopback_client_socket(SOCKET socket) {
  const DWORD receive_timeout_ms = 10000;
  setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&receive_timeout_ms),
             sizeof(receive_timeout_ms));
  // MPV 暂停读取是正常缓存背压，媒体响应不能因此被截断。
}

void abort_loopback_response(SOCKET socket) {
  linger option{};
  option.l_onoff = 1;
  option.l_linger = 0;
  setsockopt(socket, SOL_SOCKET, SO_LINGER,
             reinterpret_cast<const char*>(&option), sizeof(option));
}

void fail_loopback_response(SOCKET socket, bool response_headers_sent) {
  if (response_headers_sent) {
    abort_loopback_response(socket);
    return;
  }
  send_http_error(socket, 500, "Internal Server Error");
}

class MediaSocketRegistry final {
 public:
  class Lease final {
   public:
    Lease(MediaSocketRegistry& owner, std::uint64_t generation)
        : owner_(&owner), generation_(generation) {}
    ~Lease() {
      if (owner_ != nullptr) owner_->release(generation_);
    }
    Lease(const Lease&) = delete;
    Lease& operator=(const Lease&) = delete;
    Lease(Lease&& other) noexcept
        : owner_(std::exchange(other.owner_, nullptr)),
          generation_(other.generation_) {}

   private:
    MediaSocketRegistry* owner_;
    std::uint64_t generation_;
  };

  std::optional<Lease> activate(SOCKET socket,
                                std::uint64_t request_sequence) {
    std::lock_guard lock(mutex_);
    if (request_sequence <= generation_) return std::nullopt;
    generation_ = request_sequence;
    if (active_ != INVALID_SOCKET && active_ != socket) {
      shutdown(active_, SD_BOTH);
    }
    active_ = socket;
    return std::optional<Lease>(std::in_place, *this, generation_);
  }

 private:
  void release(std::uint64_t generation) {
    std::lock_guard lock(mutex_);
    if (generation == generation_) active_ = INVALID_SOCKET;
  }

  std::mutex mutex_;
  SOCKET active_ = INVALID_SOCKET;
  std::uint64_t generation_ = 0;
};

class LoopbackHttpServer final {
 public:
  LoopbackHttpServer(const LibblurayApi& api, bridge::BlockCache& cache,
                     std::vector<TitleInfo> titles, std::string token,
                     BlurayMetrics& bluray_metrics,
                     std::chrono::steady_clock::time_point bridge_started,
                     bridge::RemoteDiscProvider* remote_disc = nullptr)
      : api_(api),
        cache_(cache),
        titles_(std::move(titles)),
        token_(std::move(token)),
        bluray_metrics_(bluray_metrics),
        bridge_started_(bridge_started), remote_disc_(remote_disc) {}

  ~LoopbackHttpServer() { stop(); }

  std::uint16_t start() {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
      throw BridgeException("internal_error", "Unable to initialize Winsock");
    }
    winsock_started_ = true;
    listener_.reset(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    if (!listener_) {
      throw BridgeException("internal_error", "Unable to create loopback listener");
    }
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener_.get(), reinterpret_cast<const sockaddr*>(&address),
             sizeof(address)) == SOCKET_ERROR ||
        listen(listener_.get(), SOMAXCONN) == SOCKET_ERROR) {
      throw BridgeException("internal_error", "Unable to bind the loopback listener");
    }
    int address_length = sizeof(address);
    if (getsockname(listener_.get(), reinterpret_cast<sockaddr*>(&address),
                    &address_length) == SOCKET_ERROR) {
      throw BridgeException("internal_error", "Unable to read the loopback port");
    }
    port_ = ntohs(address.sin_port);
    accept_thread_ = std::thread([this] { accept_loop(); });
    return port_;
  }

  void stop() {
    if (stopped_.exchange(true)) return;
    if (remote_disc_ != nullptr) {
      remote_stopping_ = true;
      cache_.shutdown();
      std::lock_guard lock(workers_mutex_);
      for (const auto& entry : remote_sockets_) shutdown(entry.first, SD_BOTH);
    }
    if (listener_) {
      shutdown(listener_.get(), SD_BOTH);
      listener_.reset();
    }
    if (accept_thread_.joinable()) accept_thread_.join();
    {
      std::unique_lock lock(workers_mutex_);
      workers_finished_.wait(lock, [this] { return active_workers_ == 0; });
    }
    if (winsock_started_) {
      WSACleanup();
      winsock_started_ = false;
    }
  }

 private:
  void accept_loop() {
    while (!stopped_) {
      const SOCKET accepted = accept(listener_.get(), nullptr, nullptr);
      if (accepted == INVALID_SOCKET) break;
      const std::uint64_t request_sequence = ++accepted_request_sequence_;
      configure_loopback_client_socket(accepted);
      {
        std::lock_guard lock(workers_mutex_);
        if (remote_disc_ != nullptr && (stopped_ || active_workers_ >= 4)) {
          closesocket(accepted);
          continue;
        }
        ++active_workers_;
        if (remote_disc_ != nullptr) remote_sockets_[accepted] = request_sequence;
      }
      try {
        std::thread([this, accepted, request_sequence] {
          try {
            serve(SocketHandle(accepted), request_sequence);
          } catch (...) {
            // 单个 localhost 请求失败只关闭当前连接。
          }
          {
            std::lock_guard lock(workers_mutex_);
            --active_workers_;
            const auto found = remote_sockets_.find(accepted);
            if (found != remote_sockets_.end() && found->second == request_sequence)
              remote_sockets_.erase(found);
          }
          workers_finished_.notify_all();
        }).detach();
      } catch (...) {
        closesocket(accepted);
        {
          std::lock_guard lock(workers_mutex_);
          --active_workers_;
          const auto found = remote_sockets_.find(accepted);
          if (found != remote_sockets_.end() && found->second == request_sequence)
            remote_sockets_.erase(found);
        }
        workers_finished_.notify_all();
      }
    }
  }

  void serve(SocketHandle socket, std::uint64_t request_sequence) {
    std::string request;
    std::array<char, 4096> buffer{};
    while (request.find("\r\n\r\n") == std::string::npos) {
      const int received =
          recv(socket.get(), buffer.data(), static_cast<int>(buffer.size()), 0);
      if (received <= 0) return;
      request.append(buffer.data(), static_cast<std::size_t>(received));
      if (request.size() > kMaximumHttpHeaderBytes) {
        send_http_error(socket.get(), 431, "Request Header Fields Too Large");
        return;
      }
    }
    const std::size_t first_line_end = request.find("\r\n");
    if (first_line_end == std::string::npos) {
      send_http_error(socket.get(), 400, "Bad Request");
      return;
    }
    const std::string_view first_line(request.data(), first_line_end);
    const std::size_t first_space = first_line.find(' ');
    const std::size_t second_space = first_line.find(' ', first_space + 1);
    if (first_space == std::string_view::npos ||
        second_space == std::string_view::npos) {
      send_http_error(socket.get(), 400, "Bad Request");
      return;
    }
    const std::string method(first_line.substr(0, first_space));
    const std::string path(first_line.substr(first_space + 1,
                                             second_space - first_space - 1));
    if (method != "GET" && method != "HEAD") {
      send_http_error(socket.get(), 405, "Method Not Allowed");
      return;
    }
    if (remote_disc_ != nullptr) {
      if (path != "/" + token_ + "/disc.iso") {
        send_http_error(socket.get(), 404, "Not Found");
        return;
      }
      serve_remote(socket.get(), method,
                   std::string_view(request).substr(first_line_end + 2),
                   request_sequence);
      return;
    }
    const std::string prefix = "/" + token_ + "/title/";
    constexpr std::string_view kSuffix = ".m2ts";
    if (path.size() != prefix.size() + 5U + kSuffix.size() ||
        path.rfind(prefix, 0) != 0 ||
        path.substr(path.size() - kSuffix.size()) != kSuffix) {
      send_http_error(socket.get(), 404, "Not Found");
      return;
    }
    const std::string playlist_text = path.substr(prefix.size(), 5);
    std::uint32_t playlist = 0;
    const auto parsed = std::from_chars(
        playlist_text.data(), playlist_text.data() + playlist_text.size(),
        playlist);
    if (parsed.ec != std::errc{} ||
        parsed.ptr != playlist_text.data() + playlist_text.size()) {
      send_http_error(socket.get(), 404, "Not Found");
      return;
    }
    const auto title = std::find_if(
        titles_.begin(), titles_.end(),
        [playlist](const TitleInfo& item) { return item.playlist == playlist; });
    if (title == titles_.end()) {
      send_http_error(socket.get(), 404, "Not Found");
      return;
    }

    std::optional<std::string> range_header;
    std::size_t header_start = first_line_end + 2;
    while (header_start < request.size()) {
      const std::size_t header_end = request.find("\r\n", header_start);
      if (header_end == std::string::npos || header_end == header_start) break;
      const std::string_view line(request.data() + header_start,
                                  header_end - header_start);
      const std::size_t colon = line.find(':');
      if (colon != std::string_view::npos) {
        std::string name(line.substr(0, colon));
        name = lowercase_ascii(std::move(name));
        if (name == "range") {
          std::string_view value = line.substr(colon + 1);
          while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) {
            value.remove_prefix(1);
          }
          if (range_header.has_value()) {
            send_http_error(socket.get(), 416, "Range Not Satisfiable",
                            title->size);
            return;
          }
          range_header = std::string(value);
        }
      }
      header_start = header_end + 2;
    }

    bool partial = false;
    std::uint64_t start = 0;
    std::uint64_t end = title->size - 1;
    if (range_header.has_value()) {
      const auto range = bridge::parse_byte_range(*range_header, title->size);
      if (range.status != bridge::ByteRangeStatus::ok) {
        send_http_error(socket.get(), 416, "Range Not Satisfiable", title->size);
        return;
      }
      partial = true;
      start = range.start;
      end = range.end;
    }

    if (method == "HEAD") {
      static_cast<void>(
          send_headers(socket.get(), false, 0, title->size - 1, title->size));
      return;
    }
    if (terminal_failed()) {
      bluray_metrics_.record_terminal_rejected_media_get();
      send_http_error(socket.get(), 503, "Service Unavailable");
      return;
    }
    auto active_socket = media_sockets_.activate(socket.get(), request_sequence);
    if (!active_socket.has_value()) return;
    const auto get_started = std::chrono::steady_clock::now();
    bluray_metrics_.record_media_get();
    const std::uint64_t playback_generation = cache_.begin_playback();
    const auto playback_current = [this, playback_generation] {
      return cache_.is_playback_current(playback_generation);
    };
    MediaGetTiming timing;
    timing.sequence = request_sequence;
    timing.generation = playback_generation;
    timing.playlist = playlist;
    timing.request_byte = start;
    timing.started_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            get_started - bridge_started_).count());
    const auto elapsed_us = [&] {
      return std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now() - get_started).count();
    };
    bool timing_recorded = false;
    ScopeExit finish_timing([&] {
      if (!timing_recorded) {
        timing.superseded = !playback_current();
        bluray_metrics_.record_media_timing(timing);
      }
    });
    bool response_headers_sent = false;
    try {
      if (!playback_current()) return;
      auto context = playback_context_.acquire(
          playlist, std::chrono::seconds(30),
          [&playback_current] { return !playback_current(); },
          [this, playlist, playback_generation] {
            return api_.open_title(cache_, playlist, bluray_metrics_,
                                   playback_generation);
          });
      if (!context.has_value()) {
        if (!playback_current()) return;
        send_http_error(socket.get(), 503, "Service Unavailable");
        return;
      }
      if (context->reused()) {
        bluray_metrics_.record_persistent_context_reuse();
      }
      timing.context_ready_us = elapsed_us();
      if (!playback_current()) return;
      try {
        (*context)->set_playback_read_ahead(0, playback_generation);
        if (api_.title_size((*context)->get()) != title->size) {
          (*context)->rethrow_read_error();
          context->invalidate();
          send_http_error(socket.get(), 500, "Internal Server Error");
          return;
        }
        const MediaRangePlan range_plan =
            identity_media_range_plan(start, end, title->size);
        const std::int64_t seeked =
            api_.seek((*context)->get(), range_plan.packet_start);
        timing.seek_ready_us = elapsed_us();
        if (!playback_current()) return;
        if (seeked < 0 || static_cast<std::uint64_t>(seeked) >= title->size ||
            static_cast<std::uint64_t>(seeked) > range_plan.packet_start) {
          (*context)->rethrow_read_error();
          context->invalidate();
          send_http_error(socket.get(), 416, "Range Not Satisfiable",
                          title->size);
          return;
        }
        (*context)->set_playback_read_ahead(
            cache_.limit_read_ahead(bridge::playback_read_ahead_blocks(
                title->size, title->duration_milliseconds)),
            playback_generation);
        std::uint64_t discard =
            range_plan.packet_start - static_cast<std::uint64_t>(seeked);
        timing.discard_bytes = discard;
        std::array<std::uint8_t, bridge::kM2tsPacketSize * 256U> media_buffer{};
        while (discard > 0) {
          if (!playback_current()) return;
          const int wanted = static_cast<int>(std::min<std::uint64_t>(
              discard, static_cast<std::uint64_t>(media_buffer.size())));
          const int read =
              api_.read((*context)->get(), media_buffer.data(), wanted);
          if (!playback_current()) return;
          (*context)->rethrow_read_error();
          if (read <= 0 || read > wanted) {
            context->invalidate();
            send_http_error(socket.get(), 416, "Range Not Satisfiable",
                            title->size);
            return;
          }
          discard -= static_cast<std::uint64_t>(read);
        }
        const std::uint64_t source_start = range_plan.packet_start;
        std::uint64_t skip_prefix = range_plan.skip_prefix;
        if (!playback_current()) return;
        if (!send_headers(socket.get(), partial, start, end, title->size)) return;
        response_headers_sent = true;
        timing.headers_ready_us = elapsed_us();
        std::uint64_t remaining = range_plan.response_length;
        std::uint64_t absolute_offset = source_start;
        const std::uint64_t aligned_end = std::min(
            title->size,
            range_plan.source_end_exclusive +
                ((bridge::kM2tsPacketSize -
                  (range_plan.source_end_exclusive % bridge::kM2tsPacketSize)) %
                            bridge::kM2tsPacketSize));
        std::uint64_t source_remaining = aligned_end - source_start;
        bool first_body_sent = false;
        while (source_remaining > 0 && remaining > 0) {
          if (!playback_current()) return;
          const std::size_t wanted = static_cast<std::size_t>(
              std::min<std::uint64_t>(source_remaining, media_buffer.size()));
          std::size_t filled = 0;
          while (filled < wanted) {
            if (!playback_current()) return;
            const int read =
                api_.read((*context)->get(), media_buffer.data() + filled,
                          static_cast<int>(wanted - filled));
            if (!playback_current()) return;
            (*context)->rethrow_read_error();
            if (read <= 0 || static_cast<std::size_t>(read) > wanted - filled) {
              context->invalidate();
              throw BridgeException("invalid_disc",
                                    "The Blu-ray title ended unexpectedly");
            }
            filled += static_cast<std::size_t>(read);
          }
          if (!bridge::normalize_m2ts_timestamps(
                  media_buffer.data(), filled, absolute_offset, title->clips)) {
            context->invalidate();
            throw BridgeException("invalid_disc",
                                  "The Blu-ray title timeline is invalid");
          }
          const std::size_t send_offset = static_cast<std::size_t>(
              std::min<std::uint64_t>(skip_prefix, filled));
          skip_prefix -= send_offset;
          const std::size_t send_length = static_cast<std::size_t>(
              std::min<std::uint64_t>(filled - send_offset, remaining));
          if (send_length > 0) {
            if (!send_all(socket.get(),
                          reinterpret_cast<const char*>(media_buffer.data() +
                                                        send_offset),
                          send_length)) {
              return;
            }
            if (!first_body_sent) {
              timing.first_body_us = elapsed_us();
              bluray_metrics_.record_media_timing(timing);
              timing_recorded = true;
              std::uint64_t expected_ready = 0;
              const auto ready_us = static_cast<std::uint64_t>(
                  std::chrono::duration_cast<std::chrono::microseconds>(
                      std::chrono::steady_clock::now() - bridge_started_)
                      .count());
              first_media_response_ready_us_.compare_exchange_strong(
                  expected_ready, ready_us);
              first_body_sent = true;
            }
          }
          remaining -= send_length;
          absolute_offset += filled;
          source_remaining -= filled;
        }
      } catch (...) {
        context->invalidate();
        throw;
      }
    } catch (const BridgeException& error) {
      if (!playback_current()) return;
      terminal_failure_.record(playback_generation, error.code());
      bluray_metrics_.record_media_failure(request_sequence,
                                           playback_generation,
                                           error.http_status());
      fail_loopback_response(socket.get(), response_headers_sent);
    } catch (...) {
      if (!playback_current()) return;
      terminal_failure_.record(playback_generation, "internal_error");
      bluray_metrics_.record_media_failure(request_sequence,
                                           playback_generation, 0);
      fail_loopback_response(socket.get(), response_headers_sent);
    }
  }

  void serve_remote(SOCKET socket, const std::string& method,
                    std::string_view headers, std::uint64_t sequence) {
    const auto request = bridge::parse_remote_disc_request(headers, *remote_disc_);
    if (request.status != 206) {
      send_http_error(socket, request.status, "Invalid Disc Request",
                      remote_disc_->size());
      return;
    }
    if (remote_failed_ || remote_stopping_) {
      send_http_error(socket, 503, "Service Unavailable");
      return;
    }
    std::uint64_t generation = 0;
    bool sent = false;
    try {
      generation = remote_disc_->activate(request.generation);
      if (method == "HEAD") {
        send_headers(socket, false, 0, remote_disc_->size() - 1,
                     remote_disc_->size(), "application/octet-stream");
        return;
      }
      auto lease = media_sockets_.activate(socket, sequence);
      if (!lease.has_value()) return;
      // 响应按 demand block 发送，避免为每个连接再分配完整 Range 缓冲。
      std::vector<std::uint8_t> bytes(bridge::kIsoDemandBlockSize);
      const DWORD send_timeout = 10000;
      setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
                  reinterpret_cast<const char*>(&send_timeout),
                  sizeof(send_timeout));
      for (auto offset = request.start; offset <= request.end;) {
        const auto wanted = static_cast<std::size_t>(std::min<std::uint64_t>(
            bytes.size(), request.end - offset + 1));
        const auto read = remote_disc_->read(offset, bytes.data(), wanted,
                                             request.media, generation);
        if (!cache_.is_playback_current(generation)) return;
        if (read != wanted) {
          throw BridgeException("invalid_disc", "Incomplete disc block read");
        }
        if (!sent) {
          if (!send_headers(socket, true, request.start, request.end,
                             remote_disc_->size(), "application/octet-stream")) return;
          sent = true;
        }
        if (!send_all(socket, reinterpret_cast<const char*>(bytes.data()), read)) return;
        offset += read;
        std::uint64_t expected = 0;
        first_media_response_ready_us_.compare_exchange_strong(
            expected, static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - bridge_started_).count()));
      }
    } catch (const bridge::FetchCancelled&) {
      abort_loopback_response(socket);
    } catch (const BridgeException& error) {
      if (!cache_.is_playback_current(generation)) return;
      remote_failed_ = true;
      terminal_failure_.record(generation, error.code());
      bluray_metrics_.record_media_failure(sequence, generation, error.http_status());
      fail_loopback_response(socket, sent);
    } catch (...) {
      if (!cache_.is_playback_current(generation)) return;
      remote_failed_ = true;
      terminal_failure_.record(generation, "internal_error");
      bluray_metrics_.record_media_failure(sequence, generation, 0);
      fail_loopback_response(socket, sent);
    }
  }

 public:
  std::string last_error_code() const {
    const auto failure = terminal_failure_.snapshot();
    return cache_.is_playback_current(failure.generation) ? failure.code
                                                          : std::string{};
  }

  std::uint64_t first_media_response_ready_us() const {
    return first_media_response_ready_us_.load();
  }

 private:

  bool terminal_failed() const {
    const auto failure = terminal_failure_.snapshot();
    return terminal_failure_.applies_to(failure.generation) &&
           cache_.is_playback_current(failure.generation);
  }

  static bool send_headers(SOCKET socket, bool partial, std::uint64_t start,
                           std::uint64_t end, std::uint64_t total,
                           const char* content_type = "video/mp2t") {
    std::ostringstream response;
    response << "HTTP/1.1 " << (partial ? "206 Partial Content" : "200 OK")
             << "\r\n"
             << "Content-Type: " << content_type << "\r\n"
             << "Accept-Ranges: bytes\r\n"
             << "Connection: close\r\n"
             << "Content-Length: " << (end - start + 1) << "\r\n";
    if (partial) {
      response << "Content-Range: bytes " << start << '-' << end << '/' << total
               << "\r\n";
    }
    response << "\r\n";
    const std::string text = response.str();
    return send_all(socket, text.data(), text.size());
  }

  const LibblurayApi& api_;
  bridge::BlockCache& cache_;
  std::vector<TitleInfo> titles_;
  std::string token_;
  BlurayMetrics& bluray_metrics_;
  const std::chrono::steady_clock::time_point bridge_started_;
  MediaSocketRegistry media_sockets_;
  PersistentContextSlot<LibblurayApi::Disc> playback_context_;
  SocketHandle listener_;
  std::uint16_t port_ = 0;
  std::atomic<bool> stopped_ = false;
  std::uint64_t accepted_request_sequence_ = 0;
  bool winsock_started_ = false;
  std::thread accept_thread_;
  std::mutex workers_mutex_;
  std::condition_variable workers_finished_;
  std::size_t active_workers_ = 0;
  std::map<SOCKET, std::uint64_t> remote_sockets_;
  GenerationFailureState terminal_failure_;
  std::atomic<std::uint64_t> first_media_response_ready_us_ = 0;
  bridge::RemoteDiscProvider* remote_disc_ = nullptr;
  std::atomic<bool> remote_failed_ = false;
  std::atomic<bool> remote_stopping_ = false;
};

bool read_exact(HANDLE pipe, void* destination, DWORD length) {
  auto* bytes = static_cast<std::uint8_t*>(destination);
  DWORD offset = 0;
  while (offset < length) {
    DWORD received = 0;
    if (ReadFile(pipe, bytes + offset, length - offset, &received, nullptr) ==
            FALSE ||
        received == 0) {
      return false;
    }
    offset += received;
  }
  return true;
}

bool write_exact(HANDLE pipe, const void* source, DWORD length) {
  const auto* bytes = static_cast<const std::uint8_t*>(source);
  DWORD offset = 0;
  while (offset < length) {
    DWORD written = 0;
    if (WriteFile(pipe, bytes + offset, length - offset, &written, nullptr) ==
            FALSE ||
        written == 0) {
      return false;
    }
    offset += written;
  }
  return true;
}

std::optional<std::string> read_frame(HANDLE pipe) {
  std::array<std::uint8_t, 4> prefix{};
  if (!read_exact(pipe, prefix.data(), static_cast<DWORD>(prefix.size()))) {
    return std::nullopt;
  }
  const std::uint32_t length = static_cast<std::uint32_t>(prefix[0]) |
                               (static_cast<std::uint32_t>(prefix[1]) << 8U) |
                               (static_cast<std::uint32_t>(prefix[2]) << 16U) |
                               (static_cast<std::uint32_t>(prefix[3]) << 24U);
  if (length == 0 || length > bridge::kMaxControlMessageBytes) {
    throw BridgeException("protocol_error", "The control message length is invalid");
  }
  std::string message(length, '\0');
  if (!read_exact(pipe, message.data(), length)) return std::nullopt;
  return message;
}

bool write_frame(HANDLE pipe, std::string_view message) {
  if (message.empty() || message.size() > bridge::kMaxControlMessageBytes) {
    return false;
  }
  const std::uint32_t length = static_cast<std::uint32_t>(message.size());
  const std::array<std::uint8_t, 4> prefix = {
      static_cast<std::uint8_t>(length & 0xffU),
      static_cast<std::uint8_t>((length >> 8U) & 0xffU),
      static_cast<std::uint8_t>((length >> 16U) & 0xffU),
      static_cast<std::uint8_t>((length >> 24U) & 0xffU),
  };
  return write_exact(pipe, prefix.data(), static_cast<DWORD>(prefix.size())) &&
         write_exact(pipe, message.data(), length);
}

std::optional<std::string> json_string(const bridge::JsonObject& object,
                                       const std::string& key) {
  const auto found = object.find(key);
  if (found == object.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::nullopt : std::optional<std::string>(*value);
}

std::optional<std::int64_t> json_integer(const bridge::JsonObject& object,
                                         const std::string& key) {
  const auto found = object.find(key);
  if (found == object.end()) return std::nullopt;
  const auto* value = std::get_if<std::int64_t>(&found->second);
  return value == nullptr ? std::nullopt : std::optional<std::int64_t>(*value);
}

std::optional<bool> json_boolean(const bridge::JsonObject& object,
                                 const std::string& key) {
  const auto found = object.find(key);
  if (found == object.end()) return std::nullopt;
  const auto* value = std::get_if<bool>(&found->second);
  return value == nullptr ? std::nullopt : std::optional<bool>(*value);
}

std::string error_json(std::string_view code, std::string_view message) {
  return "{\"type\":\"error\",\"code\":" + bridge::json_escape(code) +
         ",\"message\":" + bridge::json_escape(message) + "}";
}

void write_network_phase_metrics(
    std::ostringstream& output, const NetworkPhaseMetricsSnapshot& metrics) {
  output << '{'
         << "\"requestCount\":" << metrics.request_count
         << ",\"redirectCount\":" << metrics.redirect_count
         << ",\"responseHeaderLatencyUsTotal\":"
         << metrics.response_header_latency_us_total
         << ",\"responseBodyActiveUsTotal\":"
         << metrics.response_body_active_us_total
         << ",\"remoteBodyBytes\":" << metrics.remote_body_bytes
         << ",\"remoteTransferWallClockUs\":"
         << metrics.remote_transfer_wall_clock_us
         << ",\"concurrentTransferWallClockUs\":"
         << metrics.concurrent_transfer_wall_clock_us
         << ",\"requestContextCreatedCount\":"
         << metrics.request_context_created_count
         << ",\"requestContextClosedCount\":"
         << metrics.request_context_closed_count << '}';
}

void write_cache_phase_metrics(std::ostringstream& output,
                               const bridge::BlockCacheMetrics& cache,
                               std::uint64_t block_bytes,
                               std::optional<std::uint64_t> retained_bytes =
                                   std::nullopt) {
  output << '{'
         << "\"requestCount\":" << cache.requests
         << ",\"foregroundFetchBytes\":" << cache.foreground_fetch_bytes
         << ",\"prefetchFetchBytes\":" << cache.prefetch_fetch_bytes
         << ",\"consumerBytesDelivered\":"
         << cache.consumer_bytes_delivered
         << ",\"cacheHitCount\":" << cache.hits
         << ",\"cacheMissCount\":" << cache.cache_miss_count
         << ",\"foregroundLoadingWaitCount\":" << cache.foreground_loading_wait_count
         << ",\"foregroundLoadingWaitUsTotal\":" << cache.foreground_loading_wait_us_total
         << ",\"foregroundLoadingWaitUsMax\":" << cache.foreground_loading_wait_us_max
         << ",\"prefetchHitCount\":" << cache.prefetch_hits
         << ",\"prefetchHitBytes\":" << cache.prefetch_hit_bytes
         << ",\"prefetchUnusedBytes\":" << cache.prefetch_unused_bytes
         << ",\"cancelledForegroundBytes\":"
         << cache.cancelled_foreground_bytes
         << ",\"cancelledPrefetchBytes\":"
         << cache.cancelled_prefetch_bytes
         << ",\"evictionCount\":" << cache.eviction_count
         << ",\"prefetchActivePeak\":" << cache.prefetch_active_peak
         << ",\"prefetchOverlapCount\":" << cache.prefetch_overlap_count
         << ",\"prefetchPendingGapUsTotal\":"
         << cache.prefetch_pending_gap_us_total
         << ",\"prefetchPendingGapUsMax\":"
         << cache.prefetch_pending_gap_us_max
         << ",\"prefetchInFlightBytesPeak\":"
         << cache.prefetch_in_flight_bytes_peak
         << ",\"prefetchConcurrentWallClockUs\":"
         << cache.prefetch_concurrent_wall_clock_us
         << ",\"residentBytes\":" << cache.resident_bytes
         << ",\"capacityBytes\":" << cache.cache_capacity_bytes
         << ",\"configuredPrefetchBlocks\":"
         << cache.configured_prefetch_blocks
         << ",\"blockBytes\":" << block_bytes
         << ",\"refetchCount\":";
  if (cache.refetch_count_available) {
    output << cache.refetch_count;
  } else {
    output << "null";
  }
  if (retained_bytes.has_value()) {
    output << ",\"retainedBytes\":" << *retained_bytes;
  }
  output << '}';
}

std::string metrics_json(
    const CacheMetricsSnapshot& caches,
    const NetworkMetricsSnapshot& network,
    const NetworkPhaseMetricsSnapshot& metadata_network,
    const NetworkPhaseMetricsSnapshot& playback_network,
    const BlurayMetricsSnapshot& bluray,
    std::uint64_t remote_transfer_active_microseconds,
    std::uint64_t first_media_response_ready_us, std::string_view error_code,
    bool control_message = false, bool final_snapshot = false) {
  const bridge::BlockCacheMetrics cache = caches.aggregate();
  std::ostringstream output;
  output << '{';
  if (control_message) output << "\"type\":\"metrics\",";
  output << "\"version\":2"
         << ",\"network\":{"
         << "\"requestCount\":" << network.request_count
         << ",\"redirectCount\":" << network.redirect_count
         << ",\"redirectResolveCount\":" << network.redirect_resolve_count
         << ",\"resolvedUrlReuseCount\":" << network.resolved_url_reuse_count
         << ",\"responseHeaderLatencyUsTotal\":"
         << network.response_header_latency_us_total
         << ",\"responseBodyActiveUsTotal\":"
         << network.response_body_active_us_total
         << ",\"remoteBodyBytes\":" << network.remote_body_bytes
         << ",\"probeBodyBytes\":" << network.probe_body_bytes
         << ",\"activeRequestPeak\":" << network.active_request_peak
         << ",\"remoteTransferWallClockUs\":"
         << network.remote_transfer_wall_clock_us
         << ",\"concurrentTransferWallClockUs\":"
         << network.concurrent_transfer_wall_clock_us
         << ",\"requestContextCreatedCount\":"
         << network.request_context_created_count
         << ",\"requestContextClosedCount\":"
         << network.request_context_closed_count
         << ",\"requestContextLive\":" << network.request_context_live
         << ",\"requestContextPeak\":" << network.request_context_peak << '}'
         << ",\"metadataNetwork\":";
  write_network_phase_metrics(output, metadata_network);
  output << ",\"playbackNetwork\":";
  write_network_phase_metrics(output, playback_network);
  output << ",\"cache\":";
  write_cache_phase_metrics(output, cache, bridge::kIsoDemandBlockSize);
  output << ",\"metadataCache\":";
  write_cache_phase_metrics(output, caches.metadata,
                            bridge::kIsoDemandBlockSize,
                            caches.metadata_retained_bytes);
  output << ",\"playbackCache\":";
  write_cache_phase_metrics(output, caches.playback,
                            bridge::kIsoDemandBlockSize);
  output << ",\"bluray\":{"
         << "\"contextCreateCount\":" << bluray.context_create_count
         << ",\"contextCreateUsTotal\":" << bluray.context_create_us_total
         << ",\"titleEnumerationUs\":" << bluray.title_enumeration_us
         << ",\"mediaGetCount\":" << bluray.media_get_count
         << ",\"persistentContextReuseCount\":"
         << bluray.persistent_context_reuse_count
         << ",\"timeSeekRedirectCount\":"
         << bluray.time_seek_redirect_count
         << ",\"maximumTimeSeekByteDelta\":"
         << bluray.maximum_time_seek_byte_delta
         << ",\"lastTimeSeekRequestByte\":"
         << bluray.last_time_seek_request_byte
         << ",\"lastTimeSeekTarget90kHz\":"
         << bluray.last_time_seek_target_ticks
         << ",\"lastTimeSeekTitleByte\":"
         << bluray.last_time_seek_title_byte
         << ",\"mediaFailureCount\":" << bluray.media_failure_count
         << ",\"lastMediaFailureSequence\":"
         << bluray.last_media_failure_sequence
         << ",\"lastMediaFailureGeneration\":"
         << bluray.last_media_failure_generation
         << ",\"lastMediaFailureHttpStatus\":"
         << bluray.last_media_failure_http_status
         << ",\"lastMediaFailureStatusCategory\":";
  if (bluray.media_failure_count == 0) {
    output << "null";
  } else if (bluray.last_media_failure_http_status >= 500) {
    output << "\"http_5xx\"";
  } else if (bluray.last_media_failure_http_status >= 400) {
    output << "\"http_4xx\"";
  } else if (bluray.last_media_failure_http_status >= 300) {
    output << "\"http_3xx\"";
  } else if (bluray.last_media_failure_http_status >= 200) {
    output << "\"http_protocol\"";
  } else {
    output << "\"transport_or_bridge\"";
  }
  output << ",\"mediaGetTimings\":[";
  bool first_timing = true;
  for (const auto& timing : bluray.media_get_timings) {
    if (!first_timing) output << ',';
    first_timing = false;
    output << "{\"sequence\":" << timing.sequence
           << ",\"generation\":" << timing.generation
           << ",\"playlist\":" << timing.playlist
           << ",\"requestByte\":" << timing.request_byte
           << ",\"startedUs\":" << timing.started_us
           << ",\"contextReadyUs\":" << timing.context_ready_us
           << ",\"seekReadyUs\":" << timing.seek_ready_us
           << ",\"headersReadyUs\":" << timing.headers_ready_us
           << ",\"firstBodyUs\":" << timing.first_body_us
           << ",\"discardBytes\":" << timing.discard_bytes
           << ",\"superseded\":" << (timing.superseded ? "true" : "false") << '}';
  }
  output << ']' << ",\"terminalRejectedMediaGetCount\":"
         << bluray.terminal_rejected_media_get_count
         << ",\"structureCacheHit\":"
         << (bluray.structure_cache_hit ? "true" : "false") << '}'
         << ",\"bridge\":{\"firstMediaResponseReadyUs\":";
  if (first_media_response_ready_us == 0) {
    output << "null";
  } else {
    output << first_media_response_ready_us;
  }
  // Version 1 aggregate fields remain until every deployed Dart reader accepts v2.
  output << ",\"final\":" << (final_snapshot ? "true" : "false")
         << ",\"timeSeekRedirectEnabled\":false"
         << ",\"demandBlockBytes\":" << bridge::kIsoDemandBlockSize << '}'
         << ",\"fetchedBytes\":" << cache.fetched_bytes
         << ",\"rangeRequests\":" << cache.requests
         << ",\"cacheHits\":" << cache.hits
         << ",\"cachePeakBytes\":" << cache.peak_bytes
         << ",\"prefetchRequests\":" << cache.prefetch_requests
         << ",\"prefetchedBytes\":" << cache.prefetched_bytes
         << ",\"prefetchHits\":" << cache.prefetch_hits
         << ",\"playbackRequests\":" << cache.playback_requests
         << ",\"stalePlaybackCancellations\":"
         << cache.stale_playback_cancellations
         << ",\"cancelledPrefetchRequests\":"
         << cache.cancelled_prefetch_requests
         << ",\"cancelledForegroundRequests\":"
         << cache.cancelled_foreground_requests
         << ",\"cacheResidentBytes\":" << cache.resident_bytes
         << ",\"cacheCapacityBytes\":" << cache.cache_capacity_bytes
         << ",\"configuredPrefetchBlocks\":"
         << cache.configured_prefetch_blocks
         << ",\"remoteTransferBytes\":" << network.remote_body_bytes
         << ",\"remoteTransferActiveMicroseconds\":"
         << remote_transfer_active_microseconds;
  if (!error_code.empty()) {
    output << ",\"lastErrorCode\":" << bridge::json_escape(error_code);
  }
  if (!cache.refetch_count_available) {
    output << ",\"errors\":[{\"error-type\":\"bad_alloc\"}]";
  }
  output << '}';
  return output.str();
}

bool write_metrics_file(
    const std::filesystem::path& path,
    const CacheMetricsSnapshot& caches,
    const NetworkMetricsSnapshot& network,
    const NetworkPhaseMetricsSnapshot& metadata_network,
    const NetworkPhaseMetricsSnapshot& playback_network,
    const BlurayMetricsSnapshot& bluray,
    std::uint64_t remote_transfer_active_microseconds,
    std::uint64_t first_media_response_ready_us,
    std::string_view error_code, bool final_snapshot = false,
    std::optional<std::uint64_t> menu_cancellations = std::nullopt,
    std::string_view virtual_disc_metrics = {}) noexcept {
  try {
    const std::filesystem::path temporary = path.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    auto json = metrics_json(caches, network, metadata_network,
                           playback_network, bluray,
                           remote_transfer_active_microseconds,
                           first_media_response_ready_us, error_code, false,
                           final_snapshot);
    if (menu_cancellations.has_value()) {
      json.pop_back();
      json += ",\"playbackMode\":\"webdavHdmvMenu\",\"menuCancelledGenerations\":" +
              std::to_string(*menu_cancellations) + "}";
    }
    if (!virtual_disc_metrics.empty()) {
      json.pop_back();
      json += ",\"playbackMode\":\"webdavHdmvMenu\",\"transport\":\"winfsp\",\"virtualDisc\":";
      json += virtual_disc_metrics;
      json += "}";
    }
    output << json;
    output.close();
    if (!output) return false;
    if (MoveFileExW(temporary.c_str(), path.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) ==
        FALSE) {
      std::error_code ignored;
      std::filesystem::remove(temporary, ignored);
      return false;
    }
    return true;
  } catch (...) {
    // 观测失败不能改变播放控制流。
    return false;
  }
}

std::string ready_json(std::uint16_t port, std::string_view token,
                       std::uint64_t total_size,
                       const std::vector<TitleInfo>& titles,
                       bool attached = false) {
  std::ostringstream output;
  output << "{\"type\":\"ready\",\"version\":1";
  if (attached) {
    output << ",\"attached\":true}";
    return output.str();
  }
  output << ",\"port\":" << port << ",\"token\":"
         << bridge::json_escape(token) << ",\"totalBytes\":" << total_size
         << ",\"titles\":[";
  for (std::size_t index = 0; index < titles.size(); ++index) {
    if (index > 0) output << ',';
    const TitleInfo& title = titles[index];
    output << "{\"titleIndex\":" << title.title_index << ",\"mplsId\":\""
           << std::setw(5) << std::setfill('0') << title.playlist
           << "\",\"durationMs\":" << title.duration_milliseconds
           << ",\"size\":" << title.size << ",\"chapters\":[";
    for (std::size_t chapter_index = 0; chapter_index < title.chapters.size();
         ++chapter_index) {
      if (chapter_index > 0) output << ',';
      const ChapterInfo& chapter = title.chapters[chapter_index];
      output << "{\"startMs\":" << chapter.start_milliseconds
             << ",\"durationMs\":" << chapter.duration_milliseconds;
      if (!chapter.name.empty()) {
        output << ",\"name\":" << bridge::json_escape(chapter.name);
      }
      output << '}';
    }
    output << "]}";
  }
  output << "]}";
  return output.str();
}

std::filesystem::path executable_directory() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                          static_cast<DWORD>(path.size()));
  if (length == 0 ||
      static_cast<std::size_t>(length) >= path.size()) {
    throw BridgeException("internal_error", "Unable to locate the helper directory");
  }
  return std::filesystem::path(std::wstring(path.data(), length)).parent_path();
}

struct PipeSecurity {
  SECURITY_ATTRIBUTES attributes{};
  PSECURITY_DESCRIPTOR descriptor = nullptr;

  PipeSecurity() = default;
  PipeSecurity(const PipeSecurity&) = delete;
  PipeSecurity& operator=(const PipeSecurity&) = delete;
  PipeSecurity(PipeSecurity&& other) noexcept
      : attributes(other.attributes),
        descriptor(std::exchange(other.descriptor, nullptr)) {
    attributes.lpSecurityDescriptor = descriptor;
  }
  PipeSecurity& operator=(PipeSecurity&& other) noexcept {
    if (this == &other) return *this;
    if (descriptor != nullptr) LocalFree(descriptor);
    attributes = other.attributes;
    descriptor = std::exchange(other.descriptor, nullptr);
    attributes.lpSecurityDescriptor = descriptor;
    return *this;
  }

  ~PipeSecurity() {
    if (descriptor != nullptr) LocalFree(descriptor);
  }
};

PipeSecurity current_user_pipe_security() {
  KernelHandle token;
  HANDLE raw_token = nullptr;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token) == FALSE) {
    throw BridgeException("internal_error", "Unable to inspect the current user");
  }
  token.reset(raw_token);
  DWORD size = 0;
  GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
  if (size == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    throw BridgeException("internal_error", "Unable to inspect the current user");
  }
  std::vector<std::uint8_t> buffer(size);
  if (GetTokenInformation(token.get(), TokenUser, buffer.data(), size, &size) ==
      FALSE) {
    throw BridgeException("internal_error", "Unable to inspect the current user");
  }
  const auto* token_user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
  LPWSTR sid_text = nullptr;
  if (ConvertSidToStringSidW(token_user->User.Sid, &sid_text) == FALSE) {
    throw BridgeException("internal_error", "Unable to inspect the current user");
  }
  const std::wstring descriptor_text =
      L"D:P(A;;GA;;;SY)(A;;GA;;;" + std::wstring(sid_text) + L")";
  LocalFree(sid_text);
  PipeSecurity result;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          descriptor_text.c_str(), SDDL_REVISION_1, &result.descriptor,
          nullptr) == FALSE) {
    throw BridgeException("internal_error", "Unable to secure the control pipe");
  }
  result.attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  result.attributes.lpSecurityDescriptor = result.descriptor;
  result.attributes.bInheritHandle = FALSE;
  return result;
}

bool is_valid_pipe_name(std::wstring_view value) {
  if (value.empty() || value.size() > 128) return false;
  return std::all_of(value.begin(), value.end(), [](wchar_t ch) {
    return (ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z') ||
           (ch >= L'0' && ch <= L'9') || ch == L'_' || ch == L'-';
  });
}

bool is_mpv_process(HANDLE process) {
  std::vector<wchar_t> path(32768);
  DWORD length = static_cast<DWORD>(path.size());
  if (QueryFullProcessImageNameW(process, 0, path.data(), &length) == FALSE) {
    return false;
  }
  const std::wstring stem = lowercase_wide(
      std::filesystem::path(std::wstring(path.data(), length)).stem().wstring());
  return stem == L"mpv" || stem.rfind(L"mpv-", 0) == 0;
}

int run_helper(std::wstring pipe_suffix, DWORD parent_pid) {
  if (!is_valid_pipe_name(pipe_suffix) || parent_pid == 0) return 2;
  KernelHandle parent(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                  FALSE, parent_pid));
  if (!parent) return 2;

  PipeSecurity security = current_user_pipe_security();
  const std::wstring pipe_name = L"\\\\.\\pipe\\" + pipe_suffix;
  KernelHandle pipe(CreateNamedPipeW(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
      1, bridge::kMaxControlMessageBytes, bridge::kMaxControlMessageBytes, 0,
      &security.attributes));
  if (!pipe) return 3;
  if (ConnectNamedPipe(pipe.get(), nullptr) == FALSE &&
      GetLastError() != ERROR_PIPE_CONNECTED) {
    return 3;
  }
  ULONG client_pid = 0;
  if (GetNamedPipeClientProcessId(pipe.get(), &client_pid) == FALSE ||
      client_pid != parent_pid) {
    write_frame(pipe.get(), error_json("protocol_error", "Unexpected control client"));
    return 4;
  }
  if (!write_frame(pipe.get(), "{\"type\":\"hello\",\"version\":1,\"pid\":" +
                                   std::to_string(GetCurrentProcessId()) + "}")) {
    return 4;
  }

  try {
    const auto open_frame = read_frame(pipe.get());
    if (!open_frame.has_value()) return 0;
    const auto open = bridge::parse_json_object(*open_frame);
    if (!open.has_value() ||
        (json_string(*open, "type") != "open" &&
         json_string(*open, "type") != "open_disc") ||
        json_integer(*open, "version") != 1) {
      throw BridgeException("protocol_error", "Expected protocol v1 open message");
    }
    const auto url = json_string(*open, "url");
    const auto origin = json_string(*open, "origin");
    const auto username = json_string(*open, "username");
    const auto password = json_string(*open, "password");
    const auto session_path = json_string(*open, "sessionPath");
    const auto structure_cache_path =
        json_string(*open, "structureCachePath");
    const bool time_seek_redirect =
        json_boolean(*open, "timeSeekRedirect").value_or(false);
    if (!url.has_value() || !origin.has_value() || !username.has_value() ||
        !password.has_value() || !session_path.has_value() ||
        session_path->empty() || !structure_cache_path.has_value() ||
        structure_cache_path->empty()) {
      throw BridgeException("protocol_error", "The open message is incomplete");
    }
    const bool remote_menu = json_string(*open, "type") == "open_disc";
    const auto transport = json_string(*open, "transport");
    const bool virtual_disc = remote_menu && transport == "winfsp";
    if (transport.has_value() && !virtual_disc) {
      throw BridgeException("protocol_error", "Unsupported disc transport");
    }
    if (remote_menu && json_string(*open, "mode") != "hdmv") {
      throw BridgeException("protocol_error", "Expected HDMV disc mode");
    }
    validate_time_seek_redirect_option(time_seek_redirect);
    const std::filesystem::path metrics_path =
        std::filesystem::path(wide_from_utf8(*session_path)) /
        L"iso-bridge-metrics.json";
    if (!metrics_path.is_absolute()) {
      throw BridgeException("protocol_error", "The session path is invalid");
    }
    const std::filesystem::path structure_path =
        std::filesystem::path(wide_from_utf8(*structure_cache_path));
    if (!bridge::is_valid_structure_cache_path(structure_path)) {
      throw BridgeException("protocol_error",
                            "The structure cache path is invalid");
    }

    const auto bridge_started = std::chrono::steady_clock::now();
    auto source = std::make_shared<WinHttpRangeSource>(*url, *origin, *username,
                                                        *password);
    const NetworkMetricsSnapshot pre_metadata_network = source->metrics();
    std::unique_ptr<bridge::BlockCache> metadata_cache;
    BlurayMetrics bluray_metrics;
    LibblurayApi api(executable_directory());
    if (!write_frame(pipe.get(), R"({"type":"metrics","stage":"parsingTitles"})")) {
      return 1;
    }
    std::vector<TitleInfo> titles;
    const auto structure_identity = bridge::make_structure_cache_identity(
        source->size(), source->structure_cache_validator_kind(),
        source->validator());
    bool should_write_structure_cache = false;
    try {
      auto cached_titles =
          !remote_menu && structure_identity.has_value()
              ? bridge::load_structure_cache(structure_path,
                                             *structure_identity)
              : std::nullopt;
      if (remote_menu) {
        metadata_cache = std::make_unique<bridge::BlockCache>(
            source, bridge::kIsoDemandBlockSize, kIsoMetadataBlockCount);
        api.require_hdmv(*metadata_cache, bluray_metrics);
      } else if (cached_titles.has_value()) {
        titles = std::move(*cached_titles);
        bluray_metrics.record_structure_cache_hit();
      } else {
        metadata_cache = std::make_unique<bridge::BlockCache>(
            source, bridge::kIsoDemandBlockSize, kIsoMetadataBlockCount);
        titles = api.enumerate(*metadata_cache, bluray_metrics);
        should_write_structure_cache = structure_identity.has_value();
      }
    } catch (...) {
      const NetworkMetricsSnapshot current_network = source->metrics();
      write_metrics_file(
          metrics_path,
          {metadata_cache != nullptr ? metadata_cache->metrics()
                                     : bridge::BlockCacheMetrics{},
           {}, 0},
          current_network,
          network_phase_metrics(current_network, pre_metadata_network), {},
          bluray_metrics.snapshot(),
          source->remote_transfer_active_microseconds(), 0, {});
      throw;
    }
    const bridge::BlockCacheMetrics metadata_cache_metrics =
        metadata_cache != nullptr ? metadata_cache->metrics()
                                  : bridge::BlockCacheMetrics{};
    const NetworkMetricsSnapshot post_metadata_network = source->metrics();
    const NetworkPhaseMetricsSnapshot metadata_network =
        network_phase_metrics(post_metadata_network, pre_metadata_network);
    static_cast<void>(write_metrics_file(
        metrics_path, {metadata_cache_metrics, {}, 0}, post_metadata_network,
        metadata_network, {}, bluray_metrics.snapshot(),
        source->remote_transfer_active_microseconds(), 0, {}));
    bridge::BlockCacheHandoff metadata_handoff;
    if (metadata_cache != nullptr) {
      metadata_handoff =
          metadata_cache->take_handoff(bridge::kIsoMetadataRetainedBytes);
    }
    const std::uint64_t metadata_retained_bytes =
        metadata_handoff.retained_bytes;

    bridge::BlockCache cache(
        source, bridge::kIsoDemandBlockSize, bridge::kIsoBlockCount,
        kIsoDemandBlockScale,
        remote_menu
            ? (virtual_disc ? 1 : bridge::kInitialPlaybackPrefetchBatchBlocks) * kIsoDemandBlockScale
            : 2 * 1024 * 1024 / bridge::kIsoDemandBlockSize,
        bridge::kPlaybackPrefetchBatchBlocks * kIsoDemandBlockScale,
        remote_menu ? 0 : bridge::kInitialPlaybackPrefetchBatchBlocks * kIsoDemandBlockScale,
        !remote_menu);
    if (metadata_cache != nullptr) {
      cache.restore_handoff(std::move(metadata_handoff));
      metadata_cache.reset();
    }
    const std::string token = random_token();
    std::unique_ptr<bridge::RemoteDiscProvider> remote_disc;
    if (remote_menu && !virtual_disc) {
      if (source->size() % bridge::RemoteDiscProvider::kSectorBytes != 0) {
        throw BridgeException("invalid_disc", "Invalid ISO sector length");
      }
      remote_disc = std::make_unique<bridge::RemoteDiscProvider>(cache, source->size());
    }
    std::unique_ptr<LoopbackHttpServer> server;
    std::uint16_t port = 0;
    if (!virtual_disc) {
      server = std::make_unique<LoopbackHttpServer>(api, cache, titles, token,
          bluray_metrics, bridge_started, remote_disc.get());
      port = server->start();
    }
    std::unique_ptr<bridge::WinFspDisc> mounted_disc;
    const auto mount_path = metrics_path.parent_path() / L"disc";
    if (virtual_disc) {
      if (!bridge::WinFspDisc::available()) {
        throw BridgeException("winfsp_unavailable", "WinFsp runtime is unavailable");
      }
      mounted_disc = std::make_unique<bridge::WinFspDisc>(cache, source->size(), mount_path, true);
    }
    const auto write_snapshot = [&](bool final_snapshot = false) {
      const NetworkMetricsSnapshot current_network = source->metrics();
      return write_metrics_file(
          metrics_path,
          {metadata_cache_metrics, cache.metrics(), metadata_retained_bytes},
          current_network, metadata_network,
          network_phase_metrics(current_network, post_metadata_network),
          bluray_metrics.snapshot(),
          source->remote_transfer_active_microseconds(),
          server ? server->first_media_response_ready_us() : 0,
          mounted_disc ? (mounted_disc->failed() ? "network_error" : "") : server->last_error_code(),
          final_snapshot, remote_disc != nullptr
              ? std::optional<std::uint64_t>(remote_disc->cancelled_generations())
              : std::nullopt, mounted_disc ? mounted_disc->metrics_json() : "");
    };
    bool final_snapshot_written = false;
    ScopeExit final_metrics([&] {
      if (!final_snapshot_written) static_cast<void>(write_snapshot());
    });
    std::string ready = ready_json(port, token, source->size(), titles);
    if (remote_menu) {
      ready.pop_back();
      if (virtual_disc) {
        ready += R"(,"capability":"winfsp-disc-v1","mode":"hdmv","discPath":)" +
            bridge::json_escape(utf8_from_wide((mount_path / L"disc.iso").wstring())) + "}";
      } else {
        ready += R"(,"capability":"remote-disc-blocks-v1","mode":"hdmv"})";
      }
    }
    if (!write_frame(pipe.get(), ready)) {
      return 0;
    }
    write_snapshot();
    std::future<bool> structure_cache_write;
    if (should_write_structure_cache) {
      try {
        const bridge::StructureCacheIdentity identity = *structure_identity;
        structure_cache_write = std::async(
            std::launch::async, [structure_path, identity, &titles] {
              return bridge::write_structure_cache(structure_path, identity,
                                                   titles);
            });
      } catch (...) {
        // 缓存写入启动失败不影响已经就绪的播放会话。
      }
    }

    bool cache_configured = false;
    while (true) {
      const auto frame = read_frame(pipe.get());
      if (!frame.has_value()) return 0;
      const auto message = bridge::parse_json_object(*frame);
      if (!message.has_value()) {
        throw BridgeException("protocol_error", "The control message is invalid");
      }
      const auto type = json_string(*message, "type");
      if (type == "shutdown") return 0;
      if (type == "metrics") {
        write_snapshot();
        const NetworkMetricsSnapshot current_network = source->metrics();
        if (!write_frame(pipe.get(),
                         metrics_json(
                             {metadata_cache_metrics, cache.metrics(),
                              metadata_retained_bytes},
                             current_network, metadata_network,
                             network_phase_metrics(current_network,
                                                   post_metadata_network),
                             bluray_metrics.snapshot(),
                             source->remote_transfer_active_microseconds(),
                             server ? server->first_media_response_ready_us() : 0, {}, true))) {
          return 0;
        }
        continue;
      }
      if (type == "configure_cache") {
        if (cache_configured) {
          throw BridgeException("protocol_error",
                                "The cache was already configured");
        }
        const auto block_count = json_integer(*message, "blockCount");
        const auto prefetch_blocks = json_integer(*message, "prefetchBlocks");
        const auto cache_seconds = json_integer(*message, "cacheSecs");
        if (!block_count.has_value() || !prefetch_blocks.has_value() ||
            *block_count < 4 || *block_count > (virtual_disc ? 256 : 16) || *prefetch_blocks < 4 ||
            *prefetch_blocks > (virtual_disc ? std::max<std::int64_t>(4, *block_count * 3 / 4) : 12) ||
            (cache_seconds.has_value() &&
             (!virtual_disc || *cache_seconds < 0 || *cache_seconds > 600))) {
          throw BridgeException("protocol_error",
                                "The cache configuration is invalid");
        }
        cache.configure(static_cast<std::size_t>(*block_count),
                        static_cast<std::size_t>(*prefetch_blocks), virtual_disc,
                        !remote_menu);
        if (mounted_disc)
          mounted_disc->configure_read_ahead(
              static_cast<unsigned>(cache_seconds.value_or(60)));
        cache_configured = true;
        if (!write_frame(pipe.get(),
                         R"({"type":"ready","configured":true})")) {
          return 0;
        }
        continue;
      }
      if (type == "attachPlayer") {
        const auto player_pid = json_integer(*message, "pid");
        if (!player_pid.has_value() || *player_pid <= 0 ||
            *player_pid > std::numeric_limits<DWORD>::max()) {
          throw BridgeException("protocol_error", "The player PID is invalid");
        }
        KernelHandle player(OpenProcess(
            SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
            static_cast<DWORD>(*player_pid)));
        if (!player || !is_mpv_process(player.get())) {
          throw BridgeException("protocol_error", "The attached process is not MPV");
        }
        if (!write_frame(pipe.get(), ready_json(0, {}, 0, {}, true))) return 0;
        FlushFileBuffers(pipe.get());
        DisconnectNamedPipe(pipe.get());
        pipe.reset();
        auto last_metrics_write = std::chrono::steady_clock::now();
        bool first_response_written = false;
        while (WaitForSingleObject(player.get(), 100) == WAIT_TIMEOUT) {
          const auto now = std::chrono::steady_clock::now();
          const bool first_response_ready =
              server && server->first_media_response_ready_us() != 0;
          if ((first_response_ready && !first_response_written) ||
              now - last_metrics_write >= std::chrono::seconds(1)) {
            write_snapshot();
            last_metrics_write = now;
            first_response_written =
                first_response_written || first_response_ready;
          }
        }
        if (mounted_disc) mounted_disc->stop();
        if (server) server->stop();
        cache.shutdown();
        final_snapshot_written = write_snapshot(true);
        return 0;
      }
      throw BridgeException("protocol_error", "The control message type is invalid");
    }
  } catch (const BridgeException& error) {
    write_frame(pipe.get(), error_json(error.code(), error.what()));
    return 5;
  } catch (...) {
    write_frame(pipe.get(), error_json("internal_error", "The ISO Bridge failed"));
    return 6;
  }
}

}  // namespace

#ifndef STREAMPATH_ISO_BRIDGE_TESTING
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (arguments == nullptr) return 2;
  if (count == 2 && wcscmp(arguments[1], L"--check-winfsp") == 0) {
    LocalFree(arguments);
    return bridge::WinFspDisc::available() ? 0 : 7;
  }
  std::wstring pipe_name;
  DWORD parent_pid = 0;
  for (int index = 1; index < count; ++index) {
    const std::wstring_view argument(arguments[index]);
    constexpr std::wstring_view kPipePrefix = L"--pipe=";
    constexpr std::wstring_view kParentPrefix = L"--parent-pid=";
    if (argument.rfind(kPipePrefix, 0) == 0) {
      pipe_name = argument.substr(kPipePrefix.size());
    } else if (argument.rfind(kParentPrefix, 0) == 0) {
      const std::wstring text(argument.substr(kParentPrefix.size()));
      wchar_t* end = nullptr;
      const unsigned long value = wcstoul(text.c_str(), &end, 10);
      if (end != text.c_str() + text.size() || value == 0 ||
          value > std::numeric_limits<DWORD>::max()) {
        LocalFree(arguments);
        return 2;
      }
      parent_pid = static_cast<DWORD>(value);
    }
  }
  LocalFree(arguments);
  try {
    return run_helper(std::move(pipe_name), parent_pid);
  } catch (...) {
    return 6;
  }
}
#endif
