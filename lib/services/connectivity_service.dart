import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();

  // 6 Tem 2026 (offline fix Adim 8): IKI KATMANLI online tespiti.
  // _nicOnline = ag karti (Wi-Fi/ethernet) var mi (connectivity_plus). ESKI davranis.
  // _backendReachable = backend'e GERCEKTEN ulasilabiliyor mu (health probe). YENI.
  // isOnline = ikisi de true. Boylece "Wi-Fi var ama internet YOK" (fake-online — Turkiye
  // sahasinda EN SIK durum: modem ayakta, WAN yok) dogru tespit edilir; uygulama 15sn timeout'a
  // takilmadan ANINDA offline moda geçer.
  bool _nicOnline = true;
  bool _backendReachable = true; // GUVENLI baslangic: probe calisana kadar online varsay (eski davranis)

  // FEATURE FLAG: probe sorun cikarirsa false yap -> saf NIC davranisina (eski) don.
  // Print-guvenlik: probe FALSE (backend erisilemez) -> isOnline=false -> printKitchen GARANTI
  // offline dala (LAN TCP fis basar). Probe yaziciyi (LAN) DEGIL internet/backend'i test eder.
  bool enableProbe = true;

  bool get isOnline => enableProbe ? (_nicOnline && _backendReachable) : _nicOnline;

  Stream<bool> get connectionStream => _connectionController.stream;

  // Probe hedefi (api_service baseUrl'inden set edilir). Bos ise probe atlanir (guvenli: online varsay).
  String? _probeBaseUrl;
  void setProbeBaseUrl(String url) {
    _probeBaseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Timer? _probeTimer;
  bool _isProbing = false;

  Future<void> init() async {
    // 6 Tem 2026 FINAL: RUNTIME KILL-SWITCH — sahada probe sorun cikarirsa yeni build beklemeden
    // kapatilabilsin. SharedPreferences 'connectivity_probe_enabled' = false yapilirsa eski saf-NIC
    // davranisina doner (varsayilan: true = probe acik). Destek kanali/gizli ayar ile degistirilebilir.
    try {
      final prefs = await SharedPreferences.getInstance();
      enableProbe = prefs.getBool('connectivity_probe_enabled') ?? true;
      if (!enableProbe) print('[Connectivity] Probe KAPALI (kill-switch aktif, saf-NIC mod)');
    } catch (_) {}

    // İlk NIC durumunu kontrol et
    final result = await _connectivity.checkConnectivity();
    _updateNicStatus(result, notify: false);
    try {
      _baslangicDurumunuLogla();
    } catch (_) {}

    // NIC değişikliklerini dinle
    _connectivity.onConnectivityChanged.listen((r) => _updateNicStatus(r, notify: true));

    // 6 Tem 2026: Periyodik reachability probe (her 12sn). Debounce ile ust uste binmez.
    // Sunucuyu yormaz (hafif GET /health ~3ms). NIC yoksa probe atlanir (zaten offline).
    if (enableProbe) {
      await _runProbe(); // ilk probe hemen
      _probeTimer = Timer.periodic(const Duration(seconds: 12), (_) => _runProbe());
    }
  }

  void _updateNicStatus(List<ConnectivityResult> results, {required bool notify}) {
    final wasOnline = isOnline;
    _nicOnline = results.any((r) =>
      r == ConnectivityResult.wifi ||
      r == ConnectivityResult.ethernet ||
      r == ConnectivityResult.mobile
    );
    // NIC kopunca backend de erisilemez sayilir (hizli offline gecisi).
    if (!_nicOnline) _backendReachable = false;
    // NIC geri gelince backend'i hemen dogrula (online oldugunu varsayma).
    if (_nicOnline && enableProbe) _runProbe();
    _emitIfChanged(wasOnline, notify);
  }

  /// Backend'e GERCEKTEN ulasilabiliyor mu — hafif GET /health (2.5sn timeout, IPv4 force).
  Future<void> _runProbe() async {
    if (!enableProbe) return;
    if (_isProbing) return; // re-entry guard (ust uste probe atma)
    _isProbing = true;
    final wasOnline = isOnline;
    try {
      if (!_nicOnline) {
        _backendReachable = false;
      } else if (_probeBaseUrl == null || _probeBaseUrl!.isEmpty) {
        // Probe hedefi yok -> guvenli: backend erisilir varsay (eski davranis).
        _backendReachable = true;
      } else {
        _backendReachable = await _pingHealth(_probeBaseUrl!);
      }
    } catch (_) {
      // Probe'un KENDISI patlarsa online akisi bozma -> erisilir varsay (guvenli taraf).
      _backendReachable = true;
    } finally {
      _isProbing = false;
      _emitIfChanged(wasOnline, true);
    }
  }

  /// GET {base}/health — 2.5sn timeout. true = 2xx/3xx (backend ayakta), false = timeout/hata/5xx.
  /// 🔴 6 Tem 2026 FINAL-FIX A (KRİTİK): Eski kod connectionFactory ile DUZ TCP soket donduruyordu;
  /// baseUrl https oldugu icin TLS el sikismasi HIC yapilmiyordu -> Cloudflare 'plain HTTP to HTTPS
  /// port' HTTP 400 -> probe HEP false -> uygulama ACILISTAN ITIBAREN KALICI OFFLINE kaliyordu
  /// (canli testle dogrulandi: ayni kod 400, curl 200). connectionFactory KALDIRILDI — TLS default
  /// akista dogru calisir. IPv4 force ZATEN global: main.dart HttpOverrides.global lookup override'i
  /// TUM HttpClient'lara uygulanir (memory feedback_flutter_ipv4_force korunuyor).
  Future<bool> _pingHealth(String base) async {
    HttpClient? client;
    try {
      final uri = Uri.parse('$base/health');
      client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 2500);
      final request = await client.getUrl(uri).timeout(const Duration(milliseconds: 2500));
      final response = await request.close().timeout(const Duration(milliseconds: 2500));
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  // 19 Eyl 2026: baglanti gecisleri POS loglarina yazilir. Mutfak fisi teshisi icin:
  // fis logunda 'offline: true' varsa kasa o anda gercekten cevrimdisi miydi, buradan dogrulanir.
  // pos_logs'u doldurmamak icin kararsiz baglantida (10 dk'da 6+ gecis) 10 dk'da TEK uyari yazilir.
  DateTime? _sonGecisAn;
  final List<DateTime> _sonGecisler = [];
  DateTime? _kararsizUyariAn;
  int _bastirilanGecis = 0; // sel bastirmasi sirasinda YUTULAN gecis sayisi (teshis kor kalmasin)

  /// Acilis durumu: gecis olmadigi icin _gecisiLogla calismaz; kasa sabah modem kapali
  /// acildiginda "hic OFFLINE logu yok" durumu olusuyordu. Uygulama basina TEK kayit.
  void _baslangicDurumunuLogla() {
    _sonGecisAn = DateTime.now();
    LogService().logAction(
      'Baglanti baslangic: ${_nicOnline ? "ONLINE" : "OFFLINE"}',
      details: {
        'durum': _nicOnline ? 'online' : 'offline',
        'nic': _nicOnline,
        // 🔴 Fable (tur 3 / B3): 'backend' diger kayitlarda BOOL; buraya metin yazmak ileride
        // details->>'backend' tipli sorgusunu patlatir. Olculmedigini AYRI alan soyler.
        'backend': null,
        'backend_olculdu': false, // ilk probe sonucu durumu degistirirse ayri kayit duser
      },
    );
  }

  void _gecisiLogla(bool nowOnline) {
    final simdi = DateTime.now();
    final fark = _sonGecisAn == null ? null : simdi.difference(_sonGecisAn!);
    // Saat geriye sicrarsa (RTC/NTP duzeltmesi) negatif sure raporlama.
    final oncekiSn = (fark == null || fark.isNegative) ? null : fark.inSeconds;
    _sonGecisAn = simdi;
    _sonGecisler.add(simdi);
    _sonGecisler.removeWhere((t) {
      final d = simdi.difference(t);
      return d.isNegative || d.inMinutes >= 10;
    });

    if (_sonGecisler.length >= 6) {
      // Kararsiz ag: her gecisi yazmak pos_logs'u doldurur. Gecisler SAYILIR, 10 dk'da
      // tek uyari ile toplu raporlanir — "kac kere gidip geldi" bilgisi kaybolmaz.
      // 🔴 Fable (tur 3 / B4): saat GERIYE sicrarsa (NTP/RTC) _kararsizUyariAn gelecekte kalir
      // ve fark negatif olur; "< 10" negatifte de dogru oldugu icin bastirma sicrama kadar
      // uzardi (1 saat geri = 70 dk sessizlik). Negatif farki suresi DOLMUS say.
      if (_kararsizUyariAn != null) {
        final gecen = simdi.difference(_kararsizUyariAn!);
        if (!gecen.isNegative && gecen.inMinutes < 10) {
          _bastirilanGecis++;
          return;
        }
      }
      _kararsizUyariAn = simdi;
      LogService().warning(
        LogType.general,
        'Baglanti kararsiz: son 10 dk icinde ${_sonGecisler.length} gecis',
        details: {
          'durum': nowOnline ? 'online' : 'offline',
          // gecis_sayisi = son 10 dk PENCERESI; yazilmayan_gecis = son uyaridan beri yutulan.
          // Ikisi ORTUSUR, TOPLANMAZ.
          'gecis_sayisi': _sonGecisler.length,
          'yazilmayan_gecis': _bastirilanGecis,
          'nic': _nicOnline,
          'backend': _backendReachable,
          if (oncekiSn != null) 'onceki_durum_sn': oncekiSn,
        },
      );
      _bastirilanGecis = 0;
      return;
    }

    LogService().logAction(
      'Baglanti ${nowOnline ? "ONLINE" : "OFFLINE"}',
      details: {
        'durum': nowOnline ? 'online' : 'offline',
        'nic': _nicOnline,
        'backend': _backendReachable,
        if (oncekiSn != null) 'onceki_durum_sn': oncekiSn,
        // Sel bastirmasi bittikten sonraki ILK normal kayit yutulanlari da soyler.
        if (_bastirilanGecis > 0) 'yazilmayan_gecis': _bastirilanGecis,
      },
    );
    _bastirilanGecis = 0;
  }

  void _emitIfChanged(bool wasOnline, bool notify) {
    final nowOnline = isOnline;
    if (wasOnline != nowOnline && notify) {
      _connectionController.add(nowOnline);
      print('[Connectivity] Status changed: ${nowOnline ? "ONLINE" : "OFFLINE"} '
          '(nic=$_nicOnline, backend=$_backendReachable)');
      // Log ASLA akisi bozmasin (LogService diske/bellege yazar, ag beklemez).
      try {
        _gecisiLogla(nowOnline);
      } catch (_) {}
    }
  }

  /// Manuel yeniden kontrol (NIC + probe). Cagiran: kritik islem oncesi tazelik isteyen yerler.
  Future<bool> checkConnection() async {
    final result = await _connectivity.checkConnectivity();
    _updateNicStatus(result, notify: true);
    await _runProbe();
    return isOnline;
  }

  void dispose() {
    _probeTimer?.cancel();
    _connectionController.close();
  }
}
