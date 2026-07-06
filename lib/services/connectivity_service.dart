import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';

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
    // İlk NIC durumunu kontrol et
    final result = await _connectivity.checkConnectivity();
    _updateNicStatus(result, notify: false);

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

  /// GET {base}/health — IPv4 force (memory: saha IPv6 olu network), 2.5sn timeout.
  /// true = 2xx/3xx (backend ayakta), false = timeout/hata/5xx.
  Future<bool> _pingHealth(String base) async {
    HttpClient? client;
    try {
      final uri = Uri.parse('$base/health');
      client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 2500);
      // IPv4 force (CF IPv6 saha routing yok — memory feedback_flutter_ipv4_force).
      client.connectionFactory = (u, proxyHost, proxyPort) async {
        final addrs = await InternetAddress.lookup(u.host, type: InternetAddressType.IPv4);
        if (addrs.isEmpty) throw const SocketException('IPv4 yok');
        return Socket.startConnect(addrs.first, u.port);
      };
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

  void _emitIfChanged(bool wasOnline, bool notify) {
    final nowOnline = isOnline;
    if (wasOnline != nowOnline && notify) {
      _connectionController.add(nowOnline);
      print('[Connectivity] Status changed: ${nowOnline ? "ONLINE" : "OFFLINE"} '
          '(nic=$_nicOnline, backend=$_backendReachable)');
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
