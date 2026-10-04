#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 在 Flutter 初始化前互斥启动，事件保留首次窗口出现前的激活请求。
struct SingleInstance {
  HANDLE activation = CreateEventW(
      nullptr, FALSE, FALSE, L"Local\\StreamPath.Activate");
  HANDLE mutex = activation
      ? CreateMutexW(nullptr, FALSE, L"Local\\StreamPath.SingleInstance")
      : nullptr;
  DWORD ownership = activation && mutex
      ? WaitForSingleObject(mutex, 0)
      : WAIT_FAILED;

  ~SingleInstance() {
    if (ownership == WAIT_OBJECT_0 || ownership == WAIT_ABANDONED) {
      ReleaseMutex(mutex);
    }
    if (mutex) CloseHandle(mutex);
    if (activation) CloseHandle(activation);
  }
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  SingleInstance app_instance;
  if (app_instance.ownership == WAIT_FAILED) {
    std::fprintf(stderr, "Single-instance initialization failed: %lu\n",
                 GetLastError());
    return EXIT_FAILURE;
  }
  if (app_instance.ownership == WAIT_TIMEOUT) {
    const HWND existing = FindWindowW(Win32Window::kWindowClassName, nullptr);
    if (existing) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(existing, &process_id);
      AllowSetForegroundWindow(process_id);
    }
    if (!SetEvent(app_instance.activation)) {
      std::fprintf(stderr, "Window activation request failed: %lu\n",
                   GetLastError());
      return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(0, 0);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"streampath", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  int exit_code = EXIT_SUCCESS;
  bool running = true;
  while (running) {
    const DWORD wait = MsgWaitForMultipleObjectsEx(
        1, &app_instance.activation, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    if (wait == WAIT_OBJECT_0) {
      window.RequestActivation();
    } else if (wait == WAIT_FAILED) {
      std::fprintf(stderr, "Window message wait failed: %lu\n", GetLastError());
      exit_code = EXIT_FAILURE;
      break;
    }
    ::MSG msg;
    while (::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        running = false;
        break;
      }
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }

  ::CoUninitialize();
  return exit_code;
}
