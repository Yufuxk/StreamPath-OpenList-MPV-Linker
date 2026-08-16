#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Channel used to deliver clipboard changes (Win+V clipboard history
  // fallback: every WM_CLIPBOARDUPDATE is forwarded to Dart, which reads
  // the text via super_clipboard, keeps an in-app clipboard history menu
  // and auto-pastes when the change happens right around (re)gaining focus).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;

  // Controls the custom title bar and queries or resets window backdrops.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      appearance_channel_;

  // Last maximize state pushed to Dart, used to filter duplicate WM_SIZE
  // notifications.
  bool last_maximize_state_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
