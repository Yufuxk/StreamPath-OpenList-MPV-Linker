#pragma once
#include <stddef.h>

// libnfs 的 Windows 实现提供此函数，NFS v4 调用点需要明确的指针返回类型。
char* strndup(const char* text, size_t length);
