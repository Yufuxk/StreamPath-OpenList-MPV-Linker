#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

namespace streampath::iso_bridge {

constexpr std::uint64_t kIsoBlockSize = 4ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t kIsoDemandBlockSize = 256ULL * 1024ULL;
constexpr std::uint64_t kIsoMetadataRetainedBytes =
    4ULL * kIsoBlockSize;
constexpr std::size_t kIsoBlockCount = 16;
constexpr std::size_t kMinimumPlaybackReadAheadBlocks = 4;
constexpr std::size_t kMaximumPlaybackReadAheadBlocks = 12;
constexpr std::size_t kInitialPlaybackPrefetchBatchBlocks = 2;
constexpr std::size_t kPlaybackPrefetchBatchBlocks = 4;
constexpr std::uint32_t kMaxControlMessageBytes = 1024U * 1024U;
constexpr std::size_t kM2tsPacketSize = 192;

struct M2tsClipTimeline {
  std::uint64_t begin_byte = 0;
  std::uint64_t end_byte = 0;
  std::int64_t timestamp_offset_90khz = 0;
};

bool normalize_m2ts_timestamps(
    std::uint8_t* data, std::size_t length, std::uint64_t absolute_offset,
    const std::vector<M2tsClipTimeline>& clips);

std::size_t playback_read_ahead_blocks(std::uint64_t stream_size,
                                       std::uint64_t duration_milliseconds,
                                       std::uint64_t block_size = kIsoBlockSize);

enum class ByteRangeStatus {
  ok,
  invalid,
  multiple,
  unsatisfiable,
};

struct ByteRangeResult {
  ByteRangeStatus status = ByteRangeStatus::invalid;
  std::uint64_t start = 0;
  std::uint64_t end = 0;
};

ByteRangeResult parse_byte_range(std::string_view value,
                                 std::uint64_t resource_size);

struct ContentRange {
  std::uint64_t start = 0;
  std::uint64_t end = 0;
  std::uint64_t total = 0;
};

std::optional<ContentRange> parse_content_range(std::string_view value);

using JsonScalar = std::variant<std::nullptr_t, bool, std::int64_t, std::string>;
using JsonObject = std::unordered_map<std::string, JsonScalar>;

std::optional<JsonObject> parse_json_object(std::string_view json);
std::string json_escape(std::string_view value);

class BlockSource {
 public:
  using CancellationProbe = std::function<bool()>;

  virtual ~BlockSource() = default;
  virtual std::uint64_t size() const = 0;
  virtual std::vector<std::uint8_t> fetch(std::uint64_t start,
                                          std::uint64_t end) = 0;
  virtual std::vector<std::uint8_t> fetch(
      std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled);
  virtual void cancel_pending();
};

class FetchCancelled final : public std::runtime_error {
 public:
  explicit FetchCancelled(std::uint64_t received_bytes)
      : std::runtime_error("block source fetch cancelled"),
        received_bytes_(received_bytes) {}

  std::uint64_t received_bytes() const noexcept { return received_bytes_; }

 private:
  std::uint64_t received_bytes_;
};

struct BlockCacheMetrics {
  // Legacy aggregate fields remain available to version 1 readers.
  std::uint64_t fetched_bytes = 0;
  std::uint64_t requests = 0;
  std::uint64_t hits = 0;
  std::uint64_t peak_bytes = 0;
  std::uint64_t prefetch_requests = 0;
  std::uint64_t prefetched_bytes = 0;
  std::uint64_t prefetch_hits = 0;
  std::uint64_t playback_requests = 0;
  std::uint64_t stale_playback_cancellations = 0;
  std::uint64_t cancelled_prefetch_requests = 0;
  std::uint64_t cancelled_foreground_requests = 0;
  std::uint64_t resident_bytes = 0;
  std::uint64_t cache_capacity_bytes = 0;
  std::size_t configured_prefetch_blocks = kMaximumPlaybackReadAheadBlocks;

