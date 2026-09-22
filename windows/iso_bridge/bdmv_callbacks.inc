struct BdmvFileHandle {
  BD_FILE_H api{};
  DiscReadContext* context;
  const bridge::DiscFile* file;
  std::uint64_t position = 0;
};

BD_FILE_H* open_bdmv_file(void* opaque, const char* path) {
  auto& context = *static_cast<DiscReadContext*>(opaque);
  try {
    const auto* file = context.files->find(path);
    if (!file || file->directory) return nullptr;
    auto handle = std::make_unique<BdmvFileHandle>();
    handle->context = &context;
    handle->file = file;
    handle->api.internal = handle.get();
    handle->api.close = [](BD_FILE_H* h) { delete static_cast<BdmvFileHandle*>(h->internal); };
    handle->api.tell = [](BD_FILE_H* h) -> std::int64_t {
      return static_cast<std::int64_t>(static_cast<BdmvFileHandle*>(h->internal)->position);
    };
    handle->api.seek = [](BD_FILE_H* h, std::int64_t offset, std::int32_t origin) -> std::int64_t {
      auto& f = *static_cast<BdmvFileHandle*>(h->internal);
      if (origin != SEEK_SET && origin != SEEK_CUR && origin != SEEK_END) return -1;
      const auto base = static_cast<std::int64_t>(origin == SEEK_SET ? 0 :
          origin == SEEK_CUR ? f.position : f.file->size);
      if (offset < -base || offset > INT64_MAX - base) return -1;
      f.position = static_cast<std::uint64_t>(base + offset);
      return base + offset;
    };
    handle->api.eof = [](BD_FILE_H* h) {
      const auto& f = *static_cast<BdmvFileHandle*>(h->internal);
      return f.position >= f.file->size ? 1 : 0;
    };
    handle->api.read = [](BD_FILE_H* h, std::uint8_t* data, std::int64_t length) -> std::int64_t {
      auto& f = *static_cast<BdmvFileHandle*>(h->internal);
      try {
        if (length < 0) return -1;
        if (f.position >= f.file->size || length == 0) return 0;
        const auto wanted = static_cast<std::size_t>(std::min<std::uint64_t>(length, f.file->size - f.position));
        const bool stream = f.file->path.size() >= 5 &&
            _stricmp(f.file->path.c_str() + f.file->path.size() - 5, ".m2ts") == 0;
        const auto count = f.context->cache->read(f.file->base + f.position, data, wanted,
            stream ? f.context->read_ahead_blocks : 0, f.context->playback_generation);
        if (count != wanted) {
          if (f.context->playback_generation != 0 &&
              !f.context->cache->is_playback_current(f.context->playback_generation)) return 0;
          throw std::runtime_error("BDMV read truncated");
        }
        f.position += count;
        return static_cast<std::int64_t>(count);
      } catch (...) {
        f.context->read_error = std::current_exception();
        return -1;
      }
    };
    handle->api.write = [](BD_FILE_H*, const std::uint8_t*, std::int64_t) -> std::int64_t { return -1; };
    return &handle.release()->api;
  } catch (...) {
    context.read_error = std::current_exception();
    return nullptr;
  }
}

struct BdmvDirHandle {
  BD_DIR_H api{};
  std::vector<const bridge::DiscFile*> children;
  std::size_t position = 0;
};

BD_DIR_H* open_bdmv_dir(void* opaque, const char* path) {
  auto& context = *static_cast<DiscReadContext*>(opaque);
  try {
    const std::string name(path);
    const auto* entry = context.files->find(name);
    if (!name.empty() && (!entry || !entry->directory)) return nullptr;
    auto handle = std::make_unique<BdmvDirHandle>();
    handle->children = context.files->children(name);
    handle->api.internal = handle.get();
    handle->api.close = [](BD_DIR_H* h) { delete static_cast<BdmvDirHandle*>(h->internal); };
    handle->api.read = [](BD_DIR_H* h, BD_DIRENT* entry) {
      auto& dir = *static_cast<BdmvDirHandle*>(h->internal);
      if (dir.position == dir.children.size()) return 1;
      const auto& path = dir.children[dir.position++]->path;
      const auto start = path.find_last_of('/') + 1;
      std::memcpy(entry->d_name, path.c_str() + start, path.size() - start + 1);
      return 0;
    };
    return &handle.release()->api;
  } catch (...) {
    context.read_error = std::current_exception();
    return nullptr;
  }
}
