#include "update_bootstrap.h"

#include <windows.h>
#include <cstdio>
#include <string>
#include <vector>

bool StreamPathUpdateBootstrap() {
  HANDLE update = OpenMutexW(SYNCHRONIZE, FALSE, L"Local\\StreamPath.Update");
  if (update) {
    CloseHandle(update);
    return false;
  }
  std::vector<wchar_t> executable(32768);
  const DWORD length = GetModuleFileNameW(nullptr, executable.data(),
                                        static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) return false;
  const std::wstring path(executable.data(), length);
  const auto root = path.substr(0, path.find_last_of(L"\\/"));
  const auto transaction = root + L"\\.streampath-update";
  if (GetFileAttributesW((transaction + L"\\pending.json").c_str()) ==
      INVALID_FILE_ATTRIBUTES) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return true;
    std::fprintf(stderr, "Update recovery marker cannot be read: %lu\n", error);
    return false;
  }
  wchar_t system[MAX_PATH];
  if (!GetSystemDirectoryW(system, MAX_PATH)) return false;
  const std::wstring powershell = std::wstring(system) +
      L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = L"\"" + powershell +
      L"\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
      transaction + L"\\helper.ps1\" -Recover -Target \"" + root +
      L"\" -ParentPid " + std::to_wstring(GetCurrentProcessId());
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr,
                      FALSE, CREATE_NO_WINDOW, nullptr, root.c_str(),
                      &startup, &process)) {
    std::fprintf(stderr, "Update recovery launch failed: %lu\n", GetLastError());
  } else {
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
  }
  return false;
}
