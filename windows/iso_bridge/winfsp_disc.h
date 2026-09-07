#pragma once

#include "bridge_core.h"
#include <filesystem>
#include <memory>

namespace streampath::iso_bridge {

// 单文件只读出口；WinFsp 只在创建挂载时加载。
class WinFspDisc {
 public:
  WinFspDisc(BlockCache& cache, std::uint64_t size,
             const std::filesystem::path& mount_path, bool prefetch = false);
  ~WinFspDisc();
  WinFspDisc(const WinFspDisc&) = delete;
  WinFspDisc& operator=(const WinFspDisc&) = delete;
  void stop();
  void configure_read_ahead(unsigned seconds);
  std::string metrics_json() const;
  bool failed() const;
  static bool available();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace streampath::iso_bridge
