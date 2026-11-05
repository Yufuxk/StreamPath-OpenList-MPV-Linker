#include "dvd_disc.h"

#pragma warning(push)
#pragma warning(disable: 4201)
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include <dvdread/nav_read.h>
#include <dvdnav/dvdnav.h>
#pragma warning(pop)

#include <algorithm>
#include <array>
#include <cstring>
#include <map>

namespace streampath::iso_bridge {
namespace {
constexpr std::uint64_t kSector = 2048;
constexpr std::int64_t kEpoch = 60 * 90000;
std::int64_t dvd_time(const dvd_time_t& time) {
  const auto bcd = [](std::uint8_t v) { return (v >> 4) * 10 + (v & 15); };
  const auto frames = bcd(time.frame_u & 0x3f);
  const auto frame_ticks = (time.frame_u >> 6) == 1 ? 3600 : 3003;
  return (bcd(time.hour) * 3600LL + bcd(time.minute) * 60LL + bcd(time.second)) * 90000 + frames * frame_ticks;
}
std::uint64_t pts(const std::uint8_t* p) {
  return (std::uint64_t(p[0] & 14) << 29) | (std::uint64_t(p[1]) << 22) |
      (std::uint64_t(p[2] & 254) << 14) | (std::uint64_t(p[3]) << 7) | (p[4] >> 1);
}
void set_pts(std::uint8_t* p, std::uint64_t value) {
  value &= (1ULL << 33) - 1;
  p[0] = static_cast<std::uint8_t>((p[0] & 0xf1) | ((value >> 29) & 14));
  p[1] = static_cast<std::uint8_t>(value >> 22);
  p[2] = static_cast<std::uint8_t>(((value >> 14) & 254) | 1);
  p[3] = static_cast<std::uint8_t>(value >> 7);
  p[4] = static_cast<std::uint8_t>((value << 1) | 1);
}
void quiet_log(void*, dvd_logger_level_t, const char*, va_list) {}
}

void normalize_dvd_sector(std::uint8_t* data, std::int64_t offset,
                          std::uint32_t vobu_start) {
  // NAV 使用 32 位时钟；PES 的 33 位表示必须先对齐到同一 VOBU 附近。
  const auto translated = [offset, vobu_start](std::uint64_t value) {
    const auto relative = static_cast<std::uint32_t>(value) - vobu_start;
    const auto delta = (relative & 0x80000000U)
        ? static_cast<std::int64_t>(relative) - (1LL << 32)
        : static_cast<std::int64_t>(relative);
    return static_cast<std::uint64_t>(static_cast<std::int64_t>(vobu_start) + offset + delta);
  };
  if (std::memcmp(data, "\0\0\1\xba", 4) != 0 || (data[4] & 0xc0) != 0x40)
    throw DvdError("invalid_disc", "Invalid DVD MPEG-PS pack");
  const std::uint64_t scr = (std::uint64_t(data[4] & 0x38) << 27) |
      (std::uint64_t(data[4] & 3) << 28) | (std::uint64_t(data[5]) << 20) |
      (std::uint64_t(data[6] & 0xf8) << 12) | (std::uint64_t(data[6] & 3) << 13) |
      (std::uint64_t(data[7]) << 5) | (data[8] >> 3);
  const auto normalized = translated(scr) & ((1ULL << 33) - 1);
  data[4] = static_cast<std::uint8_t>(0x44 | ((normalized >> 27) & 0x38) | ((normalized >> 28) & 3));
  data[5] = static_cast<std::uint8_t>(normalized >> 20);
  data[6] = static_cast<std::uint8_t>(4 | ((normalized >> 12) & 0xf8) | ((normalized >> 13) & 3));
  data[7] = static_cast<std::uint8_t>(normalized >> 5);
  data[8] = static_cast<std::uint8_t>((data[8] & 7) | (normalized << 3));
  std::size_t pos = 14 + (data[13] & 7);
  while (pos + 6 <= kSector && data[pos] == 0 && data[pos + 1] == 0 && data[pos + 2] == 1) {
    const auto id = data[pos + 3];
    const std::size_t packet_size = 6 + (std::size_t(data[pos + 4]) << 8) + data[pos + 5];
    if (pos + packet_size > kSector) throw DvdError("invalid_disc", "DVD PES packet exceeds its sector");
    if (id == 0xbd || (id >= 0xc0 && id <= 0xef)) {
      if (packet_size < 9) throw DvdError("invalid_disc", "DVD PES header is truncated");
      if ((data[pos + 6] & 0x30) != 0) throw DvdError("encrypted_disc", "CSS encrypted DVD is not supported");
      const auto flags = data[pos + 7] >> 6;
      if (flags >= 2) {
        if (packet_size < 14 || data[pos + 8] < 5) throw DvdError("invalid_disc", "DVD PTS is truncated");
        set_pts(data + pos + 9, translated(pts(data + pos + 9)));
      }
      if (flags == 3) {
        if (packet_size < 19 || data[pos + 8] < 10) throw DvdError("invalid_disc", "DVD DTS is truncated");
        set_pts(data + pos + 14, translated(pts(data + pos + 14)));
      }
    }
    pos += packet_size;
  }
}

struct DvdDisc::Impl {
  struct Cell {
    std::uint64_t begin, end;
    std::uint32_t first, last;
    std::int64_t elapsed;
  };
  struct Title {
    TitleInfo info;
    int vts;
    std::vector<Cell> cells;
  };
  BlockCache* cache;
  std::uint64_t position = 0, generation = 0;
  std::size_t read_ahead = 0;
  std::exception_ptr error;
  dvd_reader_t* reader = nullptr;
  ifo_handle_t* vmg = nullptr;
  dvdnav_t* nav = nullptr;
  std::map<int, ifo_handle_t*> ifos;
  std::map<int, dvd_file_t*> vobs;
  std::vector<Title> titles;
  std::vector<std::uint32_t> unavailable;
  dvd_reader_stream_cb callbacks{};
  dvdnav_stream_cb nav_callbacks{};

