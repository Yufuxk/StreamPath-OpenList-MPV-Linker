#include "remote_disc_endpoint.h"

#include <algorithm>
#include <charconv>
#include <cctype>

namespace streampath::iso_bridge {

RemoteDiscRequest parse_remote_disc_request(
    std::string_view headers, const RemoteDiscProvider& provider) {
  RemoteDiscRequest result;
  bool has_range = false;
  bool has_generation = false;
  bool has_phase = false;
  while (!headers.empty()) {
    const auto end = headers.find("\r\n");
    if (end == std::string_view::npos) return result;
    const auto line = headers.substr(0, end);
    headers.remove_prefix(end + 2);
    if (line.empty()) break;
    const auto colon = line.find(':');
    if (colon == std::string_view::npos) return result;
    std::string name(line.substr(0, colon));
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char ch) {
      return static_cast<char>(std::tolower(ch));
    });
    auto value = line.substr(colon + 1);
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) {
      value.remove_prefix(1);
    }
    if (name == "range") {
      if (has_range) return result;
      has_range = true;
      const auto dash = value.find('-');
      if (value.rfind("bytes=", 0) != 0 || dash <= 6 ||
          dash == std::string_view::npos || dash + 1 == value.size()) {
        result.status = 416;
        return result;
      }
      const auto range = parse_byte_range(value, provider.size());
      std::uint64_t requested_end = 0;
      const auto parsed_end = std::from_chars(value.data() + dash + 1,
          value.data() + value.size(), requested_end);
      if (range.status != ByteRangeStatus::ok ||
          parsed_end.ec != std::errc{} ||
          parsed_end.ptr != value.data() + value.size() ||
          requested_end >= provider.size() ||
          !provider.valid_range(range.start, range.end)) {
        result.status = 416;
        return result;
      }
      result.start = range.start;
      result.end = range.end;
    } else if (name == "x-streampath-generation") {
      if (has_generation) return result;
      has_generation = true;
      const auto parsed = std::from_chars(value.data(), value.data() + value.size(),
                                           result.generation);
      if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() ||
          result.generation == 0) return result;
    } else if (name == "x-streampath-phase") {
      if (has_phase || (value != "metadata" && value != "media")) return result;
      has_phase = true;
      result.media = value == "media";
    } else if (name == "accept-encoding" && value != "identity") {
      return result;
    } else if (name == "transfer-encoding" || name == "content-length") {
      return result;
    }
  }
  if (has_range && has_generation && has_phase) result.status = 206;
  return result;
}

}  // namespace streampath::iso_bridge
