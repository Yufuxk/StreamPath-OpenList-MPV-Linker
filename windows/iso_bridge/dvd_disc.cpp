#include "dvd_disc.h"

#pragma warning(push)
#pragma warning(disable: 4201)
#include "dvd_navigation.h"
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include <dvdread/nav_read.h>
#include <dvdnav/dvdnav.h>
#pragma warning(pop)

#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <set>
#include <chrono>

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
  void sector(int vts, std::uint32_t offset, std::uint8_t* data, BlockCache* sparse = nullptr) {
    auto* file = vob(vts);
    auto* original = cache;
    if (sparse) cache = sparse;
    int count = 0;
    try { count = static_cast<int>(DVDReadBlocks(file, static_cast<int>(offset), 1, data)); }
    catch (...) { cache = original; throw; }
    cache = original;
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

namespace {
void validate_pgc(const pgc_t* pgc) {
  if (!pgc || !pgc->cell_playback || !pgc->program_map || !pgc->nr_of_cells || !pgc->nr_of_programs)
    throw DvdError("invalid_dvd_navigation", "DVD PGC is incomplete");
  for (unsigned p = 0; p < pgc->nr_of_programs; ++p)
    if (!pgc->program_map[p] || pgc->program_map[p] > pgc->nr_of_cells)
      throw DvdError("invalid_dvd_navigation", "DVD program cell is out of bounds");
  bool angle = false;
  for (unsigned i = 0; i < pgc->nr_of_cells; ++i) {
    const auto& c = pgc->cell_playback[i];
    if (c.last_sector < c.first_sector || c.last_sector > INT32_MAX)
      throw DvdError("invalid_dvd_navigation", "DVD cell sector bounds are invalid");
    if (c.block_type == BLOCK_TYPE_ANGLE_BLOCK) {
      if (c.block_mode == BLOCK_MODE_FIRST_CELL && !angle) angle = true;
      else if (!angle || c.block_mode < BLOCK_MODE_IN_BLOCK)
        throw DvdError("invalid_dvd_navigation", "DVD angle block is invalid");
      if (c.block_mode == BLOCK_MODE_LAST_CELL) angle = false;
    } else if (angle || c.block_type || c.block_mode)
      throw DvdError("invalid_dvd_navigation", "DVD angle block is unterminated");
    if (c.cell_cmd_nr && (!pgc->command_tbl || c.cell_cmd_nr > pgc->command_tbl->nr_of_cell))
      throw DvdError("invalid_dvd_navigation", "DVD cell command is out of bounds");
  }
  if (angle) throw DvdError("invalid_dvd_navigation", "DVD angle block is unterminated");

}
void parse_nav(const std::uint8_t* nav, std::uint32_t sector, pci_t& pci, dsi_t& dsi) {
  if (std::memcmp(nav, "\0\0\1\xba", 4) ||
      std::memcmp(nav + 38, "\0\0\1\xbf\3\xd4\0", 7) ||
      std::memcmp(nav + 1024, "\0\0\1\xbf\3\xfa\1", 7))
    throw DvdError("invalid_dvd_navigation", "DVD NAV PCI/DSI packets are invalid");
  navRead_PCI(&pci, const_cast<std::uint8_t*>(nav) + 45);
  navRead_DSI(&dsi, const_cast<std::uint8_t*>(nav) + 1031);
  if (pci.pci_gi.nv_pck_lbn != sector || dsi.dsi_gi.nv_pck_lbn != sector)
    throw DvdError("invalid_dvd_navigation", "DVD NAV address does not match its sector");
  if (pci.hli.hl_gi.hli_ss && pci.hli.hl_gi.btn_ns)
    throw DvdError("dvd_menu_required", "DVD title contains interactive buttons");
}
bool unavailable_code(const std::string& code) {
  return code == "dvd_menu_required" || code == "dvd_navigation_indeterminate" ||
      code == "dvd_still_unsupported" || code == "invalid_dvd_navigation";
}
}

std::vector<TitleInfo> DvdDisc::enumerate(BlockCache* navigation_cache) {
  auto& self = *impl_;
  if (!detected()) return {};
  const auto started = std::chrono::steady_clock::now();
  const dvdnav_logger_cb logger{[](void*, dvdnav_logger_level_t, const char*, va_list) {}};
  self.nav_callbacks = {self.callbacks.pf_seek, self.callbacks.pf_read, nullptr};
  std::vector<TitleInfo> result;
  std::string last_code = "invalid_disc";
  std::uint64_t nav_reads = 0, spans = 0;
  for (std::uint32_t index = 0; index < self.vmg->tt_srpt->nr_of_srpts; ++index) {
    try {
      const auto& entry = self.vmg->tt_srpt->title[index];
      auto* vts = self.ifo(entry.title_set_nr);
      if (!vts->vts_ptt_srpt || !vts->vts_pgcit || !vts->vts_vobu_admap ||
          !entry.vts_ttn || entry.vts_ttn > vts->vts_ptt_srpt->nr_of_srpts)
        throw DvdError("invalid_dvd_navigation", "DVD title tables are incomplete");
      const auto vob_sectors = DVDFileSize(self.vob(entry.title_set_nr));
      self.rethrow();
      if (vob_sectors <= 0) throw DvdError("invalid_dvd_navigation", "DVD VOB file is empty or unreadable");
      const auto* address_map = vts->vts_vobu_admap;
      if (address_map->last_byte < VOBU_ADMAP_SIZE ||
          (address_map->last_byte + 1 - VOBU_ADMAP_SIZE) % sizeof(std::uint32_t))
        throw DvdError("invalid_dvd_navigation", "DVD VOBU address table size is invalid");
      const auto address_count = (address_map->last_byte + 1 - VOBU_ADMAP_SIZE) / sizeof(std::uint32_t);
      if (!address_count || !std::is_sorted(address_map->vobu_start_sectors, address_map->vobu_start_sectors + address_count))
        throw DvdError("invalid_dvd_navigation", "DVD VOBU address table is empty or unordered");
      const auto& parts = vts->vts_ptt_srpt->title[entry.vts_ttn - 1];
      if (!parts.nr_of_ptts) continue;
      // 在进入 VM 前校验本 VTS 的表结构，播放能力只按实际经过的路径判断。
      for (unsigned p = 0; p < vts->vts_pgcit->nr_of_pgci_srp; ++p)
        validate_pgc(vts->vts_pgcit->pgci_srp[p].pgc);
      for (unsigned p = 0; p < parts.nr_of_ptts; ++p) {
        const auto& part = parts.ptt[p];
        if (!part.pgcn || part.pgcn > vts->vts_pgcit->nr_of_pgci_srp || !part.pgn ||
            part.pgn > vts->vts_pgcit->pgci_srp[part.pgcn - 1].pgc->nr_of_programs)
          throw DvdError("invalid_dvd_navigation", "DVD chapter program is invalid");
      }
      if (self.nav) { dvdnav_close(self.nav); self.nav = nullptr; }
      const auto opened = dvdnav_open_stream2(&self.nav, &self, &logger, &self.nav_callbacks);
      self.rethrow();
      if (opened != DVDNAV_STATUS_OK)
        throw DvdError("invalid_dvd_navigation", "DVD VM cannot be opened");
      dvdnav_set_readahead_flag(self.nav, 0);
      const auto played = sp_dvdnav_title(self.nav, static_cast<int>(index + 1));
      self.rethrow();
      if (!played) throw DvdError("invalid_dvd_navigation", "DVD VM cannot enter title");
      dvdnav_angle_change(self.nav, 1);
      Impl::Title title{};
      title.vts = entry.title_set_nr;
      title.info.title_index = index;
      title.info.playlist = index + 1;
      title.info.dvd = true;
      std::int64_t elapsed = 0;
      std::set<std::vector<int>> visited;
      const auto append = [&](std::uint32_t first, std::uint32_t last) {
        const auto bytes = (std::uint64_t(last) - first + 1) * kSector;
        title.cells.push_back({title.info.size, title.info.size + bytes, first, last, elapsed});
        title.info.size += bytes;
      };
      for (;;) {
        sp_dvdnav_state state{};
        sp_dvdnav_state_get(self.nav, &state);
        if (!state.title_domain || state.vts_title != entry.vts_ttn || state.vts != title.vts) {
          if (title.cells.empty()) throw DvdError("dvd_menu_required", "DVD title enters a menu before any media");
          break;
        }
        if (state.navigation_error)
          throw DvdError("dvd_navigation_indeterminate", "DVD VM uses non-deterministic commands or exceeds navigation limits");
        if (state.stopped) break;
        if (!state.pgc || state.cell < 1 || state.cell > state.pgc->nr_of_cells)
          throw DvdError("invalid_dvd_navigation", "DVD VM cell position is invalid");
        if (state.block != 0)
          throw DvdError("dvd_navigation_indeterminate", "DVD VM resumes inside a cell without a fixed stream mapping");
        std::vector<int> key{state.vts, state.pgcn, state.cell};
        key.insert(key.end(), std::begin(state.registers), std::end(state.registers));
        if (!visited.insert(std::move(key)).second || visited.size() > 65536)
          throw DvdError("dvd_navigation_indeterminate", "DVD title navigation does not terminate");
        const auto& cell = state.pgc->cell_playback[state.cell - 1];
        if (cell.last_sector >= static_cast<std::uint64_t>(vob_sectors))
          throw DvdError("invalid_dvd_navigation", "DVD cell exceeds its VOB file");
        if (cell.block_type == BLOCK_TYPE_ANGLE_BLOCK && cell.block_mode != BLOCK_MODE_FIRST_CELL)
          throw DvdError("dvd_navigation_indeterminate", "DVD VM selected a non-default angle cell");
        dvdnav_angle_change(self.nav, 1);
        auto logical_last = state.cell;
        if (cell.block_type == BLOCK_TYPE_ANGLE_BLOCK) {
          while (logical_last < state.pgc->nr_of_cells &&
              state.pgc->cell_playback[logical_last].block_type == BLOCK_TYPE_ANGLE_BLOCK &&
              state.pgc->cell_playback[logical_last].block_mode >= BLOCK_MODE_IN_BLOCK) ++logical_last;
        }
        const auto pgc_still = logical_last == state.pgc->nr_of_cells ? state.pgc->still_time : 0;
        const auto still = static_cast<unsigned>(cell.still_time) + pgc_still;
        if (cell.still_time == 255 || pgc_still == 255)
          throw DvdError("dvd_menu_required", "DVD title waits indefinitely for user input");
        if (still || cell.playback_mode)
          throw DvdError("dvd_still_unsupported", "DVD timed still requires a navigation session to preserve frame hold and audio timing");
        for (unsigned p = 0; p < parts.nr_of_ptts; ++p) {
          const auto& part = parts.ptt[p];
          if (part.pgcn == state.pgcn && state.pgc->program_map[part.pgn - 1] == state.cell &&
              (title.info.chapters.empty() || title.info.chapters.back().start_milliseconds < static_cast<std::uint64_t>(elapsed / 90)))
            title.info.chapters.push_back({static_cast<std::uint64_t>(elapsed / 90), 0, {}});
        }
        if (!cell.interleaved) {
          append(cell.first_sector, cell.last_sector);
        } else {
          // 只遍历 NAV，物理跳转与 ILVU 长度由固定版本 libdvdnav 选择角度。
          std::set<std::uint32_t> seen;
          auto current = cell.first_sector;
          for (;;) {
            if (current < cell.first_sector || current > cell.last_sector || !seen.insert(current).second)
              throw DvdError("invalid_dvd_navigation", "DVD ILVU jump leaves the cell or loops");
            std::array<std::uint8_t, kSector> nav{};
            self.sector(title.vts, current, nav.data(), navigation_cache);
            ++nav_reads;
            pci_t pci{}; dsi_t dsi{};
            parse_nav(nav.data(), current, pci, dsi);
            int32_t length = 0, next = 0;
            sp_dvdnav_vobu(self.nav, &pci, &dsi, &length, &next);
            if (length < 0 || static_cast<std::uint64_t>(current) + length > cell.last_sector ||
                dsi.dsi_gi.vobu_ea > static_cast<std::uint32_t>(length))
              throw DvdError("invalid_dvd_navigation", "DVD ILVU extent is out of bounds");
            append(current, current + static_cast<std::uint32_t>(length));
            if (next == SRI_END_OF_CELL) break;
            const auto target = static_cast<std::int64_t>(current) + next;
            if (target < cell.first_sector || target > cell.last_sector ||
                (next > 0 && target <= static_cast<std::int64_t>(current) + length))
              throw DvdError("invalid_dvd_navigation", "DVD ILVU next address is invalid");
            current = static_cast<std::uint32_t>(target);
          }
        }
        elapsed += dvd_time(cell.playback_time);
        sp_dvdnav_next_cell(self.nav);
        self.rethrow();
      }
      title.info.duration_milliseconds = static_cast<std::uint64_t>(elapsed / 90);
      if (title.info.chapters.empty()) title.info.chapters.push_back({0, title.info.duration_milliseconds, {}});
      for (std::size_t p = 0; p < title.info.chapters.size(); ++p) {
        auto& chapter = title.info.chapters[p];
        const auto end = p + 1 < title.info.chapters.size() ? title.info.chapters[p + 1].start_milliseconds : title.info.duration_milliseconds;
        chapter.duration_milliseconds = end - chapter.start_milliseconds;
      }
      if (title.info.size && title.info.duration_milliseconds) {
        spans += title.cells.size();
        result.push_back(title.info);
        self.titles.push_back(std::move(title));
      }
    } catch (const DvdError& error) {
      if (!unavailable_code(error.code)) throw;
      last_code = error.code;
      std::fprintf(stderr, "DVD title %u unavailable: %s: %s\n", index + 1, error.code.c_str(), error.what());
      self.unavailable.push_back(index + 1);
    }
  }
  if (self.nav) { dvdnav_close(self.nav); self.nav = nullptr; }
  std::fprintf(stderr, "DVD navigation index: titles=%zu spans=%llu navSectors=%llu elapsedMs=%lld\n",
      result.size(), static_cast<unsigned long long>(spans), static_cast<unsigned long long>(nav_reads),
      static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count()));
  if (result.empty()) throw DvdError(last_code, "No playable DVD title path was found");
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
    const auto cell = std::prev(std::upper_bound(title->cells.begin(), title->cells.end(), offset,
        [](std::uint64_t value, const Impl::Cell& c) { return value < c.begin; }));
    const auto physical = cell->first + static_cast<std::uint32_t>((offset - cell->begin) / kSector);
    const auto* map = self.ifo(title->vts)->vts_vobu_admap;
    const auto count = (map->last_byte + 1 - VOBU_ADMAP_SIZE) / sizeof(std::uint32_t);
    const auto upper = std::upper_bound(map->vobu_start_sectors, map->vobu_start_sectors + count, physical);
    if (upper == map->vobu_start_sectors || *(upper - 1) < cell->first)
      throw DvdError("invalid_disc", "DVD VOBU address is missing");
    const auto nav_sector = *(upper - 1);
    if (nav_sector != previous_nav || previous_cell != &*cell) {
      self.sector(title->vts, nav_sector, nav.data());
      pci_t pci{}; dsi_t dsi{};
      parse_nav(nav.data(), nav_sector, pci, dsi);
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
