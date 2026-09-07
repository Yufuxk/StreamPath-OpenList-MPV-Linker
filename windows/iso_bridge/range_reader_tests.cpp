#include <condition_variable>
#include <functional>
#include <iostream>
#include <iterator>

#include "main.cpp"

extern "C" {
void* test_disc_open(const char*, HANDLE);
void test_disc_close(void*);
int test_disc_read(void*, void*, int, int);
void test_disc_advance(void*);
}

namespace {

struct TestRequest {
  std::string method;
  std::string target;
  std::map<std::string, std::string> headers;
};

struct TestResponse {
  int status = 200;
  std::vector<std::pair<std::string, std::string>> headers;
  std::string body;
};

std::string trim_ascii(std::string value) {
  const auto first = value.find_first_not_of(" \t");
  if (first == std::string::npos) return {};
  const auto last = value.find_last_not_of(" \t");
  return value.substr(first, last - first + 1);
}

TestRequest parse_test_request(const std::string& text) {
  TestRequest result;
  const auto first_end = text.find("\r\n");
  if (first_end == std::string::npos) return result;
  const std::string first = text.substr(0, first_end);
  const auto method_end = first.find(' ');
  const auto target_end = first.find(' ', method_end + 1);
  if (method_end == std::string::npos || target_end == std::string::npos) {
    return result;
  }
  result.method = first.substr(0, method_end);
  result.target = first.substr(method_end + 1, target_end - method_end - 1);
  std::size_t cursor = first_end + 2;
  while (cursor < text.size()) {
    const auto line_end = text.find("\r\n", cursor);
    if (line_end == std::string::npos || line_end == cursor) break;
    const std::string line = text.substr(cursor, line_end - cursor);
    const auto separator = line.find(':');
    if (separator != std::string::npos) {
      result.headers[lowercase_ascii(line.substr(0, separator))] =
          trim_ascii(line.substr(separator + 1));
    }
    cursor = line_end + 2;
  }
  return result;
}

const char* reason_phrase(int status) {
  switch (status) {
    case 200:
      return "OK";
    case 206:
      return "Partial Content";
    case 302:
      return "Found";
    case 405:
      return "Method Not Allowed";
    default:
      return "Error";
  }
}

void send_all(SOCKET socket, const std::string& bytes) {
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const int sent = send(socket, bytes.data() + offset,
                          static_cast<int>(bytes.size() - offset), 0);
    if (sent <= 0) return;
    offset += static_cast<std::size_t>(sent);
  }
}

class TestHttpServer final {
 public:
  using Handler = std::function<TestResponse(std::size_t, const TestRequest&)>;

  explicit TestHttpServer(Handler handler, bool keep_alive = false)
      : handler_(std::move(handler)), keep_alive_(keep_alive) {
    listener_.reset(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    if (!listener_) throw std::runtime_error("create test socket");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener_.get(), reinterpret_cast<const sockaddr*>(&address),
             sizeof(address)) == SOCKET_ERROR ||
        listen(listener_.get(), SOMAXCONN) == SOCKET_ERROR) {
      throw std::runtime_error("bind test socket");
    }
    int length = sizeof(address);
    if (getsockname(listener_.get(), reinterpret_cast<sockaddr*>(&address),
                    &length) == SOCKET_ERROR) {
      throw std::runtime_error("read test port");
    }
    port_ = ntohs(address.sin_port);
    worker_ = std::thread([this] { serve(); });
  }

  ~TestHttpServer() {
    stopping_ = true;
    {
      std::lock_guard lock(clients_mutex_);
      for (const SOCKET client : clients_) shutdown(client, SD_BOTH);
    }
    if (worker_.joinable()) worker_.join();
    for (auto& worker : connection_workers_) {
      if (worker.joinable()) worker.join();
    }
    listener_.reset();
  }

  std::string url(std::string_view path = "/disc.iso") const {
    return "http://127.0.0.1:" + std::to_string(port_) + std::string(path);
  }

  std::vector<TestRequest> requests() const {
    std::lock_guard lock(mutex_);
    return requests_;
  }

  std::vector<std::size_t> requests_per_connection() const {
    std::lock_guard lock(mutex_);
    return requests_per_connection_;
  }

 private:
  void serve() {
    while (!stopping_) {
      fd_set readable;
      FD_ZERO(&readable);
      FD_SET(listener_.get(), &readable);
      timeval timeout{};
      timeout.tv_usec = 100000;
      const int selected = select(0, &readable, nullptr, nullptr, &timeout);
      if (selected <= 0) continue;
      const SOCKET accepted = accept(listener_.get(), nullptr, nullptr);
      if (accepted == INVALID_SOCKET) continue;
      std::size_t connection_index = 0;
      {
        std::lock_guard lock(mutex_);
        connection_index = requests_per_connection_.size();
        requests_per_connection_.push_back(0);
      }
      connection_workers_.emplace_back(
          [this, connection_index, client = SocketHandle(accepted)]() mutable {
            serve_connection(std::move(client), connection_index);
          });
    }
  }

  void serve_connection(SocketHandle client, std::size_t connection_index) {
    const SOCKET socket = client.get();
    {
      std::lock_guard lock(clients_mutex_);
      clients_.push_back(socket);
    }
    ScopeExit unregister([this, socket] {
      std::lock_guard lock(clients_mutex_);
      clients_.erase(std::remove(clients_.begin(), clients_.end(), socket),
                     clients_.end());
    });

    std::string raw;
    std::array<char, 2048> buffer{};
    while (!stopping_) {
      while (raw.find("\r\n\r\n") == std::string::npos &&
             raw.size() < kMaximumHttpHeaderBytes && !stopping_) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socket, &readable);
        timeval timeout{};
        timeout.tv_usec = 100000;
        const int selected = select(0, &readable, nullptr, nullptr, &timeout);
        if (selected < 0) return;
        if (selected == 0) continue;
        const int received =
            recv(socket, buffer.data(), static_cast<int>(buffer.size()), 0);
        if (received <= 0) return;
        raw.append(buffer.data(), static_cast<std::size_t>(received));
      }
      const auto header_end = raw.find("\r\n\r\n");
      if (header_end == std::string::npos) return;
      const std::string request_text = raw.substr(0, header_end + 4);
      raw.erase(0, header_end + 4);
      const TestRequest request = parse_test_request(request_text);
      std::size_t index = 0;
      {
        std::lock_guard lock(mutex_);
        index = requests_.size();
        requests_.push_back(request);
        ++requests_per_connection_[connection_index];
      }
      const TestResponse response = handler_(index, request);
      std::ostringstream headers;
      headers << "HTTP/1.1 " << response.status << ' '
              << reason_phrase(response.status) << "\r\n";
      bool has_length = false;
      bool has_connection = false;
      for (const auto& [name, value] : response.headers) {
        if (lowercase_ascii(name) == "content-length") has_length = true;
        if (lowercase_ascii(name) == "connection") has_connection = true;
        headers << name << ": " << value << "\r\n";
      }
      if (!has_length) headers << "Content-Length: " << response.body.size() << "\r\n";
      const auto connection = request.headers.find("connection");
      const bool client_closes =
          connection != request.headers.end() &&
          lowercase_ascii(connection->second) == "close";
      const bool keep_connection = keep_alive_ && !client_closes;
      if (!has_connection) {
        headers << "Connection: "
                << (keep_connection ? "keep-alive" : "close") << "\r\n";
      }
      headers << "\r\n";
      send_all(socket, headers.str());
      if (request.method != "HEAD") send_all(socket, response.body);
      if (!keep_connection) return;
    }
  }

  Handler handler_;
  bool keep_alive_ = false;
  SocketHandle listener_;
  std::uint16_t port_ = 0;
  std::atomic<bool> stopping_ = false;
  std::thread worker_;
  std::vector<std::thread> connection_workers_;
  mutable std::mutex clients_mutex_;
  std::vector<SOCKET> clients_;
  mutable std::mutex mutex_;
  std::vector<TestRequest> requests_;
  std::vector<std::size_t> requests_per_connection_;
};

