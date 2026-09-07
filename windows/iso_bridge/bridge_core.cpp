#include "bridge_core.h"

#include <algorithm>
#include <cassert>
#include <charconv>
#include <cmath>
#include <cstring>
#include <limits>

namespace streampath::iso_bridge {
namespace {

std::string_view trim(std::string_view value) {
  while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) {
    value.remove_prefix(1);
  }
  while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) {
    value.remove_suffix(1);
  }
  return value;
}

std::optional<std::uint64_t> parse_unsigned(std::string_view value) {
  if (value.empty()) return std::nullopt;
  std::uint64_t result = 0;
  const auto parsed =
      std::from_chars(value.data(), value.data() + value.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) {
    return std::nullopt;
  }
  return result;
}

constexpr std::uint64_t kTimestampMask = (1ULL << 33U) - 1U;

std::uint64_t apply_timestamp_offset(std::uint64_t value,
                                     std::int64_t offset) {
  const std::int64_t adjusted = static_cast<std::int64_t>(value) + offset;
  return static_cast<std::uint64_t>(adjusted) & kTimestampMask;
}

bool adjust_pes_timestamp(std::uint8_t* data, std::int64_t offset) {
  if ((data[0] & 0x01U) == 0 || (data[2] & 0x01U) == 0 ||
      (data[4] & 0x01U) == 0) {
    return false;
  }
  const std::uint64_t timestamp =
      (static_cast<std::uint64_t>((data[0] >> 1U) & 0x07U) << 30U) |
      (static_cast<std::uint64_t>(data[1]) << 22U) |
      (static_cast<std::uint64_t>((data[2] >> 1U) & 0x7fU) << 15U) |
      (static_cast<std::uint64_t>(data[3]) << 7U) |
      static_cast<std::uint64_t>((data[4] >> 1U) & 0x7fU);
  const std::uint64_t adjusted = apply_timestamp_offset(timestamp, offset);
  data[0] = static_cast<std::uint8_t>(
      (data[0] & 0xf0U) | ((adjusted >> 29U) & 0x0eU) | 0x01U);
  data[1] = static_cast<std::uint8_t>(adjusted >> 22U);
  data[2] = static_cast<std::uint8_t>(((adjusted >> 14U) & 0xfeU) | 0x01U);
  data[3] = static_cast<std::uint8_t>(adjusted >> 7U);
  data[4] = static_cast<std::uint8_t>(((adjusted << 1U) & 0xfeU) | 0x01U);
  return true;
}

void adjust_program_clock_reference(std::uint8_t* data,
                                    std::int64_t offset) {
  const std::uint64_t base =
      (static_cast<std::uint64_t>(data[0]) << 25U) |
      (static_cast<std::uint64_t>(data[1]) << 17U) |
      (static_cast<std::uint64_t>(data[2]) << 9U) |
      (static_cast<std::uint64_t>(data[3]) << 1U) |
      static_cast<std::uint64_t>(data[4] >> 7U);
  const std::uint64_t adjusted = apply_timestamp_offset(base, offset);
  data[0] = static_cast<std::uint8_t>(adjusted >> 25U);
  data[1] = static_cast<std::uint8_t>(adjusted >> 17U);
  data[2] = static_cast<std::uint8_t>(adjusted >> 9U);
  data[3] = static_cast<std::uint8_t>(adjusted >> 1U);
  data[4] = static_cast<std::uint8_t>((data[4] & 0x7fU) |
                                      ((adjusted & 0x01U) << 7U));
}

bool normalize_m2ts_packet(std::uint8_t* packet, std::int64_t offset) {
  std::uint8_t* transport = packet + 4;
  if (transport[0] != 0x47U) return false;

  const std::uint8_t adaptation_control = (transport[3] >> 4U) & 0x03U;
  std::size_t payload_offset = 4;
  if (adaptation_control == 2U || adaptation_control == 3U) {
    const std::size_t adaptation_length = transport[4];
    if (adaptation_length > 183U) return false;
    payload_offset += 1U + adaptation_length;
    if (adaptation_length >= 7U) {
      const std::uint8_t flags = transport[5];
      std::size_t clock_offset = 6;
      if ((flags & 0x10U) != 0) {
        adjust_program_clock_reference(transport + clock_offset, offset);
        clock_offset += 6;
      }
      if ((flags & 0x08U) != 0 &&
          clock_offset + 6U <= 5U + adaptation_length) {
        adjust_program_clock_reference(transport + clock_offset, offset);
      }
    }
  }

  if (adaptation_control != 1U && adaptation_control != 3U) return true;
  if ((transport[1] & 0x40U) == 0 || payload_offset + 14U > 188U) {
    return true;
  }
  std::uint8_t* payload = transport + payload_offset;
  const std::size_t payload_length = 188U - payload_offset;
  if (payload_length < 14U || payload[0] != 0 || payload[1] != 0 ||
      payload[2] != 1U) {
    return true;
  }
  const std::uint8_t stream_id = payload[3];
  if (stream_id == 0xbcU || stream_id == 0xbeU || stream_id == 0xbfU ||
      stream_id == 0xf0U || stream_id == 0xf1U || stream_id == 0xf2U ||
      stream_id == 0xf8U || stream_id == 0xffU) {
    return true;
  }
  const std::uint8_t pts_dts_flags = (payload[7] >> 6U) & 0x03U;
  if (pts_dts_flags == 2U && payload_length >= 14U) {
    return adjust_pes_timestamp(payload + 9, offset);
  } else if (pts_dts_flags == 3U && payload_length >= 19U) {
    return adjust_pes_timestamp(payload + 9, offset) &&
           adjust_pes_timestamp(payload + 14, offset);
  }
  return true;
}

void append_utf8(std::string& output, std::uint32_t code_point) {
  if (code_point <= 0x7fU) {
    output.push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7ffU) {
    output.push_back(static_cast<char>(0xc0U | (code_point >> 6U)));
    output.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
  } else if (code_point <= 0xffffU) {
    output.push_back(static_cast<char>(0xe0U | (code_point >> 12U)));
    output.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
    output.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
  } else {
    output.push_back(static_cast<char>(0xf0U | (code_point >> 18U)));
    output.push_back(static_cast<char>(0x80U | ((code_point >> 12U) & 0x3fU)));
    output.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
    output.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
  }
}

