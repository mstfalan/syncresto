import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Log seviyesi
enum LogLevel { info, warning, error }

/// Log türü
enum LogType { error, sync, syncError, login, action, update, general, lan }

/// Tek bir log kaydı
class LogEntry {
  final LogLevel level;
  final LogType type;
  final String message;
  final Map<String, dynamic>? details;
  final int? userId;
  final String? userName;
  final DateTime timestamp;

  LogEntry({
    required this.level,
    required this.type,
    required this.message,
    this.details,
    this.userId,
    this.userName,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'log_level': level.name,
        'log_type': _typeToString(type),
        'message': message,
        'details': details,
        'user_id': userId,
        'user_name': userName,
        'timestamp': timestamp.toIso8601String(),
      };

  String _typeToString(LogType type) {
    switch (type) {
      case LogType.syncError:
        return 'sync_error';
      default:
        return type.name;
    }
  }
}

/// Merkezi log servisi - POS loglarını SyncResto'ya gönderir
class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  Dio? _dio;
  String? _apiKey;
  String? _deviceId;
  String? _appVersion;
  String? _platform;
  int? _currentUserId;
  String? _currentUserName;

  final List<LogEntry> _pendingLogs = [];
  Timer? _flushTimer;
  bool _isInitialized = false;
  bool _isFlushing = false;

  // Ayarlar
  static const int _maxPendingLogs = 50;
  static const Duration _flushInterval = Duration(seconds: 30);
  static const String _pendingLogsKey = 'pending_pos_logs'; // legacy (migrate-once)

  // 1 Haz 2026 — Şişme önleme (v1.5.6):
  // Sahada sunucu down olursa _pendingLogs RAM'de + SharedPreferences XML'inde
  // sınırsız büyüyordu. Üst limit + dosya bazlı persist eklendi.
  static const int _maxRetainedLogs = 1000;         // RAM cap (en yeniler kalır)
  static const int _maxPersistedBytes = 1024 * 1024; // disk cap 1MB
  static const String _persistFileName = 'pending_logs.json';
  File? _persistFile;

  /// Servisi başlat
  Future<void> init(Dio dio, String apiKey) async {
    if (_isInitialized) return;

    _dio = dio;
    _apiKey = apiKey;
    await _loadDeviceInfo();
    await _loadPendingLogs();
    _startFlushTimer();
    _isInitialized = true;

    // 23 Tem 2026: acilista build parmak-izi — hangi surumun GERCEKTEN kurulu
    // oldugu tek bakista gorunsun (saha "son surum mu?" belirsizligini bitirir).
    info(LogType.general, 'Log servisi baslatildi (surum $_appVersion)',
        details: {'app_version': _appVersion, 'platform': _platform});
  }

  /// Cihaz bilgilerini yükle
  Future<void> _loadDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();

      // 23 Tem 2026: build numarasini da ekle (1.6.6 -> 1.6.6+58). Surum bump
      // yapmiyoruz (release tetiklenmesin) ama +buildNumber sahada "hangi build
      // kurulu" belirsizligini bitirir — ayni "1.6.6" iki farkli build olabiliyordu.
      final bn = packageInfo.buildNumber;
      _appVersion = bn.isNotEmpty ? '${packageInfo.version}+$bn' : packageInfo.version;

