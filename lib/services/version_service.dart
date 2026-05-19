import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';

/// Versiyon bilgisi modeli
class VersionInfo {
  final String currentVersion;
  final String minRequiredVersion;
  final Map<String, String> downloadUrl;
  final Map<String, String> checksums;
  final List<String> changelog;
  final String releaseDate;
  final bool isCritical;

  VersionInfo({
    required this.currentVersion,
    required this.minRequiredVersion,
    required this.downloadUrl,
    required this.checksums,
    required this.changelog,
    required this.releaseDate,
    required this.isCritical,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    return VersionInfo(
      currentVersion: json['current_version'] ?? '1.0.0',
      minRequiredVersion: json['min_required_version'] ?? '1.0.0',
      downloadUrl: Map<String, String>.from(json['download_url'] ?? {}),
      checksums: Map<String, String>.from(json['checksums'] ?? {}),
      changelog: List<String>.from(json['changelog'] ?? []),
      releaseDate: json['release_date'] ?? '',
      isCritical: json['is_critical'] ?? false,
    );
  }
}

/// Güncelleme durumu
enum UpdateStatus {
  upToDate,       // Güncel
  updateAvailable, // Opsiyonel güncelleme mevcut
  updateRequired,  // Zorunlu güncelleme (uygulama kilitli)
  error,          // Hata oluştu
}

/// Güncelleme kontrol sonucu
class UpdateCheckResult {
  final UpdateStatus status;
  final VersionInfo? versionInfo;
  final String? currentVersion;
  final String? errorMessage;

  UpdateCheckResult({
    required this.status,
    this.versionInfo,
    this.currentVersion,
    this.errorMessage,
  });

