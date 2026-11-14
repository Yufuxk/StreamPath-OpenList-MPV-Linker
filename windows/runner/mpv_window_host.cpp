#include "mpv_window_host.h"

#include <commctrl.h>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kMenuDetach = 0x1f10;
constexpr UINT kMenuStop = 0x1f20;
constexpr UINT kMenuSeparator = 0x1f30;
constexpr UINT kMenuFullscreen = 0x1f40;
constexpr UINT_PTR kSurfaceSubclassId = 1;
LRESULT CALLBACK SurfaceWindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam, UINT_PTR subclass_id,
                                   DWORD_PTR) {
  if (message == WM_ERASEBKGND) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    FillRect(reinterpret_cast<HDC>(wparam), &bounds,
             static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    return 1;
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    const HDC dc = BeginPaint(window, &paint);
    FillRect(dc, &paint.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    EndPaint(window, &paint);
    return 0;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, SurfaceWindowProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}
std::wstring MenuText(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  if (it == args.end()) return {};
  const auto* text = std::get_if<std::string>(&it->second);
  if (!text) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, text->data(),
      static_cast<int>(text->size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text->data(), static_cast<int>(text->size()),
      result.data(), size);
  return result;
}
int64_t Integer(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  if (it == args.end()) return 0;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  return 0;
}
bool Boolean(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  return it != args.end() && std::holds_alternative<bool>(it->second) &&
         std::get<bool>(it->second);
}
bool OwnedWindow(HWND window, DWORD pid) {
  DWORD actual = 0;
  GetWindowThreadProcessId(window, &actual);
  return IsWindow(window) && actual == pid;
}
bool SameProcess(DWORD pid, int64_t creation) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, pid);
  if (!process) return false;
  FILETIME created{}, exited{}, kernel{}, user{};
  const bool matches = WaitForSingleObject(process, 0) == WAIT_TIMEOUT &&
      GetProcessTimes(process, &created, &exited, &kernel, &user) &&
      static_cast<int64_t>((static_cast<uint64_t>(created.dwHighDateTime) << 32) |
                           created.dwLowDateTime) == creation;
  CloseHandle(process);
  return matches;
}
HWND ChildFor(HWND host, DWORD pid) {
  for (HWND child = GetWindow(host, GW_CHILD); child;
       child = GetWindow(child, GW_HWNDNEXT)) {
    if (OwnedWindow(child, pid)) return child;
  }
  return nullptr;
}
}  // namespace

MpvWindowHost::MpvWindowHost(flutter::BinaryMessenger* messenger, HWND root,
    std::function<bool(bool)> fullscreen, std::function<bool()> is_fullscreen)
    : root_(root), fullscreen_(std::move(fullscreen)),
      is_fullscreen_(std::move(is_fullscreen)) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "streampath/mpv_window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
}

MpvWindowHost::~MpvWindowHost() {
  channel_->SetMethodCallHandler(nullptr);
}

void MpvWindowHost::NotifyWindowState() {
  if (surfaces_.empty()) return;
  channel_->InvokeMethod("windowState", std::make_unique<Value>(Map{
      {Value("fullscreen"), Value(is_fullscreen_())},
      {Value("window-maximized"), Value(IsZoomed(root_) != FALSE)},
      {Value("window-minimized"), Value(IsIconic(root_) != FALSE)}}));
}

bool MpvWindowHost::Focus() {
  for (auto& entry : surfaces_) {
    auto& surface = entry.second;
    if (IsWindowVisible(surface.window) &&
        OwnedWindow(surface.player, surface.pid)) {
      SetFocus(surface.player);
      return true;
    }
  }
  return false;
}

bool MpvWindowHost::HandleSystemCommand(WPARAM command) {
  if (command != kMenuDetach && command != kMenuStop &&
      command != kMenuFullscreen) return false;
  for (const auto& entry : surfaces_) {
    const auto& surface = entry.second;
    if (surface.menu_installed && SameProcess(surface.pid, surface.creation)) {
      channel_->InvokeMethod("menuAction", std::make_unique<Value>(Map{
          {Value("host"), Value(entry.first)},
          {Value("action"), Value(command == kMenuDetach ? "detach" :
              command == kMenuStop ? "stop" : "fullscreen")}}));
      return true;
    }
  }
  return false;
}

