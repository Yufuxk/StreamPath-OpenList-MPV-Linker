#include "bridge_core.h"
#include "iso_structure_cache.h"
#include "remote_disc_endpoint.h"

#include <windows.h>
#include <bcrypt.h>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace bridge = streampath::iso_bridge;

namespace {

void expect(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void write_pes_timestamp(std::uint8_t* data, std::uint8_t prefix,
                         std::uint64_t timestamp) {
  data[0] = static_cast<std::uint8_t>(
      (prefix << 4U) | ((timestamp >> 29U) & 0x0eU) | 0x01U);
  data[1] = static_cast<std::uint8_t>(timestamp >> 22U);
  data[2] = static_cast<std::uint8_t>(((timestamp >> 14U) & 0xfeU) | 0x01U);
  data[3] = static_cast<std::uint8_t>(timestamp >> 7U);
  data[4] = static_cast<std::uint8_t>(((timestamp << 1U) & 0xfeU) | 0x01U);
}

std::uint64_t read_pes_timestamp(const std::uint8_t* data) {
  return (static_cast<std::uint64_t>((data[0] >> 1U) & 0x07U) << 30U) |
         (static_cast<std::uint64_t>(data[1]) << 22U) |
         (static_cast<std::uint64_t>((data[2] >> 1U) & 0x7fU) << 15U) |
         (static_cast<std::uint64_t>(data[3]) << 7U) |
         static_cast<std::uint64_t>((data[4] >> 1U) & 0x7fU);
}

void write_program_clock_reference(std::uint8_t* data, std::uint64_t base) {
  data[0] = static_cast<std::uint8_t>(base >> 25U);
  data[1] = static_cast<std::uint8_t>(base >> 17U);
  data[2] = static_cast<std::uint8_t>(base >> 9U);
  data[3] = static_cast<std::uint8_t>(base >> 1U);
  data[4] = static_cast<std::uint8_t>(((base & 0x01U) << 7U) | 0x7eU);
  data[5] = 0;
}

std::uint64_t read_program_clock_reference(const std::uint8_t* data) {
  return (static_cast<std::uint64_t>(data[0]) << 25U) |
         (static_cast<std::uint64_t>(data[1]) << 17U) |
         (static_cast<std::uint64_t>(data[2]) << 9U) |
         (static_cast<std::uint64_t>(data[3]) << 1U) |
         static_cast<std::uint64_t>(data[4] >> 7U);
}

void write_test_m2ts_packet(std::uint8_t* packet, std::uint64_t pts,
                            std::uint64_t dts, std::uint64_t pcr) {
  packet[0] = 0x01U;
  packet[1] = 0x23U;
  packet[2] = 0x45U;
  packet[3] = 0x67U;
  std::uint8_t* transport = packet + 4;
  transport[0] = 0x47U;
  transport[1] = 0x40U;
  transport[2] = 0x11U;
  transport[3] = 0x30U;
  transport[4] = 13U;
  transport[5] = 0x18U;
  write_program_clock_reference(transport + 6, pcr);
  write_program_clock_reference(transport + 12, pcr + 1U);
  std::uint8_t* payload = transport + 18;
  payload[0] = 0;
  payload[1] = 0;
  payload[2] = 1U;
  payload[3] = 0xe0U;
  payload[4] = 0;
  payload[5] = 0;
  payload[6] = 0x80U;
  payload[7] = 0xc0U;
  payload[8] = 10U;
  write_pes_timestamp(payload + 9, 3U, pts);
  write_pes_timestamp(payload + 14, 1U, dts);
}

void test_m2ts_timestamp_normalization() {
  std::vector<std::uint8_t> packets(bridge::kM2tsPacketSize * 2U);
  write_test_m2ts_packet(packets.data(), 10000U, 9000U, 8000U);
  write_test_m2ts_packet(packets.data() + bridge::kM2tsPacketSize, 5000U,
                         4000U, 3000U);
  const std::vector<bridge::M2tsClipTimeline> clips = {
      {0, bridge::kM2tsPacketSize, 900},
      {bridge::kM2tsPacketSize, bridge::kM2tsPacketSize * 2U, -1800},
  };

  expect(bridge::normalize_m2ts_timestamps(
             packets.data(), packets.size(), 0, clips),
         "M2TS timestamps normalized");
  expect(packets[0] == 0x01U && packets[1] == 0x23U &&
             packets[2] == 0x45U && packets[3] == 0x67U,
         "M2TS arrival timestamp preserved");
  const std::uint8_t* first_transport = packets.data() + 4;
  const std::uint8_t* first_payload = first_transport + 18;
  expect(read_program_clock_reference(first_transport + 6) == 8900U &&
             read_program_clock_reference(first_transport + 12) == 8901U &&
             read_pes_timestamp(first_payload + 9) == 10900U &&
             read_pes_timestamp(first_payload + 14) == 9900U,
         "first clip PCR PTS DTS shifted");
  const std::uint8_t* second_transport =
      packets.data() + bridge::kM2tsPacketSize + 4;
  const std::uint8_t* second_payload = second_transport + 18;
  expect(read_program_clock_reference(second_transport + 6) == 1200U &&
             read_program_clock_reference(second_transport + 12) == 1201U &&
             read_pes_timestamp(second_payload + 9) == 3200U &&
             read_pes_timestamp(second_payload + 14) == 2200U,
         "second clip PCR PTS DTS shifted");
  expect(!bridge::normalize_m2ts_timestamps(
             packets.data(), bridge::kM2tsPacketSize - 1U, 0, clips),
         "unaligned M2TS range rejected");
}

class FakeSource final : public bridge::BlockSource {
 public:
  explicit FakeSource(std::uint64_t length) : length_(length) {}

  std::uint64_t size() const override { return length_; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    ++calls;
    last_start = start;
    last_end = end;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  std::atomic<int> calls = 0;
  std::atomic<std::uint64_t> last_start = 0;
  std::atomic<std::uint64_t> last_end = 0;

 private:
  std::uint64_t length_;
};

class InstantSource final : public bridge::BlockSource {
 public:
  explicit InstantSource(std::uint64_t length) : length_(length) {}

  std::uint64_t size() const override { return length_; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    // Keep fetches slow enough that demand readers regularly catch inflight
    // prefetch entries and block on entry->ready.
    std::this_thread::sleep_for(std::chrono::microseconds(800));
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

 private:
  std::uint64_t length_;
};

class SwitchingSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 512; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    return fetch(start, end, {});
  }

  std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled) override {
    if (start == 8 && end == 23) {
      old_prefetch_started = true;
      const auto deadline =
          std::chrono::steady_clock::now() + std::chrono::milliseconds(400);
      while (std::chrono::steady_clock::now() < deadline) {
        if (cancelled && cancelled()) {
          throw bridge::FetchCancelled(3);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
    if (start == 328 && end == 343) new_prefetch_started = true;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  std::atomic<bool> old_prefetch_started = false;
  std::atomic<bool> new_prefetch_started = false;
};

class SlowForegroundSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 512; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    return fetch(start, end, {});
  }

  std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled) override {
    if (start == 0 || start == 160) {
      if (start == 0) {
        old_request_started = true;
      } else {
        middle_request_started = true;
      }
      const auto deadline =
          std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
      while (std::chrono::steady_clock::now() < deadline) {
        if (cancelled && cancelled()) {
          throw bridge::FetchCancelled(5);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
    if (start == 320) current_request_started = true;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  std::atomic<bool> old_request_started = false;
  std::atomic<bool> middle_request_started = false;
  std::atomic<bool> current_request_started = false;
};

class BlockingPrefetchSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 128; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    return fetch(start, end, {});
  }

  std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled) override {
    ++calls;
    if (start == 8 && end == 23) {
      std::unique_lock lock(mutex_);
      prefetch_started_ = true;
      ready_.notify_all();
      ready_.wait(lock, [this] { return release_prefetch_; });
    }
    if (cancelled && cancelled()) throw bridge::FetchCancelled(0);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  bool wait_for_prefetch() {
    std::unique_lock lock(mutex_);
    return ready_.wait_for(lock, std::chrono::seconds(1),
                           [this] { return prefetch_started_; });
  }

  void release_prefetch() {
    {
      std::lock_guard lock(mutex_);
      release_prefetch_ = true;
    }
    ready_.notify_all();
  }

  std::atomic<int> calls = 0;

 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  bool prefetch_started_ = false;
  bool release_prefetch_ = false;
};

class SameBlockGenerationSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 128; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    return fetch(start, end, {});
  }

  std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled) override {
    const int call = ++calls;
    if (call == 1) {
      first_request_started = true;
      const auto deadline =
          std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (std::chrono::steady_clock::now() < deadline) {
        if (cancelled && cancelled()) throw bridge::FetchCancelled(2);
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      }
      throw std::runtime_error("stale block fetch was not cancelled");
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  std::atomic<int> calls = 0;
  std::atomic<bool> first_request_started = false;
};

class FailingSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 128; }

  std::vector<std::uint8_t> fetch(std::uint64_t,
                                  std::uint64_t) override {
    ++calls;
    std::unique_lock lock(mutex_);
    request_started_ = true;
    ready_.notify_all();
    ready_.wait(lock, [this] { return release_failure_; });
    throw std::runtime_error("shared block failure");
  }

  bool wait_for_request() {
    std::unique_lock lock(mutex_);
    return ready_.wait_for(lock, std::chrono::seconds(1),
                           [this] { return request_started_; });
  }

  void release_failure() {
    {
      std::lock_guard lock(mutex_);
      release_failure_ = true;
    }
    ready_.notify_all();
  }

  std::atomic<int> calls = 0;

 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  bool request_started_ = false;
  bool release_failure_ = false;
};

class FailOnceSource final : public bridge::BlockSource {
 public:
  std::uint64_t size() const override { return 128; }

