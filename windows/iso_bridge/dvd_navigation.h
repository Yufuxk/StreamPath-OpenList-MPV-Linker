#pragma once

#include <dvdnav/dvdnav.h>
#include <dvdread/ifo_types.h>
#include <dvdread/nav_types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 仅用于固定版本 libdvdnav 的元数据索引，不读取视频载荷。 */
typedef struct {
  const pgc_t* pgc;
  int title, vts_title, vts, pgcn, cell, block, stopped, title_domain, navigation_error;
  uint16_t registers[24 + 16];
} sp_dvdnav_state;

int sp_dvdnav_command_fixed(const uint8_t* bytes);
int sp_dvdnav_title(dvdnav_t* nav, int title);
void sp_dvdnav_state_get(dvdnav_t* nav, sp_dvdnav_state* state);
void sp_dvdnav_next_cell(dvdnav_t* nav);
void sp_dvdnav_vobu(dvdnav_t* nav, const pci_t* pci, const dsi_t* dsi,
                    int32_t* length, int32_t* next);

#ifdef __cplusplus
}
#endif
