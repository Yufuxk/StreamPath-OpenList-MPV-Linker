#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "bridge_core.h"

namespace streampath::iso_bridge {

constexpr std::uint32_t kIsoStructureCacheSchemaVersion = 1;
constexpr std::uint32_t kLibblurayStructureVersion = 0x00010501U;
constexpr std::uint32_t kMaximumStructureCacheTitles = 4096;
constexpr std::uint32_t kMaximumStructureCacheChapters = 65536;
constexpr std::uint32_t kMaximumStructureCacheClips = 65536;
constexpr std::uint32_t kMaximumStructureCacheNameBytes = 4096;
constexpr std::uint64_t kMaximumStructureCacheBytes = 16ULL * 1024ULL * 1024ULL;

enum class StructureCacheValidatorKind : std::uint8_t {
  strong_etag = 1,
  last_modified = 2,
};

struct ChapterInfo {
  std::uint64_t start_milliseconds = 0;
  std::uint64_t duration_milliseconds = 0;
  std::string name;
};

struct TitleInfo {
  std::uint32_t title_index = 0;
  std::uint32_t playlist = 0;
  std::uint64_t duration_milliseconds = 0;
  std::uint64_t size = 0;
  std::vector<ChapterInfo> chapters;
  std::vector<M2tsClipTimeline> clips;
};

struct StructureCacheIdentity {
  std::uint64_t content_length = 0;
  StructureCacheValidatorKind validator_kind =
      StructureCacheValidatorKind::strong_etag;
  std::array<std::uint8_t, 32> validator_digest{};
};

std::optional<StructureCacheIdentity> make_structure_cache_identity(
    std::uint64_t content_length, StructureCacheValidatorKind validator_kind,
    std::wstring_view validator) noexcept;

bool is_valid_structure_cache_path(
    const std::filesystem::path& path) noexcept;

std::optional<std::vector<TitleInfo>> load_structure_cache(
    const std::filesystem::path& path,
    const StructureCacheIdentity& identity) noexcept;

bool write_structure_cache(const std::filesystem::path& path,
                           const StructureCacheIdentity& identity,
                           const std::vector<TitleInfo>& titles) noexcept;

}  // namespace streampath::iso_bridge