class JsonParser {
 public:
  explicit JsonParser(std::string_view input) : input_(input) {}

  std::optional<JsonObject> parse() {
    skip_space();
    if (!consume('{')) return std::nullopt;
    JsonObject result;
    skip_space();
    if (consume('}')) return finish(std::move(result));
    while (true) {
      const auto key = string();
      if (!key.has_value()) return std::nullopt;
      skip_space();
      if (!consume(':')) return std::nullopt;
      skip_space();
      const auto value = scalar();
      if (!value.has_value() || !result.emplace(*key, *value).second) {
        return std::nullopt;
      }
      skip_space();
      if (consume('}')) return finish(std::move(result));
      if (!consume(',')) return std::nullopt;
      skip_space();
    }
  }

 private:
  std::optional<JsonObject> finish(JsonObject value) {
    skip_space();
    return position_ == input_.size()
               ? std::optional<JsonObject>(std::move(value))
               : std::nullopt;
  }

  std::optional<JsonScalar> scalar() {
    if (position_ >= input_.size()) return std::nullopt;
    if (input_[position_] == '"') {
      const auto value = string();
      if (!value.has_value()) return std::nullopt;
      return JsonScalar(*value);
    }
    if (starts_with("true")) return JsonScalar(true);
    if (starts_with("false")) return JsonScalar(false);
    if (starts_with("null")) return JsonScalar(nullptr);

    const std::size_t start = position_;
    if (input_[position_] == '-') ++position_;
    const std::size_t digits = position_;
    while (position_ < input_.size() && input_[position_] >= '0' &&
           input_[position_] <= '9') {
      ++position_;
    }
    if (digits == position_) return std::nullopt;
    std::int64_t value = 0;
    const auto parsed = std::from_chars(input_.data() + start,
                                        input_.data() + position_, value);
    if (parsed.ec != std::errc{} || parsed.ptr != input_.data() + position_) {
      return std::nullopt;
    }
    return JsonScalar(value);
  }

  std::optional<std::string> string() {
    skip_space();
    if (!consume('"')) return std::nullopt;
    std::string output;
    while (position_ < input_.size()) {
      const unsigned char byte =
          static_cast<unsigned char>(input_[position_++]);
      if (byte == '"') return output;
      if (byte < 0x20U) return std::nullopt;
      if (byte != '\\') {
        output.push_back(static_cast<char>(byte));
        continue;
      }
      if (position_ >= input_.size()) return std::nullopt;
      const char escaped = input_[position_++];
      switch (escaped) {
        case '"':
        case '\\':
        case '/':
          output.push_back(escaped);
          break;
        case 'b':
          output.push_back('\b');
          break;
        case 'f':
          output.push_back('\f');
          break;
        case 'n':
          output.push_back('\n');
          break;
        case 'r':
          output.push_back('\r');
          break;
        case 't':
          output.push_back('\t');
          break;
        case 'u': {
          auto code_point = hex4();
          if (!code_point.has_value()) return std::nullopt;
          if (*code_point >= 0xd800U && *code_point <= 0xdbffU) {
            if (position_ + 2 > input_.size() || input_[position_] != '\\' ||
                input_[position_ + 1] != 'u') {
              return std::nullopt;
            }
            position_ += 2;
            const auto low = hex4();
            if (!low.has_value() || *low < 0xdc00U || *low > 0xdfffU) {
              return std::nullopt;
            }
            code_point = 0x10000U + ((*code_point - 0xd800U) << 10U) +
                         (*low - 0xdc00U);
          } else if (*code_point >= 0xdc00U && *code_point <= 0xdfffU) {
            return std::nullopt;
          }
          append_utf8(output, *code_point);
          break;
        }
        default:
          return std::nullopt;
      }
    }
    return std::nullopt;
  }

  std::optional<std::uint32_t> hex4() {
    if (position_ + 4 > input_.size()) return std::nullopt;
    std::uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
      const char ch = input_[position_++];
      value <<= 4U;
      if (ch >= '0' && ch <= '9') {
        value |= static_cast<std::uint32_t>(ch - '0');
      } else if (ch >= 'a' && ch <= 'f') {
        value |= static_cast<std::uint32_t>(ch - 'a' + 10);
      } else if (ch >= 'A' && ch <= 'F') {
        value |= static_cast<std::uint32_t>(ch - 'A' + 10);
      } else {
        return std::nullopt;
      }
    }
    return value;
  }

  bool starts_with(std::string_view token) {
    if (input_.substr(position_, token.size()) != token) return false;
    position_ += token.size();
    return true;
  }

  bool consume(char expected) {
    if (position_ >= input_.size() || input_[position_] != expected) {
      return false;
    }
    ++position_;
    return true;
  }

  void skip_space() {
    while (position_ < input_.size()) {
      const char ch = input_[position_];
      if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') return;
      ++position_;
    }
  }

  std::string_view input_;
  std::size_t position_ = 0;
};

}  // namespace

bool normalize_m2ts_timestamps(
    std::uint8_t* data, std::size_t length, std::uint64_t absolute_offset,
    const std::vector<M2tsClipTimeline>& clips) {
  if (data == nullptr || length % kM2tsPacketSize != 0 ||
      absolute_offset % kM2tsPacketSize != 0 || clips.empty()) {
    return false;
  }
  std::size_t clip_index = 0;
  while (clip_index < clips.size() &&
         absolute_offset >= clips[clip_index].end_byte) {
    ++clip_index;
  }
  for (std::size_t offset = 0; offset < length;
       offset += kM2tsPacketSize) {
    const std::uint64_t packet_offset = absolute_offset + offset;
    while (clip_index < clips.size() &&
           packet_offset >= clips[clip_index].end_byte) {
      ++clip_index;
    }
    if (clip_index >= clips.size() ||
        packet_offset < clips[clip_index].begin_byte ||
        packet_offset + kM2tsPacketSize > clips[clip_index].end_byte ||
        !normalize_m2ts_packet(data + offset,
                               clips[clip_index].timestamp_offset_90khz)) {
      return false;
    }
  }
  return true;
}

