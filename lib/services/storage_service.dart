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

  /// 14 Eyl 2026 denetimi: `late` idi. init() 5 sn timeout'a düşerse (AV taraması, soğuk disk)
  /// alan ATANMADAN kalıyor ve ilk build'deki `getApiKey()` LateInitializationError fırlatıp
  /// GRİ EKRAN üretiyordu. Artık nullable: okuyucular null görür, uygulama Setup ekranıyla açılır.
  SharedPreferences? _prefsOrNull;
  SharedPreferences get _prefs => _prefsOrNull ?? (throw StateError('prefs hazır değil'));
  bool get hazir => _prefsOrNull != null;
  File? _backupFile;

  /// 14 Eyl 2026 (Green Chef gri ekran): shared_preferences.json bozulunca (elektrik kesintisi → dosya
  /// sıfırlarla dolar, "FormatException: Unexpected character (at character 1)") getInstance() fırlatıyor,
  /// _prefs hiç kurulmuyor, ilk ekran build'de LateInitializationError → GRİ EKRAN. Artık: bozuk dosya
  /// `.corrupt-<ts>` olarak kenara alınır, prefs yeniden kurulur (API key/URL pos_settings.json yedeğinden
  /// geri gelir); o da olmazsa bellek-içi prefs ile açılır (Setup ekranı). Uygulama HİÇBİR durumda gri kalmaz.
  bool recoveredCorruptPrefs = false;
  String? recoveryNote;

  Future<void> init() async {
    try {
      _prefsOrNull = await SharedPreferences.getInstance();
    } catch (e) {
      recoveryNote = 'prefs okunamadı: ${e.toString().split('\n').first}';
      final moved = await quarantineCorruptPrefsFile();
      try {
        _prefsOrNull = await SharedPreferences.getInstance();
        recoveredCorruptPrefs = true;
        recoveryNote = '$recoveryNote → bozuk dosya kenara alındı (${moved ?? 'dosya bulunamadı'}), prefs yeniden kuruldu';
      } catch (e2) {
        // Son çare: bellek-içi prefs — uygulama açılır, yedekten API key/URL gelir, kalıcı olmayan ayarlar Setup'ta tekrar girilir.
        // ignore: invalid_use_of_visible_for_testing_member — bilinçli: bellek-içi prefs son çare (uygulama gri/beyaz kalmasın)
        SharedPreferences.setMockInitialValues(<String, Object>{});
        _prefsOrNull = await SharedPreferences.getInstance();
        recoveredCorruptPrefs = true;
        recoveryNote = '$recoveryNote → yeniden kurulamadı (${e2.toString().split('\n').first}), bellek-içi prefs ile açıldı';
      }
      if (kDebugMode) print('[Storage] $recoveryNote');
    }

    // 14 Eyl denetimi: shared_preferences.json 0 BYTE ise eklenti hata FIRLATMAZ, sessizce boş
    // harita döndürür (kaynak: shared_preferences_windows _readFromFile). O yüzden yukarıdaki
    // catch hiç çalışmaz. Boş prefs + dolu yedek = sessiz ayar kaybı → kurtarma bayrağını biz kaldırırız.
    if (_prefsOrNull != null && _prefsOrNull!.getKeys().isEmpty) {
      recoveredCorruptPrefs = true;
      recoveryNote = 'ayar dosyasi BOS dondu (0-byte/bozuk icerik) — yedekten kurtariliyor';
    }

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
            final cozulen = _deobfuscate(backup[_apiKeyKey]);
            // Biçim doğrulaması: bozuk çözme sonucu base64 çöpü anahtar diye yazılıyordu → her istek 401.
            if (cozulen.startsWith('SR_')) await _prefs.setString(_apiKeyKey, cozulen);
            if (backup[_apiKeyNameKey] != null) {
              await _prefs.setString(_apiKeyNameKey, backup[_apiKeyNameKey]);
            }
            if (kDebugMode) print('[Storage] API key yedekten geri yuklendi');
          }
          if (getLanTenantSecret() == null && backup[_lanSecretKey] != null) {
            await _prefs.setString(_lanSecretKey, _deobfuscate(backup[_lanSecretKey]));
          }
          // Yazıcı ayarları + kiracı kimliği geri gelsin (yoksa fiş basılmaz / tenant koruması susar).
          final yazici = backup['yazici'];
          if (yazici is Map) {
            for (final e in yazici.entries) {
              final k = e.key.toString();
              if (_prefsOrNull?.getString(k) == null && e.value != null) {
                await _prefs.setString(k, e.value.toString());
              }
            }
          }
          if (backup[yazdirPrinterIdsKey] is List && (_prefsOrNull?.getStringList(yazdirPrinterIdsKey) ?? const []).isEmpty) {
            await _prefs.setStringList(yazdirPrinterIdsKey, List<String>.from(backup[yazdirPrinterIdsKey]));
          }
          if (getTenantHash() == null && backup[_tenantHashKey] != null) {
            await _prefs.setString(_tenantHashKey, backup[_tenantHashKey].toString());
          }
          if (getDeviceDisplayName() == null && backup[_deviceDisplayNameKey] != null) {
            await _prefs.setString(_deviceDisplayNameKey, backup[_deviceDisplayNameKey].toString());
          }
        }
      }
    } catch (e) {
      if (kDebugMode) print('[Storage] Yedek dosya hatasi: $e');
    }
  }

  /// Windows/Linux: shared_preferences.json {ApplicationSupport} altındadır; bozuksa `.corrupt-<ts>` adıyla kenara alır
  /// (silmez: forensik). macOS/iOS/Android'de dosya yok (NSUserDefaults/SharedPreferences XML) → null.
  /// Ayar dosyası GERÇEKTEN okunabiliyor mu? Onarım düğmesi sağlam dosyayı silmesin diye
  /// karantinadan ÖNCE sorulur (dosya yoksa "okunabilir" sayılır: silinecek bir şey yok).
  static Future<bool> prefsOkunabilir() async {
    try {
      if (!(Platform.isWindows || Platform.isLinux)) return true;
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
      if (!await f.exists()) return true;
      final icerik = await f.readAsString();
      if (icerik.trim().isEmpty) return false;       // 0-byte = bozuk
      return jsonDecode(icerik) is Map;
    } catch (_) {
      return false;   // parse edilemiyor = bozuk
    }
  }

  static Future<String?> quarantineCorruptPrefsFile() async {
    try {
      if (!(Platform.isWindows || Platform.isLinux)) return null;
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
      if (!await f.exists()) return null;
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final target = '${f.path}.corrupt-$ts';
      await f.rename(target);
      // Yalnız dosya adı döner: tam yol Windows kullanıcı adını taşır (KVKK) ve bu değer
      // recoveryNote üzerinden sunucuya/Telegram'a gidiyordu.
      return target.split(Platform.pathSeparator).last;
    } catch (e) {
      if (kDebugMode) print('[Storage] bozuk prefs kenara alınamadı: $e');
      return null;
    }
  }

  /// URL bilgilerini dosyaya yedekle (API key YAZILMAZ)
  static const String _hmacSecret = 'SyncRestoPOS_Backup_Integrity';

  static String _generateHmac(String data) {
    final key = utf8.encode(_hmacSecret);
    final bytes = utf8.encode(data);
    return Hmac(sha256, key).convert(bytes).toString();
  }

  Future<void> _saveBackup() async {
    if (_backupFile == null) return;
    try {
      final key = getApiKey();
      final lanSecret = getLanTenantSecret();
      // 14 Eyl denetimi: yedek yalnız URL+anahtar taşıyordu. prefs bozulunca YAZICI ayarları
      // gidiyordu → kasa fişi/web sipariş fişi sessizce basılmıyordu ("fiş akışı bozulamaz").
      final yaziciAyarlari = <String, String>{};
      for (final k in <String>['printers_multi', 'printer_settings', 'printer_beep_ips']) {
        final v = _prefsOrNull?.getString(k);
        if (v != null) yaziciAyarlari[k] = v;
      }
      final yazdirHedef = _prefsOrNull?.getStringList(yazdirPrinterIdsKey);
      final data = {
        _apiUrlKey: getApiUrl(),
        _backendUrlKey: getBackendUrl(),
        if (getTenantHash() != null) _tenantHashKey: getTenantHash(),
        if (getDeviceDisplayName() != null) _deviceDisplayNameKey: getDeviceDisplayName(),
        if (yaziciAyarlari.isNotEmpty) 'yazici': yaziciAyarlari,
        if (yazdirHedef != null && yazdirHedef.isNotEmpty) yazdirPrinterIdsKey: yazdirHedef,
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
      try {
        await raf.writeString(payload);
        await raf.flush();
      } finally {
        await raf.close(); // disk dolu/AV kilidi durumunda handle sızmasın
      }
      await tmp.rename(_backupFile!.path);
    } catch (e) {
      if (kDebugMode) print('[Storage] Yedekleme hatasi: $e');
    }
  }

  // Cihaza ozel salt ile XOR obfuscate (duz metin onleme — kriptografik guvenlik DEGIL, kurtarma amacli).
  static const String _obfKey = 'SyncRestoPOS_KeyObf_2026';
  static String _obfuscate(String plain) {
    final k = utf8.encode(_obfKey);
    final b = utf8.encode(plain);
    final out = List<int>.generate(b.length, (i) => b[i] ^ k[i % k.length]);
    return base64.encode(out);
  }

  static String _deobfuscate(String obf) {
    try {
      final k = utf8.encode(_obfKey);
      final b = base64.decode(obf);
      final out = List<int>.generate(b.length, (i) => b[i] ^ k[i % k.length]);
      return utf8.decode(out);
    } catch (_) {
      return obf; // eski/plain yedek — oldugu gibi don
    }
  }

  /// 14 Eyl 2026: prefs HİÇ kurulamadan (çökme sinyali) yedekten kimlik oku — HMAC doğrulamalı, anahtar çözülmüş.
  /// Örnek kullanım: CrashBeacon; hata olursa null (sinyal kimliksiz gider, sunucu cihaz geçmişinden çözer).
  static Future<Map<String, String?>?> readBackupCredentials() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/pos_settings.json');
      if (!await f.exists()) return null;
      final parsed = jsonDecode(await f.readAsString());
      if (parsed is! Map) return null;
      Map<String, dynamic> d;
      if (parsed.containsKey('hmac') && parsed.containsKey('data')) {
        if (_generateHmac(jsonEncode(parsed['data'])) != parsed['hmac']) return null;
        d = Map<String, dynamic>.from(parsed['data']);
      } else {
        // Eski biçim (HMAC'siz) — _readBackupSecure de kabul ediyor; burada reddetmek cihazı
        // kimliksiz bırakırdı (asimetri denetimde yakalandı).
        d = Map<String, dynamic>.from(parsed);
      }
      return {
        'api_url': d[_apiUrlKey]?.toString(),
        'backend_url': d[_backendUrlKey]?.toString(),
        'api_key': d[_apiKeyKey] == null ? null : _deobfuscate(d[_apiKeyKey].toString()),
      };
    } catch (_) {
      return null;
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
  String? getApiKey() => _prefsOrNull?.getString(_apiKeyKey);
  String? getApiKeyName() => _prefsOrNull?.getString(_apiKeyNameKey);
  String? getApiUrl() => _prefsOrNull?.getString(_apiUrlKey);

  Future<void> saveApiKey(String apiKey, String name) async {
    await _prefs.setString(_apiKeyKey, apiKey);
    await _prefs.setString(_apiKeyNameKey, name);
    await _prefs.setString(_tenantHashKey, hashKey(apiKey)); // atomik: key ile birlikte hash
    await _saveBackup();
  }

  // Tenant kimligi (key hash) — clear'larda SILINMEZ, tenant-degisim tespiti icin kalir.
  static const String _tenantHashKey = 'pos_tenant_key_hash';
  String hashKey(String apiKey) => sha256.convert(utf8.encode(apiKey)).toString();
  String? getTenantHash() => _prefsOrNull?.getString(_tenantHashKey);

  // 17 Tem 2026: Kasanın panelde görünen adı ('Kasa 1'). validate-key device_name/key_name'den gelir.
  // Offline'da "masayı hangi kasa açtı" için gerekli — restaurant_name (getApiKeyName) DEĞİL.
  static const String _deviceDisplayNameKey = 'pos_device_display_name';
  String? getDeviceDisplayName() => _prefsOrNull?.getString(_deviceDisplayNameKey);
  Future<void> saveDeviceDisplayName(String name) async {
    await _prefs.setString(_deviceDisplayNameKey, name);
    await _saveBackup();
  }

  // LAN tenant secret (restoran-basina, HMAC icin). validate-key'den gelir.
  static const String _lanSecretKey = 'pos_lan_tenant_secret';
  String? getLanTenantSecret() => _prefsOrNull?.getString(_lanSecretKey);
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
  String? getBackendUrl() => _prefsOrNull?.getString(_backendUrlKey);

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
  String? getWaiterToken() => _prefsOrNull?.getString(_waiterTokenKey);
  String? getWaiterData() => _prefsOrNull?.getString(_waiterDataKey);

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
    return _prefsOrNull?.getBool(_showProductImagesKey) ?? true;
  }

  Future<void> setShowProductImages(bool value) async {
    await _prefs.setBool(_showProductImagesKey, value);
  }

  // Urune tiklayinca varyant secimi acilsin mi (default KAPALI = mevcut davranis: direkt sepete).
  // Acikken varyantli urune tiklaninca varyant dialogu, varyantsiz urun direkt sepete.
  // Key PUBLIC — printer_settings (yazar) + add_item_modal (okur) ayni prefs anahtarini paylasir.
  static const String variantOnTapKey = 'variant_dialog_on_tap';
  Future<bool> getVariantDialogOnTap() async {
    return _prefsOrNull?.getBool(variantOnTapKey) ?? false;
  }

  Future<void> setVariantDialogOnTap(bool value) async {
    await _prefs.setBool(variantOnTapKey, value);
  }

  // 24 Tem 2026: Çıkmayan-fiş uyarısı otomatik pop-up açılsın mı (retry 5/5 tükenip mutfak
  // fişi çıkmayınca fişi giren kasada). DEFAULT AÇIK (Mustafa). Kapalıyken sadece sağ-üst
  // rozetten görülür. Key PUBLIC — printer_settings (yazar) + tables_screen (okur) paylaşır.
  static const String failedPrintAutoPopupKey = 'failed_print_auto_popup';
  Future<bool> getFailedPrintAutoPopup() async {
    return _prefsOrNull?.getBool(failedPrintAutoPopupKey) ?? true; // DEFAULT AÇIK
  }

  Future<void> setFailedPrintAutoPopup(bool value) async {
    await _prefs.setBool(failedPrintAutoPopupKey, value);
  }

  // 24 Agu 2026: Mutfak fisinde "Fis Basim" (baski ani) satirini goster. DEFAULT ACIK.
  // 'Urun Girisi' gercek giris saatini (P1), 'Fis Basim' fisin cikis anini gosterir —
  // gec/yeniden baskida ikisi AYRILIR (garson 10'da girip fisi 12'de bastiysa net gorunur).
  // Kapaliyken satir HIC basilmaz. Key PUBLIC — printer_settings (yazar) + printer_service (okur).
  static const String showKitchenPrintTimeKey = 'fis_basim_zamani_goster';
  Future<bool> getShowKitchenPrintTime() async {
    return _prefsOrNull?.getBool(showKitchenPrintTimeKey) ?? true; // DEFAULT ACIK
  }

  Future<void> setShowKitchenPrintTime(bool value) async {
    await _prefs.setBool(showKitchenPrintTimeKey, value);
  }

  // 24 Agu 2026 (P4): "Yazdir" butonu hedef yazicilari (coklu secim, server printer id'leri).
  // BOS -> BUGUNKU yol (cashier config'i). 1 secili -> dogrudan o yaziciya. >1 -> "Yazdir"a
  // basinca yazici-sec pop-up. Key PUBLIC — printer_settings (yazar) + add_item_modal (okur).
  static const String yazdirPrinterIdsKey = 'yazdir_hedef_yazici_ids';
  Future<List<String>> getYazdirPrinterIds() async {
    return _prefsOrNull?.getStringList(yazdirPrinterIdsKey) ?? const [];
  }

  Future<void> setYazdirPrinterIds(List<String> ids) async {
    await _prefs.setStringList(yazdirPrinterIdsKey, ids);
  }

  // 9 Agu 2026 (Mustafa): fislerde her kalemin yaninda GARSON ADI + GIRIS SAATI gosterilsin mi.
  // Kasa (adisyon+kapanis) AYRI, mutfak AYRI. IKISI DE DEFAULT ACIK. Key'ler printer_service
  // (okur, ham prefs) + printer_settings (yazar) ile AYNI string. Kapaliyken fis BIREBIR eski hali.
  static const String showWaiterTimeCashKey = 'show_waiter_time_cash';
  Future<bool> getShowWaiterTimeCash() async {
    return _prefsOrNull?.getBool(showWaiterTimeCashKey) ?? true; // DEFAULT AÇIK
  }

  Future<void> setShowWaiterTimeCash(bool value) async {
    await _prefs.setBool(showWaiterTimeCashKey, value);
  }

  static const String showWaiterTimeKitchenKey = 'show_waiter_time_kitchen';
  Future<bool> getShowWaiterTimeKitchen() async {
    return _prefsOrNull?.getBool(showWaiterTimeKitchenKey) ?? true; // DEFAULT AÇIK
  }

  Future<void> setShowWaiterTimeKitchen(bool value) async {
    await _prefs.setBool(showWaiterTimeKitchenKey, value);
  }

  // 10 Agu 2026 (Mustafa): mutfak fisinde gruplu varyant BASLIKLARI (grup adi) gosterilsin mi.
  // DEFAULT AÇIK. Amac: sadece "2. yan urun" secilince mutfak "1." sanmasin. Key printer_service
  // (okur, ham prefs) + printer_settings (yazar) ile AYNI string. Kapaliyken fis BIREBIR eski.
  static const String showGroupTitlesKitchenKey = 'show_group_titles_kitchen';
  Future<bool> getShowGroupTitlesKitchen() async {
    return _prefsOrNull?.getBool(showGroupTitlesKitchenKey) ?? true; // DEFAULT AÇIK
  }

  Future<void> setShowGroupTitlesKitchen(bool value) async {
    await _prefs.setBool(showGroupTitlesKitchenKey, value);
  }

  // 8 Eyl 2026 (Mustafa): HIZLI SATIS butonu (perakende — masa acmadan satis). DEFAULT KAPALI.
  // Acikken salon sekmelerinin BASINDA 'HIZLI SATIS' butonu gorunur; panelde 'Hizli Satis' isaretli
  // salon(lar) gerekir. Odeme alininca ekran kapanmaz, ayni masada yeni adisyon acilir.
  // Key PUBLIC — printer_settings (yazar) + tables_screen (okur) ayni prefs anahtarini paylasir.
  static const String quickSaleEnabledKey = 'quick_sale_enabled';
  Future<bool> getQuickSaleEnabled() async {
    return _prefsOrNull?.getBool(quickSaleEnabledKey) ?? false; // DEFAULT KAPALI
  }

  Future<void> setQuickSaleEnabled(bool value) async {
    await _prefs.setBool(quickSaleEnabledKey, value);
  }

  // Masa takip sıralama tercihi (kalıcı, garson tekrar tekrar değiştirmesin)
  // Değerler: 'time_asc' (default), 'time_desc', 'table_asc', 'table_desc'
  String getOrderTrackingSort() {
    return _prefsOrNull?.getString('order_tracking_sort') ?? 'time_asc';
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