  explicit Impl(BlockCache& value) : cache(&value) {
    callbacks.pf_seek = [](void* opaque, std::uint64_t offset) -> int {
      static_cast<Impl*>(opaque)->position = offset;
      return 0;
    };
    callbacks.pf_read = [](void* opaque, void* data, int length) -> int {
      auto& self = *static_cast<Impl*>(opaque);
      try {
        if (length < 0) return -1;
        const auto count = self.cache->read(self.position, static_cast<std::uint8_t*>(data),
            static_cast<std::size_t>(length), self.read_ahead, self.generation);
        self.position += count;
        return static_cast<int>(count);
      } catch (...) { self.error = std::current_exception(); return -1; }
    };
    const dvd_logger_cb logger{quiet_log};
    try {
      reader = DVDOpenStream2(this, &logger, &callbacks);
      rethrow();
      if (reader) vmg = ifoOpen(reader, 0);
      rethrow();
    } catch (...) {
      if (vmg) ifoClose(vmg);
      if (reader) DVDClose(reader);
      throw;
    }
  }
  ~Impl() {
    if (nav) dvdnav_close(nav);
    for (const auto& entry : vobs) DVDCloseFile(entry.second);
    for (const auto& entry : ifos) ifoClose(entry.second);
    if (vmg) ifoClose(vmg);
    if (reader) DVDClose(reader);
  }
  void rethrow() { if (error) std::rethrow_exception(error); }
  ifo_handle_t* ifo(int vts) {
    auto& result = ifos[vts];
    if (!result) result = ifoOpen(reader, vts);
    rethrow();
    if (!result) throw DvdError("invalid_disc", "DVD VTS IFO cannot be read");
    return result;
  }
  dvd_file_t* vob(int vts) {
    auto& result = vobs[vts];
    if (!result) result = DVDOpenFile(reader, vts, DVD_READ_TITLE_VOBS);
    rethrow();
    if (!result) throw DvdError("invalid_disc", "DVD title VOB cannot be opened");
    return result;
  }
  void sector(int vts, std::uint32_t offset, std::uint8_t* data) {
    const auto count = DVDReadBlocks(vob(vts), static_cast<int>(offset), 1, data);
    rethrow();
    if (count != 1) throw DvdError("invalid_disc", "DVD title sector read failed at " + std::to_string(offset));
  }
};

DvdDisc::DvdDisc(BlockCache& cache) : impl_(std::make_unique<Impl>(cache)) {}
DvdDisc::~DvdDisc() = default;
bool DvdDisc::detected() const { return impl_->vmg && impl_->vmg->tt_srpt; }
const std::vector<std::uint32_t>& DvdDisc::unavailable_titles() const { return impl_->unavailable; }
void DvdDisc::bind(BlockCache& cache, std::uint64_t generation, std::size_t read_ahead) {
  impl_->cache = &cache;
  impl_->generation = generation;
  impl_->read_ahead = read_ahead;
  impl_->error = {};
}

std::vector<TitleInfo> DvdDisc::enumerate() {
  auto& self = *impl_;
  if (!detected()) return {};
  // 使用独立导航上下文核对 DVD 标题表，读取回调与缓存仍由当前会话提供。
  const dvdnav_logger_cb logger{[](void*, dvdnav_logger_level_t, const char*, va_list) {}};
  self.nav_callbacks = {self.callbacks.pf_seek, self.callbacks.pf_read, nullptr};
  if (dvdnav_open_stream2(&self.nav, &self, &logger, &self.nav_callbacks) != DVDNAV_STATUS_OK)
    throw DvdError("invalid_disc", "DVD navigation structure cannot be opened");
  self.rethrow();
  dvdnav_set_readahead_flag(self.nav, 0);
  std::vector<TitleInfo> result;
  for (std::uint32_t index = 0; index < self.vmg->tt_srpt->nr_of_srpts; ++index) {
    try {
    const auto& entry = self.vmg->tt_srpt->title[index];
    auto* vts = self.ifo(entry.title_set_nr);
    if (!vts->vts_ptt_srpt || !vts->vts_pgcit || !vts->vts_vobu_admap ||
        entry.vts_ttn == 0 || entry.vts_ttn > vts->vts_ptt_srpt->nr_of_srpts)
      throw DvdError("invalid_disc", "DVD title tables are incomplete");
    const auto& parts = vts->vts_ptt_srpt->title[entry.vts_ttn - 1];
    if (parts.nr_of_ptts == 0) continue;
    const auto pgcn = parts.ptt[0].pgcn;
    if (pgcn == 0 || pgcn > vts->vts_pgcit->nr_of_pgci_srp)
      throw DvdError("invalid_disc", "DVD PGC index is invalid");
    const auto* pgc = vts->vts_pgcit->pgci_srp[pgcn - 1].pgc;
    if (!pgc || !pgc->cell_playback || !pgc->program_map) throw DvdError("invalid_disc", "DVD PGC is incomplete");
    if (pgc->pg_playback_mode != 0)
      throw DvdError("unsupported_dvd_title", "DVD title uses random program playback");
    for (unsigned part = 0; part < parts.nr_of_ptts; ++part) {
      if (parts.ptt[part].pgcn != pgcn || parts.ptt[part].pgn == 0 || parts.ptt[part].pgn > pgc->nr_of_programs)
        throw DvdError("unsupported_dvd_title", "DVD title requires a non-linear PGC path");
    }
    Impl::Title title{};
    title.vts = entry.title_set_nr;
    title.info.title_index = index;
    title.info.playlist = index + 1;
    title.info.dvd = true;
    std::int64_t elapsed = 0;
    std::vector<std::int64_t> cell_times(pgc->nr_of_cells);
    bool in_angle = false;
    const auto first_cell = pgc->program_map[parts.ptt[0].pgn - 1];
    if (first_cell == 0 || first_cell > pgc->nr_of_cells)
      throw DvdError("invalid_disc", "DVD first program cell is invalid");
    for (unsigned cell_index = first_cell - 1; cell_index < pgc->nr_of_cells; ++cell_index) {
      const auto& cell = pgc->cell_playback[cell_index];
      cell_times[cell_index] = elapsed;
      if (cell.block_type == BLOCK_TYPE_ANGLE_BLOCK) {
        if (cell.block_mode == BLOCK_MODE_FIRST_CELL) in_angle = false;
        if (in_angle) continue;
        in_angle = true;
      } else in_angle = false;
      if (cell.interleaved || cell.playback_mode || cell.still_time || cell.cell_cmd_nr)
        throw DvdError("unsupported_dvd_title", "DVD title requires interleaved or interactive cell navigation");
      if (cell.last_sector < cell.first_sector) throw DvdError("invalid_disc", "DVD cell sector range is invalid");
      const auto bytes = (std::uint64_t(cell.last_sector) - cell.first_sector + 1) * kSector;
      title.cells.push_back({title.info.size, title.info.size + bytes, cell.first_sector, cell.last_sector, elapsed});
      title.info.size += bytes;
      elapsed += dvd_time(cell.playback_time);
    }
    title.info.duration_milliseconds = static_cast<std::uint64_t>(elapsed / 90);
    for (unsigned part = 0; part < parts.nr_of_ptts; ++part) {
      const auto cell = pgc->program_map[parts.ptt[part].pgn - 1];
      if (cell == 0 || cell > cell_times.size()) throw DvdError("invalid_disc", "DVD chapter cell is invalid");
      const auto start = static_cast<std::uint64_t>(cell_times[cell - 1] / 90);
      if (!title.info.chapters.empty() && start <= title.info.chapters.back().start_milliseconds) continue;
      title.info.chapters.push_back({start, 0, {}});
    }
    for (std::size_t part = 0; part < title.info.chapters.size(); ++part) {
      auto& chapter = title.info.chapters[part];
      const auto end = part + 1 < title.info.chapters.size() ? title.info.chapters[part + 1].start_milliseconds : title.info.duration_milliseconds;
      chapter.duration_milliseconds = end - chapter.start_milliseconds;
    }
    if (title.info.size && title.info.duration_milliseconds) {
      result.push_back(title.info);
      self.titles.push_back(std::move(title));
    }
    } catch (const DvdError& error) {
      if (error.code != "unsupported_dvd_title") throw;
      self.unavailable.push_back(index + 1);
    }
  }
  if (result.empty()) throw DvdError(self.unavailable.empty() ? "invalid_disc" : "unsupported_dvd_title", "No linear DVD title was found");
  return result;
}

std::size_t DvdDisc::read(std::uint32_t id, std::uint64_t offset, std::uint8_t* data, std::size_t length) {
  auto& self = *impl_;
  const auto title = std::find_if(self.titles.begin(), self.titles.end(), [id](const Impl::Title& t) { return t.info.playlist == id; });
  if (title == self.titles.end() || offset >= title->info.size) return 0;
  length = static_cast<std::size_t>(std::min<std::uint64_t>(length, title->info.size - offset));
  std::size_t completed = 0;
  std::array<std::uint8_t, kSector> buffer{}, nav{};
  std::uint32_t previous_nav = UINT32_MAX;
  const Impl::Cell* previous_cell = nullptr;
  std::int64_t adjustment = 0;
  std::uint32_t source_anchor = 0;
  while (completed < length) {
    if (self.generation && !self.cache->is_playback_current(self.generation)) return completed;
    const auto cell = std::find_if(title->cells.begin(), title->cells.end(), [offset](const Impl::Cell& c) { return offset >= c.begin && offset < c.end; });
    const auto physical = cell->first + static_cast<std::uint32_t>((offset - cell->begin) / kSector);
    const auto* map = self.ifo(title->vts)->vts_vobu_admap;
    const auto count = (map->last_byte + 1 - VOBU_ADMAP_SIZE) / sizeof(std::uint32_t);
    const auto upper = std::upper_bound(map->vobu_start_sectors, map->vobu_start_sectors + count, physical);
    if (upper == map->vobu_start_sectors || *(upper - 1) < cell->first)
      throw DvdError("invalid_disc", "DVD VOBU address is missing");
    const auto nav_sector = *(upper - 1);
    if (nav_sector != previous_nav || previous_cell != &*cell) {
      self.sector(title->vts, nav_sector, nav.data());
      if (nav[38] != 0 || nav[39] != 0 || nav[40] != 1 || nav[41] != 0xbf || nav[44] != 0)
        throw DvdError("invalid_disc", "DVD NAV packet is invalid");
      pci_t pci{};
      navRead_PCI(&pci, nav.data() + 45);
      adjustment = kEpoch + cell->elapsed + dvd_time(pci.pci_gi.e_eltm) - pci.pci_gi.vobu_s_ptm;
      source_anchor = pci.pci_gi.vobu_s_ptm;
      previous_nav = nav_sector;
      previous_cell = &*cell;
    }
    if (physical == nav_sector) buffer = nav;
    else self.sector(title->vts, physical, buffer.data());
    normalize_dvd_sector(buffer.data(), adjustment, source_anchor);
    const auto skip = static_cast<std::size_t>(offset % kSector);
    const auto copied = std::min(length - completed, buffer.size() - skip);
    std::memcpy(data + completed, buffer.data() + skip, copied);
    offset += copied;
    completed += copied;
  }
  return completed;
}
}  // namespace streampath::iso_bridge