  std::vector<std::uint8_t> fetch(std::uint64_t start,
                                  std::uint64_t end) override {
    if (++calls == 1) throw std::runtime_error("transient block failure");
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
    for (std::size_t index = 0; index < bytes.size(); ++index) {
      bytes[index] = static_cast<std::uint8_t>((start + index) & 0xffU);
    }
    return bytes;
  }

  std::atomic<int> calls = 0;
};

void test_ranges() {
  auto result = bridge::parse_byte_range("bytes=10-19", 100);
  expect(result.status == bridge::ByteRangeStatus::ok && result.start == 10 &&
             result.end == 19,
         "closed range");
  result = bridge::parse_byte_range("bytes=95-", 100);
  expect(result.status == bridge::ByteRangeStatus::ok && result.start == 95 &&
             result.end == 99,
         "open range");
  result = bridge::parse_byte_range("bytes=-8", 100);
  expect(result.status == bridge::ByteRangeStatus::ok && result.start == 92 &&
             result.end == 99,
         "suffix range");
  expect(bridge::parse_byte_range("bytes=0-1,4-5", 100).status ==
             bridge::ByteRangeStatus::multiple,
         "multiple range");
  expect(bridge::parse_byte_range("bytes=100-", 100).status ==
             bridge::ByteRangeStatus::unsatisfiable,
         "unsatisfiable range");
  expect(bridge::parse_byte_range("bytes=9-2", 100).status ==
             bridge::ByteRangeStatus::invalid,
         "invalid range");

  const auto content = bridge::parse_content_range("bytes 10-19/100");
  expect(content.has_value() && content->start == 10 && content->end == 19 &&
             content->total == 100,
         "content range");
  expect(!bridge::parse_content_range("bytes 10-100/100").has_value(),
         "invalid content range");
}

void test_json() {
  const auto object = bridge::parse_json_object(
      R"({"type":"open","version":1,"password":"a\"b","empty":null})");
  expect(object.has_value(), "valid json");
  expect(std::get<std::string>(object->at("type")) == "open", "json string");
  expect(std::get<std::int64_t>(object->at("version")) == 1, "json integer");
  expect(std::get<std::string>(object->at("password")) == "a\"b",
         "json escape");
  expect(!bridge::parse_json_object(R"({"type":[]})").has_value(),
         "nested json rejected");
  expect(!bridge::parse_json_object(R"({"type":"open","type":"again"})")
              .has_value(),
         "duplicate json key rejected");
  expect(bridge::json_escape("a\nb") == R"("a\nb")", "json writer");
}

void test_cache() {
  auto source = std::make_shared<FakeSource>(32);
  bridge::BlockCache cache(source, 8, 2);
  std::vector<std::uint8_t> first(8);
  std::vector<std::uint8_t> second(8);
  std::thread one([&] { cache.read(0, first.data(), first.size()); });
  std::thread two([&] { cache.read(0, second.data(), second.size()); });
  one.join();
  two.join();
  expect(source->calls == 1, "same block requests coalesced");
  expect(first == second && first.front() == 0 && first.back() == 7,
         "cache bytes");

  std::vector<std::uint8_t> byte(1);
  cache.read(8, byte.data(), byte.size());
  cache.read(0, byte.data(), byte.size());
  cache.read(16, byte.data(), byte.size());
  cache.read(8, byte.data(), byte.size());
  expect(source->calls == 4, "LRU eviction");
  const auto metrics = cache.metrics();
  expect(metrics.peak_bytes == 16 && metrics.fetched_bytes == 32 &&
             metrics.foreground_fetch_bytes == 32 &&
             metrics.prefetch_fetch_bytes == 0 &&
             metrics.consumer_bytes_delivered == 20 &&
             metrics.cache_miss_count == 4 && metrics.eviction_count == 2 &&
             metrics.refetch_count == 1,
         "cache metrics");
}

