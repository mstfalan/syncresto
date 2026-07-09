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

    // Dosya bazlı yedek — URL + API key (key obfuscate edilir, duz metin degil).
    try {
      final dir = await getApplicationSupportDirectory();
      _backupFile = File('${dir.path}/pos_settings.json');

      // prefs'te KEY yoksa (bozulma/0-byte/rebrand) yedekten geri yukle — kendi kendini iyilestirme.
      if (getApiKey() == null || getApiUrl() == null) {
        final backup = _readBackupSecure();
        if (backup != null) {
          if (getApiUrl() == null && backup[_apiUrlKey] != null) {
            await _prefs.setString(_apiUrlKey, backup[_apiUrlKey]);
          }
          if (backup[_backendUrlKey] != null && getBackendUrl() == null) {
            await _prefs.setString(_backendUrlKey, backup[_backendUrlKey]);
          }
          if (getApiKey() == null && backup[_apiKeyKey] != null) {
            await _prefs.setString(_apiKeyKey, _deobfuscate(backup[_apiKeyKey]));
            if (backup[_apiKeyNameKey] != null) {
              await _prefs.setString(_apiKeyNameKey, backup[_apiKeyNameKey]);
            }
            if (kDebugMode) print('[Storage] API key yedekten geri yuklendi');
          }
          if (getLanTenantSecret() == null && backup[_lanSecretKey] != null) {
            await _prefs.setString(_lanSecretKey, _deobfuscate(backup[_lanSecretKey]));
          }
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
      final key = getApiKey();
      final lanSecret = getLanTenantSecret();
      final data = {
        _apiUrlKey: getApiUrl(),
        _backendUrlKey: getBackendUrl(),
        // API key obfuscate (duz metin degil). Yeni key girilince _saveBackup cagrilir -> yedek guncellenir.
        if (key != null) _apiKeyKey: _obfuscate(key),
        if (getApiKeyName() != null) _apiKeyNameKey: getApiKeyName(),
        if (lanSecret != null) _lanSecretKey: _obfuscate(lanSecret),
      };
      final jsonStr = jsonEncode(data);
      final hmac = _generateHmac(jsonStr);
      final payload = jsonEncode({'data': data, 'hmac': hmac});
      // Atomik yaz: temp'e yaz + flush + rename (yedek sert-kapanmada bozulmasin).
      final tmp = File('${_backupFile!.path}.tmp');
      final raf = await tmp.open(mode: FileMode.write);
      await raf.writeString(payload);
      await raf.flush();
      await raf.close();
      await tmp.rename(_backupFile!.path);
    } catch (e) {
      if (kDebugMode) print('[Storage] Yedekleme hatasi: $e');
    }
  }

  // Cihaza ozel salt ile XOR obfuscate (duz metin onleme — kriptografik guvenlik DEGIL, kurtarma amacli).
  static const String _obfKey = 'SyncRestoPOS_KeyObf_2026';
  String _obfuscate(String plain) {
    final k = utf8.encode(_obfKey);
    final b = utf8.encode(plain);
    final out = List<int>.generate(b.length, (i) => b[i] ^ k[i % k.length]);
    return base64.encode(out);
  }

  String _deobfuscate(String obf) {
    try {
      final k = utf8.encode(_obfKey);
      final b = base64.decode(obf);
      final out = List<int>.generate(b.length, (i) => b[i] ^ k[i % k.length]);
      return utf8.decode(out);
    } catch (_) {
      return obf; // eski/plain yedek — oldugu gibi don
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
    await _prefs.setString(_tenantHashKey, hashKey(apiKey)); // atomik: key ile birlikte hash
    await _saveBackup();
  }

  // Tenant kimligi (key hash) — clear'larda SILINMEZ, tenant-degisim tespiti icin kalir.
  static const String _tenantHashKey = 'pos_tenant_key_hash';
  String hashKey(String apiKey) => sha256.convert(utf8.encode(apiKey)).toString();
  String? getTenantHash() => _prefs.getString(_tenantHashKey);

  // LAN tenant secret (restoran-basina, HMAC icin). validate-key'den gelir.
  static const String _lanSecretKey = 'pos_lan_tenant_secret';
  String? getLanTenantSecret() => _prefs.getString(_lanSecretKey);
  Future<void> saveLanTenantSecret(String secret) async {
    await _prefs.setString(_lanSecretKey, secret);
    await _saveBackup();
  }
  Future<void> clearLanTenantSecret() async {
    await _prefs.remove(_lanSecretKey);
    await _saveBackup(); // backup'tan da dus (Fable ORTA-1: eski secret sizmasin)
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
    await _prefs.remove(_lanSecretKey); // LAN secret de dussun (eski tenant secret'i kalmasin)
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

  // Urune tiklayinca varyant secimi acilsin mi (default KAPALI = mevcut davranis: direkt sepete).
  // Acikken varyantli urune tiklaninca varyant dialogu, varyantsiz urun direkt sepete.
  // Key PUBLIC — printer_settings (yazar) + add_item_modal (okur) ayni prefs anahtarini paylasir.
  static const String variantOnTapKey = 'variant_dialog_on_tap';
  Future<bool> getVariantDialogOnTap() async {
    return _prefs.getBool(variantOnTapKey) ?? false;
  }

  Future<void> setVariantDialogOnTap(bool value) async {
    await _prefs.setBool(variantOnTapKey, value);
  }

  // Masa takip sıralama tercihi (kalıcı, garson tekrar tekrar değiştirmesin)
  // Değerler: 'time_asc' (default), 'time_desc', 'table_asc', 'table_desc'
  String getOrderTrackingSort() {
    return _prefs.getString('order_tracking_sort') ?? 'time_asc';
  }

  Future<void> setOrderTrackingSort(String mode) async {
    await _prefs.setString('order_tracking_sort', mode);
  }

  // Clear all
  Future<void> clearAll() async {
    await _prefs.clear();
    try { await _backupFile?.delete(); } catch (_) {}
  }
}
