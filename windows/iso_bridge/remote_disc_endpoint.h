#pragma once

#include "remote_disc_provider.h"

namespace streampath::iso_bridge {

struct RemoteDiscRequest {
  int status = 400;
  std::uint64_t start = 0;
  std::uint64_t end = 0;
  std::uint64_t generation = 0;
  bool media = false;
};

// headers 不含请求行；GET 必须携带闭区间、代际和读取阶段。
RemoteDiscRequest parse_remote_disc_request(
    std::string_view headers, const RemoteDiscProvider& provider);

}  // namespace streampath::iso_bridge
