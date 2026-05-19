@echo off
REM SyncResto POS - Detayli Tani (crash sebebini bulur)
REM Cift tikla calistir.

setlocal EnableDelayedExpansion

set "LOGFILE=%~dp0pos_crash_log.txt"

echo ============================================================ > "%LOGFILE%"
echo SyncResto POS - DETAYLI TANI >> "%LOGFILE%"
echo Tarih: %date% %time% >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"
echo. >> "%LOGFILE%"

echo ============================================================
echo SyncResto POS - DETAYLI TANI
echo ============================================================
echo.
echo Tani toplaniyor...

REM 1) POS exe bul
echo. >> "%LOGFILE%"
echo === EXE ARAMA === >> "%LOGFILE%"
set "FOUND_EXE="
for /f "delims=" %%I in ('powershell -NoProfile -Command "$paths=@('%USERPROFILE%\Desktop','%USERPROFILE%\Downloads','%USERPROFILE%\Documents','%USERPROFILE%','C:\Apps','C:\SyncResto','C:\Greenchef'); $found = @(); foreach($p in $paths){ if(Test-Path $p){ $found += Get-ChildItem -Path $p -Recurse -ErrorAction SilentlyContinue -Depth 6 -Filter '*.exe' | Where-Object { $_.Name -match '(?i)syncresto.*pos|greenchef.*pos' } } }; foreach($f in $found){ Write-Output ($f.FullName + ' [' + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ']') }"') do (
    echo %%I >> "%LOGFILE%"
    if not defined FOUND_EXE set "FOUND_EXE=%%I"
)

REM Path'i temizle (timestamp var)
for /f "tokens=1 delims=[" %%X in ("!FOUND_EXE!") do set "FOUND_EXE=%%X"
set "FOUND_EXE=!FOUND_EXE: =_!"
for /f "delims=" %%I in ('powershell -NoProfile -Command "$paths=@('%USERPROFILE%\Desktop','%USERPROFILE%\Downloads','%USERPROFILE%\Documents','%USERPROFILE%','C:\Apps','C:\SyncResto','C:\Greenchef'); $found = @(); foreach($p in $paths){ if(Test-Path $p){ $found += Get-ChildItem -Path $p -Recurse -ErrorAction SilentlyContinue -Depth 6 -Filter '*.exe' | Where-Object { $_.Name -match '(?i)syncresto.*pos|greenchef.*pos' } } }; $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($best){ Write-Output $best.FullName }"') do (
    set "FOUND_EXE=%%I"
)

if not defined FOUND_EXE (
    echo HATA: POS exe bulunamadi >> "%LOGFILE%"
    echo HATA: POS exe bulunamadi
    goto :report
)

echo. >> "%LOGFILE%"
echo SECILEN EXE: !FOUND_EXE! >> "%LOGFILE%"
echo. >> "%LOGFILE%"

REM 2) data\ ve diger gerekli klasor/dosyalar var mi
for %%F in ("!FOUND_EXE!") do set "EXE_DIR=%%~dpF"
echo === KLASOR ICERIGI: !EXE_DIR! === >> "%LOGFILE%"
dir "!EXE_DIR!" >> "%LOGFILE%" 2>&1
echo. >> "%LOGFILE%"

if exist "!EXE_DIR!data" (
    echo data\ klasoru VAR >> "%LOGFILE%"
) else (
    echo HATA: data\ klasoru YOK - zip eksik cikartilmis olabilir >> "%LOGFILE%"
)

if exist "!EXE_DIR!flutter_windows.dll" (
    echo flutter_windows.dll VAR >> "%LOGFILE%"
) else (
    echo HATA: flutter_windows.dll YOK >> "%LOGFILE%"
)

REM 3) GUVENLI MOD ile baslat ve cikti yakala
echo. >> "%LOGFILE%"
echo === GUVENLI MOD ILE BASLATMA DENEMESI === >> "%LOGFILE%"

set FLUTTER_FORCE_SOFTWARE_RENDERER=1
set IMPELLER_ENABLE=0

