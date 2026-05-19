@echo off
REM SyncResto POS - GUVENLI MOD (eski GPU driver'li PC'ler icin)
REM Flutter'i software rendering'e zorlar
REM
REM Bu dosyayi NEREDE olursanizdan calistirabilirsiniz.
REM SyncResto / GreenChef POS exe varyasyonlarini esnek arar.

setlocal EnableDelayedExpansion

echo ============================================================
echo SyncResto POS - GUVENLI MOD
echo (Yazilim render - eski GPU driver'lari icin)
echo ============================================================
echo.

REM Software rendering bayraklari
set FLUTTER_FORCE_SOFTWARE_RENDERER=1
set IMPELLER_ENABLE=0
set FLUTTER_GL_USE_ANGLE=0
set LIBGL_ALWAYS_SOFTWARE=1

REM 1. Aktif klasorde herhangi bir POS exe var mi?
for %%F in ("%~dp0*pos*.exe" "%~dp0SyncResto*.exe" "%~dp0Greenchef*.exe" "%~dp0Green Chef*.exe") do (
    if exist "%%F" (
        set "FOUND_EXE=%%F"
        goto :launch
    )
)

echo SyncResto POS exe araniyor (esnek arama)...
echo Lutfen bekleyin (10-30 saniye)...
echo.

REM 2. PowerShell ile esnek arama: tum *pos*.exe / syncresto* / greenchef*
REM    Aranan yerler: Desktop, Downloads, Documents, USERPROFILE, C:\Apps
for /f "delims=" %%I in ('powershell -NoProfile -Command "$paths=@('%USERPROFILE%\Desktop','%USERPROFILE%\Downloads','%USERPROFILE%\Documents','%USERPROFILE%','C:\Apps','C:\SyncResto','C:\Greenchef'); $found = @(); foreach($p in $paths){ if(Test-Path $p){ $found += Get-ChildItem -Path $p -Recurse -ErrorAction SilentlyContinue -Depth 6 -Filter '*.exe' | Where-Object { $_.Name -match '(?i)syncresto.*pos|greenchef.*pos|pos.*syncresto|pos.*greenchef' } } }; $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($best){ Write-Output $best.FullName }"') do (
    set "FOUND_EXE=%%I"
)

if not defined FOUND_EXE (
    echo.
    echo ============================================================
    echo HATA: POS exe bulunamadi
    echo ============================================================
    echo.
    echo Aranan isim varyasyonlari (case-insensitive):
    echo   - SyncResto POS.exe
    echo   - Greenchef POS.exe
    echo   - Green Chef POS.exe
    echo   - syncresto_pos.exe
    echo   - greenchef_pos.exe
    echo.
    echo Aranan yerler:
    echo   - %USERPROFILE%\Desktop (ve alt klasorler)
    echo   - %USERPROFILE%\Downloads
    echo   - %USERPROFILE%\Documents
    echo   - %USERPROFILE%
    echo   - C:\Apps , C:\SyncResto , C:\Greenchef
    echo.
    echo COZUM: Bu .bat dosyasini POS exe ile AYNI klasore tasiyip tekrar deneyin.
    echo.
    pause
    exit /b 1
)

:launch
echo.
echo BULUNDU: !FOUND_EXE!
echo.
echo Baslatiliyor (software rendering)...
echo.

REM Klasore gecip oradan calistir (data\ klasoru ile ayni dizinde olmasi lazim)
for %%F in ("!FOUND_EXE!") do set "EXE_DIR=%%~dpF"
cd /d "!EXE_DIR!"

start "" "!FOUND_EXE!"

timeout /t 3 /nobreak >nul

echo ============================================================
echo Pencere acildiysa: BASARILI - bu pencereyi kapatabilirsiniz
echo Pencere acilmadiysa: Mustafa'ya bildirin
echo ============================================================
echo.
pause