void test_title_recovery_batches() {
  class RecordingSource final : public bridge::BlockSource {
   public:
    std::uint64_t size() const override { return 8192; }
    std::vector<std::uint8_t> fetch(std::uint64_t start,
                                    std::uint64_t end) override {
      std::lock_guard lock(mutex);
      ranges.emplace_back(start, end - start + 1);
      return std::vector<std::uint8_t>(static_cast<std::size_t>(end - start + 1), 7);
    }
    std::mutex mutex;
    std::vector<std::pair<std::uint64_t, std::uint64_t>> ranges;
  };
  for (const bool recovery : {false, true}) {
    auto source = std::make_shared<RecordingSource>();
    bridge::BlockCache cache(source, 8, 64, 1, 1, 8, recovery ? 4 : 0);
    for (const std::uint64_t offset : {0ULL, 4096ULL}) {
      const auto generation = cache.begin_playback();
      std::size_t before = 0;
      {
        std::lock_guard lock(source->mutex);
        before = source->ranges.size();
      }
      const auto fetched = cache.metrics().prefetched_bytes;
      std::uint8_t byte = 0;
      expect(cache.read(offset, &byte, 1, 24, generation) == 1 && byte == 7,
             "recovery preserves demand bytes");
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (cache.metrics().prefetched_bytes < fetched + 24 * 8 &&
             std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      expect(cache.metrics().prefetched_bytes == fetched + 24 * 8,
             "recovery fills bounded window");
      std::lock_guard lock(source->mutex);
      expect(source->ranges.at(before + 1).second == 8 &&
                 source->ranges.at(before + 2).second == (recovery ? 32ULL : 64ULL) &&
                 source->ranges.at(before + 3).second == 64,
             "title ramps batches and resets on generation; legacy skips ramp");
    }
  }
}

void test_stream_prefetch_publication() {
  class StreamingSource final : public bridge::BlockSource {
   public:
    std::uint64_t size() const override { return 1024; }
    std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end) override {
      return std::vector<std::uint8_t>(static_cast<std::size_t>(end - start + 1), 9);
    }
    void fetch_stream(std::uint64_t start, std::uint64_t end,
                      const CancellationProbe& cancelled,
                      const ChunkConsumer& consume) override {
      std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1), 7);
      consume(bytes.data(), 11);
      {
        std::unique_lock lock(mutex);
        started = true;
        ready.notify_all();
        ready.wait(lock, [&] { return released; });
      }
      if (cancelled()) throw bridge::FetchCancelled(11);
      if (fail) throw std::runtime_error("stream tail failed");
      consume(bytes.data() + 11, bytes.size() - 11);
    }
    std::mutex mutex;
    std::condition_variable ready;
    bool started = false;
    bool released = false;
    bool fail = false;
  };
  for (const int mode : {0, 1, 2}) {
    auto source = std::make_shared<StreamingSource>();
    source->fail = mode == 1;
    bridge::BlockCache cache(source, 8, 16, 1, 4, 4, 0, true);
    cache.configure(16, 4, false, true);
    const auto generation = cache.begin_playback();
    std::uint8_t byte = 0;
    cache.read(0, &byte, 1, 4, generation);
    bool started = false;
    {
      std::unique_lock lock(source->mutex);
      started = source->ready.wait_for(lock, std::chrono::seconds(2), [&] { return source->started; });
    }
    std::atomic<bool> read_done = false;
    std::uint8_t streamed = 0;
    std::thread reader([&] {
      cache.read(8, &streamed, 1, 0, generation);
      read_done = true;
    });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (!read_done && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const bool early = read_done;
    const auto partial_metrics = cache.metrics();
    auto current = generation;
    if (mode == 2) current = cache.begin_playback();
    {
      std::lock_guard lock(source->mutex);
      source->released = true;
      source->ready.notify_all();
    }
    reader.join();
    expect(started && early && streamed == 7 && partial_metrics.prefetched_bytes == 8,
           "complete block is readable before range tail; partial block is unpublished");
    if (mode == 1) {
      bool failed = false;
      try { cache.read(16, &byte, 1, 0, current); }
      catch (const std::runtime_error&) { failed = true; }
      expect(failed, "stream tail failure reaches demand");
      failed = false;
      try { cache.read(8, &byte, 1, 0, current); }
      catch (const std::runtime_error&) { failed = true; }
      expect(failed, "stream error cannot be hidden by a completed cache hit");
      current = cache.begin_playback();
      expect(cache.read(16, &byte, 1, 0, current) == 1 && byte == 9,
             "new generation recovers without retaining partial bytes");
    } else {
      expect(cache.read(16, &byte, 1, 0, current) == 1 && byte == (mode == 2 ? 9 : 7),
             "tail completes or stale partial is discarded");
    }
    cache.shutdown();
    if (mode == 2) {
      expect(cache.metrics().cancelled_prefetch_bytes == 3,
             "cancellation counts only unpublished bytes");
    }
  }
}

void test_metadata_cache_handoff_preserves_hot_blocks_and_refetch_history() {
  auto source = std::make_shared<FakeSource>(64);
  bridge::BlockCache metadata(source, 8, 8);
  std::array<std::uint8_t, 1> byte{};
  metadata.read(0, byte.data(), byte.size());
  metadata.read(8, byte.data(), byte.size());
  metadata.read(16, byte.data(), byte.size());
  metadata.read(24, byte.data(), byte.size());
  metadata.read(8, byte.data(), byte.size());
  const auto metadata_metrics = metadata.metrics();

  auto handoff = metadata.take_handoff(16);
  expect(handoff.retained_bytes == 16 && handoff.blocks.size() == 2,
         "metadata handoff is bounded");
  bridge::BlockCache playback(source, 8, 4);
  playback.restore_handoff(std::move(handoff));

  const auto calls_before_hits = source->calls.load();
  playback.read(8, byte.data(), byte.size());
  playback.read(24, byte.data(), byte.size());
  expect(source->calls == calls_before_hits,
         "retained metadata blocks avoid a cold playback context");
  playback.read(0, byte.data(), byte.size());
  const auto playback_metrics = playback.metrics();
  expect(source->calls == calls_before_hits + 1 &&
             playback_metrics.refetch_count == 1,
         "handoff keeps cross-phase refetch history");

  const auto combined = bridge::combine_sequential_cache_metrics(
      metadata_metrics, playback_metrics);
  expect(combined.fetched_bytes == 40 && combined.requests == 5 &&
             combined.hits == 3 && combined.refetch_count == 1 &&
             combined.peak_bytes == 32 &&
             combined.resident_bytes == playback_metrics.resident_bytes,
         "sequential cache metrics preserve aggregate compatibility");
}

