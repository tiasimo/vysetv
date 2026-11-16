#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>
#include <vector>

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

  // "vyse/taskbar": flash the taskbar button, and the unread badge on it (Party messages).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> taskbar_channel_;

  // "vyse/process": helper processes (the torrent engine) that must die with VyseTV, however it
  // ends. They go in a job object that kills everything in it when its last handle closes, which
  // Windows does itself when this process exits, crashes or is ended from Task Manager.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> process_channel_;
  // Installed font families, for Settings > Subtitles (libass finds them by name).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> fonts_channel_;
  HANDLE kill_job_ = nullptr;
  HICON badge_icon_ = nullptr;
  void SetBadge(const std::vector<uint8_t>* rgba, int width, int height, const std::wstring& label);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