std::size_t playback_read_ahead_blocks(std::uint64_t stream_size,
                                       std::uint64_t duration_milliseconds,
                                       std::uint64_t block_size) {
  if (stream_size == 0 || duration_milliseconds == 0 || block_size == 0) {
    return kMinimumPlaybackReadAheadBlocks;
  }
  constexpr long double kTargetSeconds = 8.0L;
  const long double bytes_per_second =
      static_cast<long double>(stream_size) * 1000.0L /
      static_cast<long double>(duration_milliseconds);
  const long double requested = bytes_per_second * kTargetSeconds;
  const long double minimum =
      static_cast<long double>(block_size) * kMinimumPlaybackReadAheadBlocks;
  const long double maximum =
      static_cast<long double>(block_size) * kMaximumPlaybackReadAheadBlocks;
  const long double bounded = std::clamp(requested, minimum, maximum);
  return static_cast<std::size_t>(
      std::ceil(bounded / static_cast<long double>(block_size)));
}

ByteRangeResult parse_byte_range(std::string_view value,
                                 std::uint64_t resource_size) {
  value = trim(value);
  if (resource_size == 0 || value.size() < 6 || value.substr(0, 6) != "bytes=") {
    return {ByteRangeStatus::invalid, 0, 0};
  }
  value.remove_prefix(6);
  if (value.find(',') != std::string_view::npos) {
    return {ByteRangeStatus::multiple, 0, 0};
  }
  const std::size_t dash = value.find('-');
  if (dash == std::string_view::npos) {
    return {ByteRangeStatus::invalid, 0, 0};
  }
  const auto first = trim(value.substr(0, dash));
  const auto second = trim(value.substr(dash + 1));
  if (first.empty()) {
    const auto suffix = parse_unsigned(second);
    if (!suffix.has_value() || *suffix == 0) {
      return {ByteRangeStatus::invalid, 0, 0};
    }
    const std::uint64_t length = std::min(*suffix, resource_size);
    return {ByteRangeStatus::ok, resource_size - length, resource_size - 1};
  }
  const auto start = parse_unsigned(first);
  if (!start.has_value()) return {ByteRangeStatus::invalid, 0, 0};
  if (*start >= resource_size) {
    return {ByteRangeStatus::unsatisfiable, 0, 0};
  }
  if (second.empty()) {
    return {ByteRangeStatus::ok, *start, resource_size - 1};
  }
  const auto requested_end = parse_unsigned(second);
  if (!requested_end.has_value() || *requested_end < *start) {
    return {ByteRangeStatus::invalid, 0, 0};
  }
  return {ByteRangeStatus::ok, *start,
          std::min(*requested_end, resource_size - 1)};
}

std::optional<ContentRange> parse_content_range(std::string_view value) {
  value = trim(value);
  if (value.size() < 7 || value.substr(0, 6) != "bytes ") return std::nullopt;
  value.remove_prefix(6);
  const std::size_t dash = value.find('-');
  const std::size_t slash = value.find('/');
  if (dash == std::string_view::npos || slash == std::string_view::npos ||
      dash == 0 || slash <= dash + 1 || slash + 1 >= value.size()) {
    return std::nullopt;
  }
  const auto start = parse_unsigned(value.substr(0, dash));
  const auto end = parse_unsigned(value.substr(dash + 1, slash - dash - 1));
  const auto total = parse_unsigned(value.substr(slash + 1));
  if (!start.has_value() || !end.has_value() || !total.has_value() ||
      *total == 0 || *start > *end || *end >= *total) {
    return std::nullopt;
  }
  return ContentRange{*start, *end, *total};
}

std::optional<JsonObject> parse_json_object(std::string_view json) {
  return JsonParser(json).parse();
}

std::string json_escape(std::string_view value) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string output;
  output.reserve(value.size() + 2);
  output.push_back('"');
  for (const unsigned char byte : value) {
    switch (byte) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\b':
        output += "\\b";
        break;
      case '\f':
        output += "\\f";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (byte < 0x20U) {
          output += "\\u00";
          output.push_back(kHex[(byte >> 4U) & 0x0fU]);
          output.push_back(kHex[byte & 0x0fU]);
        } else {
          output.push_back(static_cast<char>(byte));
        }
    }
  }
  output.push_back('"');
  return output;
}

std::vector<std::uint8_t> BlockSource::fetch(
    std::uint64_t start, std::uint64_t end,
    const CancellationProbe& cancelled) {
  if (cancelled && cancelled()) {
    throw FetchCancelled(0);
  }
  auto bytes = fetch(start, end);
  if (cancelled && cancelled()) {
    throw FetchCancelled(bytes.size());
  }
  return bytes;
}

void BlockSource::cancel_pending() {}

