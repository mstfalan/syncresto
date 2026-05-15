#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // 15 May 2026 v1.4.0 fix: Eski GPU driver'lari (Intel HD 2014-2016 modeller)
  // D3D11 ile crash ediyor — flutter_windows.dll 0xc0000005 ACCESS_VIOLATION.
  // POS UI 3D olmadigindan software rendering varsayilan ACIK. Tum eski donanimi destekler.
  // FLUTTER_DISABLE_SW_RENDER=1 env ile devre disi birakilabilir (modern PC'ler isterse).
  char env_buf[64];
  size_t env_len = 0;
  bool disable_sw = (getenv_s(&env_len, env_buf, sizeof(env_buf), "FLUTTER_DISABLE_SW_RENDER") == 0
                     && env_len > 0 && env_buf[0] == '1');
  if (!disable_sw) {
    command_line_arguments.push_back("--enable-software-rendering");
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 15 May 2026 fix: pencereyi ekran ortasinda ac (multi-monitor / DPI sorunlarini onler)
  Win32Window::Size size(1280, 720);
  int screen_w = ::GetSystemMetrics(SM_CXSCREEN);
  int screen_h = ::GetSystemMetrics(SM_CYSCREEN);
  int x = (screen_w - 1280) / 2;
  int y = (screen_h - 720) / 2;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  Win32Window::Point origin(x, y);
  if (!window.Create(L"SyncResto POS", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
