#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "mpv/display_mode_manager.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Plezy's player: the patched flutter-plezy engine (windows/tool/
  // install-patched-engine.ps1) draws the Flutter UI on a topmost
  // DirectComposition layer when this is set, so mpv's video window sits
  // beneath the UI in the same HWND. Must be set before the engine is created.
  // On a stock engine this does nothing and the video stays hidden (the CMake
  // install step refuses to bundle a stock engine for that reason).
  ::SetEnvironmentVariableW(L"FLUTTER_WINDOWS_DCOMP", L"1");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Flutter 3.47 made Impeller the Windows default (OpenGL ES via ANGLE). Its frame times on the
  // spotlight transition measured far worse than Skia's, so stay on Skia for now.
  // Plezy's player also needs Skia here: Impeller's GLES backend gets the per-pixel alpha wrong on
  // some drivers, and the video under the UI turns black while controls are shown (plezy #2127).
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"VyseTV", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Undo a refresh-rate/HDR switch a crashed playback session left behind.
  mpv::DisplayModeManager::RecoverIfNeeded();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