BlockCacheMetrics combine_sequential_cache_metrics(
    const BlockCacheMetrics& metadata,
    const BlockCacheMetrics& playback) {
  BlockCacheMetrics combined;
  combined.fetched_bytes = metadata.fetched_bytes + playback.fetched_bytes;
  combined.requests = metadata.requests + playback.requests;
  combined.hits = metadata.hits + playback.hits;
  combined.peak_bytes = std::max(metadata.peak_bytes, playback.peak_bytes);
  combined.prefetch_requests =
      metadata.prefetch_requests + playback.prefetch_requests;
  combined.prefetched_bytes =
      metadata.prefetched_bytes + playback.prefetched_bytes;
  combined.prefetch_hits = metadata.prefetch_hits + playback.prefetch_hits;
  combined.playback_requests =
      metadata.playback_requests + playback.playback_requests;
  combined.stale_playback_cancellations =
      metadata.stale_playback_cancellations +
      playback.stale_playback_cancellations;
  combined.cancelled_prefetch_requests =
      metadata.cancelled_prefetch_requests +
      playback.cancelled_prefetch_requests;
  combined.cancelled_foreground_requests =
      metadata.cancelled_foreground_requests +
      playback.cancelled_foreground_requests;
  const bool playback_created = playback.cache_capacity_bytes != 0;
  combined.resident_bytes =
      playback_created ? playback.resident_bytes : metadata.resident_bytes;
  combined.cache_capacity_bytes = playback_created
                                      ? playback.cache_capacity_bytes
                                      : metadata.cache_capacity_bytes;
  combined.configured_prefetch_blocks =
      playback_created ? playback.configured_prefetch_blocks
                       : metadata.configured_prefetch_blocks;
  combined.foreground_fetch_bytes =
      metadata.foreground_fetch_bytes + playback.foreground_fetch_bytes;
  combined.prefetch_fetch_bytes =
      metadata.prefetch_fetch_bytes + playback.prefetch_fetch_bytes;
  combined.consumer_bytes_delivered =
      metadata.consumer_bytes_delivered + playback.consumer_bytes_delivered;
  combined.cache_miss_count =
      metadata.cache_miss_count + playback.cache_miss_count;
  combined.prefetch_unused_bytes =
      metadata.prefetch_unused_bytes + playback.prefetch_unused_bytes;
  combined.cancelled_foreground_bytes =
      metadata.cancelled_foreground_bytes +
      playback.cancelled_foreground_bytes;
  combined.cancelled_prefetch_bytes =
      metadata.cancelled_prefetch_bytes + playback.cancelled_prefetch_bytes;
  combined.eviction_count =
      metadata.eviction_count + playback.eviction_count;
  combined.refetch_count = metadata.refetch_count + playback.refetch_count;
  combined.prefetch_active_peak =
      std::max(metadata.prefetch_active_peak, playback.prefetch_active_peak);
  combined.prefetch_overlap_count =
      metadata.prefetch_overlap_count + playback.prefetch_overlap_count;
  combined.prefetch_pending_gap_us_total =
      metadata.prefetch_pending_gap_us_total +
      playback.prefetch_pending_gap_us_total;
  combined.prefetch_pending_gap_us_max =
      std::max(metadata.prefetch_pending_gap_us_max,
               playback.prefetch_pending_gap_us_max);
  combined.prefetch_in_flight_bytes_peak =
      std::max(metadata.prefetch_in_flight_bytes_peak,
               playback.prefetch_in_flight_bytes_peak);
  combined.prefetch_hit_bytes =
      metadata.prefetch_hit_bytes + playback.prefetch_hit_bytes;
  combined.prefetch_concurrent_wall_clock_us =
      metadata.prefetch_concurrent_wall_clock_us +
      playback.prefetch_concurrent_wall_clock_us;
  combined.refetch_count_available = metadata.refetch_count_available &&
                                     playback.refetch_count_available;
  return combined;
}

BlockCache::BlockCache(std::shared_ptr<BlockSource> source,
                       std::uint64_t block_size, std::size_t block_count,
                       std::size_t configuration_block_scale,
                       std::size_t initial_prefetch_batch_blocks,
                       std::size_t prefetch_batch_blocks)
    : source_(std::move(source)),
      block_size_(block_size),
      configuration_block_scale_(configuration_block_scale),
      initial_prefetch_batch_blocks_(initial_prefetch_batch_blocks),
      prefetch_batch_blocks_(prefetch_batch_blocks),
      block_count_(block_count * configuration_block_scale),
      max_read_ahead_blocks_(kMaximumPlaybackReadAheadBlocks *
                             configuration_block_scale) {
  if (!source_ || block_size_ == 0 || block_count == 0 ||
      configuration_block_scale_ == 0 || initial_prefetch_batch_blocks_ == 0 ||
      prefetch_batch_blocks_ == 0 ||
      block_count_ / configuration_block_scale_ != block_count) {
    throw std::invalid_argument("invalid block cache configuration");
  }
  prefetch_worker_ = std::thread([this] { prefetch_loop(); });
}

BlockCache::~BlockCache() { shutdown(); }

void BlockCache::shutdown() {
  {
    std::lock_guard lock(mutex_);
    if (stopping_) return;
    stopping_ = true;
    prefetch_pending_ = false;
    update_prefetch_pending_gap_locked(std::chrono::steady_clock::now());
    ++prefetch_generation_;
    ++active_playback_generation_;
    if (active_playback_generation_ == 0) ++active_playback_generation_;
    for (const auto& [index, entry] : entries_) {
      static_cast<void>(index);
      if (entry->loading) entry->cancelled.store(true);
    }
  }
  source_->cancel_pending();
  prefetch_ready_.notify_all();
  space_available_.notify_all();
  if (prefetch_worker_.joinable()) prefetch_worker_.join();
}

std::uint64_t BlockCache::begin_playback() {
  std::lock_guard transition_lock(playback_transition_mutex_);
  std::uint64_t generation = 0;
  {
    std::lock_guard lock(mutex_);
    ++active_playback_generation_;
    if (active_playback_generation_ == 0) ++active_playback_generation_;
    ++metrics_.playback_requests;
    prefetch_pending_ = false;
    prefetch_window_start_ = 0;
    prefetch_next_ = 0;
    prefetch_end_ = 0;
    ++prefetch_generation_;
    initial_prefetch_batch_ = true;
    update_prefetch_pending_gap_locked(std::chrono::steady_clock::now());
    for (auto iterator = entries_.begin(); iterator != entries_.end();) {
      const auto& entry = iterator->second;
      if (!entry->loading && entry->error) {
        entry->removed = true;
        lru_.erase(entry->lru_position);
        iterator = entries_.erase(iterator);
      } else {
        ++iterator;
      }
    }
    generation = active_playback_generation_;
  }
  source_->cancel_pending();
  space_available_.notify_all();
  return generation;
}

void BlockCache::reset_read_ahead() {
  std::lock_guard lock(mutex_);
  prefetch_pending_ = false;
  prefetch_window_start_ = 0;
  prefetch_next_ = 0;
  prefetch_end_ = 0;
  ++prefetch_generation_;
  initial_prefetch_batch_ = true;
  update_prefetch_pending_gap_locked(std::chrono::steady_clock::now());
}

