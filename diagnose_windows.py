"""
SyncResto POS — Windows Tani Scripti
================================================================
Calistirma:  python diagnose_windows.py
Cikti:       diagnose_log.txt + ekrana yazar
Kullanim:    Logu Mustafa'ya gonder

Toplananlar:
- Windows surum + ekran cozunurlugu + DPI scaling
- Calisan SyncResto POS process'leri (zombi var mi)
- Pencere konumu/boyutu (ekran disinda mi, minimize mi, gizli mi)
- Tray icon / single instance lock dosyalari
- AppData altindaki Flutter uygulama klasorleri
- SharedPreferences icerigi (varsa)
- Son uygulama log'lari
- DirectX/OpenGL desteği (Flutter Skia icin)
- Kullanici PATH + Windows Defender / Antivirus klasor karantina
"""
import os
import sys
import json
import subprocess
import platform
import datetime
import traceback
from pathlib import Path

LOG_FILE = "diagnose_log.txt"
APP_NAMES = ["SyncResto POS", "syncresto_pos", "greenchef_pos"]
EXE_NAMES = ["greenchef_pos.exe", "syncresto_pos.exe", "SyncResto POS.exe"]

log_lines = []


def log(msg=""):
    print(msg)
    log_lines.append(str(msg))


def section(title):
    log("\n" + "=" * 70)
    log(f"  {title}")
    log("=" * 70)


def safe_run(cmd, shell=False, timeout=15):
    """Run a command, return (rc, stdout, stderr) — never raise."""
    try:
        r = subprocess.run(
            cmd,
            shell=shell,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:
        return -1, "", f"EXCEPTION: {e}"


def header():
    section("SYNCRESTO POS — WINDOWS TANI RAPORU")
    log(f"Tarih       : {datetime.datetime.now().isoformat()}")
    log(f"Hostname    : {platform.node()}")
    log(f"OS          : {platform.system()} {platform.release()} ({platform.version()})")
    log(f"Mimari      : {platform.machine()}")
    log(f"Python      : {sys.version.split()[0]}")
    log(f"User        : {os.environ.get('USERNAME', '?')}")
    log(f"AppData     : {os.environ.get('APPDATA', '?')}")
    log(f"LocalAppData: {os.environ.get('LOCALAPPDATA', '?')}")


def check_screens():
    section("EKRAN BILGISI")
    # GetSystemMetrics
    try:
        import ctypes
        u = ctypes.windll.user32
        u.SetProcessDPIAware()
        SM_CXSCREEN = 0
        SM_CYSCREEN = 1
        SM_CXVIRTUALSCREEN = 78
        SM_CYVIRTUALSCREEN = 79
        SM_XVIRTUALSCREEN = 76
        SM_YVIRTUALSCREEN = 77
        SM_CMONITORS = 80
        log(f"Primary cozunurluk : {u.GetSystemMetrics(SM_CXSCREEN)} x {u.GetSystemMetrics(SM_CYSCREEN)}")
        log(f"Virtual desktop    : x={u.GetSystemMetrics(SM_XVIRTUALSCREEN)} y={u.GetSystemMetrics(SM_YVIRTUALSCREEN)} {u.GetSystemMetrics(SM_CXVIRTUALSCREEN)}x{u.GetSystemMetrics(SM_CYVIRTUALSCREEN)}")
        log(f"Monitor sayisi     : {u.GetSystemMetrics(SM_CMONITORS)}")
        # DPI
        try:
            hwnd = u.GetDesktopWindow()
            dpi = u.GetDpiForWindow(hwnd) if hasattr(u, "GetDpiForWindow") else 96
            log(f"Sistem DPI         : {dpi} (scaling = {round(dpi/96.0*100)}%)")
        except Exception as e:
            log(f"DPI okunamadi      : {e}")
    except Exception as e:
        log(f"Ekran bilgisi alinamadi: {e}")

    # PowerShell ile multi-monitor detayi
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; "
        "[System.Windows.Forms.Screen]::AllScreens | "
        "Select-Object DeviceName, Primary, @{N='Bounds';E={$_.Bounds.ToString()}}, @{N='Working';E={$_.WorkingArea.ToString()}} | "
        "ConvertTo-Json"
    ])
    if rc == 0 and out:
        log("\nMonitor detayi (PowerShell):")
        log(out)