  // Version 2 counters use demand/prefetch and delivered/remote byte domains.
  std::uint64_t foreground_fetch_bytes = 0;
  std::uint64_t prefetch_fetch_bytes = 0;
  std::uint64_t consumer_bytes_delivered = 0;
  std::uint64_t cache_miss_count = 0;
  std::uint64_t prefetch_unused_bytes = 0;
  std::uint64_t cancelled_foreground_bytes = 0;
  std::uint64_t cancelled_prefetch_bytes = 0;
  std::uint64_t eviction_count = 0;
  std::uint64_t refetch_count = 0;
  std::uint64_t prefetch_active_peak = 0;
  std::uint64_t prefetch_overlap_count = 0;
  std::uint64_t prefetch_pending_gap_us_total = 0;
  std::uint64_t prefetch_pending_gap_us_max = 0;
  std::uint64_t prefetch_in_flight_bytes_peak = 0;
  std::uint64_t prefetch_hit_bytes = 0;
  std::uint64_t prefetch_concurrent_wall_clock_us = 0;
  bool refetch_count_available = true;
};

struct RetainedBlock {
  std::uint64_t index = 0;
  std::vector<std::uint8_t> bytes;
};

struct BlockCacheHandoff {
  std::uint64_t block_size = 0;
  std::vector<RetainedBlock> blocks;
  std::unordered_set<std::uint64_t> fetched_block_indices;
  std::uint64_t retained_bytes = 0;
  bool refetch_count_available = true;
};

BlockCacheMetrics combine_sequential_cache_metrics(
    const BlockCacheMetrics& metadata,
    const BlockCacheMetrics& playback);

class BlockCache {
 public:
  explicit BlockCache(std::shared_ptr<BlockSource> source,
                      std::uint64_t block_size = kIsoBlockSize,
                      std::size_t block_count = kIsoBlockCount,
                      std::size_t configuration_block_scale = 1,
                      std::size_t initial_prefetch_batch_blocks =
                          kInitialPlaybackPrefetchBatchBlocks,
                      std::size_t prefetch_batch_blocks =
                          kPlaybackPrefetchBatchBlocks);
  ~BlockCache();
  BlockCache(const BlockCache&) = delete;
  BlockCache& operator=(const BlockCache&) = delete;

  std::uint64_t begin_playback();
  void reset_read_ahead();
  void shutdown();
  void configure(std::size_t block_count, std::size_t max_read_ahead_blocks,
                 bool protect_read_ahead = false);
  bool is_playback_current(std::uint64_t playback_generation) const;
  std::size_t limit_read_ahead(std::size_t requested_blocks) const;
  std::size_t read(std::uint64_t offset, std::uint8_t* destination,
                   std::size_t length, std::size_t read_ahead_blocks = 0,
                   std::uint64_t playback_generation = 0);
  BlockCacheMetrics metrics() const;
  BlockCacheHandoff take_handoff(std::uint64_t maximum_retained_bytes);
  void restore_handoff(BlockCacheHandoff handoff);

 private:
  struct Entry {
    bool loading = true;
    std::vector<std::uint8_t> bytes;
    std::exception_ptr error;
    bool prefetched = false;
    bool removed = false;
    // BlockCache::read() loads this outside mutex_ while the prefetch thread
    // stores it under the lock, so it must be atomic.
    std::atomic<bool> cancelled = false;
    std::condition_variable ready;
    std::list<std::uint64_t>::iterator lru_position;
  };

  std::shared_ptr<Entry> block(std::uint64_t index,
                               std::uint64_t playback_generation,
                               bool prefetch = false);
  void schedule_prefetch(std::uint64_t next_offset, std::size_t block_count,
                         std::uint64_t playback_generation);
  void prefetch_loop();
  void update_prefetch_pending_gap_locked(
      std::chrono::steady_clock::time_point now);
  void record_prefetch_started_locked(
      std::uint64_t bytes, std::chrono::steady_clock::time_point now);
  void record_prefetch_finished_locked(
      std::uint64_t bytes, std::chrono::steady_clock::time_point now);
  void touch_locked(std::uint64_t index, const std::shared_ptr<Entry>& entry);
  bool evict_one_locked();
  // Requires mutex_ held. Inserts a new entry for index; returns nullptr when
  // index is already present (the prefetch selection retries in that case).
  std::shared_ptr<Entry> insert_entry_locked(std::uint64_t index);

  const std::shared_ptr<BlockSource> source_;
  const std::uint64_t block_size_;
  const std::size_t configuration_block_scale_;
  const std::size_t initial_prefetch_batch_blocks_;
  const std::size_t prefetch_batch_blocks_;
  std::size_t block_count_;
  bool protect_read_ahead_ = false;
  std::size_t max_read_ahead_blocks_ = kMaximumPlaybackReadAheadBlocks;
  std::mutex playback_transition_mutex_;
  mutable std::mutex mutex_;
  std::condition_variable space_available_;
  std::condition_variable prefetch_ready_;
  std::unordered_map<std::uint64_t, std::shared_ptr<Entry>> entries_;
  std::unordered_set<std::uint64_t> fetched_block_indices_;
  std::list<std::uint64_t> lru_;
  BlockCacheMetrics metrics_;
  std::uint64_t resident_bytes_ = 0;
  std::thread prefetch_worker_;
  bool stopping_ = false;
  bool prefetch_pending_ = false;
  std::uint64_t prefetch_window_start_ = 0;
  std::uint64_t prefetch_next_ = 0;
  std::uint64_t prefetch_end_ = 0;
  std::uint64_t prefetch_generation_ = 0;
  std::uint64_t active_playback_generation_ = 0;
  bool initial_prefetch_batch_ = true;
  bool refetch_count_available_ = true;
  std::uint64_t active_prefetch_count_ = 0;
  std::uint64_t prefetch_in_flight_bytes_ = 0;
  std::optional<std::chrono::steady_clock::time_point>
      prefetch_pending_gap_started_;
  std::optional<std::chrono::steady_clock::time_point>
      prefetch_overlap_started_;
};

}  // namespace streampath::iso_bridge
