import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';

/// LAN'da bulunan + tenant-dogrulanmis bir POS cihazi.
class LanPeer {
  final String deviceId;
  final String ip;
  final int port;
  final String? deviceName;
  DateTime lastSeen;
  LanPeer({required this.deviceId, required this.ip, required this.port, this.deviceName})
      : lastSeen = DateTime.now();
}

/// LAN-SENKRON SERVISI (7 Tem 2026) — Yaklasim B: KASA-LIDER (HIBRIT lider).
///
/// AMAC: Ayni restorandaki birden cok POS cihazi (ayni LAN'da) CEVRIMDISIYKEN birbiriyle haberlessin.
///
/// MUTLAK KISITLAR (Mustafa):
/// 1. Yazicidan fis cikmasi ASLA bozulmaz (offline mutfak fisi LAN TCP 9100 cihaz-LOKAL, bu servise BAGLI DEGIL).
/// 2. Backend'e DOKUNULMAZ — tamamen cihaz-cihaz (Flutter).
/// 3. Multi-tenant: cihaz SADECE ayni bayinin (API key HMAC challenge) cihazlariyla konusur. Yabanci REDDEDILIR.
/// 4. Flag KAPALI / LAN yok / tek cihaz -> mevcut offline akis AYNEN.
///
/// BU FAZ 1: KESIF + TENANT-DOGRULAMA. Cihazlar birbirini subnet tarama ile bulur; her peer HMAC
/// challenge ile ayni bayi mi diye dogrulanir (yanlis bayi/misafir agi REDDEDILIR). Henuz masa senkronu
/// YOK — sadece "aynı bayiden N peer goruyorum". Lider secimi + masa yansimasi Faz 2, kilit Faz 3.
///
/// PORT STRATEJISI (Mustafa): Sabit aralik 47500-47519. ServerSocket ilk BOS portu bulur; kesif TUM
/// araligi tarar (karsi taraf hangi portu actiysa bulur). Manuel port YOK.
///
/// GUVENLIK: API key HAM GONDERILMEZ (memory: sunucudan-sunucuya-sifre-yasak). Sadece HMAC-SHA256 ispati:
/// challenge nonce -> HMAC(apiKey, nonce). Ayni key'i BILEN cihaz dogru cevap uretir; key hic aga cikmaz.
class LanSyncService {
  static final LanSyncService _instance = LanSyncService._internal();
  factory LanSyncService() => _instance;
  LanSyncService._internal();

  static const String _flagKey = 'lan_sync_enabled';
  static const String _deviceIdKey = 'pos_device_id'; // api_service._getDeviceId ile AYNI (tek kaynak)
  static const String _apiKeyPref = 'pos_api_key';    // storage_service _apiKeyKey ile AYNI
  static const String _mainDeviceKey = 'lan_main_device'; // HIBRIT: 'auto' | 'this' (ana kasa isareti)

  // Port araligi (Mustafa karari 7 Tem): GENIS aralik ki "hepsi dolu" IMKANSIZ olsun.
  // 47500-47519 (20 port). Bunlar IANA kayitsiz/gecici port araliginda, bilinen hicbir yaygin
  // servis kullanmaz. Bir masaustu PC'de 20'sinin AYNI ANDA dolu olmasi gerceklesmez.
  // ServerSocket ilk bos portu bulur; kesif TUM araligi tarar (karsi taraf hangisini actiysa bulunur).
  static const int _portBase = 47500;
  static const int _portCount = 20;

  bool _enabled = false;
  bool get enabled => _enabled;

  String? _deviceId;
  String? get deviceId => _deviceId;

  String? _apiKey; // tenant kimligi kaynagi (HMAC icin; aga HAM cikmaz)

  ServerSocket? _server;
  int? _listenPort;
  int? get listenPort => _listenPort;

  Timer? _discoveryTimer;
  bool _initDone = false;

  // Bulunan + dogrulanmis peer'lar (deviceId -> LanPeer)
  final Map<String, LanPeer> _peers = {};
  List<LanPeer> get peers => _peers.values.toList();

  final StreamController<List<LanPeer>> _peersController = StreamController<List<LanPeer>>.broadcast();
  Stream<List<LanPeer>> get peersStream => _peersController.stream;

