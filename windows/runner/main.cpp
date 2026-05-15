#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <fstream>
#include <ctime>

#include "flutter_window.h"
#include "utils.h"

// 15 May 2026 v1.4.1 — Diagnostic logging
// Cikti: %TEMP%\syncresto_startup.log
static std::ofstream g_log;
static void OpenLog() {
  wchar_t temp[MAX_PATH] = {0};
  if (::GetTempPathW(MAX_PATH, temp) > 0) {
    std::wstring path = std::wstring(temp) + L"syncresto_startup.log";
    g_log.open(std::string(path.begin(), path.end()), std::ios::out | std::ios::app);
    if (g_log.is_open()) {
      time_t t = time(nullptr);
      char buf[64];
      strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime(&t));
      g_log << "\n=== SyncResto POS startup " << buf << " ===\n";
      g_log.flush();
    }
  }
}
static void Log(const char* msg) {
  if (g_log.is_open()) { g_log << msg << "\n"; g_log.flush(); }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  OpenLog();
  Log("[1] wWinMain entry");

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  Log("[2] AttachConsole done");

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Log("[3] CoInitializeEx done");

  flutter::DartProject project(L"data");
  Log("[4] DartProject created");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // 15 May 2026 v1.4.0 fix: Eski GPU driver'lari (Intel HD 2014-2016 modeller)
  // D3D11 ile crash ediyor — flutter_windows.dll 0xc0000005 ACCESS_VIOLATION.
  // POS UI 3D olmadigindan software rendering varsayilan ACIK.
  char env_buf[64];
  size_t env_len = 0;
  bool disable_sw = (getenv_s(&env_len, env_buf, sizeof(env_buf), "FLUTTER_DISABLE_SW_RENDER") == 0
                     && env_len > 0 && env_buf[0] == '1');
  if (!disable_sw) {
    command_line_arguments.push_back("--enable-software-rendering");
    Log("[5] software rendering enabled");
  } else {
    Log("[5] hardware rendering (env override)");
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  Log("[6] entrypoint args set");

  FlutterWindow window(project);
  Log("[7] FlutterWindow object created");

  Win32Window::Size size(1280, 720);
  int screen_w = ::GetSystemMetrics(SM_CXSCREEN);
  int screen_h = ::GetSystemMetrics(SM_CYSCREEN);
  int x = (screen_w - 1280) / 2;
  int y = (screen_h - 720) / 2;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  Win32Window::Point origin(x, y);

  {
    char buf[128];
    snprintf(buf, sizeof(buf), "[8] screen=%dx%d window origin=%d,%d size=1280x720", screen_w, screen_h, x, y);
    Log(buf);
  }

  if (!window.Create(L"SyncResto POS", origin, size)) {
    Log("[X] window.Create() FAILED");
    ::MessageBoxW(nullptr, L"SyncResto POS: Pencere olusturulamadi.\nBu PC'de Flutter Windows desteklenmiyor olabilir.", L"SyncResto POS", MB_ICONERROR);
    return EXIT_FAILURE;
  }
  Log("[9] window.Create() OK");

  // 15 May 2026 v1.4.1: Pencereyi acik bir sekilde goster (Show implicit calismayabilir)
  HWND hwnd = window.GetHandle();
  if (hwnd) {
    ::ShowWindow(hwnd, SW_SHOWNORMAL);
    ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
    ::BringWindowToTop(hwnd);
    ::SetActiveWindow(hwnd);
    Log("[10] Show + Foreground done");
  } else {
    Log("[X] window.GetHandle() returned null");
    ::MessageBoxW(nullptr, L"SyncResto POS: Pencere handle alinamadi.", L"SyncResto POS", MB_ICONERROR);
  }

  window.SetQuitOnClose(true);
  Log("[11] message loop starting");

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  Log("[12] message loop exited");
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
