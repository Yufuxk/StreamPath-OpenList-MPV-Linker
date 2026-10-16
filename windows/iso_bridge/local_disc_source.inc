// 完整缓存从磁盘读取；远端身份由 Dart 播放会话保留。
class LocalIsoSource final : public RemoteSource {
 public:
  explicit LocalIsoSource(std::filesystem::path path) : path_(std::move(path)) {
    handle_ = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    LARGE_INTEGER length{};
    if (handle_ == INVALID_HANDLE_VALUE || !GetFileSizeEx(handle_, &length)) {
      if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
      throw BridgeException("invalid_disc", "Cached disc cannot be opened");
    }
    size_ = static_cast<std::uint64_t>(length.QuadPart);
    FILETIME modified{};
    if (!GetFileTime(handle_, nullptr, nullptr, &modified)) {
      CloseHandle(handle_);
      throw BridgeException("invalid_disc", "Cached disc metadata cannot be read");
    }
    validator_ = path_.wstring() + L":" + std::to_wstring(size_) + L":" +
        std::to_wstring((static_cast<std::uint64_t>(modified.dwHighDateTime) << 32) | modified.dwLowDateTime);
  }
  ~LocalIsoSource() override { CloseHandle(handle_); }
  std::uint64_t size() const override { return size_; }
  const std::wstring& validator() const { return validator_; }
  std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end) override {
    return fetch(start, end, {});
  }
  std::vector<std::uint8_t> fetch(std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled) override {
    std::vector<std::uint8_t> result;
    fetch_stream(start, end, cancelled, [&](const std::uint8_t* bytes, std::size_t count) {
      result.insert(result.end(), bytes, bytes + count);
    });
    return result;
  }
  void fetch_stream(std::uint64_t start, std::uint64_t end,
      const CancellationProbe& cancelled, const ChunkConsumer& consume) override {
    if (end < start || end >= size_) throw BridgeException("invalid_disc", "Cached disc read range is invalid");
    std::lock_guard lock(mutex_);
    LARGE_INTEGER position{}; position.QuadPart = start;
    if (!SetFilePointerEx(handle_, position, nullptr, FILE_BEGIN))
      throw BridgeException("invalid_disc", "Cached disc seek failed");
    std::vector<std::uint8_t> buffer(static_cast<std::size_t>(std::min<std::uint64_t>(1024U*1024U, end-start+1)));
    while (start <= end) {
      if (cancelled && cancelled()) throw bridge::FetchCancelled(0);
      DWORD count = 0;
      if (!ReadFile(handle_, buffer.data(), static_cast<DWORD>(std::min<std::uint64_t>(buffer.size(), end-start+1)), &count, nullptr) || count == 0)
        throw BridgeException("invalid_disc", "Cached disc read failed");
      consume(buffer.data(), count); start += count;
    }
  }
  void cancel_pending() override {}
  NetworkMetricsSnapshot metrics() const override { return {}; }
  std::uint64_t remote_transfer_active_microseconds() const override { return 0; }
 private:
  std::filesystem::path path_;
  HANDLE handle_ = INVALID_HANDLE_VALUE;
  std::uint64_t size_ = 0;
  std::wstring validator_;
  std::mutex mutex_;
};
