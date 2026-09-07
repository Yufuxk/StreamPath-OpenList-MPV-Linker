#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "iso_structure_cache.h"

#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <cwctype>
#include <fstream>
#include <limits>
#include <system_error>
#include <type_traits>
#include <unordered_set>
#include <utility>

namespace streampath::iso_bridge {
namespace {

constexpr std::array<std::uint8_t, 8> kMagic = {
    'S', 'P', 'I', 'S', 'O', 'C', '0', '1'};
constexpr std::size_t kDigestBytes = 32;
constexpr std::size_t kMinimumCacheBytes =
    kMagic.size() + sizeof(std::uint32_t) * 3U + sizeof(std::uint64_t) + 8U +
    kDigestBytes * 2U;

using Digest = std::array<std::uint8_t, kDigestBytes>;

class AlgorithmHandle final {
 public:
  ~AlgorithmHandle() {
    if (value_ != nullptr) BCryptCloseAlgorithmProvider(value_, 0);
  }
  BCRYPT_ALG_HANDLE* put() { return &value_; }
  BCRYPT_ALG_HANDLE get() const { return value_; }

 private:
  BCRYPT_ALG_HANDLE value_ = nullptr;
};

class HashHandle final {
 public:
  ~HashHandle() {
    if (value_ != nullptr) BCryptDestroyHash(value_);
  }
  BCRYPT_HASH_HANDLE* put() { return &value_; }
  BCRYPT_HASH_HANDLE get() const { return value_; }

 private:
  BCRYPT_HASH_HANDLE value_ = nullptr;
};

std::optional<Digest> sha256(const std::uint8_t* data,
                             std::size_t length) noexcept {
  if (length > static_cast<std::size_t>(std::numeric_limits<ULONG>::max())) {
    return std::nullopt;
  }
  AlgorithmHandle algorithm;
  if (BCryptOpenAlgorithmProvider(algorithm.put(), BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0) {
    return std::nullopt;
  }
  ULONG object_length = 0;
  ULONG copied = 0;
  if (BCryptGetProperty(algorithm.get(), BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_length),
                        sizeof(object_length), &copied, 0) < 0 ||
      copied != sizeof(object_length) || object_length == 0) {
    return std::nullopt;
  }
  std::vector<std::uint8_t> object(object_length);
  HashHandle hash;
  if (BCryptCreateHash(algorithm.get(), hash.put(), object.data(),
                       object_length, nullptr, 0, 0) < 0) {
    return std::nullopt;
  }
  if (length > 0 &&
      BCryptHashData(hash.get(), const_cast<PUCHAR>(data),
                     static_cast<ULONG>(length), 0) < 0) {
    return std::nullopt;
  }
  Digest result{};
  if (BCryptFinishHash(hash.get(), result.data(),
                       static_cast<ULONG>(result.size()), 0) < 0) {
    return std::nullopt;
  }
  return result;
}

template <typename Value>
void append_unsigned(std::vector<std::uint8_t>& output, Value value) {
  static_assert(std::is_unsigned_v<Value>);
  for (std::size_t index = 0; index < sizeof(Value); ++index) {
    output.push_back(static_cast<std::uint8_t>(value >> (index * 8U)));
  }
}

void append_bytes(std::vector<std::uint8_t>& output, const std::uint8_t* data,
                  std::size_t length) {
  output.insert(output.end(), data, data + length);
}

bool valid_utf8(std::string_view value) {
  std::size_t index = 0;
  while (index < value.size()) {
    const auto first = static_cast<std::uint8_t>(value[index]);
    std::uint32_t code_point = 0;
    std::size_t continuation = 0;
    if (first <= 0x7fU) {
      code_point = first;
    } else if ((first & 0xe0U) == 0xc0U) {
      code_point = first & 0x1fU;
      continuation = 1;
    } else if ((first & 0xf0U) == 0xe0U) {
      code_point = first & 0x0fU;
      continuation = 2;
    } else if ((first & 0xf8U) == 0xf0U) {
      code_point = first & 0x07U;
      continuation = 3;
    } else {
      return false;
    }
    if (continuation > value.size() - index - 1U) return false;
    for (std::size_t offset = 1; offset <= continuation; ++offset) {
      const auto byte = static_cast<std::uint8_t>(value[index + offset]);
      if ((byte & 0xc0U) != 0x80U) return false;
      code_point = (code_point << 6U) | (byte & 0x3fU);
    }
    if ((continuation == 1 && code_point < 0x80U) ||
        (continuation == 2 && code_point < 0x800U) ||
        (continuation == 3 && code_point < 0x10000U) ||
        code_point > 0x10ffffU ||
        (code_point >= 0xd800U && code_point <= 0xdfffU)) {
      return false;
    }
    index += continuation + 1U;
  }
  return true;
}

bool valid_identity(const StructureCacheIdentity& identity) {
  return identity.content_length > 0 &&
         (identity.validator_kind ==
              StructureCacheValidatorKind::strong_etag ||
          identity.validator_kind ==
              StructureCacheValidatorKind::last_modified);
}

bool valid_titles(const std::vector<TitleInfo>& titles) {
  if (titles.empty() || titles.size() > kMaximumStructureCacheTitles) {
    return false;
  }
  std::uint64_t chapter_total = 0;
  std::uint64_t clip_total = 0;
  std::unordered_set<std::uint32_t> playlists;
  std::optional<std::uint32_t> previous_title_index;
  for (const auto& title : titles) {
    if (title.playlist > 99999U || title.duration_milliseconds == 0 ||
        title.size == 0 || !playlists.insert(title.playlist).second ||
        (previous_title_index.has_value() &&
         title.title_index <= *previous_title_index)) {
      return false;
    }
    previous_title_index = title.title_index;
    if (title.chapters.size() > kMaximumStructureCacheChapters ||
        title.clips.size() > kMaximumStructureCacheClips) {
      return false;
    }
    chapter_total += static_cast<std::uint64_t>(title.chapters.size());
    clip_total += static_cast<std::uint64_t>(title.clips.size());
    if (chapter_total > kMaximumStructureCacheChapters ||
        clip_total > kMaximumStructureCacheClips || title.clips.empty()) {
      return false;
    }
    for (const auto& chapter : title.chapters) {
      const std::uint64_t tolerance =
          std::min<std::uint64_t>(title.duration_milliseconds, 1000U);
      const std::uint64_t maximum_end =
          title.duration_milliseconds >
                  std::numeric_limits<std::uint64_t>::max() - tolerance
              ? std::numeric_limits<std::uint64_t>::max()
              : title.duration_milliseconds + tolerance;
      if (chapter.name.size() > kMaximumStructureCacheNameBytes ||
          !valid_utf8(chapter.name) ||
          chapter.start_milliseconds > title.duration_milliseconds ||
          chapter.duration_milliseconds > title.duration_milliseconds ||
          chapter.start_milliseconds >
              std::numeric_limits<std::uint64_t>::max() -
                  chapter.duration_milliseconds ||
          chapter.start_milliseconds + chapter.duration_milliseconds >
              maximum_end) {
        return false;
      }
    }
    std::uint64_t next_begin = 0;
    for (const auto& clip : title.clips) {
      if (clip.begin_byte != next_begin || clip.end_byte <= clip.begin_byte ||
          clip.begin_byte % kM2tsPacketSize != 0 ||
          clip.end_byte % kM2tsPacketSize != 0) {
        return false;
      }
      next_begin = clip.end_byte;
    }
    if (next_begin != title.size) return false;
  }
  return true;
}

class Reader final {
 public:
  Reader(const std::vector<std::uint8_t>& data, std::size_t limit)
      : data_(data), limit_(limit) {}