void BlockCache::configure(std::size_t block_count,
                           std::size_t max_read_ahead_blocks,
                           bool protect_read_ahead) {
  if (block_count == 0 || max_read_ahead_blocks == 0) {
    throw std::invalid_argument("invalid block cache configuration");
  }
  if (block_count > std::numeric_limits<std::size_t>::max() /
                        configuration_block_scale_ ||
      max_read_ahead_blocks > std::numeric_limits<std::size_t>::max() /
                                  configuration_block_scale_) {
    throw std::invalid_argument("invalid block cache configuration");
  }
  std::lock_guard lock(mutex_);
  block_count_ = block_count * configuration_block_scale_;
  max_read_ahead_blocks_ =
      max_read_ahead_blocks * configuration_block_scale_;
  protect_read_ahead_ = protect_read_ahead && max_read_ahead_blocks < block_count;
  while (entries_.size() > block_count_ && evict_one_locked()) {
  }
  space_available_.notify_all();
}

bool BlockCache::is_playback_current(
    std::uint64_t playback_generation) const {
  std::lock_guard lock(mutex_);
  return playback_generation != 0 &&
         playback_generation == active_playback_generation_;
}

std::size_t BlockCache::limit_read_ahead(
    std::size_t requested_blocks) const {
  std::lock_guard lock(mutex_);
  if (requested_blocks > std::numeric_limits<std::size_t>::max() /
                             configuration_block_scale_) {
    return max_read_ahead_blocks_;
  }
  return std::min(requested_blocks * configuration_block_scale_,
                  max_read_ahead_blocks_);
}

std::size_t BlockCache::read(std::uint64_t offset, std::uint8_t* destination,
                             std::size_t length,
                             std::size_t read_ahead_blocks,
                             std::uint64_t playback_generation) {
  if (length == 0 || offset >= source_->size()) return 0;
  if (playback_generation != 0) {
    std::lock_guard lock(mutex_);
    if (playback_generation != active_playback_generation_) {
      ++metrics_.stale_playback_cancellations;
      return 0;
    }
  }
  const std::uint64_t available = source_->size() - offset;
  const std::size_t wanted = static_cast<std::size_t>(
      std::min<std::uint64_t>(available, static_cast<std::uint64_t>(length)));
  std::size_t copied = 0;
  while (copied < wanted) {
    if (playback_generation != 0 &&
        !is_playback_current(playback_generation)) {
      std::lock_guard lock(mutex_);
      ++metrics_.stale_playback_cancellations;
      return 0;
    }
    const std::uint64_t absolute = offset + copied;
    const std::uint64_t index = absolute / block_size_;
    const std::size_t within = static_cast<std::size_t>(absolute % block_size_);
    const auto entry = block(index, playback_generation);
    if (entry->cancelled) return 0;
    const auto& bytes = entry->bytes;
    if (within >= bytes.size()) break;
    const std::size_t chunk =
        std::min(wanted - copied, bytes.size() - within);
    std::memcpy(destination + copied, bytes.data() + within, chunk);
    copied += chunk;
  }
  if (copied > 0 && read_ahead_blocks > 0) {
    schedule_prefetch(offset + copied, read_ahead_blocks, playback_generation);
  }
  if (copied > 0) {
    std::lock_guard lock(mutex_);
    metrics_.consumer_bytes_delivered += copied;
  }
  return copied;
}

BlockCacheMetrics BlockCache::metrics() const {
  std::lock_guard lock(mutex_);
  auto snapshot = metrics_;
  const auto now = std::chrono::steady_clock::now();
  if (prefetch_pending_gap_started_.has_value()) {
    const auto gap = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            now - *prefetch_pending_gap_started_)
            .count());
    snapshot.prefetch_pending_gap_us_total += gap;
    snapshot.prefetch_pending_gap_us_max =
        std::max(snapshot.prefetch_pending_gap_us_max, gap);
  }
  if (prefetch_overlap_started_.has_value()) {
    snapshot.prefetch_concurrent_wall_clock_us +=
        static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now - *prefetch_overlap_started_)
                .count());
  }
  snapshot.resident_bytes = resident_bytes_;
  snapshot.cache_capacity_bytes = block_count_ * block_size_;
  snapshot.configured_prefetch_blocks =
      max_read_ahead_blocks_ / configuration_block_scale_;
  snapshot.refetch_count_available = refetch_count_available_;
  for (const auto& [index, entry] : entries_) {
    static_cast<void>(index);
    if (!entry->loading && !entry->cancelled && !entry->error &&
        entry->prefetched) {
      snapshot.prefetch_unused_bytes += entry->bytes.size();
    }
  }
  return snapshot;
}

BlockCacheHandoff BlockCache::take_handoff(
    std::uint64_t maximum_retained_bytes) {
  shutdown();
  std::lock_guard lock(mutex_);
  BlockCacheHandoff handoff;
  handoff.block_size = block_size_;
  handoff.fetched_block_indices = std::move(fetched_block_indices_);
  handoff.refetch_count_available = refetch_count_available_;
  for (const std::uint64_t index : lru_) {
    const auto found = entries_.find(index);
    if (found == entries_.end()) continue;
    const auto& entry = found->second;
    if (entry->loading || entry->cancelled || entry->error || entry->removed) {
      continue;
    }
    const std::uint64_t length = entry->bytes.size();
    if (length > maximum_retained_bytes - handoff.retained_bytes) continue;
    handoff.retained_bytes += length;
    handoff.blocks.push_back({index, std::move(entry->bytes)});
    if (handoff.retained_bytes == maximum_retained_bytes) break;
  }
  entries_.clear();
  lru_.clear();
  resident_bytes_ = 0;
  return handoff;
}