void expect_network(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <typename Callback>
void expect_bridge_error(Callback callback, std::string_view code) {
  try {
    callback();
  } catch (const BridgeException& error) {
    expect_network(error.code() == code, "unexpected bridge error code");
    return;
  }
  throw std::runtime_error("expected bridge error");
}

TestResponse valid_range_response(const TestRequest& request,
                                  std::string_view validator = "\"v1\"") {
  const auto range = request.headers.find("range");
  if (range == request.headers.end()) return {405, {}, {}};
  const auto separator = range->second.find('-');
  const auto equals = range->second.find('=');
  const std::uint64_t start = std::stoull(
      range->second.substr(equals + 1, separator - equals - 1));
  const std::uint64_t end = std::stoull(range->second.substr(separator + 1));
  std::string body;
  for (std::uint64_t position = start; position <= end; ++position) {
    body.push_back(static_cast<char>('A' + position));
  }
  return {206,
          {{"Content-Range", "bytes " + std::to_string(start) + "-" +
                                 std::to_string(end) + "/8"},
           {"ETag", std::string(validator)}},
          body};
}

TestResponse large_range_response(const TestRequest& request) {
  constexpr std::uint64_t total = kMaximumIsoRangeBytes + 1;
  const auto range = request.headers.find("range");
  if (range == request.headers.end()) return {405, {}, {}};
  const auto separator = range->second.find('-');
  const auto equals = range->second.find('=');
  const std::uint64_t start = std::stoull(
      range->second.substr(equals + 1, separator - equals - 1));
  const std::uint64_t end = std::stoull(range->second.substr(separator + 1));
  return {206,
          {{"Content-Range", "bytes " + std::to_string(start) + "-" +
                                 std::to_string(end) + "/" +
                                 std::to_string(total)},
           {"ETag", "\"v1\""}},
          std::string(static_cast<std::size_t>(end - start + 1), 'Z')};
}

class DiscReadFailureSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 4096; }

  std::vector<std::uint8_t> fetch(std::uint64_t,
                                  std::uint64_t) override {
    throw BridgeException("network_error", "injected disc read failure");
  }
};

void test_disc_read_distinguishes_error_from_cancellation() {
  auto source = std::make_shared<DiscReadFailureSource>();
  bridge::BlockCache cache(source, 2048, 4);
  std::array<std::uint8_t, 2048> bytes{};
  DiscReadContext context;
  context.cache = &cache;
  context.playback_generation = cache.begin_playback();
  expect_network(read_disc_blocks(&context, bytes.data(), 0, 1) == 0 &&
                     context.read_error,
                 "disc callback preserves a hard read error");
  try {
    std::rethrow_exception(context.read_error);
  } catch (const BridgeException& error) {
    expect_network(error.code() == "network_error",
                   "disc callback preserves the network error code");
  }

  const auto stale_generation = context.playback_generation;
  context.bind_playback(4, stale_generation);
  expect_network(static_cast<bool>(context.read_error),
                 "same generation keeps its hard read error");
  context.bind_playback(0, stale_generation + 1);
  expect_network(!context.read_error && context.read_ahead_blocks == 0 &&
                     context.playback_generation == stale_generation + 1,
                 "new generation clears only the stale callback error");
  static_cast<void>(cache.begin_playback());
  context.playback_generation = stale_generation;
  expect_network(read_disc_blocks(&context, bytes.data(), 0, 1) == 0 &&
                     !context.read_error,
                 "stale playback cancellation remains a clean callback stop");
}

void test_unknown_head_and_exact_range() {
  TestHttpServer server([](std::size_t, const TestRequest& request) {
    return valid_range_response(request);
  });
  WinHttpRangeSource source(server.url(), server.url("/"), "user", "pass");
  const auto bytes = source.fetch(1, 3);
  expect_network(bytes == std::vector<std::uint8_t>({'B', 'C', 'D'}),
                 "exact range bytes");
  const auto requests = server.requests();
  expect_network(requests.size() == 3 && requests[0].method == "HEAD",
                 "HEAD is advisory");
  for (const auto& request : requests) {
    expect_network(request.headers.at("authorization") ==
                       "Basic dXNlcjpwYXNz",
                   "same-origin authorization");
    expect_network(request.headers.at("accept-encoding") == "identity",
                   "identity encoding");
  }
  expect_network(requests[2].headers.at("if-range") == "\"v1\"",
                 "strong ETag If-Range");
  expect_network(
      source.structure_cache_validator_kind() ==
              bridge::StructureCacheValidatorKind::strong_etag &&
          !source.validator().empty(),
      "strong ETag is exposed only as the in-memory cache identity");
  const auto metrics = source.metrics();
  expect_network(metrics.request_count == 3 && metrics.redirect_count == 0 &&
                     metrics.remote_body_bytes == 3 &&
                     metrics.probe_body_bytes == 1 &&
                     metrics.active_request_peak == 1 &&
                     metrics.request_context_created_count == 3 &&
                     metrics.request_context_closed_count == 3 &&
                     metrics.request_context_live == 0 &&
                     metrics.request_context_peak == 1 &&
                     metrics.response_body_active_us_total > 0,
                  "network metric domains are separated");
}