void test_prefetch_and_demand_share_inflight_block() {
  auto source = std::make_shared<BlockingPrefetchSource>();
  bridge::BlockCache cache(source, 8, 4);
  std::uint8_t first = 0;
  const auto playback = cache.begin_playback();
  expect(cache.read(0, &first, 1, 2, playback) == 1 && first == 0,
         "foreground block loaded before prefetch");
  const bool prefetch_started = source->wait_for_prefetch();
  if (!prefetch_started) source->release_prefetch();
  expect(prefetch_started, "prefetch range started");

  std::uint8_t demanded = 0;
  std::size_t demand_result = 0;
  std::atomic<bool> demand_completed = false;
  std::thread demand([&] {
    demand_result = cache.read(8, &demanded, 1, 0, playback);
    demand_completed = true;
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  const bool waited_for_prefetch = !demand_completed;
  source->release_prefetch();
  demand.join();

  const auto metrics = cache.metrics();
  expect(waited_for_prefetch && demand_result == 1 && demanded == 8 &&
             source->calls == 2 && metrics.prefetch_hits == 1,
         "prefetch and demand share one inflight block result");
  expect(metrics.foreground_loading_wait_count == 1 &&
             metrics.foreground_loading_wait_us_total > 0 &&
             metrics.foreground_loading_wait_us_max == metrics.foreground_loading_wait_us_total,
         "foreground inflight wait is measured");
}

void test_new_generation_replaces_cancelled_same_block_load() {
  auto source = std::make_shared<SameBlockGenerationSource>();
  bridge::BlockCache cache(source, 8, 4);
  std::uint8_t stale_byte = 0;
  std::uint8_t current_byte = 0;
  std::size_t stale_result = 1;
  const auto stale = cache.begin_playback();
  std::thread stale_reader([&] {
    stale_result = cache.read(0, &stale_byte, 1, 0, stale);
  });
  const auto start_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!source->first_request_started &&
         std::chrono::steady_clock::now() < start_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  const bool stale_started = source->first_request_started;
  if (!stale_started) {
    static_cast<void>(cache.begin_playback());
    stale_reader.join();
  }
  expect(stale_started, "stale same-block request started");

  const auto switched_at = std::chrono::steady_clock::now();
  const auto current = cache.begin_playback();
  const auto current_result = cache.read(0, &current_byte, 1, 0, current);
  stale_reader.join();
  const auto elapsed = std::chrono::steady_clock::now() - switched_at;
  expect(stale_result == 0 && current_result == 1 && current_byte == 0 &&
             source->calls == 2 && elapsed < std::chrono::milliseconds(500),
         "new generation replaces a cancelled same-block loading entry");
}

void test_inflight_failure_wakes_all_waiters() {
  auto source = std::make_shared<FailingSource>();
  bridge::BlockCache cache(source, 8, 4);
  constexpr std::size_t waiter_count = 3;
  std::mutex start_mutex;
  std::condition_variable start_ready;
  std::size_t ready = 0;
  bool start = false;
  std::array<std::uint8_t, waiter_count> bytes{};
  std::array<std::string, waiter_count> errors{};
  std::array<std::thread, waiter_count> waiters;
  for (std::size_t index = 0; index < waiters.size(); ++index) {
    waiters[index] = std::thread([&, index] {
      {
        std::unique_lock lock(start_mutex);
        ++ready;
        start_ready.notify_all();
        start_ready.wait(lock, [&] { return start; });
      }
      try {
        static_cast<void>(cache.read(0, &bytes[index], 1));
      } catch (const std::exception& error) {
        errors[index] = error.what();
      }
    });
  }
  {
    std::unique_lock lock(start_mutex);
    start_ready.wait(lock, [&] { return ready == waiter_count; });
    start = true;
  }
  start_ready.notify_all();
  const bool request_started = source->wait_for_request();
  if (!request_started) {
    source->release_failure();
    for (auto& waiter : waiters) waiter.join();
  }
  expect(request_started, "shared failing request started");
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  source->release_failure();
  for (auto& waiter : waiters) waiter.join();

  bool same_error = source->calls == 1;
  for (const auto& error : errors) {
    same_error = same_error && error == "shared block failure";
  }
  expect(same_error, "inflight failure wakes all waiters with one error");
}

void test_new_playback_discards_failed_cache_entry() {
  auto source = std::make_shared<FailOnceSource>();
  bridge::BlockCache cache(source, 8, 4);
  std::uint8_t byte = 0;
  const auto first = cache.begin_playback();
  bool failed = false;
  try {
    static_cast<void>(cache.read(0, &byte, 1, 0, first));
  } catch (const std::runtime_error&) {
    failed = true;
  }
  expect(failed && source->calls == 1,
         "failed block remains stable within one playback generation");

  const auto second = cache.begin_playback();
  const auto read = cache.read(0, &byte, 1, 0, second);
  expect(read == 1 && byte == 0 && source->calls == 2,
         "new playback retries a block failed by the previous generation");
}

void test_dynamic_cache_configuration() {
  auto source = std::make_shared<FakeSource>(128);
  bridge::BlockCache cache(source, 8, 12);
  cache.configure(4, 6);
  const auto metrics = cache.metrics();
  expect(metrics.cache_capacity_bytes == 32 &&
             metrics.configured_prefetch_blocks == 6 &&
             cache.limit_read_ahead(12) == 6 &&
             cache.limit_read_ahead(4) == 4,
         "dynamic cache configuration");
}

void test_small_demand_blocks_preserve_sequential_configuration_units() {
  auto source = std::make_shared<FakeSource>(1024);
  bridge::BlockCache cache(source, 8, 4, 4, 8, 16);
  std::uint8_t byte = 0;
  const auto playback = cache.begin_playback();
  expect(cache.read(320, &byte, 1, 0, playback) == 1 &&
             source->last_start == 320 && source->last_end == 327,
         "random demand fetch uses one small physical block");

  cache.configure(4, 6);
  const auto metrics = cache.metrics();
  expect(metrics.cache_capacity_bytes == 128 &&
             metrics.configured_prefetch_blocks == 6 &&
             cache.limit_read_ahead(4) == 16 &&
             cache.limit_read_ahead(12) == 24,
         "small physical blocks retain external 4 MiB configuration units");
}

void test_playback_read_ahead_policy() {
  constexpr std::uint64_t mib = 1024ULL * 1024ULL;
  expect(bridge::playback_read_ahead_blocks(60ULL * mib, 60000) == 4,
         "low bitrate read ahead");
  expect(bridge::playback_read_ahead_blocks(240ULL * mib, 60000) == 8,
         "medium bitrate read ahead");
  expect(bridge::playback_read_ahead_blocks(600ULL * mib, 60000) == 12,
         "high bitrate read ahead");
}

void test_playback_prefetch() {
  auto source = std::make_shared<FakeSource>(128);
  bridge::BlockCache cache(source, 8, 12);
  std::vector<std::uint8_t> byte(1);
  const auto playback = cache.begin_playback();
  cache.read(0, byte.data(), byte.size(), 4, playback);

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 32 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->calls == 3, "initial playback prefetch uses two short ranges");

  cache.read(8, byte.data(), byte.size(), 4, playback);
  expect(source->calls == 3 && byte.front() == 8,
         "prefetched block reused by playback");
  cache.read(16, byte.data(), byte.size(), 4, playback);
  cache.read(24, byte.data(), byte.size(), 4, playback);
  cache.read(32, byte.data(), byte.size(), 4, playback);
  while (cache.metrics().prefetched_bytes < 64 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  const auto metrics = cache.metrics();
  expect(source->calls == 4 && metrics.prefetch_requests == 3 &&
             metrics.prefetched_bytes == 64 &&
              metrics.prefetch_fetch_bytes == 64 &&
              metrics.foreground_fetch_bytes == 8 &&
              metrics.consumer_bytes_delivered == 5 &&
              metrics.prefetch_hits >= 4 && metrics.prefetch_hit_bytes >= 32 &&
              metrics.prefetch_active_peak == 1 &&
              metrics.prefetch_overlap_count == 0 &&
              metrics.prefetch_in_flight_bytes_peak <= 32,
         "prefetch metrics");
}

void test_disc_short_window_refills_before_exhaustion() {
  auto source = std::make_shared<FakeSource>(512);
  bridge::BlockCache cache(source, 8, 16, 1, 1, 4);
  cache.configure(16, 12, true);
  const auto playback = cache.begin_playback();
  std::uint8_t byte = 0;
  cache.read(0, &byte, 1, 2, playback);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 16 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  cache.read(8, &byte, 1, 2, playback);
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 24 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  expect(cache.metrics().prefetched_bytes >= 24 &&
         cache.metrics().cache_miss_count == 1,
         "short disc window refills at half waterline despite larger batch cap");
}

void test_title_unread_window_retention() {
  class RecordingSource final : public bridge::BlockSource {
   public:
    std::uint64_t size() const override { return 65536; }
    std::vector<std::uint8_t> fetch(std::uint64_t start,
                                    std::uint64_t end) override {
      std::lock_guard lock(mutex);
      ranges.emplace_back(start, end - start + 1);
      std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
      for (std::size_t i = 0; i < bytes.size(); ++i) {
        bytes[i] = static_cast<std::uint8_t>((start + i) & 0xffU);
      }
      return bytes;
    }
    std::mutex mutex;
    std::vector<std::pair<std::uint64_t, std::uint64_t>> ranges;
  };
  for (const std::size_t window : {64U, 160U, 192U}) {
    auto source = std::make_shared<RecordingSource>();
    const std::size_t capacity = window == 64 ? 6 : 14;
    bridge::BlockCache cache(source, 8, capacity, 16, 8, 64, 32, true);
    cache.configure(capacity, window / 16, false, true);
    std::uint8_t byte = 0;
    // 连续推进和远距离换代际均覆盖满容量回收。
    for (const std::uint64_t base : {0ULL, 1024ULL, 2048ULL}) {
      const auto generation = cache.begin_playback();
      const auto before = cache.metrics();
      std::size_t first_range = 0;
      {
        std::lock_guard lock(source->mutex);
        first_range = source->ranges.size();
      }
      for (std::uint64_t i = 0; i < 256; ++i) {
        const auto position = (base + i) * 8;
        expect(cache.read(position, &byte, 1, window, generation) == 1 &&
                   byte == static_cast<std::uint8_t>(position & 0xffU),
               "title retention preserves bytes");
        if (i % 64 == 0) {
          const auto expected = before.prefetched_bytes + (window + i) * 8;
          const auto deadline = std::chrono::steady_clock::now() +
                                std::chrono::seconds(2);
          while (cache.metrics().prefetched_bytes < expected &&
                 std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
          }
          expect(cache.metrics().prefetched_bytes == expected,
                 "title retains its original refill threshold");
        }
        if (window == 64 && i == 32) {
          expect(cache.metrics().prefetched_bytes == before.prefetched_bytes + 512,
                 "title short window does not adopt menu half-window refill");
        }
      }
      const auto after = cache.metrics();
      expect(after.cache_miss_count == before.cache_miss_count + 1 &&
                 after.refetch_count == 0 && after.eviction_count > 0 &&
                 after.resident_bytes <= after.cache_capacity_bytes,
             "title evicts old bytes without refetching its unread window");
      {
        std::lock_guard lock(source->mutex);
        expect(source->ranges.at(first_range + 1).second == 8 * 8 &&
                   source->ranges.at(first_range + 2).second == 32 * 8 &&
                   source->ranges.at(first_range + 3).second ==
                       (window == 64 ? 24ULL : 64ULL) * 8,
               "title retains 2/8/16 MiB batch ramp after each generation");
      }
      // 同代际回退不改变调度窗口；新代际仍可命中保留块。
      const auto requests = after.requests;
      cache.read((base + 200) * 8, &byte, 1, window, generation);
      const auto next = cache.begin_playback();
      cache.read((base + 255) * 8, &byte, 1, 0, next);
      expect(cache.metrics().requests == requests,
             "backward and new-generation warm reads keep cached bytes");
    }
  }
}

void test_long_disc_buffer_preserves_unread_window() {
  const auto measure = [](bool protect) {
    auto source = std::make_shared<FakeSource>(4096);
    bridge::BlockCache cache(source, 8, 8, 1, 1, 1);
    cache.configure(8, 6, protect);
    const auto playback = cache.begin_playback();
    std::uint8_t byte = 0;
    for (std::uint64_t i = 0; i < 32; ++i) {
      cache.read(i * 8, &byte, 1, 6, playback);
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (source->last_end < (i + 7) * 8 - 1 &&
             std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      expect(source->last_end >= (i + 7) * 8 - 1, "long window fills ahead");
    }
    return cache.metrics().cache_miss_count;
  };
  expect(measure(false) > 1, "plain LRU evicts unread bytes before consumption");
  expect(measure(true) == 1, "disc buffer has only the initial demand miss");
}

void test_title_unread_window_allows_capacity_reduction() {
  auto source = std::make_shared<FakeSource>(65536);
  bridge::BlockCache cache(source, 8, 14, 16, 8, 64, 32, true);
  cache.configure(14, 10, false, true);
  const auto generation = cache.begin_playback();
  std::uint8_t byte = 0;
  cache.read(0, &byte, 1, 160, generation);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 1280 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  expect(cache.metrics().prefetched_bytes == 1280, "title window filled");
  cache.configure(6, 4, false, true);
  expect(cache.metrics().resident_bytes <= 768,
         "unread preference cannot prevent shrinking to configured capacity");
  const auto next = cache.begin_playback();
  expect(cache.read(8192, &byte, 1, 64, next) == 1 && byte == 0,
         "new generation can read after reducing a full cache");
}

void test_disc_seek_retains_cached_bytes_and_playback_generation() {
  auto source = std::make_shared<FakeSource>(512);
  bridge::BlockCache cache(source, 8, 16);
  std::uint8_t byte = 0;
  const auto playback = cache.begin_playback();
  cache.read(0, &byte, 1, 4, playback);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 32 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  cache.reset_read_ahead();
  expect(cache.is_playback_current(playback), "disc seek retains file generation");
  const auto requests = source->calls.load();
  cache.read(8, &byte, 1, 0, playback);
  expect(byte == 8 && source->calls == requests, "disc seek retains backward cache");
  cache.read(320, &byte, 1, 4, playback);
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 64 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  const auto after_seek = source->calls.load();
  cache.read(328, &byte, 1, 0, playback);
  expect(byte == 72 && source->calls == after_seek,
         "disc prefetch follows new position without reopening playback");
}

void test_seek_replaces_prefetch_window() {
  auto source = std::make_shared<FakeSource>(512);
  bridge::BlockCache cache(source, 8, 12);
  std::vector<std::uint8_t> byte(1);
  auto playback = cache.begin_playback();
  cache.read(0, byte.data(), byte.size(), 4, playback);
  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 32 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  playback = cache.begin_playback();
  cache.read(320, byte.data(), byte.size(), 4, playback);
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 64 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  cache.read(328, byte.data(), byte.size());
  const auto metrics = cache.metrics();
  expect(source->calls == 6 && metrics.prefetch_requests == 4 &&
             metrics.prefetch_hits >= 1 && byte.front() == 72,
         "seek replaces prefetch window");
}

void test_stale_playback_cannot_replace_current_prefetch_window() {
  auto source = std::make_shared<FakeSource>(512);
  bridge::BlockCache cache(source, 8, 12);
  cache.configure(12, 4, false, true);
  std::vector<std::uint8_t> byte(1);

  const auto previous = cache.begin_playback();
  cache.read(0, byte.data(), byte.size(), 4, previous);
  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 32 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  const auto current = cache.begin_playback();
  cache.read(320, byte.data(), byte.size(), 4, current);
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (cache.metrics().prefetched_bytes < 64 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  const auto current_prefetch_requests = cache.metrics().prefetch_requests;
  const auto source_calls = source->calls.load();

  const auto stale_bytes = cache.read(80, byte.data(), byte.size(), 4, previous);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  cache.read(328, byte.data(), byte.size());
  const auto metrics = cache.metrics();
  expect(stale_bytes == 0 && source->calls == source_calls &&
             current_prefetch_requests == 4 &&
             metrics.prefetch_requests == 4 && metrics.prefetch_hits >= 1 &&
             metrics.stale_playback_cancellations >= 1,
         "stale playback is cancelled before replacing current prefetch");
}

void test_switch_does_not_wait_for_stale_prefetch() {
  auto source = std::make_shared<SwitchingSource>();
  bridge::BlockCache cache(source, 8, 12);
  cache.configure(12, 4, false, true);
  std::vector<std::uint8_t> byte(1);

  const auto previous = cache.begin_playback();
  cache.read(0, byte.data(), byte.size(), 4, previous);
  const auto old_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!source->old_prefetch_started &&
         std::chrono::steady_clock::now() < old_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->old_prefetch_started, "old prefetch started");

  const auto current = cache.begin_playback();
  cache.read(320, byte.data(), byte.size(), 4, current);
  const auto switch_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(150);
  while (!source->new_prefetch_started &&
         std::chrono::steady_clock::now() < switch_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->new_prefetch_started,
         "new playback prefetch starts without waiting for stale range");
  expect(cache.metrics().cancelled_prefetch_requests >= 1 &&
             cache.metrics().cancelled_prefetch_bytes >= 3,
         "stale prefetch cancellation is reported");
}

void test_switch_cancels_stale_foreground_range() {
  auto source = std::make_shared<SlowForegroundSource>();
  bridge::BlockCache cache(source, 8, 12);
  cache.configure(12, 4, false, true);
  std::vector<std::uint8_t> old_byte(1);
  std::vector<std::uint8_t> current_byte(1);
  const auto previous = cache.begin_playback();
  std::size_t old_result = 1;
  std::thread old_reader([&] {
    old_result = cache.read(0, old_byte.data(), old_byte.size(), 0, previous);
  });
  const auto old_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!source->old_request_started &&
         std::chrono::steady_clock::now() < old_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->old_request_started, "old foreground range started");

  const auto switched_at = std::chrono::steady_clock::now();
  const auto current = cache.begin_playback();
  const auto current_result =
      cache.read(320, current_byte.data(), current_byte.size(), 0, current);
  old_reader.join();
  const auto elapsed = std::chrono::steady_clock::now() - switched_at;
  expect(old_result == 0 && current_result == 1 &&
             source->current_request_started &&
             elapsed < std::chrono::milliseconds(150) &&
             cache.metrics().cancelled_foreground_requests >= 1 &&
             cache.metrics().cancelled_foreground_bytes >= 5,
         "new playback does not wait for stale foreground range");
}

void test_consecutive_seeks_keep_only_latest_generation() {
  auto source = std::make_shared<SlowForegroundSource>();
  bridge::BlockCache cache(source, 8, 12);
  cache.configure(12, 4, false, true);
  std::vector<std::uint8_t> first_byte(1);
  std::vector<std::uint8_t> second_byte(1);
  std::vector<std::uint8_t> latest_byte(1);
  std::size_t first_result = 1;
  std::size_t second_result = 1;

  const auto first = cache.begin_playback();
  std::thread first_reader([&] {
    first_result = cache.read(0, first_byte.data(), 1, 0, first);
  });
  const auto first_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!source->old_request_started &&
         std::chrono::steady_clock::now() < first_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->old_request_started, "first range started");

  const auto second = cache.begin_playback();
  std::thread second_reader([&] {
    second_result = cache.read(160, second_byte.data(), 1, 0, second);
  });
  const auto second_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!source->middle_request_started &&
         std::chrono::steady_clock::now() < second_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(source->middle_request_started, "second range started");

  const auto latest = cache.begin_playback();
  const auto latest_result =
      cache.read(320, latest_byte.data(), 1, 0, latest);
  first_reader.join();
  second_reader.join();
  expect(first_result == 0 && second_result == 0 && latest_result == 1 &&
             latest_byte.front() == 64 &&
             cache.metrics().cancelled_foreground_requests >= 2,
         "consecutive seeks keep only the latest generation");
}

// Regression for the wake-after-evict heap corruption: a waiter waking from
// entry->ready must not relink an lru node that an evictor released between
// loading=false and the wakeup. Two readers share offsets so each constantly
// waits on the other's inflight blocks while a third reader and a configure
// storm keep evicting just-completed entries.
void test_waiter_wake_survives_eviction_storm() {
  auto source = std::make_shared<InstantSource>(4ULL * 1024ULL * 1024ULL);
  bridge::BlockCache cache(source, 4096, 8);
  const auto generation = cache.begin_playback();
  constexpr std::size_t kReadBytes = 4096;
  constexpr int kIterations = 500;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(20);
  std::atomic<bool> stop{false};
  std::atomic<int> failures{0};

  std::thread evictor([&] {
    std::size_t size = 8;
    while (!stop.load(std::memory_order_relaxed)) {
      size = size == 8 ? 5 : 8;
      try {
        cache.configure(size, 4);
      } catch (...) {
        failures.fetch_add(1);
      }
      std::this_thread::sleep_for(std::chrono::microseconds(150));
    }
  });

  auto reader = [&](std::uint64_t begin_offset) {
    std::vector<std::uint8_t> buffer(kReadBytes);
    for (int iteration = 0; iteration < kIterations; ++iteration) {
      if (std::chrono::steady_clock::now() > deadline) break;
      const std::uint64_t offset =
          begin_offset + static_cast<std::uint64_t>(iteration) * kReadBytes;
      const std::size_t copied =
          cache.read(offset, buffer.data(), buffer.size(), 2, generation);
      if (copied != buffer.size()) {
        failures.fetch_add(1);
        return;
      }
      for (std::size_t index = 0; index < kReadBytes; index += 997) {
        if (buffer[index] !=
            static_cast<std::uint8_t>((offset + index) & 0xffU)) {
          failures.fetch_add(1);
          return;
        }
      }
    }
  };

  std::thread shared_a([&] { reader(0); });
  std::thread shared_b([&] { reader(0); });
  std::thread displaced([&] { reader(1024ULL * 1024ULL); });
  shared_a.join();
  shared_b.join();
  displaced.join();
  stop.store(true, std::memory_order_relaxed);
  evictor.join();

  expect(failures.load(std::memory_order_relaxed) == 0,
         "waiter wake survives an eviction storm with intact data");
  expect(cache.metrics().eviction_count > 0, "eviction storm actually evicted");
}

class TemporaryStructureCacheDirectory final {
 public:
  TemporaryStructureCacheDirectory() {
    root_ = std::filesystem::temp_directory_path() /
            ("streampath_iso_structure_cache_" +
             std::to_string(std::chrono::steady_clock::now()
                                .time_since_epoch()
                                .count()));
    std::filesystem::create_directories(root_ / "iso_structure");
  }

  ~TemporaryStructureCacheDirectory() {
    std::error_code ignored;
    std::filesystem::remove_all(root_, ignored);
  }

  std::filesystem::path cache_path(char digit = 'a') const {
    return root_ / "iso_structure" /
           (std::string(64, digit) + ".cache");
  }

  const std::filesystem::path& root() const { return root_; }

 private:
  std::filesystem::path root_;
};

bridge::TitleInfo sample_structure_title(std::string chapter_name =
                                             "Chapter 1") {
  bridge::TitleInfo title;
  title.title_index = 0;
  title.playlist = 1;
  title.duration_milliseconds = 120000;
  title.size = bridge::kM2tsPacketSize * 2000U;
  title.chapters = {
      {0, 60000, std::move(chapter_name)},
      {60000, 60000, {}},
  };
  title.clips = {
      {0, bridge::kM2tsPacketSize * 1000U, 60LL * 90000LL},
      {bridge::kM2tsPacketSize * 1000U,
       bridge::kM2tsPacketSize * 2000U, 61LL * 90000LL},
  };
  return title;
}

std::vector<std::uint8_t> read_binary_file(
    const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input),
          std::istreambuf_iterator<char>()};
}