  bool get isUpdateRequired => status == UpdateStatus.updateRequired;
  bool get isUpdateAvailable => status == UpdateStatus.updateAvailable;
  bool get isUpToDate => status == UpdateStatus.upToDate;
}

/// Versiyon karşılaştırma yardımcı sınıfı
class VersionHelper {
  /// İki versiyonu karşılaştırır
  /// Returns: -1 (v1 < v2), 0 (v1 == v2), 1 (v1 > v2)
  /// Sadece major.minor.patch karsilastirir, '+build' ek kismini yok sayar.
  /// Hatali parse'da 0 (esit) doner.
  static int compare(String v1, String v2) {
    try {
      final clean1 = v1.split('+').first.split('-').first;
      final clean2 = v2.split('+').first.split('-').first;
      final parts1 = clean1.split('.').map(int.parse).toList();
      final parts2 = clean2.split('.').map(int.parse).toList();
      final maxLength = parts1.length > parts2.length ? parts1.length : parts2.length;
      for (var i = 0; i < maxLength; i++) {
        final p1 = i < parts1.length ? parts1[i] : 0;
        final p2 = i < parts2.length ? parts2[i] : 0;
        if (p1 < p2) return -1;
        if (p1 > p2) return 1;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// v1 < v2 mi?
  static bool isLessThan(String v1, String v2) => compare(v1, v2) < 0;

  /// v1 <= v2 mi?
  static bool isLessThanOrEqual(String v1, String v2) => compare(v1, v2) <= 0;

  /// v1 > v2 mi?
  static bool isGreaterThan(String v1, String v2) => compare(v1, v2) > 0;

  /// v1 >= v2 mi?
  static bool isGreaterThanOrEqual(String v1, String v2) => compare(v1, v2) >= 0;
}

/// Otomatik güncelleme servisi
class VersionService {
  static final VersionService _instance = VersionService._internal();
  factory VersionService() => _instance;
  VersionService._internal();

  Dio? _dio;
  String? _apiKey;
  final LogService _logService = LogService();

  /// Servisi başlat
  void init(Dio dio, String apiKey) {
    _dio = dio;
    _apiKey = apiKey;
  }

  /// Platform string'ini al
  String get _platform {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Güncel versiyon bilgisini al
  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  /// Sunucudan versiyon bilgisini al ve karşılaştır
  Future<UpdateCheckResult> checkForUpdates() async {
    if (_dio == null || _apiKey == null) {
      return UpdateCheckResult(
        status: UpdateStatus.error,
        errorMessage: 'Servis başlatılmamış',
      );
    }

    try {
      final currentVersion = await getCurrentVersion();

      final response = await _dio!.get(
        '/api/pos/version',
        options: Options(
          headers: {
            'X-API-Key': _apiKey,
            'X-App-Version': currentVersion,
            'X-Platform': _platform,
            'X-Timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        ),
      );

      if (response.statusCode != 200) {
        return UpdateCheckResult(
          status: UpdateStatus.error,
          errorMessage: 'Sunucu hatası: ${response.statusCode}',
          currentVersion: currentVersion,
        );
      }

      final versionInfo = VersionInfo.fromJson(response.data);

      // Versiyon karşılaştırma
      UpdateStatus status;

      if (VersionHelper.isLessThan(currentVersion, versionInfo.minRequiredVersion)) {
        // Zorunlu güncelleme gerekli
        status = UpdateStatus.updateRequired;
        _logService.logUpdate(
          'Zorunlu güncelleme gerekli: ${versionInfo.currentVersion}',
          version: versionInfo.currentVersion,
        );
      } else if (VersionHelper.isLessThan(currentVersion, versionInfo.currentVersion)) {
        // Opsiyonel güncelleme mevcut
        status = UpdateStatus.updateAvailable;
        _logService.logUpdate(
          'Yeni güncelleme mevcut: ${versionInfo.currentVersion}',
          version: versionInfo.currentVersion,
        );
      } else {
        // Güncel
        status = UpdateStatus.upToDate;
      }

      return UpdateCheckResult(
        status: status,
        versionInfo: versionInfo,
        currentVersion: currentVersion,
      );
    } catch (e) {
      debugPrint('[VersionService] Güncelleme kontrolü hatası: $e');
      _logService.error(
        LogType.update,
        'Güncelleme kontrolü hatası',
        error: e,
      );

      return UpdateCheckResult(
        status: UpdateStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  // ==================== IDEMPOTENT DISMISS (24 saat) ====================
  // Kullanici 'Sonra' derse o surum icin 24 saat tekrar gosterme.
  // Zorunlu update'lerde (isUpdateRequired) dismiss yok — modal her zaman acilir.

  static const String _dismissedVersionKey = 'update_dismissed_version';
  static const String _dismissedAtKey = 'update_dismissed_at';
  static const Duration _dismissTtl = Duration(hours: 24);

  /// Kullanici bu surumu erteledi — 24 saat goosterme
  Future<void> dismissUpdate(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedVersionKey, version);
      await prefs.setInt(_dismissedAtKey, DateTime.now().millisecondsSinceEpoch);
      _logService.logUpdate('Guncelleme ertelendi (24 saat)', version: version);
    } catch (e) {
      debugPrint('[VersionService] dismissUpdate hata: $e');
    }
  }

  /// Bu surum dismiss edildi mi (24 saat icinde)?
  Future<bool> isVersionDismissed(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissedVersion = prefs.getString(_dismissedVersionKey);
      final dismissedAtMs = prefs.getInt(_dismissedAtKey);
      if (dismissedVersion == null || dismissedAtMs == null) return false;
      if (dismissedVersion != version) return false;
      final dismissedAt = DateTime.fromMillisecondsSinceEpoch(dismissedAtMs);
      final age = DateTime.now().difference(dismissedAt);
      return age < _dismissTtl;
    } catch (e) {
      debugPrint('[VersionService] isVersionDismissed hata: $e');
      return false;
    }
  }

  /// Yeni sürüm yüklenince dismissed kayitlari temizle (artik anlamsiz)
  Future<void> clearDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_dismissedVersionKey);
      await prefs.remove(_dismissedAtKey);
    } catch (_) {}
  }

  /// Güncellemeyi indir
  Future<File?> downloadUpdate(
    VersionInfo versionInfo, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final downloadUrl = versionInfo.downloadUrl[_platform];
      if (downloadUrl == null || downloadUrl.isEmpty) {
        throw Exception('Bu platform için indirme linki bulunamadı: $_platform');
      }

      // Geçici klasör
      final tempDir = await getTemporaryDirectory();
      final fileName = 'SyncResto-$_platform-${versionInfo.currentVersion}.zip';
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);

      // Mevcut dosyayı sil
      if (await file.exists()) {
        await file.delete();
      }

      _logService.logUpdate('İndirme başladı: ${versionInfo.currentVersion}');

      // İndirme - redirect'leri takip et
      final downloadDio = Dio(BaseOptions(
        followRedirects: true,
        maxRedirects: 5,
        receiveTimeout: const Duration(minutes: 10),
        connectTimeout: const Duration(seconds: 30),
      ));

      // 19 May 2026: IPv4 force (IPv6 olu networklerde guncelleme indirimi de patlamasin)
      (downloadDio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          final addresses = await InternetAddress.lookup(
            uri.host,
            type: InternetAddressType.IPv4,
          );
          if (addresses.isEmpty) {
            throw SocketException('IPv4 adresi bulunamadi: ${uri.host}');
          }
          return Socket.startConnect(addresses.first, uri.port);
        };
        return client;
      };

      final response = await downloadDio.download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          onProgress?.call(received, total);
        },
      );

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception('İndirme hatası: ${response.statusCode}');
      }

