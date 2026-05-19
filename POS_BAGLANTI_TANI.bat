@echo off
title SyncResto POS Baglanti Tanisi
color 0E
cls
echo ================================================
echo   SyncResto POS - Baglanti Tanisi v1
echo ================================================
echo.
echo Bu test, POS exe'sinin api.syncresto.com'a neden
echo baglanamadigini ANLAR. Sonucu Mustafa'ya gonder.
echo.
pause
cls

echo ================================================
echo   [1] DNS Cozumlemesi
echo ================================================
nslookup api.syncresto.com 2>&1
echo.
echo.

echo ================================================
echo   [2] IPv4 Ping
echo ================================================
ping -4 -n 4 api.syncresto.com
echo.

echo ================================================
echo   [3] IPv6 Ping (genelde fail eder, normal)
echo ================================================
ping -6 -n 2 api.syncresto.com
echo.

echo ================================================
echo   [4] HTTPS Health Check (IPv4 zorla)
echo ================================================
curl -4 -v https://api.syncresto.com/health 2>&1
echo.
echo.

echo ================================================
echo   [5] HTTPS Health Check (IPv6 - genelde fail)
echo ================================================
curl -6 -v --max-time 5 https://api.syncresto.com/health 2>&1
echo.

echo ================================================
echo   [6] POS Validate-Key Endpoint Test
echo ================================================
echo POS exe'nin yaptigi auth cagrisini simule ediyoruz...
curl -4 -v -X POST https://api.syncresto.com/api/pos/validate-key ^
  -H "Content-Type: application/json" ^
  -H "X-API-Key: TEST_KEY_DEGISTIR" 2>&1
echo.

echo ================================================
echo   [7] Windows Firewall - POS Allowed mi?
echo ================================================
netsh advfirewall firewall show rule name=all ^| findstr /I "syncresto pos"
echo.

echo ================================================
echo   [8] Network Adapter IPv6 Durumu
echo ================================================
netsh interface ipv6 show interfaces
echo.

echo ================================================
echo   [9] DNS Sunuculari
echo ================================================
ipconfig /all | findstr /I "DNS"
echo.

echo ================================================
echo   [10] Tum Network Konfigurasyonu
echo ================================================
ipconfig
echo.

echo ================================================
echo  TEST BITTI
echo  ----------------------------------------------
echo  Ust kismi en bastan kopyala, Mustafa'ya gonder.
echo  EN ONEMLI satirlar:
echo    - [4] HTTPS IPv4 - 200 OK mu?
echo    - [6] POS Validate - cevap geliyor mu?
echo    - [7] Firewall - rule var mi?
echo ================================================
pause
