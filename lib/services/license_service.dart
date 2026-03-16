import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'log_service.dart';

/// Lisans durumu
enum LicenseStatus {
  valid,      // Lisans geçerli
  expired,    // Lisans süresi dolmuş
  inactive,   // Lisans devre dışı
  notFound,   // Lisans bulunamadı
  error,      // Kontrol hatası
}

/// Lisans bilgisi
class LicenseInfo {
  final bool isActive;
  final DateTime? expiresAt;
  final String? restaurantName;
  final int? restaurantId;
  final List<String> modules; // Aktif modüller
  final DateTime checkedAt;

  LicenseInfo({
    required this.isActive,
    this.expiresAt,
    this.restaurantName,
    this.restaurantId,
    this.modules = const [],
    DateTime? checkedAt,
  }) : checkedAt = checkedAt ?? DateTime.now();

  /// Lisans süresi dolmuş mu?
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Lisans geçerli mi?
  bool get isValid => isActive && !isExpired;

  /// Kalan gün sayısı
  int get daysRemaining {
    if (expiresAt == null) return 999;
    return expiresAt!.difference(DateTime.now()).inDays;
  }

  /// Son kontrol ne zaman yapıldı?
  int get hoursSinceLastCheck {
    return DateTime.now().difference(checkedAt).inHours;
  }

  Map<String, dynamic> toJson() => {
        'is_active': isActive,
        'expires_at': expiresAt?.toIso8601String(),
        'restaurant_name': restaurantName,
        'restaurant_id': restaurantId,
        'modules': modules,
        'checked_at': checkedAt.toIso8601String(),
        // İmza: Manipülasyonu önlemek için
        'signature': _generateSignature(),
      };

  String _generateSignature() {
    final data = '$isActive:${expiresAt?.millisecondsSinceEpoch}:$restaurantId:${checkedAt.millisecondsSinceEpoch}';
    final bytes = utf8.encode(data + 'SyncResto_License_Salt_2026');
    return sha256.convert(bytes).toString().substring(0, 16);
  }

  factory LicenseInfo.fromJson(Map<String, dynamic> json) {
    final info = LicenseInfo(
      isActive: json['is_active'] ?? false,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'])
          : null,
      restaurantName: json['restaurant_name'],
      restaurantId: json['restaurant_id'],
      modules: List<String>.from(json['modules'] ?? []),
      checkedAt: json['checked_at'] != null
          ? DateTime.tryParse(json['checked_at']) ?? DateTime.now()
          : DateTime.now(),
    );

    // İmza doğrulama
    final savedSignature = json['signature'];
    if (savedSignature != null && savedSignature != info._generateSignature()) {
      // İmza uyuşmuyor - manipüle edilmiş olabilir
      debugPrint('[LicenseService] UYARI: Lisans imzası uyuşmuyor!');
      return LicenseInfo(
        isActive: false,
        checkedAt: DateTime.now(),
      );
    }

    return info;
  }

  factory LicenseInfo.invalid() {
    return LicenseInfo(
      isActive: false,
      checkedAt: DateTime.now(),
    );
  }
}

/// Lisans kontrol sonucu
class LicenseCheckResult {
  final LicenseStatus status;
  final LicenseInfo? licenseInfo;
  final String? errorMessage;

  LicenseCheckResult({
    required this.status,
    this.licenseInfo,
    this.errorMessage,
  });

  bool get isValid => status == LicenseStatus.valid;
  bool get isExpired => status == LicenseStatus.expired;
  bool get canUseOffline {
    // Offline kullanım için:
    // 1. Lisans bilgisi mevcut olmalı
    // 2. Son 12 saat içinde online kontrol edilmiş olmalı
    // 3. Lisans aktif ve geçerli olmalı
    // NOT: API key pasif edilmişse, online kontrol sırasında cache temizlenecek
    //      ve bu fonksiyon false dönecek
    if (licenseInfo == null) return false;
    if (!licenseInfo!.isActive) return false; // Lisans pasif ise offline kullanım yok
    if (licenseInfo!.hoursSinceLastCheck > 12) return false; // 12 saatten eski kontrol
    if (licenseInfo!.isValid) return true;
    // Grace period: Sadece SÜRE dolmuş lisanslar için (pasif edilmiş değil)
    if (licenseInfo!.isExpired && licenseInfo!.daysRemaining >= -3) return true;
    return false;
  }
}