  template <typename Value>
  bool read_unsigned(Value& result) {
    static_assert(std::is_unsigned_v<Value>);
    if (sizeof(Value) > limit_ - position_) return false;
    result = 0;
    for (std::size_t index = 0; index < sizeof(Value); ++index) {
      result |= static_cast<Value>(data_[position_ + index]) << (index * 8U);
    }
    position_ += sizeof(Value);
    return true;
  }

  bool read_bytes(std::uint8_t* destination, std::size_t length) {
    if (length > limit_ - position_) return false;
    std::copy_n(data_.data() + position_, length, destination);
    position_ += length;
    return true;
  }

  bool read_string(std::string& result, std::size_t length) {
    if (length > limit_ - position_) return false;
    result.assign(reinterpret_cast<const char*>(data_.data() + position_),
                  length);
    position_ += length;
    return true;
  }

  std::size_t position() const { return position_; }

 private:
  const std::vector<std::uint8_t>& data_;
  std::size_t limit_ = 0;
  std::size_t position_ = 0;
};

std::optional<std::vector<std::uint8_t>> read_cache_file(
    const std::filesystem::path& path) {
  std::error_code error;
  const auto size = std::filesystem::file_size(path, error);
  if (error || size < kMinimumCacheBytes ||
      size > kMaximumStructureCacheBytes ||
      size > static_cast<std::uint64_t>(
                 std::numeric_limits<std::streamsize>::max())) {
    return std::nullopt;
  }
  std::ifstream input(path, std::ios::binary);
  if (!input) return std::nullopt;
  std::vector<std::uint8_t> data(static_cast<std::size_t>(size));
  input.read(reinterpret_cast<char*>(data.data()),
             static_cast<std::streamsize>(data.size()));
  if (!input || input.peek() != std::char_traits<char>::eof()) {
    return std::nullopt;
  }
  return data;
}

bool write_atomic(const std::filesystem::path& path,
                  const std::vector<std::uint8_t>& data) {
  std::error_code error;
  std::filesystem::create_directories(path.parent_path(), error);
  if (error) return false;
  const std::filesystem::path temporary =
      path.wstring() + L".tmp." + std::to_wstring(GetCurrentProcessId());
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  bool succeeded = true;
  std::size_t written_total = 0;
  while (written_total < data.size()) {
    const std::size_t remaining = data.size() - written_total;
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        remaining, std::numeric_limits<DWORD>::max()));
    DWORD written = 0;
    if (WriteFile(file, data.data() + written_total, requested, &written,
                  nullptr) == FALSE ||
        written == 0) {
      succeeded = false;
      break;
    }
    written_total += written;
  }
  if (succeeded && FlushFileBuffers(file) == FALSE) succeeded = false;
  if (CloseHandle(file) == FALSE) succeeded = false;
  if (succeeded &&
      MoveFileExW(temporary.c_str(), path.c_str(),
                  MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) !=
          FALSE) {
    return true;
  }
  DeleteFileW(temporary.c_str());
  return false;
}

}  // namespace