void test_request_contexts_close_after_normal_requests() {
  TestHttpServer server(
      [](std::size_t, const TestRequest& request) {
        return valid_range_response(request);
      },
      true);
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  constexpr std::size_t fetch_count = 128;
  for (std::size_t index = 0; index < fetch_count; ++index) {
    const std::uint64_t offset = static_cast<std::uint64_t>(index % 8);
    const auto bytes = source.fetch(offset, offset);
    expect_network(bytes.size() == 1, "normal request returns one byte");
  }
  const auto metrics = source.metrics();
  expect_network(
      metrics.request_context_created_count == fetch_count + 2 &&
          metrics.request_context_closed_count ==
              metrics.request_context_created_count &&
          metrics.request_context_live == 0 &&
          metrics.request_context_peak == 1,
      "normal request contexts are destroyed without a self reference");
}

void test_cross_origin_redirect_strips_auth() {
  TestHttpServer target([](std::size_t, const TestRequest& request) {
    return valid_range_response(request);
  });
  TestHttpServer origin([&](std::size_t, const TestRequest&) {
    return TestResponse{
        302, {{"Location", target.url("/disc.iso?signature=phase2-secret")}}, {}};
  });
  WinHttpRangeSource source(origin.url("/disc.iso?origin-secret=1"),
                            origin.url("/"), "user", "pass");
  source.fetch(0, 1);
  source.fetch(2, 3);
  const auto origin_requests = origin.requests();
  const auto target_requests = target.requests();
  expect_network(origin_requests.size() == 1 &&
                     origin_requests.front().headers.count("authorization") == 1,
                 "resolved origin is requested only once with authorization");
  expect_network(target_requests.size() == 4, "redirect target requests");
  for (const auto& request : target_requests) {
    expect_network(request.headers.count("authorization") == 0,
                   "cross-origin authorization stripped");
  }
  const auto metrics = source.metrics();
  expect_network(metrics.request_count == 5 && metrics.redirect_count == 1 &&
                     metrics.redirect_resolve_count == 1 &&
                     metrics.resolved_url_reuse_count == 3,
                 "redirect resolution and reuse metrics");
  const auto json = metrics_json({}, metrics, {}, {}, {}, 0, 0, {});
  expect_network(json.find("phase2-secret") == std::string::npos &&
                     json.find("origin-secret") == std::string::npos &&
                     json.find("Location") == std::string::npos,
                 "redirect details stay out of metrics");
}

void test_resolved_url_failure_is_anonymous_and_not_retried() {
  TestHttpServer target([](std::size_t index, const TestRequest& request) {
    if (index >= 2) return TestResponse{403, {}, {}};
    return valid_range_response(request);
  });
  TestHttpServer origin([&](std::size_t, const TestRequest&) {
    return TestResponse{
        302, {{"Location", target.url("/disc.iso?signature=expired-secret")}}, {}};
  });
  WinHttpRangeSource source(origin.url("/disc.iso?origin-secret=2"),
                            origin.url("/"), "user", "pass");

  std::string message;
  try {
    static_cast<void>(source.fetch(0, 1));
  } catch (const BridgeException& error) {
    expect_network(error.code() == "network_error",
                   "resolved endpoint failure keeps the network error code");
    message = error.what();
  }
  expect_network(!message.empty() && message.find("http") == std::string::npos &&
                     message.find("secret") == std::string::npos &&
                     message.find("Location") == std::string::npos,
                 "resolved endpoint failure is anonymous");
  expect_network(origin.requests().size() == 1 && target.requests().size() == 3,
                 "resolved endpoint failure does not retry the origin");
  const auto metrics = source.metrics();
  expect_network(metrics.request_count == 4 && metrics.redirect_count == 1 &&
                     metrics.redirect_resolve_count == 1 &&
                     metrics.resolved_url_reuse_count == 2,
                 "failed resolved endpoint reuse is measured once");
}

