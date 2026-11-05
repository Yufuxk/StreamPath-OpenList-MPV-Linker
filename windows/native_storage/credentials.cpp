#include <windows.h>
#include <wincred.h>
#include <cstdint>

// 在同一次原生调用中保存错误码，避免 Dart 运行时改写线程状态。
extern "C" __declspec(dllexport) uint32_t sp_credential_read(
    const wchar_t* target, PCREDENTIALW* result) {
  if (CredReadW(target, CRED_TYPE_GENERIC, 0, result)) return ERROR_SUCCESS;
  return GetLastError();
}

extern "C" __declspec(dllexport) uint32_t sp_credential_delete(
    const wchar_t* target) {
  if (CredDeleteW(target, CRED_TYPE_GENERIC, 0)) return ERROR_SUCCESS;
  return GetLastError();
}