std::optional<StructureCacheIdentity> make_structure_cache_identity(
    std::uint64_t content_length, StructureCacheValidatorKind validator_kind,
    std::wstring_view validator) noexcept {
  if (content_length == 0 || validator.empty() ||
      validator.size() >
          std::numeric_limits<std::size_t>::max() / sizeof(wchar_t)) {
    return std::nullopt;
  }
  const auto* bytes = reinterpret_cast<const std::uint8_t*>(validator.data());
  const auto digest = sha256(bytes, validator.size() * sizeof(wchar_t));
  if (!digest.has_value()) return std::nullopt;
  StructureCacheIdentity identity;
  identity.content_length = content_length;
  identity.validator_kind = validator_kind;
  identity.validator_digest = *digest;
  if (!valid_identity(identity)) return std::nullopt;
  return identity;
}

bool is_valid_structure_cache_path(
    const std::filesystem::path& path) noexcept {
  try {
    if (!path.is_absolute() || path.lexically_normal() != path) return false;
    std::wstring parent = path.parent_path().filename().wstring();
    std::transform(parent.begin(), parent.end(), parent.begin(),
                   [](wchar_t value) {
                     return static_cast<wchar_t>(std::towlower(value));
                   });
    if (parent != L"iso_structure" || path.extension() != L".cache") {
      return false;
    }
    const std::wstring stem = path.stem().wstring();
    return stem.size() == 64U &&
           std::all_of(stem.begin(), stem.end(), [](wchar_t value) {
             return (value >= L'0' && value <= L'9') ||
                    (value >= L'a' && value <= L'f');
           });
  } catch (...) {
    return false;
  }
}