void test_winhttp_session_reuses_keep_alive_connections() {
  TestHttpServer server(
      [](std::size_t, const TestRequest& request) {
        if (request.headers.count("if-range") != 0) {
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        return valid_range_response(request);
      },
      true);
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  auto per_connection = server.requests_per_connection();
  expect_network(per_connection.size() == 1 && per_connection.front() == 2,
                 "HEAD and Range probe reuse one keep-alive connection");

  constexpr std::size_t request_count = 4;
  std::mutex start_mutex;
  std::condition_variable start_ready;
  std::size_t ready = 0;
  bool start = false;
  std::array<std::vector<std::uint8_t>, request_count> results;
  std::array<std::thread, request_count> readers;
  std::atomic<bool> failed = false;
  for (std::size_t index = 0; index < readers.size(); ++index) {
    readers[index] = std::thread([&, index] {
      {
        std::unique_lock lock(start_mutex);
        ++ready;
        start_ready.notify_all();
        start_ready.wait(lock, [&] { return start; });
      }
      try {
        const auto range_start = static_cast<std::uint64_t>(index * 2);
        results[index] = source.fetch(range_start, range_start + 1);
      } catch (...) {
        failed = true;
      }
    });
  }
  {
    std::unique_lock lock(start_mutex);
    start_ready.wait(lock, [&] { return ready == request_count; });
    start = true;
  }
  start_ready.notify_all();
  for (auto& reader : readers) reader.join();

  per_connection = server.requests_per_connection();
  std::size_t recorded_requests = 0;
  std::size_t most_reused_connection = 0;
  for (const auto count : per_connection) {
    recorded_requests += count;
    most_reused_connection = std::max(most_reused_connection, count);
  }
  bool results_match = !failed;
  for (std::size_t index = 0; index < results.size(); ++index) {
    results_match = results_match && results[index].size() == 2 &&
                    results[index].front() ==
                        static_cast<std::uint8_t>('A' + index * 2);
  }
  const auto metrics = source.metrics();
  expect_network(results_match && recorded_requests == 6 &&
                     per_connection.size() >= 2 &&
                     per_connection.size() <= request_count &&
                      most_reused_connection >= 2 &&
                      metrics.active_request_peak >= 2 &&
                      metrics.active_request_peak <= request_count &&
                      metrics.remote_transfer_wall_clock_us > 0 &&
                      metrics.concurrent_transfer_wall_clock_us > 0,
                  "shared WinHTTP session reuses and bounds keep-alive connections");
}

void test_metrics_v2_is_atomic_and_anonymous() {
  bridge::BlockCacheMetrics cache;
  cache.fetched_bytes = 17;
  cache.foreground_fetch_bytes = 11;
  cache.prefetch_fetch_bytes = 6;
  cache.consumer_bytes_delivered = 13;
  cache.cache_miss_count = 2;
  cache.prefetch_unused_bytes = 3;
  cache.cancelled_foreground_bytes = 4;
  cache.cancelled_prefetch_bytes = 5;
  cache.eviction_count = 6;
  cache.refetch_count = 7;
  cache.prefetch_active_peak = 1;
  cache.prefetch_overlap_count = 2;
  cache.prefetch_pending_gap_us_total = 3;
  cache.prefetch_pending_gap_us_max = 4;
  cache.prefetch_in_flight_bytes_peak = 5;
  cache.prefetch_hit_bytes = 6;
  cache.prefetch_concurrent_wall_clock_us = 7;
  NetworkMetricsSnapshot network;
  network.request_count = 8;
  network.remote_body_bytes = 9;
  network.response_header_latency_us_total = 10;
  network.request_context_created_count = 18;
  network.request_context_closed_count = 18;
  network.request_context_live = 0;
  network.request_context_peak = 2;
  network.remote_transfer_wall_clock_us = 19;
  network.concurrent_transfer_wall_clock_us = 20;
  BlurayMetricsSnapshot bluray;
  bluray.context_create_count = 2;
  bluray.title_enumeration_us = 12;
  bluray.persistent_context_reuse_count = 13;
  bluray.time_seek_redirect_count = 14;
  bluray.maximum_time_seek_byte_delta = 15;
  bluray.media_failure_count = 1;
  bluray.last_media_failure_sequence = 16;
  bluray.last_media_failure_generation = 17;
  bluray.last_media_failure_http_status = 503;
  bluray.terminal_rejected_media_get_count = 2;
  bluray.structure_cache_hit = true;
  NetworkPhaseMetricsSnapshot metadata_network;
  metadata_network.request_count = 21;
  metadata_network.remote_body_bytes = 22;
  metadata_network.response_header_latency_us_total = 23;
  NetworkPhaseMetricsSnapshot playback_network;
  playback_network.request_count = 24;
  playback_network.remote_body_bytes = 25;
  const CacheMetricsSnapshot caches{{}, cache, 4096};
  const auto json = metrics_json(caches, network, metadata_network,
                                 playback_network, bluray, 14, 15, {}, false);
  expect_network(json.find("\"version\":2") != std::string::npos &&
                     json.find("\"network\"") != std::string::npos &&
                     json.find("\"cache\"") != std::string::npos &&
                     json.find("\"metadataCache\"") != std::string::npos &&
                     json.find("\"playbackCache\"") != std::string::npos &&
                     json.find("\"metadataNetwork\"") != std::string::npos &&
                     json.find("\"playbackNetwork\"") != std::string::npos &&
                     json.find("\"bluray\"") != std::string::npos &&
                     json.find("\"foregroundFetchBytes\":11") !=
                         std::string::npos &&
                     json.find("\"persistentContextReuseCount\":13") !=
                         std::string::npos &&
                     json.find("\"timeSeekRedirectCount\":14") !=
                         std::string::npos &&
                     json.find("\"requestContextClosedCount\":18") !=
                         std::string::npos &&
                     json.find("\"requestContextLive\":0") !=
                         std::string::npos &&
                     json.find("\"remoteTransferWallClockUs\":19") !=
                         std::string::npos &&
                     json.find("\"concurrentTransferWallClockUs\":20") !=
                         std::string::npos &&
                     json.find("\"prefetchActivePeak\":1") !=
                         std::string::npos &&
                     json.find("\"prefetchHitBytes\":6") !=
                         std::string::npos &&
                     json.find("\"retainedBytes\":4096") !=
                         std::string::npos &&
                     json.find("\"requestCount\":21") !=
                         std::string::npos &&
                     json.find("\"remoteBodyBytes\":25") !=
                         std::string::npos &&
                     json.find("\"lastMediaFailureSequence\":16") !=
                         std::string::npos &&
                     json.find("\"lastMediaFailureGeneration\":17") !=
                         std::string::npos &&
                     json.find("\"lastMediaFailureStatusCategory\":\"http_5xx\"") !=
                         std::string::npos &&
                     json.find("\"terminalRejectedMediaGetCount\":2") !=
                         std::string::npos &&
                     json.find("\"structureCacheHit\":true") !=
                         std::string::npos &&
                     json.find("\"timeSeekRedirectEnabled\":false") !=
                         std::string::npos &&
                     json.find("\"demandBlockBytes\":262144") !=
                         std::string::npos &&
                     json.find("remoteTransferBytes\":9") !=
                         std::string::npos,
                 "metrics v2 keeps grouped and legacy fields");
  expect_network(json.find("http://") == std::string::npos &&
                     json.find("https://") == std::string::npos &&
                     json.find("token") == std::string::npos &&
                     json.find("username") == std::string::npos,
                 "metrics v2 is anonymous");

  const auto path = std::filesystem::temp_directory_path() /
                    L"streampath-iso-metrics-v2-test.json";
  std::error_code ignored;
  std::filesystem::remove(path, ignored);
  write_metrics_file(path, caches, network, metadata_network,
                     playback_network, bluray, 14, 15, {});
  cache.fetched_bytes = 18;
  const CacheMetricsSnapshot updated_caches{{}, cache, 4096};
  const auto updated =
      metrics_json(updated_caches, network, metadata_network,
                   playback_network, bluray, 14, 15, {}, false, true);
  write_metrics_file(path, updated_caches, network, metadata_network,
                     playback_network, bluray, 14, 15, {}, true);
  std::ifstream input(path, std::ios::binary);
  const std::string stored((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  expect_network(stored == updated &&
                     stored.find("\"final\":true") != std::string::npos &&
                     !std::filesystem::exists(path.wstring() + L".tmp"),
                 "metrics v2 atomically replaces the snapshot");
  std::filesystem::remove(path, ignored);
}

void test_media_range_plan_preserves_declared_bytes_and_eof() {
  const auto unaligned = identity_media_range_plan(193, 999, 1000);
  expect_network(
      unaligned.packet_start == 192 && unaligned.skip_prefix == 1 &&
          unaligned.response_length == 807 &&
          unaligned.packet_start + unaligned.skip_prefix == 193 &&
          unaligned.packet_start + unaligned.skip_prefix +
                  unaligned.response_length ==
              unaligned.source_end_exclusive &&
          unaligned.source_end_exclusive == 1000,
      "declared EOF range consumes the real title through EOF");

  const auto middle = identity_media_range_plan(384, 575, 1000);
  expect_network(
      middle.packet_start == 384 && middle.skip_prefix == 0 &&
          middle.response_length == 192 &&
          middle.source_end_exclusive == 576,
      "aligned middle range remains an identity byte mapping");
  expect_bridge_error(
      [] { static_cast<void>(identity_media_range_plan(1000, 1000, 1000)); },
      "internal_error");
  expect_bridge_error([] { validate_time_seek_redirect_option(true); },
                      "protocol_error");
  validate_time_seek_redirect_option(false);
}

void test_generation_failure_state_does_not_poison_new_playback() {
  GenerationFailureState state;
  state.record(7, "network_error");
  const auto failed = state.snapshot();
  expect_network(failed.generation == 7 && failed.code == "network_error" &&
                     state.applies_to(7) && !state.applies_to(8),
                 "failure is bound to its playback generation");
  state.record(8, "internal_error");
  const auto latest = state.snapshot();
  expect_network(latest.generation == 8 && latest.code == "internal_error",
                 "new generation replaces stale terminal state atomically");
}

void test_capability_failures() {
  {
    TestHttpServer server([](std::size_t, const TestRequest&) {
      return TestResponse{200, {{"ETag", "\"v1\""}}, "A"};
    });
    expect_bridge_error(
        [&] { WinHttpRangeSource source(server.url(), server.url("/"), "", ""); },
        "range_unsupported");
  }
  {
    TestHttpServer server([](std::size_t, const TestRequest& request) {
      auto response = valid_range_response(request);
      if (request.method == "GET") response.headers[0].second = "bytes 1-1/8";
      return response;
    });
    expect_bridge_error(
        [&] { WinHttpRangeSource source(server.url(), server.url("/"), "", ""); },
        "range_unsupported");
  }
  {
    TestHttpServer server([](std::size_t, const TestRequest& request) {
      if (request.method == "HEAD") {
        return TestResponse{200,
                            {{"Content-Length", "9"}, {"ETag", "\"v1\""}},
                            {}};
      }
      return valid_range_response(request);
    });
    expect_bridge_error(
        [&] { WinHttpRangeSource source(server.url(), server.url("/"), "", ""); },
        "length_unavailable");
  }
}

void test_validator_change_and_interrupted_body() {
  {
    TestHttpServer server([](std::size_t index, const TestRequest& request) {
      return valid_range_response(request, index >= 2 ? "\"v2\"" : "\"v1\"");
    });
    WinHttpRangeSource source(server.url(), server.url("/"), "", "");
    expect_bridge_error([&] { source.fetch(0, 3); }, "remote_changed");
  }
  {
    TestHttpServer server([](std::size_t index, const TestRequest& request) {
      auto response = valid_range_response(request);
      if (index >= 2) {
        response.headers.emplace_back("Content-Length", "4");
        response.body = "AB";
      }
      return response;
    });
    WinHttpRangeSource source(server.url(), server.url("/"), "", "");
    expect_bridge_error([&] { source.fetch(0, 3); }, "network_error");
  }
}

void test_last_modified_and_redirect_limit() {
  {
    TestHttpServer server([](std::size_t, const TestRequest& request) {
      auto response = valid_range_response(request);
      for (auto& header : response.headers) {
        if (header.first == "ETag") {
          header = {"Last-Modified", "Wed, 27 Aug 2026 00:00:00 GMT"};
        }
      }
      return response;
    });
    WinHttpRangeSource source(server.url(), server.url("/"), "", "");
    source.fetch(0, 1);
    expect_network(source.structure_cache_validator_kind() ==
                       bridge::StructureCacheValidatorKind::last_modified,
                   "Last-Modified is a distinct structure cache identity");
    const auto requests = server.requests();
    expect_network(requests.back().headers.at("if-range") ==
                       "Wed, 27 Aug 2026 00:00:00 GMT",
                   "Last-Modified If-Range");
  }
  {
    TestHttpServer server([](std::size_t, const TestRequest&) {
      return TestResponse{302, {{"Location", "/loop"}}, {}};
    });
    expect_bridge_error(
        [&] { WinHttpRangeSource source(server.url(), server.url("/"), "", ""); },
        "network_error");
    expect_network(server.requests().size() == 12, "redirect limit");
  }
}

void test_playback_prefetch_range_size() {
  TestHttpServer server([](std::size_t, const TestRequest& request) {
    return large_range_response(request);
  });
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  const auto bytes = source.fetch(0, kMaximumIsoRangeBytes - 1);
  expect_network(bytes.size() == kMaximumIsoRangeBytes,
                 "playback prefetch range accepted");
  expect_bridge_error(
      [&] { source.fetch(0, kMaximumIsoRangeBytes); }, "network_error");
}

void test_cancelled_prefetch_skips_webdav_request() {
  TestHttpServer server([](std::size_t, const TestRequest& request) {
    return valid_range_response(request);
  });
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  bridge::BlockSource& block_source = source;
  bool cancelled = false;
  try {
    static_cast<void>(block_source.fetch(0, 3, [&] {
      cancelled = true;
      return true;
    }));
  } catch (const std::runtime_error&) {
  }
  expect_network(cancelled && server.requests().size() == 2,
                 "cancelled prefetch sends no stale range request");
}

void test_cancel_pending_aborts_slow_foreground_request() {
  TestHttpServer server([](std::size_t index, const TestRequest& request) {
    if (index == 2) std::this_thread::sleep_for(std::chrono::seconds(2));
    return valid_range_response(request);
  });
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  std::atomic<bool> completed = false;
  std::atomic<bool> cancelled = false;
  std::thread reader([&] {
    try {
      static_cast<void>(source.fetch(1, 3));
    } catch (const std::runtime_error&) {
      cancelled = true;
    }
    completed = true;
  });
  const auto request_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (server.requests().size() < 3 &&
         std::chrono::steady_clock::now() < request_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  const auto cancelled_at = std::chrono::steady_clock::now();
  source.cancel_pending();
  const auto completion_deadline =
      cancelled_at + std::chrono::milliseconds(500);
  while (!completed && std::chrono::steady_clock::now() < completion_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  const bool completed_promptly = completed;
  reader.join();
  expect_network(completed_promptly && cancelled,
                  "slow foreground request cancelled promptly");
  expect_network(source.remote_transfer_active_microseconds() > 0,
                  "cancelled transfer duration recorded");
  const auto metrics = source.metrics();
  expect_network(
      metrics.request_context_created_count ==
              metrics.request_context_closed_count &&
          metrics.request_context_live == 0,
      "cancelled request closes its context before the reader returns");
}

void test_cancelled_request_does_not_poison_keep_alive_session() {
  TestHttpServer server(
      [](std::size_t index, const TestRequest& request) {
        if (index == 2) {
          std::this_thread::sleep_for(std::chrono::milliseconds(750));
        }
        return valid_range_response(request);
      },
      true);
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  std::atomic<bool> cancelled = false;
  std::thread reader([&] {
    try {
      static_cast<void>(source.fetch(0, 1));
    } catch (const std::runtime_error&) {
      cancelled = true;
    }
  });
  const auto request_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (server.requests().size() < 3 &&
         std::chrono::steady_clock::now() < request_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  source.cancel_pending();
  reader.join();

  const auto bytes = source.fetch(4, 5);
  const auto per_connection = server.requests_per_connection();
  std::size_t recorded_requests = 0;
  for (const auto count : per_connection) recorded_requests += count;
  expect_network(cancelled && bytes == std::vector<std::uint8_t>({'E', 'F'}) &&
                     recorded_requests == 4 && per_connection.size() <= 2,
                  "cancelled request leaves the WinHTTP session reusable");
}

void test_repeated_cancellation_releases_request_contexts() {
  TestHttpServer server([](std::size_t index, const TestRequest& request) {
    if (index >= 2) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    return valid_range_response(request);
  });
  WinHttpRangeSource source(server.url(), server.url("/"), "", "");
  constexpr std::size_t cancellation_count = 64;
  for (std::size_t index = 0; index < cancellation_count; ++index) {
    std::atomic<bool> cancelled = false;
    std::thread reader([&] {
      try {
        static_cast<void>(source.fetch(0, 1));
      } catch (const bridge::FetchCancelled&) {
        cancelled = true;
      }
    });
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (server.requests().size() < index + 3 &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    source.cancel_pending();
    reader.join();
    expect_network(cancelled, "repeated request cancellation is observed");
  }
  const auto metrics = source.metrics();
  expect_network(
      metrics.request_context_created_count == cancellation_count + 2 &&
          metrics.request_context_closed_count ==
              metrics.request_context_created_count &&
          metrics.request_context_live == 0,
      "repeated cancellation leaves no request context alive");
}

struct FakePersistentContextState {
  std::mutex mutex;
  int created = 0;
  int destroyed = 0;
  int live = 0;
  int peak = 0;
};

class FakePersistentContext final {
public:
  explicit FakePersistentContext(
      const std::shared_ptr<FakePersistentContextState> &state)
      : state_(state) {
    std::lock_guard lock(state_->mutex);
    serial = ++state_->created;
    ++state_->live;
    state_->peak = std::max(state_->peak, state_->live);
  }

  ~FakePersistentContext() {
    std::lock_guard lock(state_->mutex);
    --state_->live;
    ++state_->destroyed;
  }

  int serial = 0;

private:
  std::shared_ptr<FakePersistentContextState> state_;
};

void test_persistent_context_reuses_same_title_and_switches_atomically() {
  auto state = std::make_shared<FakePersistentContextState>();
  PersistentContextSlot<FakePersistentContext> slot;
  const auto current = [] { return false; };
  const auto create = [&state] {
    return std::make_unique<FakePersistentContext>(state);
  };

  int first_serial = 0;
  {
    auto first = slot.acquire(1, std::chrono::seconds(0), current, create);
    expect_network(first.has_value() && !first->reused(),
                   "first title creates the primary context");
    first_serial = (*first)->serial;
  }
  {
    auto seek = slot.acquire(1, std::chrono::seconds(0), current, create);
    expect_network(seek.has_value() && seek->reused() &&
                       (*seek)->serial == first_serial,
                   "same-title seek reuses the primary context");
  }
  {
    auto next_title = slot.acquire(2, std::chrono::seconds(0), current, create);
    expect_network(next_title.has_value() && !next_title->reused() &&
                       (*next_title)->serial != first_serial,
                   "title switch replaces the primary context");
  }

  std::lock_guard lock(state->mutex);
  expect_network(state->created == 2 && state->destroyed == 1 &&
                     state->live == 1 && state->peak == 1,
                 "persistent context count remains bounded to one");
}

void test_persistent_context_a_b_c_cancels_waiter_and_recovers_failure() {
  auto state = std::make_shared<FakePersistentContextState>();
  PersistentContextSlot<FakePersistentContext> slot;
  std::atomic<std::uint64_t> generation = 1;
  const auto create = [&state] {
    return std::make_unique<FakePersistentContext>(state);
  };
  auto first = slot.acquire(
      1, std::chrono::seconds(0), [&generation] { return generation != 1; },
      create);
  expect_network(first.has_value(), "initial generation owns the context");

  generation = 2;
  std::atomic<bool> b_waiting = false;
  std::atomic<bool> b_acquired = false;
  std::chrono::milliseconds b_elapsed{};
  std::thread second([&] {
    const auto started = std::chrono::steady_clock::now();
    auto lease = slot.acquire(
        1, std::chrono::seconds(2),
        [&] {
          b_waiting = true;
          return generation != 2;
        },
        create);
    b_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started);
    b_acquired = lease.has_value();
  });
  const auto start_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!b_waiting && std::chrono::steady_clock::now() < start_deadline) {
    std::this_thread::yield();
  }
  const bool b_waiting_observed = b_waiting;
  generation = 3;
  std::atomic<bool> c_reused = false;
  std::thread third([&] {
    auto lease = slot.acquire(
        1, std::chrono::seconds(2), [&generation] { return generation != 3; },
        create);
    c_reused = lease.has_value() && lease->reused();
  });
  first.reset();
  second.join();
  third.join();

  expect_network(b_waiting_observed && !b_acquired &&
                     b_elapsed < std::chrono::seconds(1) && c_reused,
                 "A-B-C seek keeps only the latest generation");

  bool failed = false;
  try {
    auto broken = slot.acquire(
        2, std::chrono::seconds(0), [] { return false; },
        []() -> std::unique_ptr<FakePersistentContext> {
          throw std::runtime_error("injected context initialization failure");
        });
    static_cast<void>(broken);
  } catch (const std::runtime_error &) {
    failed = true;
  }
  auto recovered =
      slot.acquire(2, std::chrono::seconds(0), [] { return false; }, create);
  expect_network(failed && recovered.has_value() && !recovered->reused(),
                 "failed context initialization releases the slot");
  const int recovered_serial = (*recovered)->serial;
  recovered->invalidate();
  recovered.reset();
  auto after_hard_error =
      slot.acquire(2, std::chrono::seconds(0), [] { return false; }, create);
  expect_network(after_hard_error.has_value() &&
                     !after_hard_error->reused() &&
                     (*after_hard_error)->serial != recovered_serial,
                 "hard context failure forces a fresh context");
}

void test_persistent_context_stress_never_overlaps() {
  auto state = std::make_shared<FakePersistentContextState>();
  PersistentContextSlot<FakePersistentContext> slot;
  constexpr std::size_t worker_count = 8;
  std::mutex start_mutex;
  std::condition_variable start_ready;
  std::size_t ready = 0;
  bool start = false;
  std::atomic<std::size_t> completed = 0;
  std::array<std::thread, worker_count> workers;
  for (std::size_t index = 0; index < workers.size(); ++index) {
    workers[index] = std::thread([&, index] {
      {
        std::unique_lock lock(start_mutex);
        ++ready;
        start_ready.notify_all();
        start_ready.wait(lock, [&start] { return start; });
      }
      auto lease = slot.acquire(
          static_cast<std::uint32_t>(index % 2), std::chrono::seconds(2),
          [] { return false; },
          [&state] { return std::make_unique<FakePersistentContext>(state); });
      if (!lease.has_value())
        return;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      ++completed;
    });
  }
  {
    std::unique_lock lock(start_mutex);
    start_ready.wait(lock, [&] { return ready == worker_count; });
    start = true;
  }
  start_ready.notify_all();
  for (auto &worker : workers)
    worker.join();

  std::lock_guard lock(state->mutex);
  expect_network(completed == worker_count && state->peak == 1 &&
                     state->live == 1,
                 "concurrent handlers never overlap BLURAY contexts");
}

void test_loopback_socket_allows_cache_backpressure() {
  SocketHandle socket_handle(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  expect_network(static_cast<bool>(socket_handle), "test socket created");
  configure_loopback_client_socket(socket_handle.get());

  DWORD receive_timeout = 0;
  DWORD send_timeout = 1;
  int receive_length = sizeof(receive_timeout);
  int send_length = sizeof(send_timeout);
  expect_network(getsockopt(socket_handle.get(), SOL_SOCKET, SO_RCVTIMEO,
                            reinterpret_cast<char *>(&receive_timeout),
                            &receive_length) == 0 &&
                     getsockopt(socket_handle.get(), SOL_SOCKET, SO_SNDTIMEO,
                                reinterpret_cast<char *>(&send_timeout),
                                &send_length) == 0 &&
                     receive_timeout == 10000 && send_timeout == 0,
                 "loopback media output keeps an unlimited send timeout");
}

void test_hard_media_failure_uses_abortive_close() {
  SocketHandle socket_handle(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  expect_network(static_cast<bool>(socket_handle), "abort test socket created");
  fail_loopback_response(socket_handle.get(), true);
  linger option{};
  int option_length = sizeof(option);
  expect_network(getsockopt(socket_handle.get(), SOL_SOCKET, SO_LINGER,
                            reinterpret_cast<char *>(&option),
                            &option_length) == 0 &&
                     option.l_onoff == 1 && option.l_linger == 0,
                 "hard media failure configures an abortive socket close");
}

void test_media_failure_before_headers_returns_http_error() {
  SocketHandle listener(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  expect_network(static_cast<bool>(listener), "error listener created");
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  expect_network(bind(listener.get(),
                      reinterpret_cast<const sockaddr *>(&address),
                      sizeof(address)) == 0 &&
                     listen(listener.get(), 1) == 0,
                 "error listener bound");
  int address_length = sizeof(address);
  expect_network(getsockname(listener.get(),
                             reinterpret_cast<sockaddr *>(&address),
                             &address_length) == 0,
                 "error listener port read");

  SocketHandle client(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  expect_network(static_cast<bool>(client) &&
                     connect(client.get(),
                             reinterpret_cast<const sockaddr *>(&address),
                             sizeof(address)) == 0,
                 "error client connected");
  SocketHandle server(accept(listener.get(), nullptr, nullptr));
  expect_network(static_cast<bool>(server), "error server accepted");
  fail_loopback_response(server.get(), false);

  std::array<char, 256> response{};
  const int received =
      recv(client.get(), response.data(), static_cast<int>(response.size()), 0);
  expect_network(
      received > 0 &&
          std::string_view(response.data(), static_cast<std::size_t>(received))
                  .rfind("HTTP/1.1 500 Internal Server Error\r\n", 0) == 0,
      "media failure before headers returns HTTP 500");
}

void test_fixed_libbluray_runtime_version() {
  const auto source_directory = std::filesystem::path(__FILE__).parent_path();
  LibblurayApi api(source_directory / L"third_party" / L"libbluray" / L"bin");
  static_cast<void>(api);
}

void test_latest_media_socket_closes_previous_response() {
  SocketHandle listener(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  expect_network(static_cast<bool>(listener), "handover listener created");
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  expect_network(bind(listener.get(),
                      reinterpret_cast<const sockaddr *>(&address),
                      sizeof(address)) == 0 &&
                     listen(listener.get(), 2) == 0,
                 "handover listener bound");
  int address_length = sizeof(address);
  expect_network(getsockname(listener.get(),
                             reinterpret_cast<sockaddr *>(&address),
                             &address_length) == 0,
                 "handover port read");

  const auto connect_client = [&address, &listener]() {
    SocketHandle client(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    expect_network(static_cast<bool>(client), "handover client created");
    expect_network(connect(client.get(),
                           reinterpret_cast<const sockaddr *>(&address),
                           sizeof(address)) == 0,
                   "handover client connected");
    SocketHandle server(accept(listener.get(), nullptr, nullptr));
    expect_network(static_cast<bool>(server), "handover server accepted");
    return std::pair<SocketHandle, SocketHandle>(std::move(client),
                                                 std::move(server));
  };

  auto first = connect_client();
  auto second = connect_client();
  auto stale = connect_client();
  MediaSocketRegistry registry;
  auto first_lease = registry.activate(first.second.get(), 1);
  auto second_lease = registry.activate(second.second.get(), 2);
  auto stale_lease = registry.activate(stale.second.get(), 1);
  expect_network(first_lease.has_value() && second_lease.has_value(),
                 "ordered media requests activate");
  expect_network(!stale_lease.has_value(),
                 "late old media request is rejected");
  const DWORD receive_timeout_ms = 1000;
  setsockopt(first.first.get(), SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&receive_timeout_ms),
             sizeof(receive_timeout_ms));
  char byte = 0;
  expect_network(recv(first.first.get(), &byte, 1, 0) == 0,
                 "new media request closes previous response");
  const char marker = 'x';
  expect_network(send(second.second.get(), &marker, 1, 0) == 1 &&
                     recv(second.first.get(), &byte, 1, 0) == 1 &&
                     byte == marker,
                 "latest media response remains active after stale request");
}

}  // namespace

void test_remote_disc_endpoint_with_adapter() {
  class Source final : public bridge::BlockSource {
   public:
    std::uint64_t size() const override { return 16 * bridge::kIsoBlockSize; }
    std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end) override {
      std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
      for (std::size_t i = 0; i < bytes.size(); ++i)
        bytes[i] = static_cast<std::uint8_t>((start + i) / 2048 % 251);
      return bytes;
    }
  };
  auto source = std::make_shared<Source>();
  bridge::BlockCache cache(source, bridge::kIsoDemandBlockSize, 64);
  bridge::RemoteDiscProvider provider(cache, source->size());
  LibblurayApi api(std::filesystem::path(__FILE__).parent_path() /
                  L"third_party" / L"libbluray" / L"bin");
  BlurayMetrics metrics;
  const std::string token = "0123456789abcdef0123456789abcdef";
  LoopbackHttpServer server(api, cache, {}, token, metrics,
    std::chrono::steady_clock::now(), &provider);
  const auto port = server.start();
  KernelHandle cancel(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  const auto url = "http://127.0.0.1:" + std::to_string(port) + "/" + token + "/disc.iso";
  void* disc = test_disc_open(url.c_str(), cancel.get());
  expect_network(disc != nullptr, "adapter consumes real remote-disc HEAD");
  ScopeExit close([&] { test_disc_close(disc); });
  std::vector<std::uint8_t> bytes(2048);
  for (const int lba : {23, 777, 500, 1}) {
    expect_network(test_disc_read(disc, bytes.data(), lba, 1) == 1,
      "real endpoint serves aligned blocks");
    expect_network(std::all_of(bytes.begin(), bytes.end(), [lba](auto value) {
      return value == lba % 251;
    }), "actual endpoint bytes preserve position");
    test_disc_advance(disc);
  }
  expect_network(provider.cancelled_generations() == 4,
    "HEAD advances generation without waiting for a subsequent read");
  SocketHandle pending(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(port);
  expect_network(connect(pending.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
    "pending header client connected");
  send_all(pending.get(), "GET /incomplete");
  const auto before = std::chrono::steady_clock::now();
  server.stop();
  expect_network(std::chrono::steady_clock::now() - before < std::chrono::seconds(1),
    "menu stop closes sockets without header timeout");
}

void test_remote_mpv_block_adapter() {
  constexpr std::uint64_t total = 16 * bridge::kIsoBlockSize;
  TestHttpServer server([total](std::size_t, const TestRequest& request) {
    TestResponse response;
    if (request.method == "HEAD") {
      response.headers.emplace_back("Content-Length", std::to_string(total));
      return response;
    }
    const auto range = bridge::parse_byte_range(request.headers.at("range"), total);
    expect_network(range.status == bridge::ByteRangeStatus::ok, "adapter emits valid range");
    expect_network(request.headers.at("accept-encoding") == "identity", "adapter identity encoding");
    expect_network(request.headers.at("x-streampath-phase") == "metadata", "adapter metadata demand only");
    expect_network(request.headers.count("authorization") == 0, "adapter never carries upstream auth");
    response.status = 206;
    response.headers.emplace_back("Content-Range", "bytes " + std::to_string(range.start) +
        "-" + std::to_string(range.end) + "/" + std::to_string(total));
    response.body.resize(static_cast<std::size_t>(range.end - range.start + 1));
    for (std::size_t i = 0; i < response.body.size(); ++i) {
      const auto offset = range.start + i;
      response.body[i] = static_cast<char>((offset ^ (offset >> 11)) & 255);
    }
    return response;
  });
  KernelHandle cancel(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  void* disc = test_disc_open(server.url("/0123456789abcdef0123456789abcdef/disc.iso").c_str(), cancel.get());
  expect_network(disc != nullptr, "adapter opens token-bound loopback endpoint");
  ScopeExit close([&] { test_disc_close(disc); });
  std::vector<std::uint8_t> bytes(9 * 2048);
  for (const int lba : {1, 100, 3, 777, 8}) {
    expect_network(test_disc_read(disc, bytes.data(), lba, 9) == 9, "adapter returns exact sector count");
    for (std::size_t i = 0; i < bytes.size(); ++i) {
      const auto offset = static_cast<std::uint64_t>(lba) * 2048 + i;
      expect_network(bytes[i] == ((offset ^ (offset >> 11)) & 255), "adapter random read byte equality");
    }
    test_disc_advance(disc);
  }
  expect_network(test_disc_read(disc, bytes.data(), -1, 1) == -1, "adapter rejects negative LBA");
  SetEvent(cancel.get());
  expect_network(test_disc_read(disc, bytes.data(), 0, 1) == -1, "adapter obeys player cancellation");
  expect_network(test_disc_open("http://example.com/disc.iso", cancel.get()) == nullptr,
         "adapter rejects non-loopback URL");
}

int main() {
  WSADATA data{};
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 1;
  try {
    test_unknown_head_and_exact_range();
    test_request_contexts_close_after_normal_requests();
    test_disc_read_distinguishes_error_from_cancellation();
    test_cross_origin_redirect_strips_auth();
    test_resolved_url_failure_is_anonymous_and_not_retried();
    test_winhttp_session_reuses_keep_alive_connections();
    test_metrics_v2_is_atomic_and_anonymous();
    test_media_range_plan_preserves_declared_bytes_and_eof();
    test_generation_failure_state_does_not_poison_new_playback();
    test_capability_failures();
    test_validator_change_and_interrupted_body();
    test_last_modified_and_redirect_limit();
    test_playback_prefetch_range_size();
    test_cancelled_prefetch_skips_webdav_request();
    test_loopback_socket_allows_cache_backpressure();
    test_hard_media_failure_uses_abortive_close();
    test_media_failure_before_headers_returns_http_error();
    test_cancel_pending_aborts_slow_foreground_request();
    test_cancelled_request_does_not_poison_keep_alive_session();
    test_repeated_cancellation_releases_request_contexts();
    test_persistent_context_reuses_same_title_and_switches_atomically();
    test_persistent_context_a_b_c_cancels_waiter_and_recovers_failure();
    test_persistent_context_stress_never_overlaps();
    test_fixed_libbluray_runtime_version();
    test_latest_media_socket_closes_previous_response();
    test_remote_mpv_block_adapter();
    test_remote_disc_endpoint_with_adapter();
    WSACleanup();
    std::cout << "streampath_iso_bridge_network_tests: PASS\n";
    return 0;
  } catch (const std::exception& error) {
    WSACleanup();
    std::cerr << "streampath_iso_bridge_network_tests: FAIL: " << error.what()
              << '\n';
    return 1;
  }
}