      if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        _deviceId = windowsInfo.deviceId;
        _platform = 'windows';
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        _deviceId = macInfo.systemGUID ?? 'unknown';
        _platform = 'macos';
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        _deviceId = linuxInfo.machineId ?? 'unknown';
        _platform = 'linux';
      } else {
        _deviceId = 'unknown';
        _platform = Platform.operatingSystem;
      }
    } catch (e) {
      debugPrint('[LogService] Cihaz bilgisi alınamadı: $e');
      _deviceId = 'unknown';
      _platform = 'unknown';
    }
  }

  /// Kullanıcı bilgisini ayarla
  void setUser(int? userId, String? userName) {
    _currentUserId = userId;
    _currentUserName = userName;
  }

  /// Kullanıcı bilgisini temizle
  void clearUser() {
    _currentUserId = null;
    _currentUserName = null;
  }

  /// Info seviyesinde log ekle
  void info(LogType type, String message, {Map<String, dynamic>? details}) {
    _addLog(LogLevel.info, type, message, details: details);
  }

  /// Warning seviyesinde log ekle
  void warning(LogType type, String message, {Map<String, dynamic>? details}) {
    _addLog(LogLevel.warning, type, message, details: details);
  }

  /// Error seviyesinde log ekle
  void error(LogType type, String message,
      {Map<String, dynamic>? details, dynamic error, StackTrace? stackTrace}) {
    final errorDetails = <String, dynamic>{
      ...?details,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stack_trace': stackTrace.toString().split('\n').take(10).join('\n'),
    };
    _addLog(LogLevel.error, type, message, details: errorDetails);
  }

  /// Login log'u
  void logLogin(int userId, String userName) {
    setUser(userId, userName);
    info(LogType.login, 'Kullanıcı giriş yaptı: $userName');
  }

  /// Logout log'u
  void logLogout() {
    final userName = _currentUserName ?? 'Bilinmeyen';
    info(LogType.login, 'Kullanıcı çıkış yaptı: $userName');
    clearUser();
  }

  /// Sync log'u
  void logSync(String message, {int? count, String? operation}) {
    info(LogType.sync, message, details: {
      if (count != null) 'count': count,
      if (operation != null) 'operation': operation,
    });
  }

  /// Sync error log'u
  void logSyncError(String message, {String? operation, dynamic error}) {
    this.error(LogType.syncError, message, details: {
      if (operation != null) 'operation': operation,
    }, error: error);
  }

  /// Action log'u (masa açma, kapama vb.)
  void logAction(String action, {Map<String, dynamic>? details}) {
    info(LogType.action, action, details: details);
  }

  /// Update log'u
  void logUpdate(String message, {String? version}) {
    info(LogType.update, message, details: {
      if (version != null) 'version': version,
    });
  }

  /// Log ekle
  void _addLog(LogLevel level, LogType type, String message,
      {Map<String, dynamic>? details}) {
    final entry = LogEntry(
      level: level,
      type: type,
      message: message,
      details: details,
      userId: _currentUserId,
      userName: _currentUserName,
    );

    _pendingLogs.add(entry);
    debugPrint('[LOG ${level.name.toUpperCase()}] ${type.name}: $message');

    // Max log sayısına ulaştıysa hemen gönder
    if (_pendingLogs.length >= _maxPendingLogs) {
      flush();
    }
  }

  /// Flush timer'ı başlat
  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Bekleyen logları sunucuya gönder
  Future<void> flush() async {
    if (_isFlushing) return;
    if (_pendingLogs.isEmpty || _dio == null || _apiKey == null) return;

    _isFlushing = true;

    // Max 100 log per batch — 413 Payload Too Large engeli
    const maxBatchSize = 100;
    final logsToSend = _pendingLogs.length > maxBatchSize
        ? _pendingLogs.sublist(0, maxBatchSize)
        : List<LogEntry>.from(_pendingLogs);

    // Sadece gonderilenleri pending'den dusur (digerleri sonraki flush'a kalir)
    _pendingLogs.removeRange(0, logsToSend.length);

    if (logsToSend.isEmpty) {
      _isFlushing = false;
      return;
    }

    try {
      final response = await _dio!.post(
        '/api/pos/logs',
        options: Options(
          headers: {
            'X-API-Key': _apiKey,
            'X-Device-Id': _deviceId,
            'X-App-Version': _appVersion,
            'X-Platform': _platform,
          },
          // 413 ve diger 4xx hatalarda exception yerine response'a izin ver
          validateStatus: (s) => s != null && s < 500,
        ),
        data: {
          'logs': logsToSend.map((l) => l.toJson()).toList(),
          'device_info': {
            'device_id': _deviceId,
            'app_version': _appVersion,
            'platform': _platform,
          },
        },
      );

      // 🔴 6 Agu 2026 — LOG TEKRARI (REPLAY) FIX.
      // ESKI DAVRANIS: _pendingLogs.removeRange (satir ~255) SADECE BELLEKTEN siliyordu;
      // disk (pending_logs.json) yalnizca BASARISIZLIK yollarinda guncelleniyordu.
      // Basarili gonderimden sonra dosya ESKI HALIYLE kaliyor -> her acilista
      // _loadPendingLogs onu tekrar kuyruga koyup TEKRAR gonderiyordu. Sunucuda dedupe yok
      // ve backend created_at'i NOW() ile bastigi icin onlarca eski kayit AYNI SANIYEYE
      // dusuyordu. Sonuc: pos_logs %57 tekrar (151.870 ham -> 65.395 tekil), redirect-loop
      // hatasi 26 gercek olay 29.337 satir gorunuyordu (1128x sisme) ve teshisler yaniltiyordu.
      // FIX: kuyrugu KUCULTEN her yolda diski de senkronla. Kuyruk bosaldiysa dosya "[]" olur.
      // NOT: _clearPendingLogs() (satir ~448) bu is icin UYGUN DEGIL — o yalnizca legacy
      // SharedPreferences anahtarini siliyor, dosyaya DOKUNMUYOR. Olu ama silinmedi
      // ([[feedback_fix_dead_code_check]]: kullanim testi yapilmadan silme yok).
      if (response.statusCode == 200) {
        debugPrint('[LogService] ${logsToSend.length} log gönderildi');
        await _savePendingLogs();
      } else if (response.statusCode == 413) {
        // Payload Too Large — bu log'lari DROP et, geri pending'e ekleme.
        // Sonsuz dongu engelleyici. Sahada sunucu limiti ayarlanana kadar
        // log telemetrisi kismi olur ama POS yasamaya devam eder.
        debugPrint('[LogService] 413 Payload Too Large — ${logsToSend.length} log atildi (sonsuz dongu engellendi)');
        await _savePendingLogs();
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        // Auth hatasi — kucuk batch tekrar denemenin anlami yok, drop
        debugPrint('[LogService] Auth hatasi (${response.statusCode}) — ${logsToSend.length} log atildi');
        await _savePendingLogs();
      } else {
        // Diger hatalar (5xx vs) — geri pending'e ekle, sonra retry
        _pendingLogs.insertAll(0, logsToSend);
        _capPendingLogs(); // 1 Haz 2026: max 1000, taşan en eski log'lar drop
        await _savePendingLogs();
      }
    } catch (e) {
      // Network/timeout vs — sadece bunlari retry et
      debugPrint('[LogService] Log gonderme network hatasi: $e');
      _pendingLogs.insertAll(0, logsToSend);
      _capPendingLogs(); // 1 Haz 2026: max 1000, taşan en eski log'lar drop
      await _savePendingLogs();
    } finally {
      _isFlushing = false;
    }
  }

  /// 1 Haz 2026 (v1.5.6) — _pendingLogs üst limit guard'ı.
  /// Sunucu uzun süre down kalsa bile RAM/disk sınırsız büyümez.
  /// En eski log'lar drop edilir, son N tutulur.
  void _capPendingLogs() {
    if (_pendingLogs.length > _maxRetainedLogs) {
      final dropCount = _pendingLogs.length - _maxRetainedLogs;
      _pendingLogs.removeRange(0, dropCount);
      debugPrint('[LogService] $dropCount eski log drop edildi (cap=$_maxRetainedLogs)');
    }
  }

  /// 1 Haz 2026 (v1.5.6) — Disk persist dosyası (lazy init).
  /// SharedPreferences XML'i log için verimsiz, ayrı dosya kullanılır.
  Future<File?> _getPersistFile() async {
    if (_persistFile != null) return _persistFile;
    try {
      final dir = await getApplicationSupportDirectory();
      _persistFile = File(path.join(dir.path, _persistFileName));
      return _persistFile;
    } catch (e) {
      debugPrint('[LogService] Persist dosyası açılamadı: $e');
      return null;
    }
  }

  /// Bekleyen logları local'e kaydet
  /// 1 Haz 2026: dosya bazlı + boyut guard (>1MB ise drop + uyarı)
  Future<void> _savePendingLogs() async {
    try {
      _capPendingLogs(); // garanti
      final logsJson = _pendingLogs.map((l) => l.toJson()).toList();
      final jsonStr = jsonEncode(logsJson);

      // Boyut guard
      if (jsonStr.length > _maxPersistedBytes) {
        // En yeni 500'ünü tut, gerisini drop
        final keep = _pendingLogs.length > 500
            ? _pendingLogs.sublist(_pendingLogs.length - 500)
            : List<LogEntry>.from(_pendingLogs);
        _pendingLogs
          ..clear()
          ..addAll(keep);
        debugPrint('[LogService] Disk persist >1MB → en yeni 500 log tutuldu');
      }

      final file = await _getPersistFile();
      if (file != null) {
        await file.writeAsString(jsonEncode(_pendingLogs.map((l) => l.toJson()).toList()));
      } else {
        // Fallback: SharedPreferences (legacy)
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingLogsKey, jsonEncode(_pendingLogs.map((l) => l.toJson()).toList()));
      }
    } catch (e) {
      debugPrint('[LogService] Log kaydetme hatası: $e');
    }
  }

  /// Bekleyen logları local'den yükle
  /// 1 Haz 2026: önce dosya, yoksa eski SharedPreferences (legacy migration)
  Future<void> _loadPendingLogs() async {
    try {
      // 1) Dosyadan yükle (yeni)
      final file = await _getPersistFile();
      String? logsJson;
      if (file != null && await file.exists()) {
        logsJson = await file.readAsString();
      }

      // 2) Yoksa legacy SharedPreferences'tan migrate et
      if (logsJson == null || logsJson.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        logsJson = prefs.getString(_pendingLogsKey);
        if (logsJson != null && logsJson.isNotEmpty) {
          debugPrint('[LogService] Legacy log\'lar SharedPreferences\'tan dosyaya migrate ediliyor');
        }
      }

      if (logsJson != null) {
        final logs = jsonDecode(logsJson) as List;
        for (final log in logs) {
          _pendingLogs.add(LogEntry(
            level: LogLevel.values.firstWhere(
              (l) => l.name == log['log_level'],
              orElse: () => LogLevel.info,
            ),
            type: _stringToType(log['log_type']),
            message: log['message'] ?? '',
            details: log['details'],
            userId: log['user_id'],
            userName: log['user_name'],
            timestamp: DateTime.tryParse(log['timestamp'] ?? '') ?? DateTime.now(),
          ));
        }
        debugPrint('[LogService] ${_pendingLogs.length} bekleyen log yüklendi');

        // 1 Haz 2026 (v1.5.6) — Load sonrası cap + legacy temizlik
        _capPendingLogs();
        try {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.containsKey(_pendingLogsKey)) {
            await prefs.remove(_pendingLogsKey); // migrate sonrası eski şişmiş key
            debugPrint('[LogService] Legacy SharedPreferences key temizlendi');
          }
        } catch (_) {}
        // Yeni dosya formatına yaz (legacy şişme sıfırlansın)
        await _savePendingLogs();
      }
    } catch (e) {
      debugPrint('[LogService] Log yükleme hatası: $e');
    }
  }

  LogType _stringToType(String? type) {
    switch (type) {
      case 'sync_error':
        return LogType.syncError;
      case 'error':
        return LogType.error;
      case 'sync':
        return LogType.sync;
      case 'login':
        return LogType.login;
      case 'action':
        return LogType.action;
      case 'update':
        return LogType.update;
      case 'lan':
        return LogType.lan;
      default:
        return LogType.general;
    }
  }

  /// Bekleyen logları temizle
  Future<void> _clearPendingLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingLogsKey);
    } catch (e) {
      debugPrint('[LogService] Log temizleme hatası: $e');
    }
  }

  /// Servisi kapat
  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _isInitialized = false;
  }
}