std::optional<std::vector<TitleInfo>> load_structure_cache(
    const std::filesystem::path& path,
    const StructureCacheIdentity& identity) noexcept {
  try {
    if (!is_valid_structure_cache_path(path) || !valid_identity(identity)) {
      return std::nullopt;
    }
    const auto file = read_cache_file(path);
    if (!file.has_value()) return std::nullopt;
    const std::size_t payload_size = file->size() - kDigestBytes;
    const auto digest = sha256(file->data(), payload_size);
    if (!digest.has_value() ||
        !std::equal(digest->begin(), digest->end(),
                    file->begin() + static_cast<std::ptrdiff_t>(payload_size))) {
      return std::nullopt;
    }
    Reader reader(*file, payload_size);
    std::array<std::uint8_t, kMagic.size()> magic{};
    std::uint32_t schema = 0;
    std::uint32_t libbluray_version = 0;
    std::uint64_t content_length = 0;
    std::uint8_t validator_kind = 0;
    std::array<std::uint8_t, 7> reserved{};
    Digest validator_digest{};
    std::uint32_t title_count = 0;
    if (!reader.read_bytes(magic.data(), magic.size()) || magic != kMagic ||
        !reader.read_unsigned(schema) ||
        schema != kIsoStructureCacheSchemaVersion ||
        !reader.read_unsigned(libbluray_version) ||
        libbluray_version != kLibblurayStructureVersion ||
        !reader.read_unsigned(content_length) ||
        content_length != identity.content_length ||
        !reader.read_unsigned(validator_kind) ||
        validator_kind != static_cast<std::uint8_t>(identity.validator_kind) ||
        !reader.read_bytes(reserved.data(), reserved.size()) ||
        std::any_of(reserved.begin(), reserved.end(),
                    [](std::uint8_t value) { return value != 0; }) ||
        !reader.read_bytes(validator_digest.data(), validator_digest.size()) ||
        validator_digest != identity.validator_digest ||
        !reader.read_unsigned(title_count) || title_count == 0 ||
        title_count > kMaximumStructureCacheTitles) {
      return std::nullopt;
    }

    std::vector<TitleInfo> titles;
    titles.reserve(title_count);
    std::uint64_t chapter_total = 0;
    std::uint64_t clip_total = 0;
    for (std::uint32_t title_index = 0; title_index < title_count;
         ++title_index) {
      TitleInfo title;
      std::uint32_t chapter_count = 0;
      std::uint32_t clip_count = 0;
      if (!reader.read_unsigned(title.title_index) ||
          !reader.read_unsigned(title.playlist) ||
          !reader.read_unsigned(title.duration_milliseconds) ||
          !reader.read_unsigned(title.size) ||
          !reader.read_unsigned(chapter_count) ||
          !reader.read_unsigned(clip_count)) {
        return std::nullopt;
      }
      chapter_total += chapter_count;
      clip_total += clip_count;
      if (chapter_total > kMaximumStructureCacheChapters ||
          clip_total > kMaximumStructureCacheClips) {
        return std::nullopt;
      }
      title.chapters.reserve(chapter_count);
      for (std::uint32_t chapter_index = 0; chapter_index < chapter_count;
           ++chapter_index) {
        ChapterInfo chapter;
        std::uint32_t name_length = 0;
        if (!reader.read_unsigned(chapter.start_milliseconds) ||
            !reader.read_unsigned(chapter.duration_milliseconds) ||
            !reader.read_unsigned(name_length) ||
            name_length > kMaximumStructureCacheNameBytes ||
            !reader.read_string(chapter.name, name_length)) {
          return std::nullopt;
        }
        title.chapters.push_back(std::move(chapter));
      }
      title.clips.reserve(clip_count);
      for (std::uint32_t clip_index = 0; clip_index < clip_count; ++clip_index) {
        M2tsClipTimeline clip;
        std::uint64_t timestamp_offset = 0;
        if (!reader.read_unsigned(clip.begin_byte) ||
            !reader.read_unsigned(clip.end_byte) ||
            !reader.read_unsigned(timestamp_offset)) {
          return std::nullopt;
        }
        clip.timestamp_offset_90khz =
            static_cast<std::int64_t>(timestamp_offset);
        title.clips.push_back(clip);
      }
      titles.push_back(std::move(title));
    }
    if (reader.position() != payload_size || !valid_titles(titles)) {
      return std::nullopt;
    }
    return titles;
  } catch (...) {
    return std::nullopt;
  }
}

bool write_structure_cache(const std::filesystem::path& path,
                           const StructureCacheIdentity& identity,
                           const std::vector<TitleInfo>& titles) noexcept {
  try {
    if (!is_valid_structure_cache_path(path) || !valid_identity(identity) ||
        !valid_titles(titles)) {
      return false;
    }
    std::vector<std::uint8_t> output;
    output.reserve(4096);
    append_bytes(output, kMagic.data(), kMagic.size());
    append_unsigned(output, kIsoStructureCacheSchemaVersion);
    append_unsigned(output, kLibblurayStructureVersion);
    append_unsigned(output, identity.content_length);
    append_unsigned(output, static_cast<std::uint8_t>(identity.validator_kind));
    for (std::size_t index = 0; index < 7U; ++index) {
      append_unsigned(output, static_cast<std::uint8_t>(0));
    }
    append_bytes(output, identity.validator_digest.data(),
                 identity.validator_digest.size());
    append_unsigned(output, static_cast<std::uint32_t>(titles.size()));
    for (const auto& title : titles) {
      append_unsigned(output, title.title_index);
      append_unsigned(output, title.playlist);
      append_unsigned(output, title.duration_milliseconds);
      append_unsigned(output, title.size);
      append_unsigned(output, static_cast<std::uint32_t>(title.chapters.size()));
      append_unsigned(output, static_cast<std::uint32_t>(title.clips.size()));
      for (const auto& chapter : title.chapters) {
        append_unsigned(output, chapter.start_milliseconds);
        append_unsigned(output, chapter.duration_milliseconds);
        append_unsigned(output,
                        static_cast<std::uint32_t>(chapter.name.size()));
        append_bytes(
            output, reinterpret_cast<const std::uint8_t*>(chapter.name.data()),
            chapter.name.size());
      }
      for (const auto& clip : title.clips) {
        append_unsigned(output, clip.begin_byte);
        append_unsigned(output, clip.end_byte);
        append_unsigned(
            output, static_cast<std::uint64_t>(clip.timestamp_offset_90khz));
      }
      if (output.size() > kMaximumStructureCacheBytes - kDigestBytes) {
        return false;
      }
    }
    const auto digest = sha256(output.data(), output.size());
    if (!digest.has_value()) return false;
    append_bytes(output, digest->data(), digest->size());
    return write_atomic(path, output);
  } catch (...) {
    return false;
  }
}

}  // namespace streampath::iso_bridge
