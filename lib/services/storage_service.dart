import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _apiKeyKey = 'pos_api_key';
  static const String _apiKeyNameKey = 'pos_api_key_name';
  static const String _apiUrlKey = 'pos_api_url';
  static const String _backendUrlKey = 'pos_backend_url';
  static const String _waiterTokenKey = 'waiter_token';
  static const String _waiterDataKey = 'waiter_data';
  static const String _showProductImagesKey = 'show_product_images';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // API Key
  String? getApiKey() => _prefs.getString(_apiKeyKey);
  String? getApiKeyName() => _prefs.getString(_apiKeyNameKey);
  String? getApiUrl() => _prefs.getString(_apiUrlKey);

  Future<void> saveApiKey(String apiKey, String name) async {
    await _prefs.setString(_apiKeyKey, apiKey);
    await _prefs.setString(_apiKeyNameKey, name);
  }

  Future<void> saveApiUrl(String url) async {
    await _prefs.setString(_apiUrlKey, url);
  }

  // Backend URL (for images, assets)
  String? getBackendUrl() => _prefs.getString(_backendUrlKey);

  Future<void> saveBackendUrl(String url) async {
    await _prefs.setString(_backendUrlKey, url);
  }

  Future<void> clearApiKey() async {
    await _prefs.remove(_apiKeyKey);
    await _prefs.remove(_apiKeyNameKey);
    await _prefs.remove(_apiUrlKey);
    await _prefs.remove(_backendUrlKey);
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
  }
}
