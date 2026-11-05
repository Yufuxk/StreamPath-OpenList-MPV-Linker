#include "win32_window.h"

#include <iostream>

class TestWindow : public Win32Window {
 public:
  bool suppress_size = false;
  void DispatchSize(WPARAM state) {
    Win32Window::MessageHandler(GetHandle(), WM_SIZE, state, 0);
  }

 protected:
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam) noexcept override {
    if (suppress_size && message == WM_SIZE) return 0;
    return Win32Window::MessageHandler(window, message, wparam, lparam);
  }
};

bool SameSize(HWND first, HWND second) {
  RECT a{}, b{};
  GetClientRect(first, &a);
  GetClientRect(second, &b);
  return a.right == b.right && a.bottom == b.bottom;
}

int main() {
  TestWindow window;
  if (!window.Create(L"Window restore test", {0, 0}, {1000, 800})) return 1;
  HWND child = CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 1, 1,
                               window.GetHandle(), nullptr,
                               GetModuleHandleW(nullptr), nullptr);
  if (!child) return 2;
  window.SetChildContent(child);
  if (!SameSize(window.GetHandle(), child)) return 3;
  RECT original{};
  GetClientRect(child, &original);

  // 模拟最小化客户区收缩，但由测试显式投递相应的尺寸状态。
  window.suppress_size = true;
  SetWindowPos(window.GetHandle(), nullptr, 0, 0, 160, 28,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  window.DispatchSize(SIZE_MINIMIZED);
  RECT minimized{};
  GetClientRect(child, &minimized);
  if (original.right != minimized.right || original.bottom != minimized.bottom) {
    std::cerr << "Minimizing resized the content window\n";
    return 4;
  }

  window.suppress_size = false;
  for (WPARAM state : {SIZE_RESTORED, SIZE_MAXIMIZED}) {
    SetWindowPos(window.GetHandle(), nullptr, 0, 0, 1100, 850,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    window.DispatchSize(state);
    if (!SameSize(window.GetHandle(), child)) return 5;
    SetWindowPos(window.GetHandle(), nullptr, 0, 0, 900, 650,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (!SameSize(window.GetHandle(), child)) return 6;
  }
  RECT locked_bounds{}, after_command{};
  GetWindowRect(window.GetHandle(), &locked_bounds);
  SetProp(window.GetHandle(), L"StreamPathTaskLocked", reinterpret_cast<HANDLE>(1));
  for (WPARAM command : {SC_MAXIMIZE, SC_MINIMIZE, SC_MOVE, SC_SIZE, SC_RESTORE}) {
    SendMessage(window.GetHandle(), WM_SYSCOMMAND, command, 0);
    GetWindowRect(window.GetHandle(), &after_command);
    if (!EqualRect(&locked_bounds, &after_command)) return 7;
  }
  if (SendMessage(window.GetHandle(), WM_NCHITTEST, 0,
      MAKELPARAM(locked_bounds.left + 2, locked_bounds.top + 2)) != HTCLIENT) return 8;
  SetWindowPos(window.GetHandle(), nullptr, locked_bounds.left + 20,
               locked_bounds.top + 20, 500, 400, SWP_NOZORDER | SWP_NOACTIVATE);
  GetWindowRect(window.GetHandle(), &after_command);
  if (!EqualRect(&locked_bounds, &after_command)) return 9;
  RemoveProp(window.GetHandle(), L"StreamPathTaskLocked");
  window.Destroy();
  std::cout << "PASS: minimize preserves content bounds; restore, maximize and resize apply bounds\n";
  return 0;
}
