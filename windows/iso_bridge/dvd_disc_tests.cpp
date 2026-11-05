#include "dvd_disc.h"
#pragma warning(push)
#pragma warning(disable: 4201)
#include "dvd_navigation.h"
#pragma warning(pop)

#include <array>
#include <cstring>
#include <iostream>

using namespace streampath::iso_bridge;

int main() {
  try {
    const std::array<std::uint8_t, 8> set_gprm{0x71,0,0,1,0,0,0,0};
    const std::array<std::uint8_t, 8> link_cell{0x20,0x07,0,0,0,0,0,3};
    const std::array<std::uint8_t, 8> random{0x78,0,0,1,0,2,0,0};
    const std::array<std::uint8_t, 8> timer{0x52,0,0,1,0,0,0,0};
    const std::array<std::uint8_t, 8> counter{0x53,0,0,1,0,0x80,0,0};
    const std::array<std::uint8_t, 8> register_mode{0x53,0,0,1,0,0,0,0};
    if (!sp_dvdnav_command_fixed(register_mode.data()) || !sp_dvdnav_command_fixed(set_gprm.data()) || !sp_dvdnav_command_fixed(link_cell.data()) ||
        sp_dvdnav_command_fixed(random.data()) || sp_dvdnav_command_fixed(timer.data()) ||
        sp_dvdnav_command_fixed(counter.data()))
      throw std::runtime_error("DVD deterministic command policy is invalid");
    std::array<std::uint8_t, 2048> sector{};
    // MPEG-2 pack，SCR=0，PTS=90000，DTS=0，其余为 padding_stream。
    const std::uint8_t prefix[] = {0,0,1,0xba,0x44,0,4,0,4,1,0,0,3,0,
      0,0,1,0xe0,0,13,0x80,0xc0,10,0x31,0,5,0xbf,0x21,0x11,0,1,0,1,
      0,0,1,0xbe,7,0xd9};
    std::memcpy(sector.data(), prefix, sizeof(prefix));
    std::fill(sector.begin() + sizeof(prefix), sector.end(), std::uint8_t(0xff));
    normalize_dvd_sector(sector.data(), 90000);
    const std::uint8_t expected_pts[] = {0x31,0,0x0b,0x7e,0x41};
    const std::uint8_t expected_dts[] = {0x11,0,5,0xbf,0x21};
    if (std::memcmp(sector.data() + 23, expected_pts, 5) ||
        std::memcmp(sector.data() + 28, expected_dts, 5) || sector[100] != 0xff)
      throw std::runtime_error("DVD timestamp normalization changed media payload or timestamps");
    normalize_dvd_sector(sector.data(), -90000);
    if (std::memcmp(sector.data(), prefix, sizeof(prefix)))
      throw std::runtime_error("DVD timestamp translation is not reversible");
    auto wrapped = sector;
    // PTS=2^32+90000，NAV 时钟已在 32 位边界回绕。
    wrapped[23] = 0x39;
    normalize_dvd_sector(wrapped.data(), 90000, 0);
    if (std::memcmp(wrapped.data() + 23, expected_pts, 5))
      throw std::runtime_error("DVD NAV/PES clock wrap is not aligned");
    auto encrypted = sector;
    encrypted[20] |= 0x10;
    bool rejected = false;
    try { normalize_dvd_sector(encrypted.data(), 0); }
    catch (const DvdError& error) { rejected = error.code == "encrypted_disc"; }
    if (!rejected) throw std::runtime_error("Encrypted DVD PES was accepted");
    auto malformed = sector;
    malformed[18] = 0xff;
    rejected = false;
    try { normalize_dvd_sector(malformed.data(), 0); }
    catch (const DvdError& error) { rejected = error.code == "invalid_disc"; }
    if (!rejected) throw std::runtime_error("Truncated DVD PES was accepted");
    std::cout << "DVD sector tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
