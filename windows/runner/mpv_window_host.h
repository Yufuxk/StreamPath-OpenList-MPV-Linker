#ifndef RUNNER_MPV_WINDOW_HOST_H_
#define RUNNER_MPV_WINDOW_HOST_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <functional>
#include <map>
#include <memory>

// 原生视频容器不负责启动、结束或恢复媒体会话。
class MpvWindowHost {
 public:
  MpvWindowHost(flutter::BinaryMessenger* messenger, HWND root, HWND flutter_view,
                std::function<bool(bool)> fullscreen,
                std::function<bool()> is_fullscreen);
  ~MpvWindowHost();
  void NotifyWindowState();
  bool Focus();
  bool HandleSystemCommand(WPARAM command);
  HWND root() const { return root_; }
  bool is_fullscreen() const { return is_fullscreen_(); }

 private:
  struct Surface {
    HWND window = nullptr;
    DWORD pid = 0;
    int64_t creation = 0;
    bool menu_installed = false;
    HWND player = nullptr;
  };
  static LRESULT CALLBACK FlutterViewProc(HWND window, UINT message,
      WPARAM wparam, LPARAM lparam, UINT_PTR subclass_id, DWORD_PTR ref_data);
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  HWND root_;
  HWND flutter_view_;
  std::function<bool(bool)> fullscreen_;
  std::function<bool()> is_fullscreen_;
  std::map<int64_t, Surface> surfaces_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
