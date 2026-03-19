import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
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
  static int compare(String v1, String v2) {
    final parts1 = v1.split('.').map(int.parse).toList();
    final parts2 = v2.split('.').map(int.parse).toList();

    final maxLength = parts1.length > parts2.length ? parts1.length : parts2.length;

    for (var i = 0; i < maxLength; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 < p2) return -1;
      if (p1 > p2) return 1;
    }

    return 0;
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

      // Windows'ta SSL sertifika sorunlarını bypass et
      if (Platform.isWindows) {
        (downloadDio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
          final client = HttpClient();
          client.badCertificateCallback = (cert, host, port) => true;
          return client;
        };
      }

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
  Future<bool> applyUpdate(File updateFile) async {
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

        // Eski uygulamayı sil
        final oldApp = Directory(appPath);
        if (await oldApp.exists()) {
          debugPrint('[VersionService] Eski uygulama siliniyor: $appPath');
          await oldApp.delete(recursive: true);
        }

        // Yeni uygulamayı kopyala
        debugPrint('[VersionService] Yeni uygulama kopyalanıyor: $newAppPath -> $appPath');

        // Source app var mı kontrol et
        final sourceApp = Directory(newAppPath);
        final sourceExists = await sourceApp.exists();
        debugPrint('[VersionService] Source app exists: $sourceExists');

        if (!sourceExists) {
          throw Exception('Kaynak app bulunamadı: $newAppPath');
        }

        await _writeDebugLog('Kopyalama: $newAppPath -> $appPath');
        final copyResult = await Process.run('cp', ['-R', newAppPath, appPath]);
        await _writeDebugLog('Copy exit code: ${copyResult.exitCode}');
        await _writeDebugLog('Copy stderr: ${copyResult.stderr}');
        debugPrint('[VersionService] Copy exit code: ${copyResult.exitCode}');
        debugPrint('[VersionService] Copy stderr: ${copyResult.stderr}');

        if (copyResult.exitCode != 0) {
          await _writeDebugLog('HATA: Kopyalama başarısız');
          throw Exception('Kopyalama hatası: ${copyResult.stderr}');
        }

        // Kopyalama başarılı mı kontrol et
        final targetApp = Directory(appPath);
        final targetExists = await targetApp.exists();
        await _writeDebugLog('Target app exists: $targetExists');
        debugPrint('[VersionService] Target app exists: $targetExists');

        if (!targetExists) {
          await _writeDebugLog('HATA: Hedef app bulunamadı');
          throw Exception('Kopyalama sonrası hedef app bulunamadı');
        }

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
        // Windows: ZIP'i çıkart ve güncelle
        final appData = Platform.environment['LOCALAPPDATA'];
        if (appData == null) {
          throw Exception('LOCALAPPDATA bulunamadı');
        }

        final appDir = '$appData\\SyncResto POS';
        final tempDir = await getTemporaryDirectory();
        final extractDir = '${tempDir.path}\\SyncResto_Update';

        // Uygulama dizini yoksa oluştur
        final appDirObj = Directory(appDir);
        if (!await appDirObj.exists()) {
          await appDirObj.create(recursive: true);
        }

        // PowerShell ile ZIP çıkart
        final extractResult = await Process.run('powershell', [
          '-Command',
          'Expand-Archive -Path "${updateFile.path}" -DestinationPath "$extractDir" -Force',
        ]);

        if (extractResult.exitCode != 0) {
          throw Exception('ZIP çıkartma hatası: ${extractResult.stderr}');
        }

        // Batch script oluştur ve çalıştır
        final batchContent = '''
@echo off
timeout /t 2 /nobreak > nul
xcopy /E /Y "$extractDir\\*" "$appDir\\"
start "" "$appDir\\SyncResto POS.exe"
del "%~f0"
''';

        final batchFile = File('${tempDir.path}\\syncresto_updater.bat');
        await batchFile.writeAsString(batchContent);

        await Process.start('cmd', ['/c', batchFile.path], mode: ProcessStartMode.detached);

        await _logService.flush();
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