  /// Baslatma. Flag kapaliysa hicbir sey yapmaz (mevcut akis aynen).
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    await _reloadPrefs();
    print('[LanSync] init: enabled=$_enabled, deviceId=${_deviceId ?? "(yok)"}');
    if (!_enabled) return;
    await _start();
  }

  /// Fable Faz-0 notu #2: device_id boot'ta null olabilir (validateApiKey init'ten sonra). Lazy re-read.
  Future<void> _reloadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_flagKey) ?? false;
      _deviceId = prefs.getString(_deviceIdKey);
      _apiKey = prefs.getString(_apiKeyPref);
    } catch (e) {
      print('[LanSync] pref okuma hatasi (guvenli: kapali): $e');
      _enabled = false;
    }
  }

  /// Servisi baslat: ServerSocket ac (ilk bos port) + periyodik kesif. SADECE _enabled ise cagrilir.
  Future<void> _start() async {
    if (_deviceId == null || _apiKey == null) {
      // Kimlik henuz hazir degil (kurulum tamamlanmamis) -> baslatma, bir sonraki reconnect'te tekrar denenir.
      print('[LanSync] Kimlik hazir degil (deviceId/apiKey), LAN baslatilmadi');
      return;
    }
    await _startServer();
    // Ilk kesif hemen + periyodik (15sn). LAN peer'lar gelir/gider.
    _runDiscovery();
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 15), (_) => _runDiscovery());
  }

  // ---------------- SERVER (bu cihazi dinlenebilir yap) ----------------

  Future<void> _startServer() async {
    if (_server != null) return;
    for (int p = _portBase; p < _portBase + _portCount; p++) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, p);
        _listenPort = p;
        print('[LanSync] Dinleme portu: $p');
        _server!.listen(_handleIncoming, onError: (e) => print('[LanSync] server err: $e'));
        _log('server_start', msg: 'LAN dinleme basladi (port $p)');
        return;
      } catch (_) {
        // port dolu -> sonrakini dene (Mustafa: sirasiyla)
      }
    }
    print('[LanSync] UYARI: 47500-47519 arasi bos port yok, LAN dinleme acilamadi');
    _log('server_fail', msg: 'LAN dinleme portu acilamadi (47500-47519 dolu)', warn: true);
  }

  int _activeIncoming = 0; // FIX (Fable #6): es zamanli gelen baglanti sayaci
  int _incomingPeakLogged = 0; // limit-yaklasma logu spam onleme
  // 7 Tem 2026 (Mustafa: "her buyuklugu dusun", 10-30 cihaz zincir): limit BOL (128). Restoranda
  // cihaz sayisi kadar es-zamanli baglanti olur (siparis sayisi DEGIL — baglantilar 5sn'de kapanir,
  // birikmez). 30 cihaz her 15sn'de kisa baglanir -> tepe ~30. 128 = 4x pay, macOS fd 256 altinda
  // (yazici/sync icin yer kalir). Limit asilirsa SESSIZCE KESME -> logla (adminsync'te teshis).
  static const int _maxIncoming = 128;
  static const int _maxLineBytes = 8192; // FIX (Fable #1): satir/buffer boyut siniri (DoS onleme)

  /// Gelen baglanti: satir-bazli JSON protokol. FAZ 1'de sadece CHALLENGE cevabi.
  /// FIX'ler: (#6) es zamanli baglanti limiti+log, (#1) buffer boyut siniri + byte-bazli birikim,
  /// (#7) guvenli UTF-8 (allowMalformed — bolunmus multi-byte'ta CRASH etmez), socket her yolda KAPANIR.
  void _handleIncoming(Socket socket) {
    // Limit yaklasma erken uyarisi (teshis): %75'te bir kez logla (spam'siz).
    if (_activeIncoming >= (_maxIncoming * 3 ~/ 4) && _activeIncoming > _incomingPeakLogged) {
      _incomingPeakLogged = _activeIncoming;
      _log('incoming_high', warn: true,
          msg: 'LAN es-zamanli baglanti yuksek: $_activeIncoming/$_maxIncoming',
          extra: {'active': _activeIncoming, 'limit': _maxIncoming});
    }
    if (_activeIncoming >= _maxIncoming) {
      // Limit asildi. SESSIZCE kesmiyoruz -> LOGLA (Mustafa: masa senkronu sessizce dusmesin,
      // teshis edelim). Yine de bu baglantiyi kapatmak zorundayiz (fd korumasi); ama bu ANLIK
      // bir keşif challenge'i oldugundan cihaz 15sn sonra tekrar dener (kalici kayip degil).
      _log('incoming_limit', warn: true,
          msg: 'LAN baglanti limiti asildi ($_maxIncoming) — baglanti reddedildi, 15sn sonra retry',
          extra: {'limit': _maxIncoming});
      socket.destroy();
      return;
    }
    _activeIncoming++;
    if (_activeIncoming < (_maxIncoming * 3 ~/ 4)) _incomingPeakLogged = 0; // normale donunce reset
    final bytes = <int>[]; // byte biriktir (utf8'i satir tamamlaninca coz -> bolunmus multi-byte guvenli)
    bool closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      _activeIncoming--;
      _pending.remove(socket);
      try {
        socket.destroy();
      } catch (_) {}
    }

    // Emniyet: bir baglanti en fazla 5sn acik kalir (FAZ 1 tek-mesaj challenge; asili kalma onleme).
    final guard = Timer(const Duration(seconds: 5), closeOnce);

    socket.listen(
      (data) {
        if (closed) return;
        bytes.addAll(data);
        if (bytes.length > _maxLineBytes) {
          // Boyut siniri asildi (newline'siz dev mesaj / DoS) -> baglantiyi kes.
          guard.cancel();
          closeOnce();
          return;
        }
        int nl;
        while ((nl = bytes.indexOf(10)) != -1) { // 10 = '\n'
          final lineBytes = bytes.sublist(0, nl);
          bytes.removeRange(0, nl + 1);
          String line;
          try {
            line = utf8.decode(lineBytes, allowMalformed: true);
          } catch (_) {
            continue;
          }
          _handleMessage(socket, line);
        }
      },
      onError: (_) {
        guard.cancel();
        closeOnce();
      },
      onDone: () {
        guard.cancel();
        closeOnce();
      },
      cancelOnError: true,
    );
  }

  void _handleMessage(Socket socket, String line) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = msg['type'];
    // FIX (Fable #5): HMAC oracle KAPATMA. Client challenge yollasa da HEMEN proof VERMEYIZ —
    // once client kendini ispatlamali (challenge_verify). Boylece yanlis-key saldirgan sectigi
    // nonce'lar icin MAC TOPLAYAMAZ. client nonce'u serverNonce ile birlikte saklanir.
    if (type == 'challenge') {
      final nonce = msg['nonce']?.toString() ?? '';
      if (nonce.isEmpty || nonce.length > 128) return;
      final serverNonce = _randomNonce();
      _pending[socket] = _Pending(clientNonce: nonce, serverNonce: serverNonce);
      _send(socket, {'type': 'challenge_ok', 'server_nonce': serverNonce}); // proof YOK (henuz)
    } else if (type == 'challenge_verify') {
      final p = _pending.remove(socket);
      if (p == null) return;
      final expected = _hmac(p.serverNonce);
      final got = msg['proof']?.toString() ?? '';
      if (_constantTimeEquals(got, expected)) {
        // Client kendini ispatladi -> ARTIK ona hem proof (client nonce) hem kimligimizi veririz.
        _send(socket, {
          'type': 'identity',
          'proof': _hmac(p.clientNonce),
          'device_id': _deviceId,
          'device_name': null,
          'port': _listenPort,
        });
      }
    }
  }

  final Map<Socket, _Pending> _pending = {};

  // ---------------- CLIENT (digerlerini bul + dogrula) ----------------

  bool _scanning = false; // FIX (Fable #3): re-entry guard — tarama uste binmesin (fd tukenmesi katlanmasin)

  Future<void> _runDiscovery() async {
    if (!_enabled || _apiKey == null) return;
    if (_scanning) return; // onceki tarama bitmeden yenisini baslatma
    _scanning = true;
    try {
      final subnet = await _localSubnet();
      if (subnet == null) return;

      // Eski peer'lari sula (45sn gorulmezse dus)
      final now = DateTime.now();
      _peers.removeWhere((_, peer) => now.difference(peer.lastSeen).inSeconds > 45);

      // FIX (Fable #2+#4): HAVUZ-SINIRLI tarama. Eskiden 254 IP once TUM future'lar uretilip ayni anda
      // Socket.connect ediliyordu -> macOS fd limiti (256) asilir -> "Too many open files" -> DOLAYLI
      // olarak yazicinin 9100 connect'i / sync HTTP'si PATLAR (Mustafa kirmizi cizgi). Simdi ayni anda
      // en fazla _scanPool kadar host taranir; her host portlari SIRAYLA dener (ilk acik portta durur).
      final myIp = subnet.myIp;
      final hosts = <String>[];
      for (int i = 1; i <= 254; i++) {
        final ip = '${subnet.prefix}$i';
        if (ip != myIp) hosts.add(ip);
      }
      const scanPool = 32; // ayni anda en fazla 32 host (fd guvenli)
      for (int start = 0; start < hosts.length; start += scanPool) {
        final batch = hosts.sublist(start, (start + scanPool).clamp(0, hosts.length));
        await Future.wait(batch.map(_probeHost));
      }

      _peersController.add(peers);
      print('[LanSync] Kesif tamam: ${_peers.length} dogrulanmis peer (ayni bayi)');
      _log('discovery', msg: 'Kesif tamam: ${_peers.length} peer (ayni bayi)', extra: {
        'subnet': subnet.prefix,
        'peers': peers.map((p) => {'id': p.deviceId, 'ip': p.ip, 'port': p.port}).toList(),
      });
    } finally {
      _scanning = false;
    }
  }

  /// Bir HOST'ta port araligini SIRAYLA dener; ilk gecerli POS peer'inda durur.
  Future<void> _probeHost(String ip) async {
    for (int p = _portBase; p < _portBase + _portCount; p++) {
      final found = await _probePeer(ip, p);
      if (found) return; // bu host'ta peer bulundu, kalan portlari deneme
    }
  }

  /// Bir IP:port'a baglan, karsilikli HMAC dogrula. Doner: true = bu port'ta POS peer (host taramasi dursun).
  Future<bool> _probePeer(String ip, int port) async {
    Socket? socket;
    StreamSubscription? sub;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
      // Tek listener (Socket single-subscription): mesajlari tek kuyruktan oku (StateError yok).
      final inbox = StreamController<Map<String, dynamic>>();
      final buf = <int>[];
      sub = socket.listen((data) {
        buf.addAll(data);
        if (buf.length > _maxLineBytes) { buf.clear(); return; }
        int nl;
        while ((nl = buf.indexOf(10)) != -1) {
          final lineBytes = buf.sublist(0, nl);
          buf.removeRange(0, nl + 1);
          try {
            final m = jsonDecode(utf8.decode(lineBytes, allowMalformed: true));
            if (m is Map<String, dynamic> && !inbox.isClosed) inbox.add(m);
          } catch (_) {}
        }
      }, onError: (_) { if (!inbox.isClosed) inbox.close(); },
         onDone: () { if (!inbox.isClosed) inbox.close(); }, cancelOnError: true);

      Future<Map<String, dynamic>?> next() =>
          inbox.stream.first.timeout(const Duration(milliseconds: 800), onTimeout: () => <String, dynamic>{}).then((m) => m.isEmpty ? null : m);

      final nonce = _randomNonce();
      final expected = _hmac(nonce);
      // Adim1: challenge -> challenge_ok (server_nonce; proof HENUZ yok — oracle kapali)
      _send(socket, {'type': 'challenge', 'nonce': nonce});
      final r1 = await next();
      if (r1 == null || r1['type'] != 'challenge_ok') return false;
      final serverNonce = r1['server_nonce']?.toString();
      if (serverNonce == null) return false;
      // Adim2: server_nonce'a BIZIM ispat -> identity (proof + device_id). Once biz ispatlariz.
      _send(socket, {'type': 'challenge_verify', 'proof': _hmac(serverNonce)});
      final r2 = await next();
      if (r2 == null || r2['type'] != 'identity') return true; // karsi taraf bizi dogrulamadi
      // Simdi peer'in ispatini dogrula (ayni bayi mi). Sabit-zaman (Fable #9).
      final proof = r2['proof']?.toString();
      if (proof == null || !_constantTimeEquals(proof, expected)) {
        _log('peer_rejected', msg: 'Peer REDDEDILDI (farkli bayi): $ip:$port', warn: true,
            extra: {'peer_ip': ip, 'peer_port': port});
        return true;
      }
      final peerDeviceId = r2['device_id']?.toString();
      if (peerDeviceId == null || peerDeviceId == _deviceId) return true;
      final replyPort = (r2['port'] is int) ? r2['port'] as int : port;
      final existing = _peers[peerDeviceId];
      if (existing != null) {
        existing.lastSeen = DateTime.now();
      } else {
        _peers[peerDeviceId] = LanPeer(deviceId: peerDeviceId, ip: ip, port: replyPort,
            deviceName: r2['device_name']?.toString());
        _log('peer_found', msg: 'Peer dogrulandi (ayni bayi): $ip:$replyPort', extra: {
          'peer_ip': ip, 'peer_port': replyPort, 'peer_device_id': peerDeviceId,
        });
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      await sub?.cancel();
      socket?.destroy();
    }
  }

  /// Sabit-zamanli string esitlik (timing yan-kanal onleme).
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ---------------- LOGLAMA ----------------
  // 7 Tem 2026 (Mustafa): LAN akislarini adminsync #poslogs'ta gormek icin. log_type='lan' + details.
  // Backend log_type'i esnek kabul ediyor -> backend'e DOKUNULMAZ. Sadece POS -> POST /api/pos/logs.

  void _log(String event, {String? msg, Map<String, dynamic>? extra, bool warn = false}) {
    final details = <String, dynamic>{
      'event': event, // 'discovery' / 'peer_found' / 'peer_rejected' / 'server_start' / 'leader' / ...
      'device_id': _deviceId,
      'listen_port': _listenPort,
      'peer_count': _peers.length,
      if (extra != null) ...extra,
    };
    final text = msg ?? 'LAN: $event';
    try {
      if (warn) {
        LogService().warning(LogType.lan, text, details: details);
      } else {
        LogService().info(LogType.lan, text, details: details);
      }
    } catch (_) {
      // log servisi hazir degilse sessiz (LAN akisini bloklamaz)
    }
  }

  // ---------------- YARDIMCILAR ----------------

  /// HMAC-SHA256(apiKey, nonce) hex. Ayni key'i bilenin ispati; key aga CIKMAZ.
  String _hmac(String nonce) {
    final key = utf8.encode(_apiKey ?? '');
    final bytes = utf8.encode(nonce);
    return Hmac(sha256, key).convert(bytes).toString();
  }

  String _randomNonce() {
    // DateTime + hashCode yeterli (kriptografik rastgelelik gerekmiyor; nonce tekrar-onleme icin).
    final seed = '${DateTime.now().microsecondsSinceEpoch}-${_peers.length}-${identityHashCode(this)}';
    return sha256.convert(utf8.encode(seed)).toString().substring(0, 24);
  }

  void _send(Socket socket, Map<String, dynamic> msg) {
    try {
      socket.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  Future<_Subnet?> _localSubnet() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              return _Subnet('${parts[0]}.${parts[1]}.${parts[2]}.', addr.address);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ---------------- KONTROL ----------------

  Future<void> setEnabled(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_flagKey, value);
      _enabled = value;
      if (value) {
        await _reloadPrefs();
        await _start();
      } else {
        dispose();
      }
      print('[LanSync] setEnabled=$value');
    } catch (e) {
      print('[LanSync] setEnabled hatasi: $e');
    }
  }

  /// HIBRIT lider ayari: bu cihaz "ana kasa" olsun mu? (Faz 2 lider seciminde kullanilir.)
  Future<void> setThisMainDevice(bool isMain) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mainDeviceKey, isMain ? 'this' : 'auto');
  }

  Future<bool> isThisMainDevice() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_mainDeviceKey) ?? 'auto') == 'this';
  }

  void dispose() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _server?.close();
    _server = null;
    _listenPort = null;
    _peers.clear();
  }
}

class _Pending {
  final String clientNonce;
  final String serverNonce;
  _Pending({required this.clientNonce, required this.serverNonce});
}

class _Subnet {
  final String prefix; // "192.168.1."
  final String myIp;
  _Subnet(this.prefix, this.myIp);
}