/// Lisans kontrol servisi - Çevrimiçi ve çevrimdışı lisans doğrulama
class LicenseService {
  static final LicenseService _instance = LicenseService._internal();
  factory LicenseService() => _instance;
  LicenseService._internal();

  Dio? _dio;
  String? _apiKey;
  final LogService _logService = LogService();

  static const String _licenseKey = 'pos_license_info';
  static const String _lastOnlineCheckKey = 'pos_license_last_online_check';

  LicenseInfo? _cachedLicenseInfo;

  /// Servisi başlat
  void init(Dio dio, String apiKey) {
    _dio = dio;
    _apiKey = apiKey;
  }

  /// Lisans kontrolü yap
  Future<LicenseCheckResult> checkLicense({bool forceOnline = false}) async {
    // 1. Önce local'den yükle
    final localLicense = await _loadLocalLicense();

    // 2. Online kontrol gerekli mi?
    bool shouldCheckOnline = forceOnline;
    if (!shouldCheckOnline && localLicense != null) {
      // Son 4 saatte kontrol edilmemişse online kontrol yap
      shouldCheckOnline = localLicense.hoursSinceLastCheck >= 4;
    }
    if (localLicense == null) {
      shouldCheckOnline = true;
    }

    // 3. Online kontrol
    if (shouldCheckOnline && _dio != null && _apiKey != null) {
      try {
        final onlineResult = await _checkLicenseOnline();

        // Online kontrol başarılı - sonucu kaydet ve döndür
        if (onlineResult.status == LicenseStatus.valid && onlineResult.licenseInfo != null) {
          await _saveLicenseLicenseLocally(onlineResult.licenseInfo!);
          _cachedLicenseInfo = onlineResult.licenseInfo;
          return onlineResult;
        }

        // Online kontrol başarısız (API key pasif, lisans yok vs.)
        // Local cache'i de geçersiz kıl!
        if (onlineResult.status == LicenseStatus.inactive ||
            onlineResult.status == LicenseStatus.expired) {
          await clearLicense(); // Local cache'i temizle
          _logService.warning(
            LogType.general,
            'Lisans geçersiz - cache temizlendi',
            details: {'status': onlineResult.status.name},
          );
          return onlineResult;
        }
      } on DioException catch (e) {
        // Network hatası - sadece bu durumda offline'a izin ver
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown) {
          debugPrint('[LicenseService] Network hatası, offline moda geçiliyor: ${e.message}');
          // Network hatası - local'e devam
        } else {
          // 401, 403 gibi hatalar - lisans geçersiz
          if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
            await clearLicense();
            _logService.warning(
              LogType.general,
              'API key geçersiz veya pasif - cache temizlendi',
            );
            return LicenseCheckResult(
              status: LicenseStatus.inactive,
              errorMessage: e.response?.data?['error'] ?? 'API key geçersiz',
            );
          }
        }
      } catch (e) {
        debugPrint('[LicenseService] Online kontrol hatası: $e');
        // Bilinmeyen hata - local'e devam
      }
    }

    // 4. Local lisansı değerlendir (sadece network hatası durumunda buraya gelir)
    if (localLicense != null) {
      _cachedLicenseInfo = localLicense;

      if (localLicense.isValid) {
        return LicenseCheckResult(
          status: LicenseStatus.valid,
          licenseInfo: localLicense,
        );
      } else if (localLicense.isExpired) {
        // Grace period kontrolü - sadece süresi dolanlar için
        if (localLicense.daysRemaining >= -7) {
          _logService.warning(
            LogType.general,
            'Lisans süresi doldu ama grace period içinde: ${localLicense.daysRemaining} gün',
          );
          return LicenseCheckResult(
            status: LicenseStatus.valid, // Grace period
            licenseInfo: localLicense,
          );
        }
        return LicenseCheckResult(
          status: LicenseStatus.expired,
          licenseInfo: localLicense,
        );
      } else {
        // isActive = false - lisans pasif edilmiş
        return LicenseCheckResult(
          status: LicenseStatus.inactive,
          licenseInfo: localLicense,
        );
      }
    }

    // 5. Hiçbir lisans bulunamadı
    return LicenseCheckResult(
      status: LicenseStatus.notFound,
      errorMessage: 'Lisans bilgisi bulunamadı. Lütfen internete bağlanın.',
    );
  }

  /// Online lisans kontrolü
  Future<LicenseCheckResult> _checkLicenseOnline() async {
    try {
      final response = await _dio!.post(
        '/api/pos/validate-key',
        options: Options(
          headers: {
            'X-API-Key': _apiKey,
          },
        ),
      );

      if (response.statusCode == 200 && response.data['valid'] == true) {
        final data = response.data;

        final licenseInfo = LicenseInfo(
          isActive: true,
          expiresAt: data['license_end'] != null
              ? DateTime.tryParse(data['license_end'])
              : null,
          restaurantName: data['restaurant_name'],
          restaurantId: data['restaurant_id'],
          modules: List<String>.from(data['modules'] ?? []),
        );

        _logService.info(
          LogType.general,
          'Lisans doğrulandı: ${licenseInfo.restaurantName}',
          details: {
            'expires_at': licenseInfo.expiresAt?.toIso8601String(),
            'days_remaining': licenseInfo.daysRemaining,
          },
        );

        return LicenseCheckResult(
          status: LicenseStatus.valid,
          licenseInfo: licenseInfo,
        );
      } else {
        _logService.warning(
          LogType.general,
          'Lisans doğrulanamadı: ${response.data['error'] ?? 'Bilinmeyen hata'}',
        );

        return LicenseCheckResult(
          status: LicenseStatus.inactive,
          errorMessage: response.data['error'] ?? 'Lisans geçersiz',
        );
      }
    } on DioException catch (e) {
      // 401/403 = API key geçersiz veya pasif
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        debugPrint('[LicenseService] API key geçersiz: ${e.response?.statusCode}');
        _logService.warning(
          LogType.general,
          'API key geçersiz veya pasif',
          details: {'status': e.response?.statusCode},
        );
        return LicenseCheckResult(
          status: LicenseStatus.inactive,
          errorMessage: e.response?.data?['error'] ?? 'API key geçersiz veya pasif',
        );
      }
      // Network hatası - rethrow ile üst katmana bildir
      debugPrint('[LicenseService] Network hatası: ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('[LicenseService] Online kontrol hatası: $e');
      return LicenseCheckResult(
        status: LicenseStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Local lisansı yükle
  Future<LicenseInfo?> _loadLocalLicense() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final licenseJson = prefs.getString(_licenseKey);

      if (licenseJson != null) {
        final license = LicenseInfo.fromJson(jsonDecode(licenseJson));
        return license;
      }
    } catch (e) {
      debugPrint('[LicenseService] Local lisans yükleme hatası: $e');
    }
    return null;
  }

  /// Lisansı local'e kaydet
  Future<void> _saveLicenseLicenseLocally(LicenseInfo license) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_licenseKey, jsonEncode(license.toJson()));
      await prefs.setString(
        _lastOnlineCheckKey,
        DateTime.now().toIso8601String(),
      );
    } catch (e) {
      debugPrint('[LicenseService] Lisans kaydetme hatası: $e');
    }
  }

  /// Cached lisans bilgisi
  LicenseInfo? get cachedLicense => _cachedLicenseInfo;

  /// Lisans bilgisini temizle (logout için)
  Future<void> clearLicense() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_licenseKey);
      await prefs.remove(_lastOnlineCheckKey);
      _cachedLicenseInfo = null;
    } catch (e) {
      debugPrint('[LicenseService] Lisans temizleme hatası: $e');
    }
  }
}