void write_binary_file(const std::filesystem::path& path,
                       const std::vector<std::uint8_t>& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  expect(static_cast<bool>(output), "test cache bytes written");
}

std::array<std::uint8_t, 32> test_sha256(const std::uint8_t* data,
                                         std::size_t length) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  expect(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                     nullptr, 0) >= 0,
         "test sha256 provider opened");
  std::array<std::uint8_t, 32> digest{};
  const NTSTATUS status = BCryptHash(
      algorithm, nullptr, 0, const_cast<PUCHAR>(data),
      static_cast<ULONG>(length), digest.data(),
      static_cast<ULONG>(digest.size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  expect(status >= 0, "test sha256 completed");
  return digest;
}

void refresh_test_cache_digest(std::vector<std::uint8_t>& bytes) {
  expect(bytes.size() >= 32U, "test cache has digest");
  const std::size_t payload_size = bytes.size() - 32U;
  const auto digest = test_sha256(bytes.data(), payload_size);
  std::copy(digest.begin(), digest.end(), bytes.begin() +
                                               static_cast<std::ptrdiff_t>(
                                                   payload_size));
}

void write_test_uint32(std::vector<std::uint8_t>& bytes, std::size_t offset,
                       std::uint32_t value) {
  expect(offset + sizeof(value) <= bytes.size(), "test cache field exists");
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    bytes[offset + index] =
        static_cast<std::uint8_t>(value >> (index * 8U));
  }
}

