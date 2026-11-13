#include "bridge_core.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <future>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace bridge = streampath::iso_bridge;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr std::uint64_t MiB = 1024 * 1024;
constexpr std::uint64_t Block = bridge::kIsoDemandBlockSize;

void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

template <typename Predicate>
void wait_until(Predicate predicate, const char* message) {
  const auto deadline = Clock::now() + 5s;
  while (!predicate()) {
    require(Clock::now() < deadline, message);
    std::this_thread::sleep_for(1ms);
  }
}

class CountingSource : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 256 * MiB; }
  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                 std::uint64_t end) override {
    ++requests;
    return std::vector<std::uint8_t>(static_cast<std::size_t>(end - start + 1), 0xa5);
  }
  std::atomic<int> requests{0};
};

class GatedSource final : public CountingSource {
 public:
  void fetch_stream(std::uint64_t start, std::uint64_t end,
                    const CancellationProbe& cancelled,
                    const ChunkConsumer& consume) override {
    ++requests;
    const auto length = static_cast<std::size_t>(end - start + 1);
    std::vector<std::uint8_t> first(static_cast<std::size_t>(Block), 0xa5);
    consume(first.data(), first.size());
    published = true;
    const auto deadline = Clock::now() + 5s;
    while (!release) {
      if (cancelled()) {
        cancelled_seen = true;
        throw bridge::FetchCancelled(Block);
      }
      require(Clock::now() < deadline, "gated source release timed out");
      std::this_thread::sleep_for(1ms);
    }
    std::vector<std::uint8_t> rest(length - first.size(), 0xa5);
    if (!rest.empty()) consume(rest.data(), rest.size());
  }
  void cancel_pending() override { release = true; }
  std::atomic<bool> published{false};
  std::atomic<bool> release{false};
  std::atomic<bool> cancelled_seen{false};
};

void check_cold_multiblock() {
  auto source = std::make_shared<CountingSource>();
  bridge::BlockCache cache(source, Block, 16, 16, 8, 64, 32, true);
  const auto generation = cache.begin_playback();
  std::vector<std::uint8_t> bytes(2 * MiB);
  require(cache.read(0, bytes.data(), bytes.size(), 0, generation) == bytes.size(),
          "cold read failed");
  require(source->requests == 8 && cache.metrics().cache_miss_count == 8,
          "cold read request count changed");
  require(std::all_of(bytes.begin(), bytes.end(), [](auto b) { return b == 0xa5; }),
          "cold read bytes differ");
  std::cout << "{\"test\":\"cold_multiblock\",\"bytes\":2097152,\"requests\":8,\"pass\":true}\n";
}

void check_stream_and_reset(bool reset) {
  auto source = std::make_shared<GatedSource>();
  bridge::BlockCache cache(source, Block, 16, 16, 16, 64, 0, true);
  const auto generation = cache.begin_playback();
  source->release = false;
  std::uint8_t byte = 0;
  require(cache.read(0, &byte, 1, 32, generation) == 1, "seed read failed");
  wait_until([&] { return source->published.load(); }, "stream did not publish");
  auto reader = std::async(std::launch::async, [&] {
    std::uint8_t value = 0;
    return cache.read(Block, &value, 1, 0, generation) == 1 && value == 0xa5;
  });
  require(reader.wait_for(1s) == std::future_status::ready && reader.get(),
          "published block waited for response tail");
  if (reset) cache.reset_read_ahead();
  require(cache.read(0, &byte, 1, 0, generation) == 1, "cached backread failed");
  if (reset) {
    wait_until([&] { return source->cancelled_seen.load(); }, "reset did not cancel");
    require(cache.is_playback_current(generation), "reset changed playback generation");
  } else {
    require(!source->cancelled_seen, "cached read cancelled active prefetch");
    source->release = true;
  }
  cache.shutdown();
  std::cout << "{\"test\":\"stream_and_cached_backread\",\"reset\":"
            << (reset ? "true" : "false")
            << ",\"cancelled\":" << (source->cancelled_seen ? "true" : "false")
            << ",\"pass\":true}\n";
}

void check_short_window_refill(bool early_refill) {
  auto source = std::make_shared<CountingSource>();
  bridge::BlockCache cache(source, Block, 14, 16, 8, 64, 32, true);
  const auto generation = cache.begin_playback();
  cache.configure(14, 4, early_refill, true);
  const auto window = cache.limit_read_ahead(4);
  std::uint8_t byte = 0;
  require(cache.read(0, &byte, 1, window, generation) == 1, "refill seed failed");
  wait_until([&] { return cache.contiguous_cached_bytes(Block) >= 16 * MiB; },
             "short window did not fill");
  for (std::uint64_t position = Block; position <= 8 * MiB; position += Block) {
    require(cache.read(position, &byte, 1, window, generation) == 1,
            "short window read failed");
  }
  if (early_refill) {
    wait_until([&] { return cache.metrics().prefetched_bytes >= 24 * MiB; },
               "half-window refill did not start");
  } else {
    std::this_thread::sleep_for(20ms);
    require(cache.metrics().prefetched_bytes == 16 * MiB,
            "title refill threshold changed");
  }
  std::cout << "{\"test\":\"short_window_refill\",\"earlyRefillControl\":"
            << (early_refill ? "true" : "false")
            << ",\"windowMiB\":16,\"advancedMiB\":8,\"prefetchedBytes\":"
            << cache.metrics().prefetched_bytes << ",\"pass\":true}\n";
}

