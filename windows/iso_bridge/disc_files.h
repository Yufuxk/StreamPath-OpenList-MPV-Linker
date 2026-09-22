#pragma once

#include "bridge_core.h"
#include <algorithm>
#include <map>

namespace streampath::iso_bridge {

struct DiscFile {
  std::string path;
  std::string url;
  std::uint64_t size = 0;
  std::uint64_t base = 0;
  bool directory = false;
  std::string etag;
  std::string last_modified;
};

// 会话内固定映射；文件间保留空隙，防止 EOF 与下一个文件混同。
class DiscFiles {
 public:
  std::vector<DiscFile> entries;
  std::uint64_t bytes = 0;
  std::uint64_t address_size = 0;

  void add(std::string path, std::string url, std::uint64_t size, bool directory, std::string etag = {}, std::string modified = {}) {
    if (entries.size() >= 32768 || path.empty() || path.size() > 4096 ||
        path.front() == '/' || path.back() == '/' ||
        path.find_first_of("\\:") != std::string::npos || size > INT64_MAX / 2)
      throw std::invalid_argument("Invalid BDMV entry");
    std::size_t begin = 0;
    while (begin < path.size()) {
      const auto end = path.find('/', begin);
      const auto part = path.substr(begin, end - begin);
      if (part.empty() || part == "." || part == ".." || part.size() > 255 ||
          part.find_first_of("<>\"|?*\r\n\t") != std::string::npos ||
          part.back() == '.' || part.back() == ' ')
        throw std::invalid_argument("Invalid BDMV path component");
      if (end == std::string::npos) break;
      begin = end + 1;
    }
    const auto key = fold(path);
    if (indices_.count(key)) throw std::invalid_argument("Duplicate BDMV path");
    const auto parent = path.find_last_of('/');
    if (parent != std::string::npos) {
      const auto* folder = find(path.substr(0, parent));
      if (!folder || !folder->directory)
        throw std::invalid_argument("Missing BDMV parent");
    } else if (key != "bdmv" && key != "certificate") {
      throw std::invalid_argument("Invalid BDMV root");
    }
    if (address_size > static_cast<std::uint64_t>(INT64_MAX) - size - 2 * kIsoDemandBlockSize)
      throw std::invalid_argument("BDMV size overflow");
    indices_.emplace(key, entries.size());
    entries.push_back({std::move(path), std::move(url), size, address_size, directory, std::move(etag), std::move(modified)});
    if (!directory) {
      bytes += size;
      address_size += ((size + kIsoDemandBlockSize - 1) / kIsoDemandBlockSize + 1) * kIsoDemandBlockSize;
    }
  }
  const DiscFile* find(std::string path) const {
    std::replace(path.begin(), path.end(), '\\', '/');
    const auto found = indices_.find(fold(path));
    return found == indices_.end() ? nullptr : &entries[found->second];
  }
  const DiscFile* at(std::uint64_t offset) const {
    const auto it = std::upper_bound(entries.begin(), entries.end(), offset,
        [](std::uint64_t value, const DiscFile& file) { return value < file.base; });
    if (it == entries.begin()) return nullptr;
    const auto& file = *std::prev(it);
    return !file.directory && offset - file.base < file.size ? &file : nullptr;
  }
  std::vector<const DiscFile*> children(const std::string& path) const {
    std::vector<const DiscFile*> result;
    const auto prefix = path.empty() ? "" : fold(path) + '/';
    for (const auto& entry : entries) {
      const auto name = fold(entry.path);
      if (name.compare(0, prefix.size(), prefix) == 0 &&
          name.find('/', prefix.size()) == std::string::npos)
        result.push_back(&entry);
    }
    return result;
  }
 private:
  static std::string fold(std::string path) {
    std::replace(path.begin(), path.end(), '\\', '/');
    for (auto& c : path) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return path;
  }
  std::map<std::string, std::size_t> indices_;
};
}  // namespace streampath::iso_bridge