def find_processes():
    section("CALISAN POS PROCESS'LERI")
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-Process | Where-Object {$_.ProcessName -match 'greenchef|syncresto|flutter'} | "
        "Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle, StartTime, "
        "@{N='MemMB';E={[math]::Round($_.WorkingSet64/1MB,1)}} | "
        "Format-List | Out-String -Width 200"
    ])
    if out:
        log(out)
    else:
        log("(POS process'i yok — uygulama hic baslamamis)")
    if err and rc != 0:
        log(f"PowerShell err: {err}")


def find_windows():
    section("PENCERE LISTESI (gorunur + gizli)")
    # Tum pencereleri listele, POS olanlari isaretle
    ps = '''
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class WinList {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<string> All() {
    var list = new List<string>();
    EnumWindows((h, lp) => {
      var sb = new StringBuilder(512);
      GetWindowText(h, sb, sb.Capacity);
      string t = sb.ToString();
      if (string.IsNullOrEmpty(t)) return true;
      uint pid = 0; GetWindowThreadProcessId(h, out pid);
      RECT r; GetWindowRect(h, out r);
      bool vis = IsWindowVisible(h);
      bool min = IsIconic(h);
      list.Add(string.Format("PID={0} HWND=0x{1:X} Vis={2} Min={3} Rect=({4},{5})-({6},{7}) Title={8}",
        pid, h.ToInt64(), vis, min, r.L, r.T, r.R, r.B, t));
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
"@
[WinList]::All() | Where-Object { $_ -match "SyncResto|Greenchef|Flutter|POS" }
'''
    rc, out, err = safe_run(["powershell", "-NoProfile", "-Command", ps])
    if out:
        log(out)
    else:
        log("(Eslesen pencere yok — uygulama gorunmuyor)")
    if err and rc != 0:
        log(f"PowerShell err: {err[:500]}")


def find_install_paths():
    section("UYGULAMA DOSYALARI")
    candidates = []
    appdata = os.environ.get("APPDATA", "")
    localapp = os.environ.get("LOCALAPPDATA", "")
    pf = os.environ.get("ProgramFiles", "")
    pf86 = os.environ.get("ProgramFiles(x86)", "")
    home = str(Path.home())

    for base in [appdata, localapp, pf, pf86, home, r"C:\\"]:
        if not base or not os.path.exists(base):
            continue
        for name in ["SyncResto POS", "SyncResto", "greenchef_pos", "syncresto_pos"]:
            p = os.path.join(base, name)
            if os.path.exists(p):
                candidates.append(p)

    if not candidates:
        log("(Bilinen yollarda klasor yok)")
    for c in candidates:
        log(f"\n{c}")
        try:
            for root, dirs, files in os.walk(c):
                depth = root.replace(c, "").count(os.sep)
                if depth > 2:
                    dirs[:] = []
                    continue
                indent = "  " * depth
                log(f"{indent}{os.path.basename(root)}/")
                for f in files[:20]:
                    fp = os.path.join(root, f)
                    try:
                        sz = os.path.getsize(fp)
                        log(f"{indent}  {f}  ({sz:,} B)")
                    except Exception:
                        log(f"{indent}  {f}")
        except Exception as e:
            log(f"  walk err: {e}")


def find_exe():
    section("EXE DOSYALARI")
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-ChildItem -Path C:\\Users,C:\\Program*,C:\\Apps -Recurse -Filter 'greenchef_pos.exe','syncresto*.exe' -ErrorAction SilentlyContinue | "
        "Select-Object FullName, Length, LastWriteTime | Format-List | Out-String -Width 200"
    ], timeout=60)
    if out:
        log(out)
    else:
        log("(Bilinen lokasyonlarda EXE yok)")


def check_shared_prefs():
    section("FLUTTER SharedPreferences (varsa)")
    # Flutter Windows shared_prefs lokasyonu: %APPDATA%\com.example.app\shared_preferences.json (genellikle)
    # Ya da: %APPDATA%\<bundle>\shared_preferences.json
    appdata = os.environ.get("APPDATA", "")
    if not appdata:
        log("APPDATA env yok")
        return
    found = []
    for root, dirs, files in os.walk(appdata):
        depth = root.replace(appdata, "").count(os.sep)
        if depth > 3:
            dirs[:] = []
            continue
        for f in files:
            if "shared_preferences" in f.lower() or f.lower().endswith("preferences.json"):
                found.append(os.path.join(root, f))
    if not found:
        log("(SharedPreferences dosyasi bulunamadi)")
        return
    for f in found:
        log(f"\n{f}")
        try:
            with open(f, "r", encoding="utf-8") as fp:
                data = fp.read()
            log(data[:2000])
        except Exception as e:
            log(f"  okunamadi: {e}")


