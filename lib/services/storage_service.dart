import 'dart:io';
import 'dart:convert';
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

    // Dosya bazlı yedek - pkill sonrası kayıp önleme
    try {
      final dir = await getApplicationSupportDirectory();
      _backupFile = File('${dir.path}/pos_settings.json');

      // SharedPreferences boşsa yedekten geri yükle
      if (getApiKey() == null && _backupFile!.existsSync()) {
        final backup = jsonDecode(await _backupFile!.readAsString()) as Map<String, dynamic>;
        if (backup[_apiKeyKey] != null) {
          await _prefs.setString(_apiKeyKey, backup[_apiKeyKey]);
          if (backup[_apiKeyNameKey] != null) await _prefs.setString(_apiKeyNameKey, backup[_apiKeyNameKey]);
          if (backup[_apiUrlKey] != null) await _prefs.setString(_apiUrlKey, backup[_apiUrlKey]);
          if (backup[_backendUrlKey] != null) await _prefs.setString(_backendUrlKey, backup[_backendUrlKey]);
          print('[Storage] Ayarlar yedekten geri yuklendi');
        }
      }
    } catch (e) {
      print('[Storage] Yedek dosya hatasi: $e');
    }
  }

  /// Ayarları dosyaya yedekle
  Future<void> _saveBackup() async {
    if (_backupFile == null) return;
    try {
      final data = {
        _apiKeyKey: getApiKey(),
        _apiKeyNameKey: getApiKeyName(),
        _apiUrlKey: getApiUrl(),
        _backendUrlKey: getBackendUrl(),
      };
      await _backupFile!.writeAsString(jsonEncode(data));
    } catch (e) {
      print('[Storage] Yedekleme hatasi: $e');
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

  // Backend URL (for images, assets)
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
    // Yedek dosyayı da sil
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