cd /d "!EXE_DIR!"

REM Process'i baslat ve PID'i al
echo. >> "%LOGFILE%"
echo Calistirma anindaki sistem zamani: %date% %time% >> "%LOGFILE%"
echo Calistirilan: !FOUND_EXE! >> "%LOGFILE%"

start "" "!FOUND_EXE!"
timeout /t 5 /nobreak >nul

REM 4) Process hala var mi kontrol et
echo. >> "%LOGFILE%"
echo === 5 SANIYE SONRA PROCESS DURUMU === >> "%LOGFILE%"
powershell -NoProfile -Command "Get-Process | Where-Object { $_.ProcessName -match 'syncresto|greenchef' } | Format-List Id, ProcessName, MainWindowTitle, StartTime, WorkingSet" >> "%LOGFILE%" 2>&1

REM 5) Yeni event log girdileri (son 5 dakika)
echo. >> "%LOGFILE%"
echo === SON 5 DAKIKA EVENT LOG === >> "%LOGFILE%"
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2,3; StartTime=(Get-Date).AddMinutes(-5)} -ErrorAction SilentlyContinue -MaxEvents 30 | Where-Object { $_.Message -match 'syncresto|greenchef|flutter|0xc0000|exception' } | ForEach-Object { Write-Output ('--- ' + $_.TimeCreated + ' [' + $_.LevelDisplayName + '] ' + $_.ProviderName + ' (ID=' + $_.Id + ') ---'); $msg = if($_.Message.Length -gt 600){ $_.Message.Substring(0,600)+'...' } else { $_.Message }; Write-Output $msg; Write-Output '' }" >> "%LOGFILE%" 2>&1

REM 6) WER (Windows Error Reporting) crash dump var mi
echo. >> "%LOGFILE%"
echo === WER CRASH DUMP'LARI (LocalAppData\CrashDumps) === >> "%LOGFILE%"
if exist "%LOCALAPPDATA%\CrashDumps" (
    powershell -NoProfile -Command "Get-ChildItem '%LOCALAPPDATA%\CrashDumps' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'syncresto|greenchef' -or $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } | Select-Object Name, LastWriteTime, @{N='SizeMB';E={[math]::Round($_.Length/1MB,2)}} | Format-List" >> "%LOGFILE%" 2>&1
) else (
    echo CrashDumps klasoru yok >> "%LOGFILE%"
)

REM 7) WER reports (kullanici raporlari)
echo. >> "%LOGFILE%"
echo === WER REPORTS === >> "%LOGFILE%"
if exist "%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive" (
    powershell -NoProfile -Command "Get-ChildItem '%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'syncresto|greenchef' -or $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } | Select-Object Name, LastWriteTime | Format-List" >> "%LOGFILE%" 2>&1
)

REM 8) DLL'ler eksik olabilir - dependency walker basit kontrol
echo. >> "%LOGFILE%"
echo === EXE DOSYA BILGISI === >> "%LOGFILE%"
powershell -NoProfile -Command "Get-Item '!FOUND_EXE!' | Select-Object FullName, Length, LastWriteTime, @{N='Version';E={(Get-Item $_.FullName).VersionInfo.FileVersion}} | Format-List" >> "%LOGFILE%" 2>&1

REM 9) Visual C++ Redistributable yuklu mu (Flutter Windows runtime icin gerekli)
echo. >> "%LOGFILE%"
echo === VC++ REDIST KONTROLU === >> "%LOGFILE%"
powershell -NoProfile -Command "Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -match 'Visual C\+\+.*Redist' } | Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName -Unique | Format-List" >> "%LOGFILE%" 2>&1

:report
echo. >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"
echo TANI BITTI >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"

echo.
echo ============================================================
echo TANI TAMAMLANDI
echo ============================================================
echo.
echo Log dosyasi: %LOGFILE%
echo.
echo BU DOSYAYI MUSTAFA'YA GONDERIN
echo.
pause
