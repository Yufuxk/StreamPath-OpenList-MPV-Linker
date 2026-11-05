/* 此文件附加编译到固定版本 dvdnav.c，复用其 VM 和 ILVU 选择逻辑。 */
#include "dvd_navigation.h"

int sp_dvdnav_command_fixed(const uint8_t* bytes) {
  const int type = bytes[0] >> 5, op = bytes[0] & 15;
  return !((type == 2 && (op == 2 || (op == 3 && (bytes[5] & 0x80)))) || (type >= 3 && op == 8));
}

int sp_dvdnav_title(dvdnav_t* nav, int title) {
  /* 标题模式从复位寄存器进入标题，不执行 First Play 菜单。 */
  nav->started = 1;
  nav->vm->stopped = 0;
  return vm_jump_title_part(nav->vm, title, 1);
}

void sp_dvdnav_state_get(dvdnav_t* nav, sp_dvdnav_state* out) {
  const dvd_state_t* s = &nav->vm->state;
  out->pgc = s->pgc;
  out->title = s->TTN_REG;
  out->vts_title = s->VTS_TTN_REG;
  out->vts = s->vtsN;
  out->pgcn = s->pgcN;
  out->cell = s->cellN;
  out->block = s->blockN;
  out->stopped = nav->vm->stopped;
  out->navigation_error = s->registers.sp_index_error;
  out->title_domain = s->domain == DVD_DOMAIN_VTSTitle;
  memcpy(out->registers, s->registers.SPRM, sizeof(s->registers.SPRM));
  memcpy(out->registers + 24, s->registers.GPRM, sizeof(s->registers.GPRM));
}

void sp_dvdnav_next_cell(dvdnav_t* nav) {
  vm_get_next_cell(nav->vm);
}

void sp_dvdnav_vobu(dvdnav_t* nav, const pci_t* pci, const dsi_t* dsi,
                    int32_t* length, int32_t* next) {
  dvdnav_vobu_t vobu;
  /* 上游接口未标 const，但只读取这两个结构。 */
  dvdnav_get_vobu(nav, (dsi_t*)dsi, (pci_t*)pci, &vobu);
  *length = vobu.vobu_length;
  *next = vobu.vobu_next;
}
