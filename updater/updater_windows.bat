@echo off
REM SyncResto POS Windows Updater Script
REM Guvenlik: Bu script sadece SyncResto POS uygulamasi tarafindan calistirilir
REM Arguman 1: ZIP dosyasi yolu
REM Arguman 2: Uygulama dizini

setlocal enabledelayedexpansion

set "ZIP_FILE=%~1"
set "APP_DIR=%~2"
set "BACKUP_DIR=%APP_DIR%\backup_%date:~-4,4%%date:~-10,2%%date:~-7,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
set "BACKUP_DIR=!BACKUP_DIR: =0!"
set "TEMP_DIR=%TEMP%\SyncRestoUpdate"
set "LOG_FILE=%APP_DIR%\update_log.txt"

echo [%date% %time%] Guncelleme basladi >> "%LOG_FILE%"

REM Parametreleri kontrol et
if "%ZIP_FILE%"=="" (
    echo HATA: ZIP dosyasi belirtilmedi >> "%LOG_FILE%"
    exit /b 1
)

if "%APP_DIR%"=="" (
    echo HATA: Uygulama dizini belirtilmedi >> "%LOG_FILE%"
    exit /b 1
)

REM ZIP dosyasinin varligini kontrol et
if not exist "%ZIP_FILE%" (
    echo HATA: ZIP dosyasi bulunamadi: %ZIP_FILE% >> "%LOG_FILE%"
    exit /b 1
)

echo [%date% %time%] Uygulama kapanmasi bekleniyor... >> "%LOG_FILE%"
echo Uygulama kapanmasi bekleniyor...

REM Uygulamanin kapanmasini bekle (5 saniye)
timeout /t 5 /nobreak > nul

REM Processin hala calisip calismadigini kontrol et
tasklist /FI "IMAGENAME eq greenchef_pos.exe" 2>NUL | find /I /N "greenchef_pos.exe">NUL
if "%ERRORLEVEL%"=="0" (
    echo [%date% %time%] Uygulama hala calisiyor, zorla kapatiliyor... >> "%LOG_FILE%"
    taskkill /F /IM greenchef_pos.exe > nul 2>&1
    timeout /t 2 /nobreak > nul
)

REM Yedek dizini olustur
echo [%date% %time%] Yedek olusturuluyor: %BACKUP_DIR% >> "%LOG_FILE%"
mkdir "%BACKUP_DIR%" 2>nul

REM Mevcut dosyalari yedekle (kritik dosyalar)
if exist "%APP_DIR%\greenchef_pos.exe" (
    copy /Y "%APP_DIR%\greenchef_pos.exe" "%BACKUP_DIR%\" > nul 2>&1
)
if exist "%APP_DIR%\data" (
    xcopy /E /I /Y "%APP_DIR%\data" "%BACKUP_DIR%\data" > nul 2>&1
)

REM Gecici dizin olustur
echo [%date% %time%] Gecici dizin olusturuluyor... >> "%LOG_FILE%"
rmdir /S /Q "%TEMP_DIR%" 2>nul
mkdir "%TEMP_DIR%"

REM ZIP dosyasini cikart (PowerShell kullan)
echo [%date% %time%] ZIP dosyasi cikarililiyor... >> "%LOG_FILE%"
powershell -Command "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%TEMP_DIR%' -Force"

if %ERRORLEVEL% NEQ 0 (
    echo HATA: ZIP cikarilirken hata olustu >> "%LOG_FILE%"
    echo Yedekten geri yukleniyor...
    xcopy /E /I /Y "%BACKUP_DIR%\*" "%APP_DIR%\" > nul 2>&1
    exit /b 1
)

REM Yeni dosyalari kopyala
echo [%date% %time%] Yeni dosyalar kopyalaniyor... >> "%LOG_FILE%"
xcopy /E /I /Y "%TEMP_DIR%\*" "%APP_DIR%\" > nul 2>&1

if %ERRORLEVEL% NEQ 0 (
    echo HATA: Dosyalar kopyalanirken hata olustu >> "%LOG_FILE%"
    echo Yedekten geri yukleniyor...
    xcopy /E /I /Y "%BACKUP_DIR%\*" "%APP_DIR%\" > nul 2>&1
    exit /b 1
)

REM Temizlik
echo [%date% %time%] Temizlik yapiliyor... >> "%LOG_FILE%"
rmdir /S /Q "%TEMP_DIR%" 2>nul
del /Q "%ZIP_FILE%" 2>nul

REM Eski yedekleri temizle (7 günden eski)
forfiles /P "%APP_DIR%" /D -7 /M "backup_*" /C "cmd /c rmdir /S /Q @path" 2>nul

echo [%date% %time%] Guncelleme tamamlandi! >> "%LOG_FILE%"
echo Guncelleme tamamlandi! Uygulama yeniden baslatiliyor...

REM Uygulamayi yeniden baslat
timeout /t 2 /nobreak > nul
start "" "%APP_DIR%\greenchef_pos.exe"

exit /b 0