def check_event_log():
    section("WINDOWS EVENT LOG (son 24 saat — uygulama hatalari)")
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-EventLog -LogName Application -EntryType Error,Warning -After (Get-Date).AddDays(-1) -ErrorAction SilentlyContinue | "
        "Where-Object {$_.Source -match 'Application|Flutter|.NET' -or $_.Message -match 'syncresto|greenchef|flutter|crashed'} | "
        "Select-Object TimeGenerated, Source, EventID, EntryType, @{N='Msg';E={$_.Message.Substring(0,[Math]::Min(300,$_.Message.Length))}} | "
        "Select-Object -First 20 | Format-List | Out-String -Width 200"
    ], timeout=30)
    if out:
        log(out)
    else:
        log("(Event log'da ilgili kayit yok)")


def check_dx_gpu():
    section("DIRECTX / GPU (Flutter Skia rendering icin)")
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-CimInstance -ClassName Win32_VideoController | "
        "Select-Object Name, DriverVersion, AdapterRAM, VideoModeDescription | "
        "Format-List | Out-String -Width 200"
    ])
    if out:
        log(out)


def check_antivirus():
    section("ANTIVIRUS / DEFENDER")
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-MpComputerStatus -ErrorAction SilentlyContinue | "
        "Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, "
        "QuickScanStartTime, QuickScanEndTime | Format-List"
    ])
    if out:
        log(out)
    # Defender quarantine
    rc, out, err = safe_run([
        "powershell", "-NoProfile", "-Command",
        "Get-MpThreat -ErrorAction SilentlyContinue | "
        "Where-Object {$_.Resources -match 'syncresto|greenchef'} | "
        "Format-List"
    ])
    if out and out.strip():
        log("\nDefender quarantine (POS ilgili):")
        log(out)


def check_lockfile():
    section("SINGLE-INSTANCE LOCK / TRAY")
    appdata = os.environ.get("APPDATA", "")
    if appdata:
        for root, dirs, files in os.walk(appdata):
            depth = root.replace(appdata, "").count(os.sep)
            if depth > 3:
                dirs[:] = []
                continue
            for f in files:
                if f.endswith(".lock") and ("syncresto" in root.lower() or "greenchef" in root.lower()):
                    p = os.path.join(root, f)
                    log(f"Lock dosyasi: {p}")
                    try:
                        log(f"  boyut: {os.path.getsize(p)} B  mtime: {datetime.datetime.fromtimestamp(os.path.getmtime(p))}")
                    except Exception:
                        pass


def attempt_run_diagnostic():
    section("DENEME: PROCESS VAR MI? GORUNUR MU?")
    # POS calisiyorsa ana pencere handle gorunur degilse problem net
    ps = '''
Get-Process | Where-Object {$_.ProcessName -match "greenchef|syncresto"} | ForEach-Object {
    $hasWin = $_.MainWindowHandle.ToInt64() -ne 0
    $vis = $false
    if ($hasWin) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W { [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd); }
"@ -ErrorAction SilentlyContinue
        $vis = [W]::IsWindowVisible($_.MainWindowHandle)
    }
    "PID={0} {1}  MainWindowHandle={2:X}  HasWindow={3}  Visible={4}" -f $_.Id, $_.ProcessName, $_.MainWindowHandle.ToInt64(), $hasWin, $vis
}
'''
    rc, out, err = safe_run(["powershell", "-NoProfile", "-Command", ps])
    if out:
        log(out)
    else:
        log("(POS process yok)")


def write_log_file():
    try:
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(log_lines))
        print(f"\n{'='*70}")
        print(f"LOG YAZILDI: {os.path.abspath(LOG_FILE)}")
        print(f"{'='*70}")
        print("BU DOSYAYI MUSTAFA'YA GONDER")
    except Exception as e:
        print(f"Log yazilamadi: {e}")


def main():
    if platform.system() != "Windows":
        print("Bu script Windows uzerinde calismali (su an: " + platform.system() + ")")
        sys.exit(1)
    try:
        header()
        check_screens()
        find_processes()
        attempt_run_diagnostic()
        find_windows()
        find_exe()
        find_install_paths()
        check_shared_prefs()
        check_lockfile()
        check_dx_gpu()
        check_antivirus()
        check_event_log()
    except Exception as e:
        log(f"\n*** TANI HATASI: {e}\n{traceback.format_exc()}")
    finally:
        write_log_file()


if __name__ == "__main__":
    main()
