import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

/// LAN-SENKRON SERVISI (7 Tem 2026) — Yaklasim B: KASA-LIDER.
///
/// AMAC: Ayni restorandaki birden cok POS cihazi (ayni LAN'da) CEVRIMDISIYKEN birbiriyle
/// haberlessin — Kasa1 offline masa acinca Kasa2 de DOLU gorsun; iki cihaz ayni masaya girmesin.
///
/// MUTLAK KISITLAR (Mustafa):
/// 1. Yazicidan fis cikmasi ASLA bozulmaz (offline mutfak fisi LAN TCP 9100 cihaz-LOKAL, bu servise BAGLI DEGIL).
/// 2. Backend'e DOKUNULMAZ — tamamen cihaz-cihaz (Flutter).
/// 3. Multi-tenant: cihaz SADECE ayni bayinin (API key HMAC challenge) cihazlariyla konusur.
/// 4. Flag KAPALI / LAN yok / tek cihaz -> mevcut offline akis AYNEN calisir (bu servis hic devreye girmez).
///
/// TASARIM: Ayri dosya (mevcut servisleri sismeme). Feature-flag default KAPALI (opt-in).
/// Fazlar: 0=altyapi (bu), 1=kesif+tenant-dogrulama, 2=lider+salt-okunur yansima, 3=masa-kilidi+yetki.
///
/// Bu FAZ 0: sadece feature-flag (SharedPreferences, backend'den BAGIMSIZ — cache sync ezmesin) +
/// kalici device_id erisimi. Henuz ag/kesif/senkron YOK. Flag kapali oldugu icin hicbir davranis degismez.
class LanSyncService {
  static final LanSyncService _instance = LanSyncService._internal();
  factory LanSyncService() => _instance;
  LanSyncService._internal();

  // Feature-flag anahtari (SharedPreferences). Probe kill-switch ile ayni desen: cihaz-yerel,
  // backend cache sync'i bunu EZEMEZ (cached_settings'e KOYULMAZ — o backend'den geliyor).
  static const String _flagKey = 'lan_sync_enabled';

  // device_id: api_service.dart _getDeviceId() ile AYNI anahtar (pos_device_id, SharedPreferences).
  // Ayri uretmiyoruz — cihazda zaten kalici bir kimlik var, onu kullaniyoruz (tek kaynak).
  static const String _deviceIdKey = 'pos_device_id';

  bool _enabled = false;
  bool get enabled => _enabled;

  String? _deviceId;
  String? get deviceId => _deviceId;

  bool _initDone = false;

  /// Baslatma: flag + device_id oku. FAZ 0'da baska is yapmaz. Flag kapaliysa erken doner.
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_flagKey) ?? false; // default KAPALI
      _deviceId = prefs.getString(_deviceIdKey); // api_service _getDeviceId() zaten set etmis olur
      print('[LanSync] init: enabled=$_enabled, deviceId=${_deviceId ?? "(henuz yok)"}');
    } catch (e) {
      print('[LanSync] init hatasi (guvenli: kapali kalir): $e');
      _enabled = false;
    }
    // NOT: FAZ 1'de burada kesif (subnet scan) + tenant HMAC challenge baslar — SADECE _enabled ise.
    if (!_enabled) return;
    // (Faz 1+): if (_enabled) { await _startDiscovery(); ... }
  }

  /// Feature-flag'i degistir (ayar ekrani / destek kanali). true yapinca Faz 1+ devreye girer.
  Future<void> setEnabled(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_flagKey, value);
      _enabled = value;
      print('[LanSync] setEnabled=$value (yeniden baslatmada devreye girer)');
    } catch (e) {
      print('[LanSync] setEnabled hatasi: $e');
    }
  }

  void dispose() {
    // FAZ 1+: burada socket/timer/subscription kapatilir. Faz 0'da bir sey yok.
  }
}
