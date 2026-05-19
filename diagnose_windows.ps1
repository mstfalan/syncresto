# SyncResto POS - Windows Tani Scripti (PowerShell)
# ===========================================================
# Kullanim:
#   1. Bu dosyaya cift tikla -> "PowerShell ile calistir"
#   2. (Eger acmazsa) sag tik -> "PowerShell ile calistir"
#   3. Cikti: ayni klasorde diagnose_log.txt olusur
#   4. Bu dosyayi Mustafa'ya gonder
# ===========================================================

# Cift tikla acildiginda PS1 calismayabilir - execution policy bypass
if ($MyInvocation.MyCommand.Path) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptDir  = Split-Path $scriptPath -Parent
} else {
    $scriptDir = (Get-Location).Path
}
Set-Location $scriptDir

$LogFile = Join-Path $scriptDir "diagnose_log.txt"
$OutputBuffer = New-Object System.Text.StringBuilder

function Log {
    param([string]$msg = "")
    Write-Host $msg
    [void]$OutputBuffer.AppendLine($msg)
}

function Section {
    param([string]$title)
    Log ""
    Log ("=" * 70)
    Log "  $title"
    Log ("=" * 70)
}

function SafeRun {
    param([scriptblock]$block, [string]$label)
    try {
        $result = & $block 2>&1 | Out-String
        return $result.Trim()
    } catch {
        return "HATA [$label]: $($_.Exception.Message)"
    }
}

# ===========================================================
# HEADER
# ===========================================================
Section "SYNCRESTO POS - WINDOWS TANI RAPORU"
Log "Tarih       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Hostname    : $env:COMPUTERNAME"
Log "Kullanici   : $env:USERNAME"
Log "OS          : $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)"
Log "Mimari      : $env:PROCESSOR_ARCHITECTURE"
Log "PowerShell  : $($PSVersionTable.PSVersion)"
Log "AppData     : $env:APPDATA"
Log "LocalAppData: $env:LOCALAPPDATA"

# ===========================================================
# 1) EKRAN BILGISI
# ===========================================================
Section "EKRAN BILGISI (Multi-Monitor + DPI)"

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $screens = [System.Windows.Forms.Screen]::AllScreens
    Log "Toplam monitor sayisi: $($screens.Count)"
    Log ""
    foreach ($s in $screens) {
        $primary = if ($s.Primary) { " [PRIMARY]" } else { "" }
        Log "Monitor: $($s.DeviceName)$primary"
        Log "  Bounds      : $($s.Bounds)"
        Log "  Working Area: $($s.WorkingArea)"
        Log "  BitsPerPixel: $($s.BitsPerPixel)"
        Log ""
    }
} catch {
    Log "WindowsForms yuklenemedi: $_"
}

# DPI bilgisi
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DPI {
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hDC, int nIndex);
    public static int GetDpi() {
        IntPtr h = GetDC(IntPtr.Zero);
        int dpi = GetDeviceCaps(h, 88); // LOGPIXELSX
        ReleaseDC(IntPtr.Zero, h);
        return dpi;
    }
}
"@ -ErrorAction SilentlyContinue
    $dpi = [DPI]::GetDpi()
    $scaling = [math]::Round($dpi / 96.0 * 100)
    Log "Sistem DPI: $dpi (Display Scaling: $scaling%)"
} catch {
    Log "DPI bilgisi alinamadi: $_"
}

# ===========================================================
# 2) CALISAN POS PROCESS'LERI
# ===========================================================
Section "CALISAN POS PROCESS'LERI"

$procs = Get-Process | Where-Object {
    $_.ProcessName -match 'greenchef|syncresto|flutter'
}

