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
  char temp[MAX_PATH] = {0};
  if (::GetTempPathA(MAX_PATH, temp) > 0) {
    std::string path = std::string(temp) + "syncresto_startup.log";
    g_log.open(path, std::ios::out | std::ios::app);
    if (g_log.is_open()) {
      time_t t = time(nullptr);
      struct tm tm_info;
      char buf[64] = {0};
      if (localtime_s(&tm_info, &t) == 0) {
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tm_info);
      }
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

  // 15 May 2026 v1.4.3: Pencere ekrana otomatik sigsin
  // Onceki sorun: 1024x768 ekranda 1280x720 sigmiyordu, beyaz ekran kaliyordu
  // SystemParametersInfo ile working area al (taskbar haric kullanilabilir alan)
  RECT work_area = {0};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  int work_w = work_area.right - work_area.left;
  int work_h = work_area.bottom - work_area.top;

  // POS UI ekranin %95'i (kucuk ve buyuk her ekranda dolu gozuksun)
  int win_w = (int)(work_w * 0.95);
  int win_h = (int)(work_h * 0.95);
  // Cok kucuk ekranlarda (800x600 alti — POS tabletleri) tam kapla
  if (work_w < 1024) win_w = work_w;
  if (work_h < 768)  win_h = work_h;
  // Minimum guvenli boyut
  if (win_w < 800) win_w = 800;
  if (win_h < 600) win_h = 600;

  // Working area'da ortala
  int x = work_area.left + (work_w - win_w) / 2;
  int y = work_area.top  + (work_h - win_h) / 2;
  if (x < work_area.left) x = work_area.left;
  if (y < work_area.top)  y = work_area.top;

  Win32Window::Size size(win_w, win_h);
  Win32Window::Point origin(x, y);

  {
    char buf[200];
    snprintf(buf, sizeof(buf), "[8] workarea=%dx%d window=%dx%d origin=%d,%d", work_w, work_h, win_w, win_h, x, y);
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
