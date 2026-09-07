#include "flutter_window.h"

#include <windows.h>
#include <dwmapi.h>
#include <optional>
#include <shobjidl.h>
#include <winternl.h>
#include <wrl/client.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

struct WindowsVersion {
  DWORD major = 0;
  DWORD minor = 0;
  DWORD build = 0;
};

WindowsVersion ReadWindowsVersion() {
  RTL_OSVERSIONINFOW version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  const HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) {
    return {};
  }
  using RtlGetVersionFunction = LONG(WINAPI*)(RTL_OSVERSIONINFOW*);
  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFunction>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (rtl_get_version == nullptr || rtl_get_version(&version) != 0) {
    return {};
  }
  return {version.dwMajorVersion, version.dwMinorVersion,
          version.dwBuildNumber};
}

bool ReadTransparencyEnabled() {
  DWORD enabled = 1;
  DWORD size = sizeof(enabled);
  const LSTATUS status = ::RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"EnableTransparency", RRF_RT_REG_DWORD, nullptr, &enabled, &size);
  return status == ERROR_SUCCESS ? enabled != 0 : true;
}

bool ReadHighContrastEnabled() {
  HIGHCONTRASTW high_contrast = {};
  high_contrast.cbSize = sizeof(high_contrast);
  if (!::SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(high_contrast),
                               &high_contrast, 0)) {
    return false;
  }
  return (high_contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

flutter::EncodableValue ReadWindowCapabilities(HWND window) {
  const WindowsVersion version = ReadWindowsVersion();
  BOOL composition_enabled = FALSE;
  const bool composition_available =
      SUCCEEDED(::DwmIsCompositionEnabled(&composition_enabled)) &&
      composition_enabled != FALSE;

  constexpr DWORD kSystemBackdropType = 38;
  INT system_backdrop_type = 0;
  if (version.major >= 10 && version.build >= 22523) {
    ::DwmGetWindowAttribute(
        window, static_cast<DWMWINDOWATTRIBUTE>(kSystemBackdropType),
        &system_backdrop_type, sizeof(system_backdrop_type));
  }

  flutter::EncodableMap capabilities;
  capabilities[flutter::EncodableValue("platformSupported")] =
      flutter::EncodableValue(true);
  capabilities[flutter::EncodableValue("versionMajor")] =
      flutter::EncodableValue(static_cast<int32_t>(version.major));
  capabilities[flutter::EncodableValue("versionMinor")] =
      flutter::EncodableValue(static_cast<int32_t>(version.minor));
  capabilities[flutter::EncodableValue("buildNumber")] =
      flutter::EncodableValue(static_cast<int32_t>(version.build));
  capabilities[flutter::EncodableValue("compositionEnabled")] =
      flutter::EncodableValue(composition_available);
  capabilities[flutter::EncodableValue("transparencyEnabled")] =
      flutter::EncodableValue(ReadTransparencyEnabled());
  capabilities[flutter::EncodableValue("highContrast")] =
      flutter::EncodableValue(ReadHighContrastEnabled());
  capabilities[flutter::EncodableValue("remoteSession")] =
      flutter::EncodableValue(::GetSystemMetrics(SM_REMOTESESSION) != 0);
  capabilities[flutter::EncodableValue("supportsLegacyAcrylic")] =
      flutter::EncodableValue(version.major >= 10 && version.build >= 17134);
  capabilities[flutter::EncodableValue("supportsMica")] =
      flutter::EncodableValue(version.major >= 10 && version.build >= 22000);
  capabilities[flutter::EncodableValue("supportsSystemBackdrop")] =
      flutter::EncodableValue(version.major >= 10 && version.build >= 22523);
  capabilities[flutter::EncodableValue("systemBackdropType")] =
      flutter::EncodableValue(static_cast<int32_t>(system_backdrop_type));
  return flutter::EncodableValue(capabilities);
}

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring converted(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), converted.data(),
                            length) <= 0) {
    return {};
  }
  return converted;
}