if ($procs) {
    Log "BULUNAN: $($procs.Count) process"
    foreach ($p in $procs) {
        $startTime = try { $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { "?" }
        $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
        $hasWindow = $p.MainWindowHandle.ToInt64() -ne 0
        $title = if ($p.MainWindowTitle) { $p.MainWindowTitle } else { "(baslik yok)" }
        Log ""
        Log "  PID         : $($p.Id)"
        Log "  Process     : $($p.ProcessName)"
        Log "  Path        : $($p.Path)"
        Log "  Baslangic   : $startTime"
        Log "  Memory      : $memMB MB"
        Log "  Window Title: $title"
        Log "  HWND        : 0x$('{0:X}' -f $p.MainWindowHandle.ToInt64())"
        Log "  Has Window  : $hasWindow"
    }
} else {
    Log "(POS process'i CALISMIYOR - uygulama hic baslamamis veya hemen kapanmis)"
}

# ===========================================================
# 3) PENCERE DURUMU - GORUNUR/GIZLI/MINIMIZE
# ===========================================================
Section "PENCERE DURUMU (Gorunur / Gizli / Minimize / Ekran Disi)"

try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class WL {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder t, int c);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<string> Find(string pattern) {
        var results = new List<string>();
        EnumWindows((h, lp) => {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            string t = sb.ToString();
            if (string.IsNullOrEmpty(t)) return true;
            if (System.Text.RegularExpressions.Regex.IsMatch(t, pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
                uint pid = 0; GetWindowThreadProcessId(h, out pid);
                RECT r; GetWindowRect(h, out r);
                bool vis = IsWindowVisible(h);
                bool min = IsIconic(h);
                results.Add(string.Format(
                    "PID={0,-6} HWND=0x{1:X8}  Visible={2}  Minimized={3}  Rect=({4},{5}) - ({6},{7})  Size={8}x{9}  Title={10}",
                    pid, h.ToInt64(), vis, min, r.L, r.T, r.R, r.B, r.R-r.L, r.B-r.T, t));
            }
            return true;
        }, IntPtr.Zero);
        return results;
    }
}
"@ -ErrorAction SilentlyContinue

    $matches = [WL]::Find("syncresto|greenchef|flutter|POS")
    if ($matches.Count -gt 0) {
        Log "BULUNAN: $($matches.Count) pencere"
        Log ""
        foreach ($m in $matches) {
            Log $m
        }
        Log ""
        Log "DEGERLENDIRME:"
        Log "  - Visible=False  -> Pencere GIZLI (CreateWindow yapildi ama Show cagrilmadi/iptal edildi)"
        Log "  - Minimized=True -> Iconified (Tray'e mi gitti?)"
        Log "  - Rect L<-1000  -> Ekran disinda (multi-monitor sorunu)"
    } else {
        Log "(Eslesen POS penceresi YOK)"
        Log ""
        Log "Process varsa ama pencere yoksa: GUI hic olusmamis."
        Log "Genelde sebep: runner main.cpp icindeki window.Create() basarisiz oldu."
    }
} catch {
    Log "Pencere taramasi yapilamadi: $_"
}

# ===========================================================
# 4) BILINEN YOLLARDA EXE ARA
# ===========================================================
Section "EXE DOSYALARI"

$searchPaths = @(
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\Documents",
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:USERPROFILE",
    "C:\Apps",
    "C:\SyncResto",
    "C:\Program Files",
    "C:\Program Files (x86)"
)

foreach ($path in $searchPaths) {
    if (-not (Test-Path $path)) { continue }
    try {
        $exes = Get-ChildItem -Path $path -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue -Depth 4 |
                Where-Object { $_.Name -match 'syncresto|greenchef' }
        foreach ($e in $exes) {
            $size = [math]::Round($e.Length / 1MB, 1)
            Log "  $($e.FullName) ($size MB - $($e.LastWriteTime))"
        }
    } catch {}
}

# ===========================================================
# 5) FLUTTER SHARED PREFERENCES
# ===========================================================
Section "FLUTTER SharedPreferences (varsa pencere konum kayitli olabilir)"

$prefPaths = @(
    "$env:APPDATA",
    "$env:LOCALAPPDATA"
)

$found = @()
foreach ($base in $prefPaths) {
    if (-not (Test-Path $base)) { continue }
    try {
        $files = Get-ChildItem -Path $base -Recurse -Include "shared_preferences*.json", "*preferences.json" -ErrorAction SilentlyContinue -Depth 3
        foreach ($f in $files) {
            if ($f.FullName -match 'syncresto|greenchef|flutter') {
                $found += $f.FullName
            }
        }
    } catch {}
}

if ($found.Count -eq 0) {
    Log "(SharedPreferences dosyasi yok)"
} else {
    foreach ($p in $found) {
        Log ""
        Log "DOSYA: $p"
        try {
            Get-Content $p -Raw -ErrorAction Stop | Out-String | ForEach-Object { Log $_.Trim() }
        } catch {
            Log "  okunamadi"
        }
    }
}

# ===========================================================
# 6) UYGULAMA KLASORLERI ICERIGI
# ===========================================================
Section "UYGULAMA KLASORLERI"

