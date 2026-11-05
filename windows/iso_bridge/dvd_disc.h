#pragma once

#include "iso_structure_cache.h"

#include <memory>
#include <stdexcept>

namespace streampath::iso_bridge {

class DvdError final : public std::runtime_error {
 public:
  DvdError(std::string code, std::string message)
      : std::runtime_error(std::move(message)), code(std::move(code)) {}
  const std::string code;
};

// DVD 标题以固定的逻辑扇区顺序提供随机读取，所有状态归本次 Bridge 会话所有。
class DvdDisc final {
 public:
  explicit DvdDisc(BlockCache& cache);
  ~DvdDisc();
  DvdDisc(const DvdDisc&) = delete;
  DvdDisc& operator=(const DvdDisc&) = delete;
  bool detected() const;
  std::vector<TitleInfo> enumerate();
  const std::vector<std::uint32_t>& unavailable_titles() const;
  void bind(BlockCache& cache, std::uint64_t generation, std::size_t read_ahead);
  std::size_t read(std::uint32_t title, std::uint64_t offset,
                   std::uint8_t* bytes, std::size_t length);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

void normalize_dvd_sector(std::uint8_t* bytes, std::int64_t offset_90k,
                          std::uint32_t vobu_start_90k = 0);

}  // namespace streampath::iso_bridge