void check_large_batch_short_window_counterexample() {
  auto source = std::make_shared<CountingSource>();
  bridge::BlockCache cache(source, Block, 14, 16, 8, 128, 32, true);
  const auto generation = cache.begin_playback();
  cache.configure(14, 4, false, true);
  const auto window = cache.limit_read_ahead(4);
  std::uint8_t byte = 0;
  require(cache.read(0, &byte, 1, window, generation) == 1, "counterexample seed failed");
  wait_until([&] { return cache.contiguous_cached_bytes(Block) >= 16 * MiB; },
             "counterexample window did not fill");
  for (std::uint64_t position = Block; position <= 16 * MiB; position += Block) {
    require(cache.read(position, &byte, 1, window, generation) == 1,
            "counterexample read failed");
  }
  std::this_thread::sleep_for(20ms);
  require(cache.metrics().prefetched_bytes == 16 * MiB,
          "counterexample unexpectedly refilled");
  const int before = source->requests.load();
  require(cache.read(16 * MiB + Block, &byte, 1, window, generation) == 1,
          "counterexample boundary read failed");
  require(source->requests == before + 1, "counterexample did not require demand fetch");
  std::cout << "{\"test\":\"large_batch_short_window_counterexample\","
               "\"batchMiB\":32,\"windowMiB\":16,\"demandFetchAtBoundary\":true,\"pass\":true}\n";
}

int count_short_window_requests(bool early_refill) {
  auto source = std::make_shared<CountingSource>();
  bridge::BlockCache cache(source, Block, 14, 16, 8, 64, 32, true);
  const auto generation = cache.begin_playback();
  cache.configure(14, 4, early_refill, true);
  const auto window = cache.limit_read_ahead(4);
  std::uint8_t byte = 0;
  require(cache.read(0, &byte, 1, window, generation) == 1, "request-count seed failed");
  wait_until([&] { return cache.contiguous_cached_bytes(Block) >= 16 * MiB; },
             "request-count window did not fill");
  for (std::uint64_t position = MiB; position <= 48 * MiB; position += MiB) {
    require(cache.read(position, &byte, 1, window, generation) == 1,
            "request-count read failed");
    std::this_thread::sleep_for(2ms);
  }
  wait_until([&] { return cache.metrics().prefetched_bytes >= 64 * MiB; },
             "request-count final refill failed");
  require(cache.metrics().prefetched_bytes == 64 * MiB,
          "request-count byte ranges differ");
  return source->requests.load();
}

void check_early_refill_request_tradeoff() {
  const int current = count_short_window_requests(false);
  const int early = count_short_window_requests(true);
  require(current == 7 && early == 10, "early-refill request-count tradeoff changed");
  std::cout << "{\"test\":\"early_refill_request_tradeoff\",\"windowMiB\":16,"
               "\"advancedMiB\":48,\"currentRequests\":7,\"earlyRequests\":10,\"pass\":true}\n";
}

class TimedSource final : public bridge::BlockSource {
 public:
  explicit TimedSource(int header_ms) : header_ms_(header_ms) {}
  std::uint64_t size() const override { return 192 * MiB; }
  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                 std::uint64_t end) override {
    std::vector<std::uint8_t> out;
    fetch_stream(start, end, {}, [&](const auto* p, std::size_t n) {
      out.insert(out.end(), p, p + n);
    });
    return out;
  }
  void fetch_stream(std::uint64_t start, std::uint64_t end,
                    const CancellationProbe& cancelled,
                    const ChunkConsumer& consume) override {
    ++requests;
    const auto concurrent = ++active;
    auto previous = peak.load();
    while (concurrent > previous && !peak.compare_exchange_weak(previous, concurrent)) {}
    const auto began = Clock::now();
    const auto wanted = end - start + 1;
    std::uint64_t sent = 0;
    try {
      std::vector<std::uint8_t> chunk(64 * 1024, 0xa5);
      while (sent < wanted) {
        const auto count = static_cast<std::size_t>(
            std::min<std::uint64_t>(chunk.size(), wanted - sent));
        const auto body_time = std::chrono::duration<double>(
            static_cast<double>(sent + count) / (12.0 * MiB));
        const auto due = began + std::chrono::milliseconds(header_ms_) +
            std::chrono::duration_cast<Clock::duration>(body_time);
        while (Clock::now() < due) {
          if (stop || (cancelled && cancelled())) throw bridge::FetchCancelled(sent);
          std::this_thread::sleep_until(std::min(due, Clock::now() + 5ms));
        }
        consume(chunk.data(), count);
        sent += count;
        received += count;
      }
    } catch (...) {
      --active;
      throw;
    }
    --active;
  }
  void cancel_pending() override { stop = true; }
  std::atomic<bool> stop{false};
  std::atomic<int> requests{0}, active{0}, peak{0};
  std::atomic<std::uint64_t> received{0};
 private:
  const int header_ms_;
};

