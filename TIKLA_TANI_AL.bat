@echo off
REM SyncResto POS - Windows Tani
REM Cift tikla calisir. PowerShell execution policy bypass.

cd /d "%~dp0"

echo ===========================================================
echo SyncResto POS - Windows Tani Scripti
echo ===========================================================
echo.
echo Tani toplaniyor, lutfen bekleyin (30-60 saniye)...
echo.

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0diagnose_windows.ps1"

echo.
echo ===========================================================
echo Bitti. diagnose_log.txt dosyasini Mustafa'ya gonderin.
echo Klasor: %~dp0
echo ===========================================================
echo.
pause