void BlockCache::restore_handoff(BlockCacheHandoff handoff) {
  if (handoff.block_size != block_size_) {
    throw std::invalid_argument("cache handoff block size mismatch");
  }
  std::uint64_t retained_bytes = 0;
  std::unordered_set<std::uint64_t> retained_indices;
  retained_indices.reserve(handoff.blocks.size());
  for (const auto& block : handoff.blocks) {
    if (!retained_indices.insert(block.index).second ||
        block.index > std::numeric_limits<std::uint64_t>::max() /
                          block_size_) {
      throw std::invalid_argument("invalid cache handoff");
    }
    const std::uint64_t start = block.index * block_size_;
    if (start >= source_->size()) {
      throw std::invalid_argument("invalid cache handoff");
    }
    const std::uint64_t expected =
        std::min(block_size_, source_->size() - start);
    if (block.bytes.size() != expected ||
        retained_bytes > std::numeric_limits<std::uint64_t>::max() -
                             block.bytes.size()) {
      throw std::invalid_argument("invalid cache handoff");
    }
    retained_bytes += block.bytes.size();
  }
  if (retained_bytes != handoff.retained_bytes ||
      handoff.blocks.size() > block_count_) {
    throw std::invalid_argument("invalid cache handoff");
  }

  std::lock_guard lock(mutex_);
  if (!entries_.empty() || resident_bytes_ != 0) {
    throw std::logic_error("cache handoff requires an empty cache");
  }
  fetched_block_indices_ = std::move(handoff.fetched_block_indices);
  refetch_count_available_ = handoff.refetch_count_available;
  for (auto iterator = handoff.blocks.rbegin();
       iterator != handoff.blocks.rend(); ++iterator) {
    auto entry = insert_entry_locked(iterator->index);
    if (!entry) throw std::logic_error("duplicate cache handoff block");
    entry->bytes = std::move(iterator->bytes);
    entry->loading = false;
    resident_bytes_ += entry->bytes.size();
  }
  metrics_.peak_bytes = std::max(metrics_.peak_bytes, resident_bytes_);
}

std::shared_ptr<BlockCache::Entry> BlockCache::block(std::uint64_t index,
                                                     std::uint64_t playback_generation,
                                                     bool prefetch) {
  std::shared_ptr<Entry> entry;
  {
    std::unique_lock lock(mutex_);
    while (true) {
      const auto existing = entries_.find(index);
      if (existing != entries_.end()) {
        entry = existing->second;
        while (entry->loading) entry->ready.wait(lock);
        if (entry->cancelled) continue;
        if (entry->error) std::rethrow_exception(entry->error);
        if (!prefetch) {
          ++metrics_.hits;
          if (entry->prefetched) {
            ++metrics_.prefetch_hits;
            metrics_.prefetch_hit_bytes += entry->bytes.size();
            entry->prefetched = false;
          }
          // The entry may have been evicted between loading=false and this
          // wakeup. Its lru node is gone, but its bytes were fully written
          // before eviction, so return them without relinking.
          if (!entry->removed) {
            touch_locked(index, entry);
          }
        }
        return entry;
      }
      if (entries_.size() < block_count_ || evict_one_locked()) {
        entry = insert_entry_locked(index);
        if (entry) break;
        continue;
      }
      space_available_.wait(lock);
    }
    ++metrics_.requests;
    if (prefetch) {
      ++metrics_.prefetch_requests;
    } else {
      ++metrics_.cache_miss_count;
    }
  }

  try {
    const std::uint64_t start = index * block_size_;
    const std::uint64_t end =
        std::min(source_->size() - 1, start + block_size_ - 1);
    auto bytes = source_->fetch(start, end, [this, playback_generation] {
      if (playback_generation == 0) return false;
      std::lock_guard lock(mutex_);
      return playback_generation != active_playback_generation_;
    });
    const std::size_t expected = static_cast<std::size_t>(end - start + 1);
    if (bytes.size() != expected) {
      throw std::runtime_error("block source returned an invalid length");
    }
    std::lock_guard lock(mutex_);
    entry->bytes = std::move(bytes);
    entry->prefetched = prefetch;
    entry->loading = false;
    resident_bytes_ += entry->bytes.size();
    metrics_.fetched_bytes += entry->bytes.size();
    if (prefetch) {
      metrics_.prefetched_bytes += entry->bytes.size();
      metrics_.prefetch_fetch_bytes += entry->bytes.size();
    } else {
      metrics_.foreground_fetch_bytes += entry->bytes.size();
    }
    if (refetch_count_available_) {
      try {
        if (!fetched_block_indices_.insert(index).second) {
          ++metrics_.refetch_count;
        }
      } catch (const std::bad_alloc&) {
        refetch_count_available_ = false;
        fetched_block_indices_.clear();
      }
    }
    metrics_.peak_bytes = std::max(metrics_.peak_bytes, resident_bytes_);
  } catch (...) {
    std::lock_guard lock(mutex_);
    const bool cancelled =
        playback_generation != 0 &&
        playback_generation != active_playback_generation_;
    if (cancelled) {
      ++metrics_.cancelled_foreground_requests;
      try {
        std::rethrow_exception(std::current_exception());
      } catch (const FetchCancelled& error) {
        metrics_.cancelled_foreground_bytes += error.received_bytes();
      } catch (...) {
      }
      const auto found = entries_.find(index);
      if (found != entries_.end() && found->second == entry &&
            !entry->removed) {
        entry->removed = true;
        lru_.erase(entry->lru_position);
        entries_.erase(found);
      }
      entry->cancelled = true;
    } else {
      entry->error = std::current_exception();
    }
    entry->loading = false;
  }
  {
    std::lock_guard lock(mutex_);
    entry->ready.notify_all();
    space_available_.notify_all();
  }
  if (entry->error) std::rethrow_exception(entry->error);
  return entry;
}

