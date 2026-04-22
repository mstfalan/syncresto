import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static const String _apiKeyKey = 'pos_api_key';
  static const String _apiKeyNameKey = 'pos_api_key_name';
  static const String _apiUrlKey = 'pos_api_url';
  static const String _backendUrlKey = 'pos_backend_url';
  static const String _waiterTokenKey = 'waiter_token';
  static const String _waiterDataKey = 'waiter_data';
  static const String _showProductImagesKey = 'show_product_images';

  late SharedPreferences _prefs;
  File? _backupFile;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    // Dosya bazlı yedek - sadece URL bilgileri (API key YAZILMAZ)
    try {
      final dir = await getApplicationSupportDirectory();
      _backupFile = File('${dir.path}/pos_settings.json');

      // SharedPreferences boşsa yedekten URL'leri geri yükle
      if (getApiUrl() == null) {
        final backup = _readBackupSecure();
        if (backup != null) {
          if (backup[_apiUrlKey] != null) await _prefs.setString(_apiUrlKey, backup[_apiUrlKey]);
          if (backup[_backendUrlKey] != null) await _prefs.setString(_backendUrlKey, backup[_backendUrlKey]);
          if (kDebugMode) print('[Storage] URL ayarlari yedekten geri yuklendi');
        }
      }
    } catch (e) {
      if (kDebugMode) print('[Storage] Yedek dosya hatasi: $e');
    }
  }

  /// URL bilgilerini dosyaya yedekle (API key YAZILMAZ)
  static const String _hmacSecret = 'SyncRestoPOS_Backup_Integrity';

  String _generateHmac(String data) {
    final key = utf8.encode(_hmacSecret);
    final bytes = utf8.encode(data);
    return Hmac(sha256, key).convert(bytes).toString();
  }

  Future<void> _saveBackup() async {
    if (_backupFile == null) return;
    try {
      final data = {
        _apiUrlKey: getApiUrl(),
        _backendUrlKey: getBackendUrl(),
      };
      final jsonStr = jsonEncode(data);
      final hmac = _generateHmac(jsonStr);
      await _backupFile!.writeAsString(jsonEncode({'data': data, 'hmac': hmac}));
    } catch (e) {
      if (kDebugMode) print('[Storage] Yedekleme hatasi: $e');
    }
  }

  Map<String, dynamic>? _readBackupSecure() {
    if (_backupFile == null || !_backupFile!.existsSync()) return null;
    try {
      final content = _backupFile!.readAsStringSync();
      final parsed = jsonDecode(content);
      // HMAC doğrulama
      if (parsed is Map && parsed.containsKey('hmac') && parsed.containsKey('data')) {
        final dataStr = jsonEncode(parsed['data']);
        if (_generateHmac(dataStr) == parsed['hmac']) {
          return Map<String, dynamic>.from(parsed['data']);
        }
        if (kDebugMode) print('[Storage] Backup HMAC dogrulama basarisiz');
        return null;
      }
      // Eski format (HMAC'siz) - bir kerelik kabul et
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
      return null;
    } catch (e) {
      return null;
    }
  }

  // API Key
  String? getApiKey() => _prefs.getString(_apiKeyKey);
  String? getApiKeyName() => _prefs.getString(_apiKeyNameKey);
  String? getApiUrl() => _prefs.getString(_apiUrlKey);

  Future<void> saveApiKey(String apiKey, String name) async {
    await _prefs.setString(_apiKeyKey, apiKey);
    await _prefs.setString(_apiKeyNameKey, name);
    await _saveBackup();
  }

  Future<void> saveApiUrl(String url) async {
    await _prefs.setString(_apiUrlKey, url);
    await _saveBackup();
  }

  // Backend URL
  String? getBackendUrl() => _prefs.getString(_backendUrlKey);

  Future<void> saveBackendUrl(String url) async {
    await _prefs.setString(_backendUrlKey, url);
    await _saveBackup();
  }

  Future<void> clearApiKey() async {
    await _prefs.remove(_apiKeyKey);
    await _prefs.remove(_apiKeyNameKey);
    await _prefs.remove(_apiUrlKey);
    await _prefs.remove(_backendUrlKey);
    try { await _backupFile?.delete(); } catch (_) {}
  }

  // Waiter Token
  String? getWaiterToken() => _prefs.getString(_waiterTokenKey);
  String? getWaiterData() => _prefs.getString(_waiterDataKey);

  Future<void> saveWaiterSession(String token, String waiterJson) async {
    await _prefs.setString(_waiterTokenKey, token);
    await _prefs.setString(_waiterDataKey, waiterJson);
  }

  Future<void> clearWaiterSession() async {
    await _prefs.remove(_waiterTokenKey);
    await _prefs.remove(_waiterDataKey);
  }

  // POS Ayarları
  Future<bool> getShowProductImages() async {
    return _prefs.getBool(_showProductImagesKey) ?? true;
  }

  Future<void> setShowProductImages(bool value) async {
    await _prefs.setBool(_showProductImagesKey, value);
  }

  // Clear all
  Future<void> clearAll() async {
    await _prefs.clear();
    try { await _backupFile?.delete(); } catch (_) {}
  }
}
