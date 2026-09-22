// 与 WinHttpRangeSource 共用现有认证、Range 和取消实现。
class BdmvSource final : public RemoteSource {
 public:
  BdmvSource(bridge::DiscFiles files, std::string origin,
             std::string username, std::string password)
      : files(std::move(files)), origin_(std::move(origin)),
        username_(std::move(username)), password_(std::move(password)) {}
  bridge::DiscFiles files;
  std::optional<bridge::StructureCacheIdentity> structure_identity() const {
    std::vector<const bridge::DiscFile*> sorted;
    for (const auto& file : files.entries) sorted.push_back(&file);
    std::sort(sorted.begin(), sorted.end(), [](const auto* a, const auto* b) { return a->path < b->path; });
    std::string snapshot = "bdmv-manifest-v2\n";
    for (const auto* file : sorted) {
      snapshot += file->path + '\n' + (file->directory ? "directory\n" : "file\n") +
          std::to_string(file->size) + '\n';
      if (!file->directory && file->size != 0) {
        const auto version = manifest_validator(*file);
        if (!version) return std::nullopt;
        snapshot += std::to_string(static_cast<int>(version->first)) + '\n' + utf8_from_wide(version->second) + '\n';
      }
    }
    return bridge::make_structure_cache_identity(files.bytes,
        bridge::StructureCacheValidatorKind::strong_etag, wide_from_utf8(snapshot));
  }
  std::uint64_t size() const override { return files.address_size; }
  std::uint64_t extent_end(std::uint64_t offset) const override {
    const auto* file = files.at(offset);
    return file ? file->base + file->size : offset;
  }
  std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end) override {
    return fetch(start, end, {});
  }
  std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end,
                                 const CancellationProbe& cancelled) override {
    std::vector<std::uint8_t> result;
    fetch_stream(start, end, cancelled, [&](const std::uint8_t* p, std::size_t n) {
      result.insert(result.end(), p, p + n);
    });
    return result;
  }
  void fetch_stream(std::uint64_t start, std::uint64_t end,
                    const CancellationProbe& cancelled,
                    const ChunkConsumer& consume) override {
    const auto* file = files.at(start);
    if (!file || end < start || end >= file->base + file->size)
      throw BridgeException("invalid_disc", "BDMV read crosses file boundary");
    auto source = acquire(*file);
    source->fetch_stream(start - file->base, end - file->base, cancelled, consume);
  }
  void cancel_pending() override {
    std::lock_guard lock(mutex_);
    for (auto& entry : active_) entry.second->cancel_pending();
  }
  NetworkMetricsSnapshot metrics() const override {
    std::lock_guard lock(mutex_);
    auto result = retired_;
    for (const auto& entry : active_) add_metrics(result, entry.second->metrics());
    result.cross_resource_timings_valid = false;
    return result;
  }
  std::uint64_t remote_transfer_active_microseconds() const override {
    std::lock_guard lock(mutex_);
    auto result = retired_time_;
    for (const auto& entry : active_) result += entry.second->remote_transfer_active_microseconds();
    return result;
  }
 private:
  static std::optional<std::pair<bridge::StructureCacheValidatorKind, std::wstring>> manifest_validator(const bridge::DiscFile& file) {
    if (file.etag.size() >= 2 && file.etag.front() == '"' && file.etag.back() == '"' &&
        std::all_of(file.etag.begin() + 1, file.etag.end() - 1,
            [](unsigned char c) { return c >= 0x21 && c != '"' && c != 0x7f; }))
      return std::make_pair(bridge::StructureCacheValidatorKind::strong_etag, wide_from_utf8(file.etag));
    SYSTEMTIME date{};
    if (!file.last_modified.empty() && file.last_modified.find_first_of("\r\n") == std::string::npos &&
        WinHttpTimeToSystemTime(wide_from_utf8(file.last_modified).c_str(), &date))
      return std::make_pair(bridge::StructureCacheValidatorKind::last_modified, wide_from_utf8(file.last_modified));
    return std::nullopt;
  }
  static void add_metrics(NetworkMetricsSnapshot& a, const NetworkMetricsSnapshot& b) {
#define ADD(field) a.field += b.field
    ADD(request_count); ADD(redirect_count); ADD(redirect_resolve_count);
    ADD(resolved_url_reuse_count); ADD(response_header_latency_us_total);
    ADD(response_body_active_us_total); ADD(remote_body_bytes); ADD(probe_body_bytes);
    ADD(remote_transfer_wall_clock_us); ADD(concurrent_transfer_wall_clock_us);
    ADD(request_context_created_count); ADD(request_context_closed_count);
    ADD(request_context_live);
#undef ADD
    a.active_request_peak = std::max(a.active_request_peak, b.active_request_peak);
    a.request_context_peak = std::max(a.request_context_peak, b.request_context_peak);
  }
  std::shared_ptr<WinHttpRangeSource> acquire(const bridge::DiscFile& file) {
    std::lock_guard lock(mutex_);
    auto found = active_.find(file.path);
    if (found != active_.end()) return found->second;
    if (active_.size() >= 8) {
      auto unused = std::find_if(active_.begin(), active_.end(),
          [](const auto& item) { return item.second.use_count() == 1; });
      if (unused == active_.end())
        throw BridgeException("network_error", "Too many active BDMV readers");
      auto snapshot = unused->second->metrics();
      retired_time_ += unused->second->remote_transfer_active_microseconds();
      // 请求句柄由同步收尾释放，累计计数不保留瞬时存活数。
      snapshot.request_context_closed_count += snapshot.request_context_live;
      snapshot.request_context_live = 0;
      add_metrics(retired_, snapshot);
      if (!unused->second->validator().empty())
        validators_[unused->first] = {unused->second->structure_cache_validator_kind(), unused->second->validator()};
      active_.erase(unused);
    }
    const auto known = validators_.find(file.path);
    auto source = std::make_shared<WinHttpRangeSource>(file.url, origin_, username_, password_,
        known == validators_.end() ? manifest_validator(file) : std::make_optional(known->second), file.size, true);
    if (source->size() != file.size)
      throw BridgeException("remote_changed", "BDMV file length changed");
    const auto identity = std::make_pair(source->structure_cache_validator_kind(), source->validator());
    const auto previous = validators_.find(file.path);
    if (previous != validators_.end() && previous->second != identity)
      throw BridgeException("remote_changed", "BDMV file validator changed");
    if (!source->validator().empty()) validators_[file.path] = identity;
    active_[file.path] = source;
    return source;
  }
  std::string origin_, username_, password_;
  mutable std::mutex mutex_;
  std::map<std::string, std::shared_ptr<WinHttpRangeSource>> active_;
  std::map<std::string, std::pair<bridge::StructureCacheValidatorKind, std::wstring>> validators_;
  NetworkMetricsSnapshot retired_;
  std::uint64_t retired_time_ = 0;
};
