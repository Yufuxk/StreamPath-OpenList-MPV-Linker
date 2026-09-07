#pragma once

#include "bridge_core.h"

namespace streampath::iso_bridge {

// 完整光盘的读取仅在菜单会话内启用，沿用共享缓存与代际取消。
class RemoteDiscProvider final {
 public:
  static constexpr std::uint64_t kSectorBytes = 2048;
  static constexpr std::uint64_t kMaximumReadBytes = kIsoBlockSize;

  RemoteDiscProvider(BlockCache& cache, std::uint64_t size);
  std::uint64_t size() const { return size_; }
  bool valid_range(std::uint64_t start, std::uint64_t end) const;
  std::uint64_t activate(std::uint64_t generation);
  std::size_t read(std::uint64_t start, std::uint8_t* destination,
                   std::size_t length, bool media,
                   std::uint64_t cache_generation);
  std::uint64_t cancelled_generations() const;

 private:
  BlockCache& cache_;
  const std::uint64_t size_;
  mutable std::mutex mutex_;
  std::uint64_t generation_ = 0;
  std::uint64_t cache_generation_ = 0;
  std::uint64_t cancelled_generations_ = 0;
};

}  // namespace streampath::iso_bridge
