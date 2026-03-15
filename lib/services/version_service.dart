import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
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

      // İndirme
      final response = await Dio().download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          onProgress?.call(received, total);
        },
      );

      if (response.statusCode != 200) {
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

  /// Güncellemeyi uygula (updater script'i çalıştır)
  Future<bool> applyUpdate(File updateFile) async {
    try {
      final appDir = await _getApplicationDirectory();
      if (appDir == null) {
        throw Exception('Uygulama dizini bulunamadı');
      }

      _logService.logUpdate('Güncelleme uygulanıyor...');

      // Updater script yolu
      final updaterPath = _platform == 'windows'
          ? '${appDir.path}\\updater.bat'
          : '${appDir.path}/updater.sh';

      final updaterFile = File(updaterPath);
      if (!await updaterFile.exists()) {
        throw Exception('Updater script bulunamadı: $updaterPath');
      }

      // Updater'ı çalıştır ve uygulamayı kapat
      if (_platform == 'windows') {
        await Process.start(
          'cmd',
          ['/c', 'start', '', updaterPath, updateFile.path, appDir.path],
          mode: ProcessStartMode.detached,
        );
      } else {
        // macOS / Linux
        await Process.start(
          'bash',
          [updaterPath, updateFile.path, appDir.path],
          mode: ProcessStartMode.detached,
        );
      }

      // Log'ları gönder ve uygulamayı kapat
      await _logService.flush();
      exit(0);
    } catch (e) {
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