$appPaths = @(
    "$env:APPDATA\SyncResto POS",
    "$env:APPDATA\com.syncresto.pos",
    "$env:LOCALAPPDATA\SyncResto POS",
    "$env:LOCALAPPDATA\com.syncresto.pos"
)

foreach ($p in $appPaths) {
    if (Test-Path $p) {
        Log ""
        Log "$p"
        try {
            Get-ChildItem -Path $p -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Replace($p, "")
                if ($_.PSIsContainer) {
                    Log "  [DIR] $rel"
                } else {
                    Log "  $rel ($($_.Length) B - $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
                }
            }
        } catch {}
    }
}

# ===========================================================
# 7) DIRECTX / GPU
# ===========================================================
Section "GPU / GRAPHICS DRIVER (Flutter Skia rendering icin kritik)"

try {
    Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
        Select-Object Name, DriverVersion, DriverDate, AdapterRAM, VideoModeDescription |
        Format-List | Out-String | ForEach-Object { Log $_.Trim() }
} catch {
    Log "GPU bilgisi alinamadi: $_"
}

# ===========================================================
# 8) ANTIVIRUS / WINDOWS DEFENDER
# ===========================================================
Section "ANTIVIRUS / DEFENDER DURUMU"

try {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        Log "Defender Service Aktif    : $($mp.AMServiceEnabled)"
        Log "AV Aktif                  : $($mp.AntivirusEnabled)"
        Log "Real-Time Protection      : $($mp.RealTimeProtectionEnabled)"
    } else {
        Log "(Defender bilgisi alinamadi - belki 3rd party AV var)"
    }

    $threats = Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.Resources -match 'syncresto|greenchef' }
    if ($threats) {
        Log ""
        Log "!! DEFENDER QUARANTINE !! (POS dosyalari engellendi)"
        $threats | Format-List | Out-String | ForEach-Object { Log $_.Trim() }
    }
} catch {
    Log "Defender check failed: $_"
}

# ===========================================================
# 9) WINDOWS EVENT LOG (UYGULAMA HATALARI - SON 24 SAAT)
# ===========================================================
Section "EVENT LOG (Application errors - son 24 saat)"

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        Level = 1, 2, 3
        StartTime = (Get-Date).AddDays(-1)
    } -ErrorAction SilentlyContinue -MaxEvents 500 |
    Where-Object {
        $_.Message -match 'syncresto|greenchef|flutter|0xc0000|exception|crashed' -or
        $_.ProviderName -match 'Application Error|.NET Runtime|Windows Error'
    } |
    Select-Object -First 15

    if ($events.Count -eq 0) {
        Log "(Ilgili hata yok)"
    } else {
        foreach ($e in $events) {
            Log ""
            Log "Time   : $($e.TimeCreated)"
            Log "Source : $($e.ProviderName)"
            Log "Level  : $($e.LevelDisplayName) (ID=$($e.Id))"
            $msg = if ($e.Message.Length -gt 400) { $e.Message.Substring(0, 400) + "..." } else { $e.Message }
            Log "Message: $msg"
        }
    }
} catch {
    Log "Event log okunamadi: $_"
}

# ===========================================================
# 10) NET PORT / SOCKET KONTROL
# ===========================================================
Section "NET BAGLANTILARI (POS belki sunucuya baglanamayip duruyor)"

try {
    $procs = Get-Process | Where-Object { $_.ProcessName -match 'greenchef|syncresto' }
    foreach ($p in $procs) {
        $conns = Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue
        if ($conns) {
            Log ""
            Log "PID $($p.Id) ($($p.ProcessName)) baglantilari:"
            $conns | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State |
                Format-Table | Out-String | ForEach-Object { Log $_.Trim() }
        }
    }
    if (-not $procs) {
        Log "(POS process yok)"
    }
} catch {
    Log "Net check fail: $_"
}

# ===========================================================
# YAZIM
# ===========================================================
Log ""
Log ("=" * 70)
Log "RAPOR TAMAMLANDI"
Log ("=" * 70)

try {
    $OutputBuffer.ToString() | Out-File -FilePath $LogFile -Encoding UTF8
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Green
    Write-Host "LOG DOSYASI HAZIR:" -ForegroundColor Green
    Write-Host "  $LogFile" -ForegroundColor Yellow
    Write-Host "===================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "BU DOSYAYI MUSTAFA'YA GONDERIN" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pencereyi kapatmak icin Enter'a basin..." -ForegroundColor White
    Read-Host
} catch {
    Write-Host "Log dosyasi yazilamadi: $_" -ForegroundColor Red
    Read-Host
}