void test_structure_cache_roundtrip_and_identity() {
  TemporaryStructureCacheDirectory temporary;
  const auto path = temporary.cache_path();
  const auto identity = bridge::make_structure_cache_identity(
      8ULL * 1024ULL * 1024ULL,
      bridge::StructureCacheValidatorKind::strong_etag,
      L"\"secret-etag-token\"");
  expect(identity.has_value(), "etag cache identity created");
  const std::vector<bridge::TitleInfo> titles = {sample_structure_title()};
  expect(bridge::write_structure_cache(path, *identity, titles),
         "structure cache written");
  const auto loaded = bridge::load_structure_cache(path, *identity);
  expect(loaded.has_value() && loaded->size() == 1 &&
             loaded->front().playlist == 1 &&
             loaded->front().chapters.size() == 2 &&
             loaded->front().chapters.front().name == "Chapter 1" &&
             loaded->front().clips.size() == 2 &&
             loaded->front().clips.back().end_byte == titles.front().size,
         "structure cache round trip preserves titles chapters and clips");

  const auto changed_validator = bridge::make_structure_cache_identity(
      identity->content_length,
      bridge::StructureCacheValidatorKind::strong_etag, L"\"v2\"");
  const auto changed_length = bridge::make_structure_cache_identity(
      identity->content_length + 1,
      bridge::StructureCacheValidatorKind::strong_etag,
      L"\"secret-etag-token\"");
  const auto changed_kind = bridge::make_structure_cache_identity(
      identity->content_length,
      bridge::StructureCacheValidatorKind::last_modified,
      L"\"secret-etag-token\"");
  expect(changed_validator.has_value() && changed_length.has_value() &&
             changed_kind.has_value() &&
             !bridge::load_structure_cache(path, *changed_validator)
                  .has_value() &&
             !bridge::load_structure_cache(path, *changed_length).has_value() &&
             !bridge::load_structure_cache(path, *changed_kind).has_value(),
         "structure cache identity changes are misses");

  const auto bytes = read_binary_file(path);
  const std::string raw(bytes.begin(), bytes.end());
  expect(raw.find("secret-etag-token") == std::string::npos,
         "structure cache stores only the validator digest");

  const auto last_modified_path = temporary.cache_path('b');
  const auto last_modified = bridge::make_structure_cache_identity(
      identity->content_length,
      bridge::StructureCacheValidatorKind::last_modified,
      L"Mon, 31 Aug 2026 10:00:00 GMT");
  expect(last_modified.has_value() &&
             bridge::write_structure_cache(last_modified_path,
                                           *last_modified, titles) &&
             bridge::load_structure_cache(last_modified_path, *last_modified)
                 .has_value(),
         "last-modified cache identity round trips");
}