void BlockCache::schedule_prefetch(std::uint64_t next_offset,
                                   std::size_t block_count,
                                   std::uint64_t playback_generation) {
  if (block_count == 0 || next_offset >= source_->size()) return;
  const std::uint64_t total_blocks =
      source_->size() / block_size_ +
      (source_->size() % block_size_ == 0 ? 0ULL : 1ULL);
  const std::uint64_t start =
      next_offset / block_size_ +
      (next_offset % block_size_ == 0 ? 0ULL : 1ULL);
  if (start >= total_blocks) return;
  const std::uint64_t requested = static_cast<std::uint64_t>(block_count);
  const std::uint64_t end =
      requested > total_blocks - start ? total_blocks : start + requested;

  {
    std::lock_guard lock(mutex_);
    if (stopping_) return;
    if ((playback_generation == 0 && active_playback_generation_ != 0) ||
        (playback_generation != 0 &&
         playback_generation != active_playback_generation_)) {
      ++metrics_.stale_playback_cancellations;
      return;
    }
    bool replaced = false;
    if (start >= prefetch_window_start_ && start <= prefetch_end_) {
      if (protect_read_ahead_) prefetch_window_start_ = start;
      prefetch_next_ = std::max(prefetch_next_, start);
      prefetch_end_ = std::max(prefetch_end_, end);
    } else {
      prefetch_window_start_ = start;
      prefetch_next_ = start;
      prefetch_end_ = end;
      ++prefetch_generation_;
      initial_prefetch_batch_ = true;
      replaced = true;
    }
    const std::uint64_t queued = prefetch_end_ - prefetch_next_;
    const std::size_t refill_blocks = protect_read_ahead_
        ? std::min(prefetch_batch_blocks_, std::max<std::size_t>(1, block_count / 2))
        : prefetch_batch_blocks_;
    prefetch_pending_ =
        prefetch_next_ < prefetch_end_ &&
        (prefetch_pending_ || replaced ||
         queued >= refill_blocks ||
         prefetch_end_ == total_blocks);
    update_prefetch_pending_gap_locked(std::chrono::steady_clock::now());
  }
  prefetch_ready_.notify_one();
}

void BlockCache::prefetch_loop() {
  while (true) {
    std::vector<std::pair<std::uint64_t, std::shared_ptr<Entry>>> batch;
    std::uint64_t generation = 0;
    std::uint64_t fetch_start = 0;
    std::uint64_t fetch_end = 0;
    std::uint64_t in_flight_bytes = 0;
    {
      std::unique_lock lock(mutex_);
      prefetch_ready_.wait(lock,
                           [this] { return stopping_ || prefetch_pending_; });
      if (stopping_) return;
      // Select the batch inside one critical section: every wake from the
      // capacity wait recomputes the window against the current entries_, so
      // the build below can never race a foreground insertion.
      std::uint64_t batch_start = 0;
      std::size_t batch_count = 0;
      while (true) {
        while (prefetch_next_ < prefetch_end_ &&
               entries_.find(prefetch_next_) != entries_.end()) {
          ++prefetch_next_;
        }
        if (prefetch_next_ >= prefetch_end_) {
          batch_count = 0;
          break;
        }
        batch_start = prefetch_next_;
        const bool short_disc_window = protect_read_ahead_ &&
            prefetch_end_ - prefetch_window_start_ <= 2 * initial_prefetch_batch_blocks_;
        const std::size_t batch_blocks =
            (initial_prefetch_batch_ || short_disc_window)
                ? initial_prefetch_batch_blocks_ : prefetch_batch_blocks_;
        const std::uint64_t batch_limit = std::min<std::uint64_t>(
            prefetch_end_, batch_start + batch_blocks);
        batch_count = 0;
        while (batch_start + batch_count < batch_limit &&
               entries_.find(batch_start + batch_count) == entries_.end()) {
          ++batch_count;
        }
        if (entries_.size() + batch_count <= block_count_) break;
        if (evict_one_locked()) continue;
        space_available_.wait(lock);
        if (stopping_) return;
      }
      if (batch_count == 0) {
        prefetch_pending_ = false;
        update_prefetch_pending_gap_locked(std::chrono::steady_clock::now());
        continue;
      }

      batch.reserve(batch_count);
      for (std::size_t offset = 0; offset < batch_count; ++offset) {
        const std::uint64_t index = batch_start + offset;
        auto entry = insert_entry_locked(index);
        if (!entry) {
          // Unreachable while selection and the build share this critical
          // section; kept so a future edit cannot strand orphan entries or
          // ghost lru nodes.
          for (const auto& [done_index, done_entry] : batch) {
            done_entry->removed = true;
            lru_.erase(done_entry->lru_position);
            entries_.erase(done_index);
          }
          batch.clear();
          break;
        }
        batch.emplace_back(index, std::move(entry));
      }
      if (batch.empty()) continue;
      prefetch_next_ += batch_count;
      generation = prefetch_generation_;
      initial_prefetch_batch_ = false;
      prefetch_pending_ = prefetch_next_ < prefetch_end_;
      ++metrics_.requests;
      ++metrics_.prefetch_requests;
      fetch_start = batch.front().first * block_size_;
      const std::uint64_t last_start = batch.back().first * block_size_;
      const std::uint64_t last_length =
          std::min(block_size_, source_->size() - last_start);
      fetch_end = last_start + last_length - 1;
      in_flight_bytes = fetch_end - fetch_start + 1;
      record_prefetch_started_locked(in_flight_bytes,
                                     std::chrono::steady_clock::now());
    }

    try {
      auto bytes = source_->fetch(fetch_start, fetch_end, [this, generation] {
        std::lock_guard lock(mutex_);
        return stopping_ || generation != prefetch_generation_;
      });
      const std::size_t expected =
          static_cast<std::size_t>(fetch_end - fetch_start + 1);
      if (bytes.size() != expected) {
        throw std::runtime_error("block source returned an invalid length");
      }
      std::lock_guard lock(mutex_);
      if (generation != prefetch_generation_) {
        ++metrics_.cancelled_prefetch_requests;
        metrics_.cancelled_prefetch_bytes += bytes.size();
        for (const auto& [index, entry] : batch) {
          const auto found = entries_.find(index);
          if (found != entries_.end() && found->second == entry &&
                !entry->removed) {
            entry->removed = true;
            lru_.erase(entry->lru_position);
            entries_.erase(found);
          }
          entry->cancelled = true;
          entry->loading = false;
        }
      } else {
        std::size_t copied = 0;
        for (const auto& [index, entry] : batch) {
          const std::uint64_t block_start = index * block_size_;
          const std::size_t length = static_cast<std::size_t>(
              std::min(block_size_, source_->size() - block_start));
          entry->bytes.assign(bytes.begin() + copied,
                              bytes.begin() + copied + length);
          entry->prefetched = true;
          entry->loading = false;
          copied += length;
          resident_bytes_ += length;
        }
        metrics_.fetched_bytes += bytes.size();
        metrics_.prefetched_bytes += bytes.size();
        metrics_.prefetch_fetch_bytes += bytes.size();
        if (refetch_count_available_) {
          try {
            for (const auto& [index, entry] : batch) {
              static_cast<void>(entry);
              if (!fetched_block_indices_.insert(index).second) {
                ++metrics_.refetch_count;
              }
            }
          } catch (const std::bad_alloc&) {
            refetch_count_available_ = false;
            fetched_block_indices_.clear();
          }
        }
        metrics_.peak_bytes = std::max(metrics_.peak_bytes, resident_bytes_);
      }
    } catch (...) {
      std::lock_guard lock(mutex_);
      const bool cancelled = stopping_ || generation != prefetch_generation_;
      if (cancelled) {
        ++metrics_.cancelled_prefetch_requests;
        try {
          std::rethrow_exception(std::current_exception());
        } catch (const FetchCancelled& error) {
          metrics_.cancelled_prefetch_bytes += error.received_bytes();
        } catch (...) {
        }
      }
      const auto error = cancelled ? std::exception_ptr{}
                                   : std::current_exception();
      for (const auto& [index, entry] : batch) {
        if (cancelled) {
          const auto found = entries_.find(index);
          if (found != entries_.end() && found->second == entry &&
                !entry->removed) {
            entry->removed = true;
            lru_.erase(entry->lru_position);
            entries_.erase(found);
          }
          entry->cancelled = true;
        } else {
          entry->error = error;
        }
        entry->loading = false;
      }
      if (generation == prefetch_generation_) prefetch_pending_ = false;
    }
    {
      std::lock_guard lock(mutex_);
      record_prefetch_finished_locked(in_flight_bytes,
                                      std::chrono::steady_clock::now());
      for (const auto& [index, entry] : batch) {
        static_cast<void>(index);
        entry->ready.notify_all();
      }
      space_available_.notify_all();
    }
  }
}

