#define _CRT_SECURE_NO_WARNINGS
#include "mpv/streampath_disc.h"

void *test_disc_open(const char *url, HANDLE cancel) { return sp_disc_open(url, cancel, NULL); }
void test_disc_close(void *disc) { sp_disc_close(disc); }
int test_disc_read(void *disc, void *bytes, int lba, int blocks) {
    return sp_disc_read(disc, bytes, lba, blocks);
}
void test_disc_advance(void *disc) { sp_disc_advance(disc); sp_disc_overlay(disc); }
