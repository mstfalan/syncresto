import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _apiKeyKey = 'pos_api_key';
  static const String _apiKeyNameKey = 'pos_api_key_name';
  static const String _waiterTokenKey = 'waiter_token';
  static const String _waiterDataKey = 'waiter_data';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // API Key
  String? getApiKey() => _prefs.getString(_apiKeyKey);
  String? getApiKeyName() => _prefs.getString(_apiKeyNameKey);

  Future<void> saveApiKey(String apiKey, String name) async {
    await _prefs.setString(_apiKeyKey, apiKey);
    await _prefs.setString(_apiKeyNameKey, name);
  }

  Future<void> clearApiKey() async {
    await _prefs.remove(_apiKeyKey);
    await _prefs.remove(_apiKeyNameKey);
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

  // Clear all
  Future<void> clearAll() async {
    await _prefs.clear();
  }
}