      // Checksum doğrulama
      final expectedChecksum = versionInfo.checksums[_platform];
      if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
        final isValid = await _verifyChecksum(file, expectedChecksum);
        if (!isValid) {
          await file.delete();
          throw Exception('Dosya bütünlüğü doğrulanamadı (checksum hatası)');
        }
        debugPrint('[VersionService] Checksum doğrulama başarılı');
      }

      _logService.logUpdate(
        'İndirme tamamlandı: ${versionInfo.currentVersion}',
        version: versionInfo.currentVersion,
      );

      return file;
    } catch (e) {
      debugPrint('[VersionService] İndirme hatası: $e');
      _logService.error(LogType.update, 'İndirme hatası', error: e);
      return null;
    }
  }

  /// SHA-256 checksum doğrulama
  Future<bool> _verifyChecksum(File file, String expectedChecksum) async {
    try {
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      final actualChecksum = digest.toString();

      // sha256:xxx formatını temizle
      final cleanExpected = expectedChecksum.replaceFirst('sha256:', '');

      return actualChecksum.toLowerCase() == cleanExpected.toLowerCase();
    } catch (e) {
      debugPrint('[VersionService] Checksum hesaplama hatası: $e');
      return false;
    }
  }

  /// Dosyaya log yaz (debug için)
  Future<void> _writeDebugLog(String message) async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final logFile = File('$home/syncresto_update.log');
      final timestamp = DateTime.now().toIso8601String();
      await logFile.writeAsString('[$timestamp] $message\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Güncellemeyi uygula
  /// [expectedVersion]: paket içindeki .app sürümü bununla eşleşmeli (mac doğrulama için)
  Future<bool> applyUpdate(File updateFile, {String? expectedVersion}) async {
    try {
      await _writeDebugLog('=== Güncelleme başlıyor ===');
      await _writeDebugLog('Update file: ${updateFile.path}');
      _logService.logUpdate('Güncelleme uygulanıyor...');

      if (_platform == 'macos') {
        // macOS: ZIP'i çıkart ve ~/Applications'a kopyala (izin sorunu yok)
        final home = Platform.environment['HOME'];
        if (home == null) {
          throw Exception('HOME dizini bulunamadı');
        }

        final userAppsDir = Directory('$home/Applications');
        if (!await userAppsDir.exists()) {
          await userAppsDir.create(recursive: true);
        }

        final tempDir = await getTemporaryDirectory();
        final extractDir = Directory('${tempDir.path}/SyncResto_Update');

        // Önceki çıkartmayı temizle
        if (await extractDir.exists()) {
          await extractDir.delete(recursive: true);
        }
        await extractDir.create();

        await _writeDebugLog('HOME: $home');
        await _writeDebugLog('Extract dir: ${extractDir.path}');
        debugPrint('[VersionService] ZIP çıkartılıyor: ${updateFile.path}');
        debugPrint('[VersionService] Extract dir: ${extractDir.path}');

        // ZIP'i çıkart
        final unzipResult = await Process.run('unzip', [
          '-o',
          updateFile.path,
          '-d', extractDir.path,
        ]);

        await _writeDebugLog('Unzip exit code: ${unzipResult.exitCode}');
        await _writeDebugLog('Unzip stdout: ${unzipResult.stdout}');
        await _writeDebugLog('Unzip stderr: ${unzipResult.stderr}');
        debugPrint('[VersionService] Unzip exit code: ${unzipResult.exitCode}');
        debugPrint('[VersionService] Unzip stdout: ${unzipResult.stdout}');
        debugPrint('[VersionService] Unzip stderr: ${unzipResult.stderr}');

        if (unzipResult.exitCode != 0) {
          await _writeDebugLog('HATA: ZIP çıkartma başarısız');
          throw Exception('ZIP çıkartma hatası: ${unzipResult.stderr}');
        }

        // Çıkartılan dosyaları listele
        final listResult = await Process.run('ls', ['-la', extractDir.path]);
        await _writeDebugLog('Extracted files: ${listResult.stdout}');
        debugPrint('[VersionService] Extracted files: ${listResult.stdout}');

        final appPath = '$home/Applications/SyncResto POS.app';
        // ZIP içinde nested olabilir, kontrol et
        String newAppPath = '${extractDir.path}/SyncResto POS.app';

        // Eğer direkt yoksa, içindeki klasöre bak
        final directApp = Directory(newAppPath);
        if (!await directApp.exists()) {
          debugPrint('[VersionService] Direkt app bulunamadı, nested kontrol ediliyor...');
          // macOS klasör yapısı bazen __MACOSX içerir
          final findResult = await Process.run('find', [
            extractDir.path,
            '-name', '*.app',
            '-type', 'd',
            '-maxdepth', '3',
          ]);
          debugPrint('[VersionService] Find result: ${findResult.stdout}');

          final apps = (findResult.stdout as String).trim().split('\n').where((p) =>
            p.endsWith('.app') && !p.contains('__MACOSX')).toList();

          if (apps.isNotEmpty) {
            newAppPath = apps.first;
            debugPrint('[VersionService] Bulunan app: $newAppPath');
          } else {
            throw Exception('ZIP içinde .app bulunamadı');
          }
        }

        // Source app var mı kontrol et
        final sourceApp = Directory(newAppPath);
        final sourceExists = await sourceApp.exists();
        debugPrint('[VersionService] Source app exists: $sourceExists');

        if (!sourceExists) {
          throw Exception('Kaynak app bulunamadı: $newAppPath');
        }

        // ÖN-DOĞRULAMA: Yeni .app içindeki Info.plist version'ı, beklenen sürümle eşleşiyor mu?
        // Eşleşmezse mevcut kuruluma DOKUNMA — yanlış/bozuk paket kullanıcının çalışan kurulumunu bozmasın.
        if (expectedVersion != null && expectedVersion.isNotEmpty) {
          try {
            final plistPath = '$newAppPath/Contents/Info.plist';
            final plistFile = File(plistPath);
            if (await plistFile.exists()) {
              final plistResult = await Process.run(
                '/usr/libexec/PlistBuddy',
                ['-c', 'Print CFBundleShortVersionString', plistPath],
              );
              final actualVersion = (plistResult.stdout as String).trim();
              await _writeDebugLog('İndirilen .app sürümü: $actualVersion (beklenen: $expectedVersion)');
              debugPrint('[VersionService] .app version: $actualVersion, beklenen: $expectedVersion');
              // Sadece major.minor.patch karşılaştır (çıkardığımız zip'te +build farklı olabilir)
              String stripBuild(String v) => v.split('+').first.trim();
              if (actualVersion.isNotEmpty && stripBuild(actualVersion) != stripBuild(expectedVersion)) {
                await _writeDebugLog('UYARI: Sürüm eşleşmiyor — mevcut kurulum korunuyor');
                throw Exception('İndirilen paket sürümü beklenen sürümle eşleşmiyor (paket: $actualVersion, beklenen: $expectedVersion). Güncelleme iptal edildi.');
              }
            }
          } catch (e) {
            // PlistBuddy yoksa veya hata varsa, akışa devam et (kritik değil) ama logla
            if (e.toString().contains('eşleşmiyor')) rethrow;
            await _writeDebugLog('Plist doğrulama atlandı: $e');
          }
        }

        // Eski uygulamayı YEDEKLE (rollback için), sonra sil
        final backupPath = '$appPath.backup';
        final oldApp = Directory(appPath);
        if (await oldApp.exists()) {
          debugPrint('[VersionService] Eski uygulama yedekleniyor: $appPath -> $backupPath');
          // Eski yedek varsa sil
          final oldBackup = Directory(backupPath);
          if (await oldBackup.exists()) {
            await oldBackup.delete(recursive: true);
          }
          // Eski .app'i .backup'a taşı (rename)
          await Process.run('mv', [appPath, backupPath]);
        }

        // Yeni uygulamayı kopyala
        debugPrint('[VersionService] Yeni uygulama kopyalanıyor: $newAppPath -> $appPath');
        await _writeDebugLog('Kopyalama: $newAppPath -> $appPath');
        final copyResult = await Process.run('cp', ['-R', newAppPath, appPath]);
        await _writeDebugLog('Copy exit code: ${copyResult.exitCode}');
        await _writeDebugLog('Copy stderr: ${copyResult.stderr}');
        debugPrint('[VersionService] Copy exit code: ${copyResult.exitCode}');
        debugPrint('[VersionService] Copy stderr: ${copyResult.stderr}');

        if (copyResult.exitCode != 0) {
          await _writeDebugLog('HATA: Kopyalama başarısız, eski sürümü geri yükle');
          // Rollback: yedeği geri taşı
          final backup = Directory(backupPath);
          if (await backup.exists()) {
            await Process.run('mv', [backupPath, appPath]);
          }
          throw Exception('Kopyalama hatası: ${copyResult.stderr}');
        }

        // Kopyalama başarılı mı kontrol et
        final targetApp = Directory(appPath);
        final targetExists = await targetApp.exists();
        await _writeDebugLog('Target app exists: $targetExists');
        debugPrint('[VersionService] Target app exists: $targetExists');

        if (!targetExists) {
          await _writeDebugLog('HATA: Hedef app bulunamadı, eski sürümü geri yükle');
          // Rollback
          final backup = Directory(backupPath);
          if (await backup.exists()) {
            await Process.run('mv', [backupPath, appPath]);
          }
          throw Exception('Kopyalama sonrası hedef app bulunamadı');
        }

        // Başarılı — yedeği temizle
        try {
          final backup = Directory(backupPath);
          if (await backup.exists()) {
            await backup.delete(recursive: true);
          }
        } catch (_) {}

        await _writeDebugLog('Güncelleme tamamlandı!');
        _logService.logUpdate('Güncelleme tamamlandı, uygulama yeniden başlatılıyor...');

        // Yeni uygulamayı başlat
        await _writeDebugLog('Uygulama başlatılıyor: $appPath');
        debugPrint('[VersionService] Uygulama başlatılıyor: $appPath');

        // open komutu yerine detached process kullan
        final openResult = await Process.start(
          'open',
          ['-n', '-a', appPath],  // -n: new instance, -a: application
          mode: ProcessStartMode.detached,
        );
        await _writeDebugLog('Open process PID: ${openResult.pid}');
        debugPrint('[VersionService] Open process started, PID: ${openResult.pid}');

        // Biraz bekle
        await Future.delayed(const Duration(seconds: 2));

        // Log'ları gönder ve uygulamayı kapat
        await _logService.flush();
        await _writeDebugLog('Uygulama kapatılıyor...');
        debugPrint('[VersionService] Uygulama kapatılıyor...');
        exit(0);

      } else if (_platform == 'windows') {
        // Windows: ZIP'i çıkart ve mevcut kurulumu KOMPLE değiştir.
        // Kritik kurallar:
        //   1. Önce eski klasörün İÇERİĞİ silinir (klasörün kendisi değil — yetki sorunu çıkmasın)
        //   2. Yeni dosyalar robocopy /MIR ile aynalanır (eski silinen dosyalar bırakılmaz)
        //   3. Çalışan .exe kapanması için 20 saniye bekle, sonra start
        //   4. Hata olursa batch errorlevel ile yakalanır, log'a yazılır
        final appData = Platform.environment['LOCALAPPDATA'];
        if (appData == null) {
          throw Exception('LOCALAPPDATA bulunamadı');
        }

        final appDir = '$appData\\SyncResto POS';
        final tempDir = await getTemporaryDirectory();
        final extractDir = '${tempDir.path}\\SyncResto_Update';
        final logFile = '${tempDir.path}\\syncresto_updater.log';

        await _writeDebugLog('=== Windows update başlıyor ===');
        await _writeDebugLog('appDir: $appDir');
        await _writeDebugLog('extractDir: $extractDir');

        // Önceki extract dizinini temizle
        try {
          final oldExtract = Directory(extractDir);
          if (await oldExtract.exists()) {
            await oldExtract.delete(recursive: true);
          }
        } catch (_) {}

        // Uygulama dizini yoksa oluştur
        final appDirObj = Directory(appDir);
        if (!await appDirObj.exists()) {
          await appDirObj.create(recursive: true);
        }

        // PowerShell ile ZIP çıkart
        final extractResult = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Expand-Archive -Path "${updateFile.path}" -DestinationPath "$extractDir" -Force',
        ]);

        if (extractResult.exitCode != 0) {
          await _writeDebugLog('Extract hatası: ${extractResult.stderr}');
          throw Exception('ZIP çıkartma hatası: ${extractResult.stderr}');
        }

        // ZIP içinde nested klasör (örn. "SyncResto-Windows/") olabilir, gerçek source path'i bul
        // Eğer extractDir içinde tek bir alt klasör varsa ve içinde .exe varsa, onu kullan
        String sourceDir = extractDir;
        try {
          final entries = await Directory(extractDir).list().toList();
          final dirs = entries.whereType<Directory>().toList();
          // Tek dir + içinde exe yoksa nested kabul et
          if (dirs.length == 1) {
            final exeInRoot = entries.whereType<File>().any((f) => f.path.toLowerCase().endsWith('.exe'));
            if (!exeInRoot) {
              sourceDir = dirs.first.path;
              await _writeDebugLog('Nested klasör tespit edildi: $sourceDir');
            }
          }
        } catch (e) {
          await _writeDebugLog('Source dir tespit hatası: $e');
        }

        // Updater batch script — robocopy /MIR + bekleme + restart + hata kontrolü
        // %ERRORLEVEL% < 8 = robocopy başarılı (8+ gerçek hata)
        final batchContent = '''
@echo off
setlocal enabledelayedexpansion
echo [%date% %time%] Update başlıyor > "$logFile"
echo Source: $sourceDir >> "$logFile"
echo Target: $appDir >> "$logFile"

REM Çalışan POS uygulamasının kapanmasını bekle (max 30 sn)
echo Eski uygulama kapanıyor... >> "$logFile"
taskkill /IM "SyncResto POS.exe" /F >nul 2>&1
timeout /t 5 /nobreak > nul

REM Robocopy ile mirror — eski dosyalar silinir, yeniler kopyalanır
REM /MIR: mirror, /R:3 retry 3, /W:2 wait 2, /NFL/NDL/NJH/NJS quiet
robocopy "$sourceDir" "$appDir" /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS >> "$logFile" 2>&1
set RC=!ERRORLEVEL!
echo Robocopy exit code: !RC! >> "$logFile"

REM Robocopy 0-7 başarılı, 8+ hata
if !RC! GEQ 8 (
  echo HATA: Robocopy başarısız !RC! >> "$logFile"
  pause
  exit /b 1
)

echo Yeni uygulama başlatılıyor... >> "$logFile"
start "" "$appDir\\SyncResto POS.exe"
echo [%date% %time%] Update tamamlandı >> "$logFile"

REM Updater script'i kendini sil
(goto) 2>nul & del "%~f0"
''';

        final batchFile = File('${tempDir.path}\\syncresto_updater.bat');
        await batchFile.writeAsString(batchContent);

        await _writeDebugLog('Batch dosyası yazıldı: ${batchFile.path}');

        // Detached olarak başlat — POS app kapatılınca da batch yaşamaya devam etsin
        await Process.start(
          'cmd',
          ['/c', 'start', '""', '/MIN', batchFile.path],
          mode: ProcessStartMode.detached,
          runInShell: true,
        );

        await _writeDebugLog('Updater başlatıldı, uygulama kapatılıyor...');
        await _logService.flush();
        // Kısa bekleme — batch'in taskkill'e ulaşmasından önce kendi çıkışımızı garantile
        await Future.delayed(const Duration(milliseconds: 500));
        exit(0);
      }

      return false;
    } catch (e) {
      await _writeDebugLog('EXCEPTION: $e');
      debugPrint('[VersionService] Güncelleme uygulama hatası: $e');
      _logService.error(LogType.update, 'Güncelleme uygulama hatası', error: e);
      return false;
    }
  }

  /// Uygulama dizinini al
  Future<Directory?> _getApplicationDirectory() async {
    try {
      if (Platform.isWindows) {
        final appData = Platform.environment['LOCALAPPDATA'];
        if (appData != null) {
          return Directory('$appData\\SyncResto POS');
        }
      } else if (Platform.isMacOS) {
        return Directory('/Applications/SyncResto POS.app/Contents/MacOS');
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
