#include "remote_disc_provider.h"

namespace streampath::iso_bridge {

RemoteDiscProvider::RemoteDiscProvider(BlockCache& cache, std::uint64_t size)
    : cache_(cache), size_(size) {
  if (size == 0 || size % kSectorBytes != 0) {
    throw std::invalid_argument("Invalid disc sector length");
  }
}

bool RemoteDiscProvider::valid_range(std::uint64_t start,
                                     std::uint64_t end) const {
  return start <= end && end < size_ && start % kSectorBytes == 0 &&
         (end - start + 1) % kSectorBytes == 0 &&
         end - start + 1 <= kMaximumReadBytes;
}

std::uint64_t RemoteDiscProvider::activate(std::uint64_t generation) {
  std::lock_guard lock(mutex_);
  if (generation == 0 || generation < generation_) {
    throw FetchCancelled(generation);
  }
  if (generation > generation_) {
    if (generation_ != 0) ++cancelled_generations_;
    cache_generation_ = cache_.begin_playback();
    generation_ = generation;
  }
  return cache_generation_;
}

std::size_t RemoteDiscProvider::read(std::uint64_t start,
                                     std::uint8_t* destination,
                                     std::size_t length, bool media,
                                     std::uint64_t cache_generation) {
  if (length == 0 || start >= size_ || length > size_ - start ||
      !valid_range(start, start + length - 1)) {
    throw std::invalid_argument("Invalid remote disc block range");
  }
  return cache_.read(start, destination, length,
                     media ? cache_.limit_read_ahead(4) : 0,
                     cache_generation);
}

std::uint64_t RemoteDiscProvider::cancelled_generations() const {
  std::lock_guard lock(mutex_);
  return cancelled_generations_;
}

}  // namespace streampath::iso_bridge
