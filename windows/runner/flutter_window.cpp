#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>

#include "flutter/generated_plugin_registrant.h"
#include "mpv/display_mode_manager.h"
#include "mpv/mpv_plugin.h"

namespace {

// A 32-bit icon from straight (not premultiplied) RGBA pixels.
HICON IconFromRgba(const std::vector<uint8_t>& rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.size() < static_cast<size_t>(width) * height * 4) return nullptr;
  BITMAPV5HEADER bi = {};
  bi.bV5Size = sizeof(bi);
  bi.bV5Width = width;
  bi.bV5Height = -height;  // top-down
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;
  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, dc);
  if (!color || !bits) return nullptr;
  auto* px = static_cast<uint8_t*>(bits);
  for (size_t i = 0; i < static_cast<size_t>(width) * height; i++) {
    px[i * 4 + 0] = rgba[i * 4 + 2];  // B
    px[i * 4 + 1] = rgba[i * 4 + 1];  // G
    px[i * 4 + 2] = rgba[i * 4 + 0];  // R
    px[i * 4 + 3] = rgba[i * 4 + 3];  // A
  }
  HBITMAP mask = CreateBitmap(width, height, 1, 1, nullptr);
  ICONINFO ii = {};
  ii.fIcon = TRUE;
  ii.hbmMask = mask;
  ii.hbmColor = color;
  HICON icon = CreateIconIndirect(&ii);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

// Every installed font family, sorted, without the vertical-writing "@" twins.
int CALLBACK CollectFontFamily(const LOGFONTW* lf, const TEXTMETRICW*, DWORD, LPARAM param) {
  if (lf->lfFaceName[0] != L'@') reinterpret_cast<std::set<std::wstring>*>(param)->insert(lf->lfFaceName);
  return 1;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
  return out;
}

flutter::EncodableList InstalledFontFamilies() {
  std::set<std::wstring> names;
  LOGFONTW lf = {};
  lf.lfCharSet = DEFAULT_CHARSET;
  HDC dc = GetDC(nullptr);
  EnumFontFamiliesExW(dc, &lf, CollectFontFamily, reinterpret_cast<LPARAM>(&names), 0);
  ReleaseDC(nullptr, dc);
  std::vector<std::string> sorted;
  for (const auto& n : names) sorted.push_back(Utf8(n));
  std::sort(sorted.begin(), sorted.end(), [](const std::string& a, const std::string& b) {
    return _stricmp(a.c_str(), b.c_str()) < 0;
  });
  flutter::EncodableList list;
  for (const auto& n : sorted) list.push_back(flutter::EncodableValue(n));
  return list;
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

  // Plezy's mpv player (video + music cores), see windows/runner/mpv/.
  MpvPlayerPluginRegisterWithRegistrar(flutter_controller_->engine()->GetRegistrarForPlugin("MpvPlayerPlugin"));
  MpvAudioPlayerPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("MpvAudioPlayerPlugin"));
  MpvAudio2PlayerPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("MpvAudio2PlayerPlugin"));

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // helper processes that live and die with VyseTV
  process_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "vyse/process",
      &flutter::StandardMethodCodec::GetInstance());
  process_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "adopt") return result->NotImplemented();
        const auto* pid = std::get_if<int32_t>(call.arguments());
        if (!pid) return result->Error("bad-args", "adopt takes a process id");
        if (!kill_job_) {
          kill_job_ = CreateJobObjectW(nullptr, nullptr);
          if (kill_job_) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(kill_job_, JobObjectExtendedLimitInformation, &info, sizeof(info));
          }
        }
        bool ok = false;
        if (kill_job_) {
          HANDLE proc = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, static_cast<DWORD>(*pid));
          if (proc) {
            ok = AssignProcessToJobObject(kill_job_, proc) != FALSE;
            CloseHandle(proc);
          }
        }
        result->Success(flutter::EncodableValue(ok));
      });

  // Settings > Subtitles: the fonts libass can use here
  fonts_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "vyse/fonts",
      &flutter::StandardMethodCodec::GetInstance());
  fonts_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "families") return result->NotImplemented();
        result->Success(flutter::EncodableValue(InstalledFontFamilies()));
      });

  // Party: flash the taskbar button for a message, and show the unread count on it
  taskbar_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "vyse/taskbar",
      &flutter::StandardMethodCodec::GetInstance());
  taskbar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HWND hwnd = GetHandle();
        if (call.method_name() == "flash") {
          // orange until the window comes to the front, like Discord
          if (hwnd && GetForegroundWindow() != hwnd) {
            FLASHWINFO fi = {};
            fi.cbSize = sizeof(fi);
            fi.hwnd = hwnd;
            fi.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
            FlashWindowEx(&fi);
          }
          result->Success();
        } else if (call.method_name() == "badge") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            SetBadge(nullptr, 0, 0, L"");
            return result->Success();
          }
          auto get = [args](const char* key) -> const flutter::EncodableValue* {
            auto it = args->find(flutter::EncodableValue(key));
            return it == args->end() ? nullptr : &it->second;
          };
          const auto* w = get("w");
          const auto* h = get("h");
          const auto* px = get("rgba");
          const auto* label = get("label");
          std::wstring text;
          if (label) {
            if (const auto* l = std::get_if<std::string>(label)) text.assign(l->begin(), l->end());
          }
          if (w && h && px && std::holds_alternative<int32_t>(*w) && std::holds_alternative<int32_t>(*h) &&
              std::holds_alternative<std::vector<uint8_t>>(*px)) {
            SetBadge(&std::get<std::vector<uint8_t>>(*px), std::get<int32_t>(*w), std::get<int32_t>(*h), text);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
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

void FlutterWindow::SetBadge(const std::vector<uint8_t>* rgba, int width, int height, const std::wstring& label) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ITaskbarList3* taskbar = nullptr;
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar))) || !taskbar) return;
  if (SUCCEEDED(taskbar->HrInit())) {
    HICON icon = rgba ? IconFromRgba(*rgba, width, height) : nullptr;
    taskbar->SetOverlayIcon(hwnd, icon, icon ? label.c_str() : nullptr);
    if (badge_icon_) DestroyIcon(badge_icon_);
    badge_icon_ = icon;
  }
  taskbar->Release();
}

void FlutterWindow::OnDestroy() {
  taskbar_channel_ = nullptr;
  fonts_channel_ = nullptr;
  if (badge_icon_) {
    DestroyIcon(badge_icon_);
    badge_icon_ = nullptr;
  }
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
    case WM_DISPLAYCHANGE:
      // One bounded, serialized retry for a display that may have reconnected.
      mpv::DisplayModeManager::RecoverIfNeeded();
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