void BlockCache::update_prefetch_pending_gap_locked(
    std::chrono::steady_clock::time_point now) {
  const bool gap_active =
      !stopping_ && prefetch_pending_ && active_prefetch_count_ == 0;
  if (gap_active) {
    if (!prefetch_pending_gap_started_.has_value()) {
      prefetch_pending_gap_started_ = now;
    }
    return;
  }
  if (!prefetch_pending_gap_started_.has_value()) return;
  const auto gap = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(
          now - *prefetch_pending_gap_started_)
          .count());
  metrics_.prefetch_pending_gap_us_total += gap;
  metrics_.prefetch_pending_gap_us_max =
      std::max(metrics_.prefetch_pending_gap_us_max, gap);
  prefetch_pending_gap_started_.reset();
}

void BlockCache::record_prefetch_started_locked(
    std::uint64_t bytes, std::chrono::steady_clock::time_point now) {
  update_prefetch_pending_gap_locked(now);
  if (active_prefetch_count_ == 1) {
    ++metrics_.prefetch_overlap_count;
    prefetch_overlap_started_ = now;
  }
  ++active_prefetch_count_;
  prefetch_in_flight_bytes_ += bytes;
  metrics_.prefetch_active_peak =
      std::max(metrics_.prefetch_active_peak, active_prefetch_count_);
  metrics_.prefetch_in_flight_bytes_peak = std::max(
      metrics_.prefetch_in_flight_bytes_peak, prefetch_in_flight_bytes_);
  update_prefetch_pending_gap_locked(now);
}

void BlockCache::record_prefetch_finished_locked(
    std::uint64_t bytes, std::chrono::steady_clock::time_point now) {
  if (active_prefetch_count_ >= 2 && prefetch_overlap_started_.has_value()) {
    metrics_.prefetch_concurrent_wall_clock_us +=
        static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                now - *prefetch_overlap_started_)
                .count());
    prefetch_overlap_started_.reset();
  }
  assert(active_prefetch_count_ > 0);
  assert(prefetch_in_flight_bytes_ >= bytes);
  --active_prefetch_count_;
  prefetch_in_flight_bytes_ -= bytes;
  update_prefetch_pending_gap_locked(now);
}

void BlockCache::touch_locked(std::uint64_t index,
                              const std::shared_ptr<Entry>& entry) {
  // Requires an entry that is still in entries_; an evicted entry's lru node
  // has already been freed by evict_one_locked().
  assert(!entry->removed);
  lru_.erase(entry->lru_position);
  lru_.push_front(index);
  entry->lru_position = lru_.begin();
}

bool BlockCache::evict_one_locked() {
  for (auto iterator = lru_.rbegin(); iterator != lru_.rend(); ++iterator) {
    const auto found = entries_.find(*iterator);
    if (found == entries_.end() || found->second->loading) continue;
    if (protect_read_ahead_ && found->first >= prefetch_window_start_ &&
        found->first < prefetch_end_) continue;
    if (found->second->prefetched) {
      metrics_.prefetch_unused_bytes += found->second->bytes.size();
    }
    found->second->removed = true;
    ++metrics_.eviction_count;
    resident_bytes_ -= found->second->bytes.size();
    const auto forward = std::next(iterator).base();
    lru_.erase(forward);
    entries_.erase(found);
    return true;
  }
  return false;
}

std::shared_ptr<BlockCache::Entry> BlockCache::insert_entry_locked(
    std::uint64_t index) {
  auto entry = std::make_shared<Entry>();
  const auto inserted = entries_.emplace(index, entry);
  if (!inserted.second) return nullptr;
  try {
    lru_.push_front(index);
  } catch (...) {
    entries_.erase(inserted.first);
    throw;
  }
  entry->lru_position = lru_.begin();
  return entry;
}

}  // namespace streampath::iso_bridge
