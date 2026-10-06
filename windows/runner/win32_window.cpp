#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <algorithm>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

void DisableDwmBorder(HWND window) {
  // Numeric values keep this compatible with older Windows SDK headers.
  constexpr DWORD kWindowBorderColor = 34;
  constexpr COLORREF kColorNone = 0xFFFFFFFE;
  DwmSetWindowAttribute(
      window, static_cast<DWMWINDOWATTRIBUTE>(kWindowBorderColor),
      &kColorNone, sizeof(kColorNone));
}

int GetResizeMargin(HWND window) {
  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  return GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

LRESULT HitTestCustomFrame(HWND window, LPARAM lparam, bool fullscreen) {
  if (fullscreen) return HTCLIENT;
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ScreenToClient(window, &point);
  RECT client_rect{};
  GetClientRect(window, &client_rect);

  if (!IsZoomed(window)) {
    const int margin = GetResizeMargin(window);
    const bool left = point.x < margin;
    const bool right = point.x >= client_rect.right - margin;
    const bool top = point.y < margin;
    const bool bottom = point.y >= client_rect.bottom - margin;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
  }

  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  const int title_bar_height = MulDiv(32, dpi, 96);
  const int window_controls_width = MulDiv(46 * 4, dpi, 96);
  if (point.y < title_bar_height &&
      point.x < client_rect.right - window_controls_width) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

constexpr UINT_PTR kFlutterViewSubclassId = 1;

void ShowWindowMenu(HWND window, POINT point) {
  const HMENU menu = GetSystemMenu(window, FALSE);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window, nullptr);
  if (command != 0) PostMessage(window, WM_SYSCOMMAND, command, 0);
}

LRESULT CALLBACK FlutterViewSubclassProc(HWND window,
                                         UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam,
                                         UINT_PTR subclass_id,
                                         DWORD_PTR ref_data) {
  auto* host = reinterpret_cast<Win32Window*>(ref_data);
  if (message == WM_SYSKEYDOWN && wparam == VK_SPACE && host != nullptr &&
      !host->IsFullscreen()) {
    SendMessage(host->GetHandle(), WM_SYSCOMMAND, SC_KEYMENU, VK_SPACE);
    return 0;
  } else if (message == WM_NCHITTEST && host != nullptr && host->GetHandle() != nullptr) {
    const LRESULT result = HitTestCustomFrame(host->GetHandle(), lparam, host->IsFullscreen());
    if (result != HTCLIENT) {
      return HTTRANSPARENT;
    }
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, FlutterViewSubclassProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = Win32Window::kWindowClassName;
    // 保留自绘窗口的系统阴影。
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return Win32Window::kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(Win32Window::kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;
  MONITORINFO monitor_info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(monitor, &monitor_info)) return false;
  const RECT work = monitor_info.rcWork;
  const int width = std::min(Scale(size.width, scale_factor),
                            static_cast<int>(work.right - work.left));
  const int height = std::min(Scale(size.height, scale_factor),
                             static_cast<int>(work.bottom - work.top));
  const int x = work.left + (work.right - work.left - width) / 2;
  const int y = work.top + (work.bottom - work.top - height) / 2;

  // 保留标准窗口的合成动画，标题栏仍由 WM_NCCALCSIZE 与 Flutter 绘制。
  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      x, y, width, height,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // 系统菜单沿用原对象，Caption 样式保留合成动画，按钮由 Flutter 绘制。
  GetSystemMenu(window, FALSE);
  SetWindowLongPtr(window, GWL_STYLE,
                   GetWindowLongPtr(window, GWL_STYLE) & ~WS_SYSMENU);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  UpdateTheme(window);
  DisableDwmBorder(window);

  // Windows 11 does not round corners of caption-less windows by default;
  // request rounded corners explicitly. Older systems ignore this attribute.
  constexpr DWORD kWindowCornerPreference = 33;
  constexpr INT kCornerRound = 2;
  DwmSetWindowAttribute(window,
                        static_cast<DWMWINDOWATTRIBUTE>(kWindowCornerPreference),
                        &kCornerRound, sizeof(kCornerRound));

  return OnCreate();
}

bool Win32Window::Show() {
  first_frame_ready_ = true;
  const bool shown = ShowWindow(window_handle_, SW_SHOWNORMAL);
  if (activation_pending_) RequestActivation();
  return shown;
}

void Win32Window::RequestActivation() {
  if (!first_frame_ready_) {
    activation_pending_ = true;
    return;
  }
  activation_pending_ = false;
  if (IsIconic(window_handle_)) ShowWindow(window_handle_, SW_RESTORE);
  if (!IsWindowVisible(window_handle_)) ShowWindow(window_handle_, SW_SHOWNORMAL);
  constexpr UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
  SetWindowPos(window_handle_, HWND_TOPMOST, 0, 0, 0, 0, flags);
  SetForegroundWindow(window_handle_);
  SetWindowPos(window_handle_, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
      // 最大化的系统边框位于屏幕外，客户区只覆盖可见区域。
      if (wparam && IsZoomed(hwnd)) {
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                           &monitor)) {
          auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
          params->rgrc[0] = IsFullscreen() ? monitor.rcMonitor : monitor.rcWork;
        }
      }
      return 0;

    case WM_NCACTIVATE:
      // Keep the custom border disabled while DWM updates backdrop state.
      // A -1 region suppresses only the transitional non-client repaint.
      DisableDwmBorder(hwnd);
      return DefWindowProc(hwnd, message, wparam, static_cast<LPARAM>(-1));

    case WM_NCHITTEST:
      // Preserve native resize, drag and double-click maximize semantics.
      return HitTestCustomFrame(hwnd, lparam, IsFullscreen());

    case WM_SYSCOMMAND:
      if (!IsFullscreen() && (wparam & 0xFFF0) == SC_KEYMENU &&
          lparam == VK_SPACE) {
        RECT bounds{};
        GetWindowRect(hwnd, &bounds);
        const int title_height = MulDiv(32, FlutterDesktopGetDpiForHWND(hwnd), 96);
        ShowWindowMenu(hwnd, {bounds.left, bounds.top + title_height});
        return 0;
      }
      break;

    case WM_NCRBUTTONUP:
      if (wparam == HTCAPTION && !IsFullscreen()) {
        ShowWindowMenu(hwnd, {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)});
        return 0;
      }
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (IsFullscreen() && GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
        newRectSize = &monitor.rcMonitor;
      }
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_GETMINMAXINFO: {
      // 最大化使用工作区，全屏使用整个显示器。
      auto* min_max_info = reinterpret_cast<MINMAXINFO*>(lparam);
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(MONITORINFO);
      if (::GetMonitorInfo(
              ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
              &monitor_info)) {
        const RECT bounds = IsFullscreen() ? monitor_info.rcMonitor : monitor_info.rcWork;
        min_max_info->ptMaxPosition.x = bounds.left - monitor_info.rcMonitor.left;
        min_max_info->ptMaxPosition.y = bounds.top - monitor_info.rcMonitor.top;
        min_max_info->ptMaxSize.x = bounds.right - bounds.left;
        min_max_info->ptMaxSize.y = bounds.bottom - bounds.top;
      }
      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, FlutterViewSubclassProc, kFlutterViewSubclassId,
                    reinterpret_cast<DWORD_PTR>(this));
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
