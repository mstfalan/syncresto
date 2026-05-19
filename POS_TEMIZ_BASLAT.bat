@echo off
REM SyncResto POS - TEMIZ BASLAT
REM 1) Tum eski POS process'lerini oldur (zombi temizleme)
REM 2) GUVENLI MOD ile tek seferde baslat
REM 3) Pencere acilinca zorla one getir

setlocal EnableDelayedExpansion

echo ============================================================
echo SyncResto POS - TEMIZ BASLAT
echo ============================================================
echo.

REM === ADIM 1: Eski POS process'lerini oldur ===
echo [1/3] Eski SyncResto POS process'leri kapatiliyor...
taskkill /F /IM "SyncResto POS.exe" >nul 2>&1
taskkill /F /IM "Greenchef POS.exe" >nul 2>&1
taskkill /F /IM "syncresto_pos.exe" >nul 2>&1
taskkill /F /IM "greenchef_pos.exe" >nul 2>&1
timeout /t 2 /nobreak >nul

REM Hala canli process var mi kontrol et
powershell -NoProfile -Command "Get-Process | Where-Object {$_.ProcessName -match 'syncresto|greenchef'} | Stop-Process -Force -ErrorAction SilentlyContinue" >nul 2>&1
timeout /t 1 /nobreak >nul

echo      OK - eski process'ler kapatildi
echo.

REM === ADIM 2: POS exe'yi bul ===
echo [2/3] POS exe araniyor...
set "FOUND_EXE="
for /f "delims=" %%I in ('powershell -NoProfile -Command "$paths=@('%USERPROFILE%\Desktop','%USERPROFILE%\Downloads','%USERPROFILE%\Documents','%USERPROFILE%','C:\Apps','C:\SyncResto','C:\Greenchef'); $found = @(); foreach($p in $paths){ if(Test-Path $p){ $found += Get-ChildItem -Path $p -Recurse -ErrorAction SilentlyContinue -Depth 6 -Filter '*.exe' | Where-Object { $_.Name -match '(?i)syncresto.*pos|greenchef.*pos' } } }; $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($best){ Write-Output $best.FullName }"') do (
    set "FOUND_EXE=%%I"
)

if not defined FOUND_EXE (
    echo      HATA: POS exe bulunamadi
    echo.
    pause
    exit /b 1
)

echo      OK - !FOUND_EXE!
echo.

REM === ADIM 3: GUVENLI MOD ile baslat ===
echo [3/3] Yazilim render modunda baslatiliyor...
echo.

set FLUTTER_FORCE_SOFTWARE_RENDERER=1
set IMPELLER_ENABLE=0
set FLUTTER_GL_USE_ANGLE=0
set LIBGL_ALWAYS_SOFTWARE=1

for %%F in ("!FOUND_EXE!") do set "EXE_DIR=%%~dpF"
cd /d "!EXE_DIR!"

start "SyncResto POS" "!FOUND_EXE!"

echo      OK - baslatildi, pencere bekleniyor (8 saniye)...
timeout /t 8 /nobreak >nul

REM === Pencereyi zorla one getir ===
echo.
echo Pencere zorla one getiriliyor...
powershell -NoProfile -Command ^
"Add-Type @' ^
using System; ^
using System.Runtime.InteropServices; ^
public class WF { ^
  [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr hWnd, int nCmd); ^
  [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd); ^
  [DllImport(\"user32.dll\")] public static extern bool BringWindowToTop(IntPtr hWnd); ^
  [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndAfter, int x, int y, int cx, int cy, uint flags); ^
} ^
'@; ^
$proc = Get-Process | Where-Object {$_.ProcessName -match 'syncresto|greenchef'} | Select-Object -First 1; ^
if ($proc -and $proc.MainWindowHandle.ToInt64() -ne 0) { ^
    Write-Host ('Process bulundu: PID=' + $proc.Id + ' HWND=0x' + ('{0:X}' -f $proc.MainWindowHandle.ToInt64())); ^
    [WF]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null; ^
    [WF]::ShowWindow($proc.MainWindowHandle, 5) | Out-Null; ^
    [WF]::SetWindowPos($proc.MainWindowHandle, [IntPtr]::new(-1), 100, 50, 1024, 700, 0x0040) | Out-Null; ^
    [WF]::BringWindowToTop($proc.MainWindowHandle) | Out-Null; ^
    [WF]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null; ^
    Write-Host 'OK - Pencere ekrana cekildi'; ^
} elseif ($proc) { ^
    Write-Host ('UYARI: Process var (PID=' + $proc.Id + ') ama pencere handle yok'); ^
    Write-Host 'Sebepler: 1) Pencere hala olusturuluyor  2) Flutter renderer hatali'; ^
} else { ^
    Write-Host 'HATA: Process baslatilmadi'; ^
}"

echo.
echo ============================================================
echo Tamam. Pencere acildi mi?
echo - EVET: bu pencereyi kapatabilirsiniz, POS calisiyor
echo - HAYIR: Mustafa'ya bildirin
echo ============================================================
echo.
pause