void MpvWindowHost::Handle(const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (call.method_name() == "create") {
    // STATIC 的黑色表面与 Flutter 保持独立的原生裁剪区域。
    HWND host = CreateWindowExW(0, L"STATIC", L"StreamPath MPV surface",
        WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | SS_BLACKRECT,
        0, 0, 640, 360, root_, nullptr, GetModuleHandle(nullptr), nullptr);
    if (!host) {
      result->Error("surface_create", "Unable to create MPV surface");
      return;
    }
    if (!SetWindowSubclass(host, SurfaceWindowProc, kSurfaceSubclassId, 0)) {
      DestroyWindow(host);
      result->Error("surface_create", "Unable to initialize MPV surface");
      return;
    }
    const auto id = static_cast<int64_t>(reinterpret_cast<uintptr_t>(host));
    surfaces_.emplace(id, Surface{host});
    result->Success(Value(id));
    return;
  }
  if (call.method_name() == "fullscreen") {
    if (!args || !fullscreen_(Boolean(*args, "enabled"))) {
      result->Error("fullscreen_failed", "Unable to change fullscreen state");
    } else {
      NotifyWindowState();
      result->Success();
    }
    return;
  }
  if (call.method_name() == "state") {
    result->Success(Value(Map{
        {Value("fullscreen"), Value(is_fullscreen_())},
        {Value("window-maximized"), Value(IsZoomed(root_) != FALSE)},
        {Value("window-minimized"), Value(IsIconic(root_) != FALSE)}}));
    return;
  }
  if (!args) {
    result->Error("invalid_arguments", "Missing MPV window arguments");
    return;
  }
  const auto found = surfaces_.find(Integer(*args, "host"));
  if (found == surfaces_.end()) {
    result->Error("surface_missing", "MPV surface no longer exists");
    return;
  }
  auto& surface = found->second;
  const auto& method = call.method_name();
  if (method == "menuInstall") {
    const auto detach = MenuText(*args, "detach");
    const auto stop = MenuText(*args, "stop");
    const auto fullscreen = MenuText(*args, "fullscreen");
    const HMENU menu = GetSystemMenu(root_, FALSE);
    if (!menu || detach.empty() || stop.empty() || fullscreen.empty()) {
      result->Error("menu_install", "Unable to install window menu");
      return;
    }
    if (!surface.menu_installed) {
      MENUITEMINFOW separator{};
      separator.cbSize = sizeof(separator);
      separator.fMask = MIIM_FTYPE | MIIM_ID;
      separator.fType = MFT_SEPARATOR;
      separator.wID = kMenuSeparator;
      if (!InsertMenuItemW(menu, GetMenuItemCount(menu), TRUE, &separator) ||
          !AppendMenuW(menu, MF_STRING, kMenuFullscreen, fullscreen.c_str()) ||
          !AppendMenuW(menu, MF_STRING, kMenuDetach, detach.c_str()) ||
          !AppendMenuW(menu, MF_STRING, kMenuStop, stop.c_str())) {
        DeleteMenu(menu, kMenuFullscreen, MF_BYCOMMAND);
        DeleteMenu(menu, kMenuDetach, MF_BYCOMMAND);
        DeleteMenu(menu, kMenuStop, MF_BYCOMMAND);
        DeleteMenu(menu, kMenuSeparator, MF_BYCOMMAND);
        result->Error("menu_install", "Unable to install window menu");
        return;
      }
      surface.menu_installed = true;
      SetPropW(root_, L"StreamPathMpvActive", reinterpret_cast<HANDLE>(1));
    }
    result->Success();
  } else if (method == "bind") {
    const auto pid = static_cast<DWORD>(Integer(*args, "pid"));
    const auto creation = Integer(*args, "creation");
    if (!SameProcess(pid, creation)) {
      result->Success(Value(false));
      return;
    }
    surface.pid = pid;
    surface.creation = creation;
    HWND child = ChildFor(surface.window, pid);
    if (!child || !AreDpiAwarenessContextsEqual(
            GetWindowDpiAwarenessContext(root_), GetWindowDpiAwarenessContext(child))) {
      result->Success(Value(false));
      return;
    }
    surface.player = child;
    EnableWindow(child, TRUE);
    result->Success(Value(true));
  } else if (method == "bounds") {
    // 布局坐标已由 FlutterView 的 DPR 转为物理像素。
    auto pixel = [&](const char* key) { return static_cast<int>(Integer(*args, key)); };
    SetWindowPos(surface.window, HWND_TOP, pixel("x"), pixel("y"),
                 pixel("width"), pixel("height"), SWP_NOACTIVATE);
    if (OwnedWindow(surface.player, surface.pid)) {
      RECT bounds{};
      GetClientRect(surface.window, &bounds);
      SetWindowPos(surface.player, nullptr, 0, 0, bounds.right, bounds.bottom,
          SWP_NOACTIVATE | SWP_NOZORDER | SWP_ASYNCWINDOWPOS);
    }
    result->Success();
  } else if (method == "visible") {
    ShowWindow(surface.window, Boolean(*args, "enabled") ? SW_SHOWNOACTIVATE : SW_HIDE);
    result->Success();
  } else if (method == "focus") {
    result->Success(Value(Focus()));
  } else if (method == "detached") {
    HWND player = reinterpret_cast<HWND>(static_cast<uintptr_t>(Integer(*args, "window")));
    const bool detached = SameProcess(surface.pid, surface.creation) &&
        OwnedWindow(player, surface.pid) && !IsChild(surface.window, player) &&
        !(GetWindowLongPtr(player, GWL_STYLE) & WS_CHILD) &&
        GetWindow(player, GW_OWNER) == nullptr &&
        GetAncestor(player, GA_ROOT) == player;
    result->Success(Value(detached));
  } else if (method == "release") {
    // 不销毁仍有播放器子窗口的容器。
    if (GetWindow(surface.window, GW_CHILD)) {
      result->Error("surface_in_use", "MPV is still attached to this surface");
      return;
    }
    if (surface.menu_installed) {
      const HMENU menu = GetSystemMenu(root_, FALSE);
      DeleteMenu(menu, kMenuDetach, MF_BYCOMMAND);
      DeleteMenu(menu, kMenuStop, MF_BYCOMMAND);
      DeleteMenu(menu, kMenuFullscreen, MF_BYCOMMAND);
      DeleteMenu(menu, kMenuSeparator, MF_BYCOMMAND);
      RemovePropW(root_, L"StreamPathMpvActive");
    }
    DestroyWindow(surface.window);
    surfaces_.erase(found);
    result->Success();
  } else if (method == "minimize" || method == "maximize") {
    if (method == "minimize") {
      ShowWindow(root_, Boolean(*args, "enabled") ? SW_MINIMIZE : SW_RESTORE);
    } else {
      if (is_fullscreen_()) fullscreen_(false);
      ShowWindow(root_, Boolean(*args, "enabled") ? SW_MAXIMIZE : SW_RESTORE);
    }
    NotifyWindowState();
    result->Success();
  } else {
    result->NotImplemented();
  }
}