HRESULT PickDirectory(HWND owner, const std::wstring& title,
                      std::string* selected_path) {
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT result = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&dialog));
  if (FAILED(result)) {
    return result;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  result = dialog->GetOptions(&options);
  if (FAILED(result)) {
    return result;
  }
  result = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                              FOS_PATHMUSTEXIST);
  if (FAILED(result)) {
    return result;
  }
  if (!title.empty()) {
    result = dialog->SetTitle(title.c_str());
    if (FAILED(result)) {
      return result;
    }
  }

  result = dialog->Show(owner);
  if (FAILED(result)) {
    return result;
  }

  Microsoft::WRL::ComPtr<IShellItem> item;
  result = dialog->GetResult(&item);
  if (FAILED(result)) {
    return result;
  }
  PWSTR display_name = nullptr;
  result = item->GetDisplayName(SIGDN_FILESYSPATH, &display_name);
  if (FAILED(result)) {
    return result;
  }
  *selected_path = Utf8FromUtf16(display_name);
  ::CoTaskMemFree(display_name);
  return S_OK;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Win+V clipboard history fallback: watch clipboard changes so the Dart
  // side can paste the content into the focused text field even when the
  // key sequence injected by Windows is swallowed by the Flutter engine.
  // (Clipboard history always writes the picked entry back to the clipboard,
  // which fires WM_CLIPBOARDUPDATE.)
  AddClipboardFormatListener(GetHandle());
  clipboard_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "streampath/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  appearance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "streampath/appearance",
          &flutter::StandardMethodCodec::GetInstance());
  folder_picker_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "streampath/folder_picker",
          &flutter::StandardMethodCodec::GetInstance());
  folder_picker_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "pickDirectory") {
          result->NotImplemented();
          return;
        }
        std::string title;
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments != nullptr) {
          const auto entry =
              arguments->find(flutter::EncodableValue("title"));
          if (entry != arguments->end()) {
            if (const auto* value = std::get_if<std::string>(&entry->second)) {
              title = *value;
            }
          }
        }
        std::string selected_path;
        const HRESULT picker_result =
            PickDirectory(GetHandle(), Utf16FromUtf8(title), &selected_path);
        if (picker_result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          result->Success();
          return;
        }
        if (FAILED(picker_result)) {
          result->Error("folder_picker_failed",
                        "Windows folder picker failed",
                        flutter::EncodableValue(
                            static_cast<int64_t>(picker_result)));
          return;
        }
        result->Success(flutter::EncodableValue(selected_path));
      });
  appearance_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const std::string method = call.method_name();

        // Window controls for the custom Flutter title bar.
        if (method == "minimize") {
          ::ShowWindow(GetHandle(), SW_MINIMIZE);
          result->Success();
          return;
        }
        if (method == "toggleMaximize") {
          const HWND window = GetHandle();
          ::ShowWindow(window, ::IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
          const auto maximized =
              flutter::EncodableValue(::IsZoomed(window) != FALSE);
          result->Success(maximized);
          return;
        }
        if (method == "isMaximized") {
          const auto maximized =
              flutter::EncodableValue(::IsZoomed(GetHandle()) != FALSE);
          result->Success(maximized);
          return;
        }
        if (method == "close") {
          ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (method == "setFrameColor") {
          // Keep the rounded fill aligned with Flutter, but always suppress
          // the native border. DWM cannot use an alpha caption color.
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments) {
            const auto r_entry = arguments->find(flutter::EncodableValue("r"));
            const auto g_entry = arguments->find(flutter::EncodableValue("g"));
            const auto b_entry = arguments->find(flutter::EncodableValue("b"));
            const auto a_entry = arguments->find(flutter::EncodableValue("a"));
            if (r_entry != arguments->end() && g_entry != arguments->end() &&
                b_entry != arguments->end()) {
              constexpr COLORREF kColorNone = 0xFFFFFFFE;
              const COLORREF caption_color =
                  a_entry != arguments->end() &&
                          std::get<int32_t>(a_entry->second) < 255
                      ? kColorNone
                      : RGB(std::get<int32_t>(r_entry->second),
                            std::get<int32_t>(g_entry->second),
                            std::get<int32_t>(b_entry->second));
              constexpr DWORD kFrameBorderColor = 34;
              constexpr DWORD kFrameCaptionColor = 35;
              const HWND window = GetHandle();
              ::DwmSetWindowAttribute(
                  window, static_cast<DWMWINDOWATTRIBUTE>(kFrameBorderColor),
                  &kColorNone, sizeof(kColorNone));
              ::DwmSetWindowAttribute(
                  window, static_cast<DWMWINDOWATTRIBUTE>(kFrameCaptionColor),
                  &caption_color, sizeof(caption_color));
            }
          }
          result->Success();
          return;
        }

        if (method == "getWindowCapabilities") {
          result->Success(ReadWindowCapabilities(GetHandle()));
          return;
        }

        if (method != "resetWindowEffect") {
          result->NotImplemented();
          return;
        }

        bool dark = false;
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments) {
          const auto dark_entry =
              arguments->find(flutter::EncodableValue("dark"));
          if (dark_entry != arguments->end()) {
            dark = std::get<bool>(dark_entry->second);
          }
        }

        constexpr DWORD kUseImmersiveDarkMode = 20;
        constexpr DWORD kBorderColor = 34;
        constexpr DWORD kCaptionColor = 35;
        constexpr DWORD kSystemBackdropType = 38;
        constexpr INT kBackdropNone = 1;
        constexpr COLORREF kDefaultCaptionColor = 0xFFFFFFFF;
        constexpr COLORREF kColorNone = 0xFFFFFFFE;
        const BOOL dark_mode = dark ? TRUE : FALSE;
        const MARGINS margins = {0, 0, 1, 0};
        const HWND window = GetHandle();
        ::DwmExtendFrameIntoClientArea(window, &margins);
        ::DwmSetWindowAttribute(
            window, static_cast<DWMWINDOWATTRIBUTE>(kSystemBackdropType),
            &kBackdropNone, sizeof(kBackdropNone));
        ::DwmSetWindowAttribute(
            window, static_cast<DWMWINDOWATTRIBUTE>(kBorderColor),
            &kColorNone, sizeof(kColorNone));
        ::DwmSetWindowAttribute(
            window, static_cast<DWMWINDOWATTRIBUTE>(kCaptionColor),
            &kDefaultCaptionColor, sizeof(kDefaultCaptionColor));
        ::DwmSetWindowAttribute(
            window, static_cast<DWMWINDOWATTRIBUTE>(kUseImmersiveDarkMode),
            &dark_mode, sizeof(dark_mode));
        ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                           SWP_NOACTIVATE | SWP_FRAMECHANGED);
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveClipboardFormatListener(GetHandle());
  folder_picker_channel_.reset();
  appearance_channel_.reset();
  clipboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE: {
      // Keep the Dart-side title bar in sync with the maximize state
      // (switches between the maximize and restore icons).
      if (appearance_channel_) {
        const bool maximized = wparam == SIZE_MAXIMIZED;
        if (maximized != last_maximize_state_) {
          last_maximize_state_ = maximized;
          appearance_channel_->InvokeMethod(
              "maximizeChanged",
              std::make_unique<flutter::EncodableValue>(maximized));
        }
      }
      break;
    }
    case WM_CLIPBOARDUPDATE: {
      // Clipboard content changed. Notify Dart (which reads the text via
      // super_clipboard): it keeps an in-app clipboard history (right-click
      // menu of text fields) and auto-pastes when the change matches the
      // clipboard-history pick signature.
      if (clipboard_channel_) {
        clipboard_channel_->InvokeMethod("clipboardChanged", nullptr);
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