void test_structure_cache_corruption_limits_and_atomic_replace() {
  TemporaryStructureCacheDirectory temporary;
  const auto path = temporary.cache_path();
  const auto identity = bridge::make_structure_cache_identity(
      16ULL * 1024ULL * 1024ULL,
      bridge::StructureCacheValidatorKind::strong_etag, L"\"v1\"");
  expect(identity.has_value(), "cache identity created");
  const std::vector<bridge::TitleInfo> original = {sample_structure_title()};
  expect(bridge::write_structure_cache(path, *identity, original),
         "original structure cache written");
  const auto valid_bytes = read_binary_file(path);

  auto truncated = valid_bytes;
  truncated.resize(truncated.size() / 2U);
  const auto truncated_path = temporary.cache_path('b');
  write_binary_file(truncated_path, truncated);
  expect(!bridge::load_structure_cache(truncated_path, *identity).has_value(),
         "truncated structure cache is a miss");

  auto corrupted = valid_bytes;
  corrupted[70] ^= 0x5aU;
  const auto corrupted_path = temporary.cache_path('c');
  write_binary_file(corrupted_path, corrupted);
  expect(!bridge::load_structure_cache(corrupted_path, *identity).has_value(),
         "integrity mismatch is a miss");

  auto future_schema = valid_bytes;
  write_test_uint32(future_schema, 8,
                    bridge::kIsoStructureCacheSchemaVersion + 1U);
  refresh_test_cache_digest(future_schema);
  const auto future_path = temporary.cache_path('d');
  write_binary_file(future_path, future_schema);
  expect(!bridge::load_structure_cache(future_path, *identity).has_value(),
         "future structure cache schema is a miss");

  auto excessive_titles = valid_bytes;
  write_test_uint32(excessive_titles, 64,
                    bridge::kMaximumStructureCacheTitles + 1U);
  refresh_test_cache_digest(excessive_titles);
  const auto excessive_path = temporary.cache_path('e');
  write_binary_file(excessive_path, excessive_titles);
  expect(!bridge::load_structure_cache(excessive_path, *identity).has_value(),
         "excessive title count is a miss");

  expect(!bridge::write_structure_cache(path, *identity, {}),
         "invalid replacement is rejected");
  expect(bridge::load_structure_cache(path, *identity).has_value(),
         "rejected replacement preserves the last valid cache");

  const std::vector<bridge::TitleInfo> replacement = {
      sample_structure_title("Replaced")};
  expect(bridge::write_structure_cache(path, *identity, replacement),
         "valid replacement is written atomically");
  const auto replaced = bridge::load_structure_cache(path, *identity);
  expect(replaced.has_value() &&
             replaced->front().chapters.front().name == "Replaced",
         "atomic replacement exposes the complete new cache");

  const auto blocked_parent = temporary.root() / "blocked" / "iso_structure";
  std::filesystem::create_directories(blocked_parent.parent_path());
  write_binary_file(blocked_parent, {1U});
  const auto blocked_path = blocked_parent /
                            (std::string(64, 'f') + ".cache");
  expect(!bridge::write_structure_cache(blocked_path, *identity, original),
         "unwritable structure cache path does not fail playback work");
}

}  // namespace