void trial(int repetition, std::size_t batch_mib, int header_ms,
           std::size_t maximum_mib = 0) {
  auto source = std::make_shared<TimedSource>(header_ms);
  bridge::BlockCache cache(source, Block, 14, 16, 8,
                          static_cast<std::size_t>(batch_mib * MiB / Block), 32, true,
                          false, static_cast<std::size_t>(maximum_mib * MiB / Block));
  const auto generation = cache.begin_playback();
  source->stop = false;
  cache.configure(14, 12, false, true);
  const auto window = cache.limit_read_ahead(12);
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(Block));
  const auto seed_began = Clock::now();
  require(cache.read(0, bytes.data(), bytes.size(), window, generation) == bytes.size(),
          "trial seed failed");
  wait_until([&] { return cache.contiguous_cached_bytes(Block) >= 8 * MiB; },
             "trial prefill failed");
  const double seed_ms = std::chrono::duration<double, std::milli>(Clock::now() - seed_began).count();
  const auto began = Clock::now();
  auto due = began;
  double wait_ms = 0, max_ms = 0;
  int slow_reads = 0;
  for (auto position = Block; position < source->size(); position += Block) {
    std::this_thread::sleep_until(due);
    const auto read_began = Clock::now();
    require(cache.read(position, bytes.data(), bytes.size(), window, generation) == bytes.size(),
            "trial read failed");
    require(bytes.front() == 0xa5 && bytes.back() == 0xa5, "trial bytes differ");
    const auto elapsed = std::chrono::duration<double, std::milli>(Clock::now() - read_began).count();
    wait_ms += elapsed;
    max_ms = std::max(max_ms, elapsed);
    slow_reads += elapsed >= 100;
    const auto interval = std::chrono::duration_cast<Clock::duration>(
        std::chrono::duration<double>(static_cast<double>(Block) / (9.0 * MiB)));
    due = std::max(due, Clock::now()) + interval;
  }
  const auto elapsed_ms = std::chrono::duration<double, std::milli>(Clock::now() - began).count();
  cache.shutdown();
  const auto metrics = cache.metrics();
  std::cout << std::fixed << std::setprecision(3)
            << "{\"test\":\"timed_core_only\",\"repetition\":" << repetition
            << ",\"batchMiB\":" << batch_mib
            << ",\"maximumMiB\":" << maximum_mib
            << ",\"sourceMiB\":192,\"capacityMiB\":56,\"windowMiB\":48"
            << ",\"headerMs\":" << header_ms << ",\"bodyMiBps\":12,\"consumerMiBps\":9"
            << ",\"prefillMs\":" << seed_ms
            << ",\"elapsedMs\":" << elapsed_ms << ",\"readWaitMsTotal\":" << wait_ms
            << ",\"readWaitMsMax\":" << max_ms << ",\"readsGe100ms\":" << slow_reads
            << ",\"requests\":" << source->requests << ",\"receivedBytes\":" << source->received
            << ",\"activePeak\":" << source->peak
            << ",\"refetchBlocks\":" << metrics.refetch_count
            << ",\"peakResidentBytes\":" << metrics.peak_bytes << ",\"pass\":true}\n" << std::flush;
}

int main(int argc, char** argv) {
  try {
    if (argc >= 2 && (std::string(argv[1]) == "--timed" || std::string(argv[1]) == "--adaptive")) {
      const bool adaptive = std::string(argv[1]) == "--adaptive";
      const int header_ms = argc == 3 ? std::stoi(argv[2]) : 600;
      require(header_ms > 0, "header delay must be positive");
      for (int i = 0; i < 3; ++i) {
        if (i % 2 == 0) { trial(i, 16, header_ms); trial(i, adaptive ? 16 : 32, header_ms, adaptive ? 32 : 0); }
        else { trial(i, adaptive ? 16 : 32, header_ms, adaptive ? 32 : 0); trial(i, 16, header_ms); }
      }
    } else {
      for (int i = 0; i < 3; ++i) {
        check_cold_multiblock();
        check_stream_and_reset(false);
        check_stream_and_reset(true);
        check_short_window_refill(false);
        check_short_window_refill(true);
        check_large_batch_short_window_counterexample();
        check_early_refill_request_tradeoff();
      }
    }
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "probe failed: " << e.what() << '\n';
    return 1;
  }
}