void test_remote_disc_random_reads_and_protocol() {
  class DiscSource final : public bridge::BlockSource {
   public:
    std::uint64_t size() const override { return 16 * bridge::kIsoBlockSize; }
    std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end) override {
      std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end - start + 1));
      for (std::size_t i = 0; i < bytes.size(); ++i) bytes[i] = pattern(start + i);
      return bytes;
    }
    static std::uint8_t pattern(std::uint64_t offset) {
      return static_cast<std::uint8_t>((offset ^ (offset >> 11) ^ (offset >> 19)) & 255);
    }
  };
  auto source = std::make_shared<DiscSource>();
  bridge::BlockCache cache(source, bridge::kIsoDemandBlockSize, 64);
  bridge::RemoteDiscProvider disc(cache, source->size());
  auto generation = disc.activate(1);
  std::uint64_t seed = 1234567;
  std::vector<std::uint8_t> bytes(3 * 2048);
  for (int i = 0; i < 120; ++i) {
    seed = seed * 6364136223846793005ULL + 1;
    const auto start = (seed % (source->size() / 2048 - 3)) * 2048;
    expect(disc.read(start, bytes.data(), bytes.size(), false, generation) == bytes.size(),
           "remote disc complete random read");
    for (std::size_t j = 0; j < bytes.size(); ++j) {
      expect(bytes[j] == DiscSource::pattern(start + j), "remote disc positional bytes");
    }
  }
  expect(disc.activate(1) == generation, "adjacent reads retain generation");
  generation = disc.activate(3);
  bool cancelled = false;
  try { disc.activate(2); } catch (const bridge::FetchCancelled&) { cancelled = true; }
  expect(cancelled && cache.is_playback_current(generation), "stale input cannot cancel latest");
  expect(disc.cancelled_generations() == 1, "navigation cancellation metric");
  const std::string fields = "X-StreamPath-Generation: 3\r\nX-StreamPath-Phase: metadata\r\n";
  expect(bridge::parse_remote_disc_request(
      "Range: bytes=2048-4095\r\n" + fields + "\r\n", disc).status == 206,
      "valid closed aligned range");
  for (const std::string& range : {"bytes=0-", "bytes=-2048", "bytes=1-2048",
       "bytes=0-1023", "bytes=0-8388607", "bytes=0-2047,4096-6143",
       "bytes=0-18446744073709551615"}) {
    expect(bridge::parse_remote_disc_request("Range: " + range + "\r\n" + fields + "\r\n", disc).status != 206,
           "unbounded, malformed and unaligned disc requests rejected");
  }
  expect(bridge::parse_remote_disc_request(fields + "\r\n", disc).status != 206,
         "full ISO GET is forbidden");
  expect(bridge::parse_remote_disc_request("Range: bytes=0-2047\r\n" + fields +
      "X-StreamPath-Generation: 4\r\n\r\n", disc).status != 206, "duplicate generation rejected");
  expect(bridge::parse_remote_disc_request("Range: bytes=0-2047\r\n" + fields +
      "Accept-Encoding: gzip\r\n\r\n", disc).status != 206, "encoded disc request rejected");
}

int main() {
  try {
    test_ranges();
    test_remote_disc_random_reads_and_protocol();
    test_json();
    test_m2ts_timestamp_normalization();
    test_cache();
    test_title_recovery_batches();
    test_stream_prefetch_publication();
    test_metadata_cache_handoff_preserves_hot_blocks_and_refetch_history();
    test_prefetch_and_demand_share_inflight_block();
    test_new_generation_replaces_cancelled_same_block_load();
    test_inflight_failure_wakes_all_waiters();
    test_new_playback_discards_failed_cache_entry();
    test_dynamic_cache_configuration();
    test_small_demand_blocks_preserve_sequential_configuration_units();
    test_playback_read_ahead_policy();
    test_playback_prefetch();
    test_seek_replaces_prefetch_window();
    test_disc_seek_retains_cached_bytes_and_playback_generation();
    test_long_disc_buffer_preserves_unread_window();
    test_disc_short_window_refills_before_exhaustion();
    test_title_unread_window_retention();
    test_title_unread_window_allows_capacity_reduction();
    test_stale_playback_cannot_replace_current_prefetch_window();
    test_switch_does_not_wait_for_stale_prefetch();
    test_switch_cancels_stale_foreground_range();
    test_consecutive_seeks_keep_only_latest_generation();
    test_waiter_wake_survives_eviction_storm();
    test_structure_cache_roundtrip_and_identity();
    test_structure_cache_corruption_limits_and_atomic_replace();
    std::cout << "streampath_iso_bridge_tests: PASS\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "streampath_iso_bridge_tests: FAIL: " << error.what() << '\n';
    return 1;
  }
}
