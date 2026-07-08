import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';
import 'local_db_service.dart';

/// LAN'da bulunan + tenant-dogrulanmis bir POS cihazi.
class LanPeer {
  final String deviceId;
  final String ip;
  final int port;
  final String? deviceName;
  final bool isMain; // "ana kasa" isaretli mi (lider seciminde oncelikli)
  DateTime lastSeen;
  LanPeer({required this.deviceId, required this.ip, required this.port, this.deviceName, this.isMain = false})
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
    // 🔴 7 Tem (Fable K3): Flag KAPALI olsa bile bir kez LAN satirlarini temizle. LAN acikken
    // sert kapanma (dispose calismaz) sonrasi kalintili lan_origin='lan' satirlar getOfflineOpenTableIds'e
    // sizip hayalet dolu masa + cift kayit uretebilir. Flag OFF = LAN satiri SIFIR garantisi.
    try {
      await _localDb.pruneLanTickets(const {});
    } catch (_) {}
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
      _cachedIsMain = (prefs.getString(_mainDeviceKey) ?? 'auto') == 'this';
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
    // Faz 2: masa senkronu (5sn) — lider secilir, acik masalar peer'lere yayilir/cekilir.
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _runTableSync());
    // 7 Tem (Fable re-audit DÜŞÜK-1): init prune LAN satirlarini siler; periyodik sync ILK tetigi
    // 5sn sonra. Ilk kesif bitince (~1.5sn) bir kez erken sync -> LAN masalari daha hizli geri gelir
    // (boot flicker ~5sn -> ~1.5sn). Timer degil tek-atis; hata LAN akisini bloklamaz.
    Timer(const Duration(milliseconds: 1500), () { _runTableSync().catchError((_) {}); });
  }

  Timer? _syncTimer;
  bool _syncing = false;
  final _localDb = LocalDbService();

  /// HIBRIT lider secimi (DETERMINISTIK — oylama YOK, herkes ayni sonuca varir = kavga YOK).
  /// Kural: "ana kasa" isaretli cihaz(lar) varsa -> onlarin en kucuk device_id'si lider.
  /// Yoksa -> tum cihazlarin (biz + peer'ler) en kucuk device_id'si lider.
  /// Doner: lider device_id (bu cihaz lider ise _deviceId).
  Future<String?> _electLeader() async {
    if (_deviceId == null) return null;
    final iAmMain = await isThisMainDevice();
    // Aday havuzu: kendimiz + dogrulanmis peer'lar.
    final all = <String>{_deviceId!, ..._peers.keys};
    // Ana-kasa isaretli cihazlar: kendimiz (biliyoruz) + peer'lerin main bayragi (handshake'te tasinir).
    final mains = <String>{
      if (iAmMain) _deviceId!,
      ..._peers.values.where((p) => p.isMain).map((p) => p.deviceId),
    };
    final pool = mains.isNotEmpty ? mains : all;
    final sorted = pool.toList()..sort();
    return sorted.isEmpty ? null : sorted.first;
  }

  /// Masa senkronu: lider isek acik masalarimizi peer'lere yayariz; degilsek liderden cekeriz.
  Future<void> _runTableSync() async {
    if (!_enabled || _syncing || _deviceId == null) return;
    if (_peers.isEmpty) {
      // Tek cihaz -> LAN yansimasi gereksiz; onceki LAN masalarini temizle (varsa).
      await _localDb.pruneLanTickets(const {});
      return;
    }
    _syncing = true;
    try {
      final leader = await _electLeader();
      if (leader == _deviceId) {
        await _localDb.pruneLanReflectionsKeepLeases(); // K-1: lease tasiyan defter kopyasi KORUNUR
        await _renewOwnLeases();
        await _localDb.reconcileHeldSyncs(_deviceId!); // K-3: teslim edilmemis held -> backend
        await _localDb.quarantinePrune();
        return;
      }
      final leaderPeer = _peers[leader];
      if (leaderPeer == null) {
        await _localDb.pruneLanTickets(const {});
        return;
      }
      await _renewOwnLeasesViaLeader(leaderPeer);
      final tickets = await _fetchLeaderTables(leaderPeer);
      if (tickets == null) return; // lidere ulasilamadi -> mevcut LAN masalari kalsin
      final active = <String>{};
      for (final t in tickets) {
        final tn = t['ticket_number']?.toString();
        final tid = t['table_id'];
        if (tn == null || tid is! int) continue;
        active.add(tn);
        final realOwner = t['owner_device_id']?.toString() ?? leader ?? '';
        final leaseMs = (t['lease_ms'] is num) ? (t['lease_ms'] as num).toInt() : null;
        await _localDb.upsertLanTicket(
          ticketNumber: tn,
          tableId: tid,
          tableNumber: t['table_number']?.toString(),
          ownerDeviceId: realOwner,
          status: t['status']?.toString() ?? 'open',
          total: (t['total'] is num) ? (t['total'] as num).toDouble() : 0,
          leaseMs: leaseMs,
        );
      }
      await _localDb.pruneLanTickets(active); // kapanan LAN masalarini temizle
      await _localDb.reconcileHeldSyncs(_deviceId!); // K-3: teslim edilmemis held -> backend
      await _localDb.quarantinePrune();
    } catch (e) {
      print('[LanSync] Masa senkron hatasi: $e');
    } finally {
      _syncing = false;
    }
  }

  /// Bu cihazin acik self masalari icin lease damgasini tazele (lider isek dogrudan defter).
  Future<void> _renewOwnLeases() async {
    if (_deviceId == null) return;
    try {
      final mine = await _localDb.getSelfOpenTicketsForLan();
      for (final t in mine) {
        final tid = t['table_id'];
        if (t['owner_device_id']?.toString() != _deviceId) continue;
        if (tid is int) {
          await _localDb.tryGrantLease(
            tableId: tid, claimant: _deviceId!, leaseTtl: leaseTtl, isRenew: true);
        }
      }
    } catch (_) {}
  }

  /// Istemci: kendi acik masalarini lidere lease_renew ile tazele. Red 'held' + yerel foreign-lease
  /// teyidi -> korumali demote (held, geri donusumlu).
  Future<void> _renewOwnLeasesViaLeader(LanPeer leader) async {
    if (_deviceId == null) return;
    try {
      final mine = await _localDb.getSelfOpenTicketsForLan();
      for (final t in mine) {
        final tid = t['table_id'];
        if (t['owner_device_id']?.toString() != _deviceId) continue;
        if (tid is! int) continue;
        final res = await _sendLeaseMsg(leader, 'lease_renew', tid);
        if (res != null && res['reason'] == 'held') {
          await _demoteCandidate(tid, res['owner']?.toString());
        }
      }
    } catch (_) {}
  }

  /// Korumali demote: SADECE yerel defterde karsi-owner'in CANLI lease'i teyit edilirse dusur
  /// (iki-sinyal: lider 'held' + yerel ledger foreign lease). Teyit yoksa DOKUNMA (gecici titreme /
  /// lider amnezisi = yanlis-pozitif, veri kaybi yasak Fable S8). demote SILMEZ, held'e alir (un-hold geri donusumlu).
  Future<void> _demoteCandidate(int tableId, String? foreignOwner) async {
    if (_deviceId == null) return;
    try {
      final hasForeign = await _localDb.hasLiveForeignLease(tableId, _deviceId!);
      if (hasForeign) {
        await _localDb.demoteSelfAfterLeaseLost(tableId);
        _log('lease_demoted', msg: 'masa $tableId $foreignOwner cihazina devredildi (held)', warn: true);
      }
    } catch (_) {}
  }

  /// Liderden acik masalari cek (state_request). Auth: peer zaten kesifte HMAC-dogrulanmis.
  Future<List<Map<String, dynamic>>?> _fetchLeaderTables(LanPeer leader) async {
    Socket? socket;
    StreamSubscription? sub;
    try {
      socket = await Socket.connect(leader.ip, leader.port, timeout: const Duration(milliseconds: 600));
      final inbox = StreamController<Map<String, dynamic>>();
      final buf = <int>[];
      sub = socket.listen((data) {
        buf.addAll(data);
        if (buf.length > 65536) { buf.clear(); return; } // state cevabi buyuk olabilir (cok masa)
        int nl;
        while ((nl = buf.indexOf(10)) != -1) {
          final lb = buf.sublist(0, nl);
          buf.removeRange(0, nl + 1);
          try {
            final m = jsonDecode(utf8.decode(lb, allowMalformed: true));
            if (m is Map<String, dynamic> && !inbox.isClosed) inbox.add(m);
          } catch (_) {}
        }
      }, onError: (_) { if (!inbox.isClosed) inbox.close(); },
         onDone: () { if (!inbox.isClosed) inbox.close(); }, cancelOnError: true);

      // state_request'e proof ekle (liderin ayni bayi oldugumuzu bilmesi icin nonce degil, statik degil —
      // her istekte challenge/verify pahali; kesifte zaten dogrulandik. Basit: nonce+hmac tek atis).
      final nonce = _randomNonce();
      _send(socket, {'type': 'state_request', 'nonce': nonce, 'proof': _hmac(nonce)});
      final reply = await inbox.stream.first
          .timeout(const Duration(milliseconds: 1000), onTimeout: () => <String, dynamic>{});
      if (reply['type'] != 'state' || reply['tables'] is! List) return null;
      // 🔴 7 Tem (Fable O3): liderin cevabini da HMAC ile dogrula (bizim nonce'umuza). Boylece
      // lider IP:port'unu ele geciren sahte cihaz kanitsiz masa listesi ENJEKTE EDEMEZ.
      final leaderProof = reply['proof']?.toString() ?? '';
      if (!_constantTimeEquals(leaderProof, _hmac(nonce))) return null; // kanitsiz cevap -> yansitma
      return (reply['tables'] as List).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      socket?.destroy();
    }
  }

  /// Masaya yazma-oncesi lease iste. flag OFF -> true (Faz 2 aynen). Lider isek dogrudan defter;
  /// degilsek lidere lease_claim yolla. Lider ulasilamazsa true (offline yazmaya izin — split-brain
  /// riski salt-okunur yansima + backend merge ile karsilanir; kilitli kalmasindan iyidir).
  Future<bool> claimTable(int tableId, {bool isRenew = false}) async {
    if (!_enabled || _deviceId == null) return true;
    final leader = await _electLeader();
    bool granted;
    if (leader == _deviceId) {
      final res = await _localDb.tryGrantLease(
        tableId: tableId, claimant: _deviceId!, leaseTtl: leaseTtl, isRenew: isRenew);
      granted = res['granted'] == true;
    } else {
      final leaderPeer = _peers[leader];
      if (leaderPeer == null) return true;
      final res = await _sendLeaseMsg(leaderPeer, isRenew ? 'lease_renew' : 'lease_claim', tableId);
      if (res == null) return true;
      granted = res['ok'] == true;
    }
    // NOT: un-hold ARTIK burada yapilmiyor (K-2). openTicket = HER ZAMAN temiz yeni oturum;
    // eski demote edilmis held sync'ler _reconcileHeldSyncs (arka plan) ile teslim edilir,
    // dirilip yeni oturuma karismaz. Backend masa-bazli merge iki kaydi dogru ayirir.
    return granted;
  }

  /// LAN ayar ekrani icin lease durum ozeti (UI gostergesi). flag OFF veya deviceId yoksa bos.
  Future<Map<String, dynamic>> leaseStatus() async {
    if (!_enabled || _deviceId == null) {
      return {'mine': const [], 'foreign': const [], 'heldCount': 0};
    }
    return await _localDb.getLanLeaseStatus(_deviceId!);
  }

  Future<bool> releaseTable(int tableId) async {
    if (!_enabled || _deviceId == null) return true;
    final leader = await _electLeader();
    if (leader == _deviceId) {
      await _localDb.clearLease(tableId, _deviceId!);
      return true;
    }
    final leaderPeer = _peers[leader];
    if (leaderPeer == null) return true;
    await _sendLeaseMsg(leaderPeer, 'lease_release', tableId);
    return true;
  }

  Future<Map<String, dynamic>?> _sendLeaseMsg(LanPeer leader, String type, int tableId) async {
    Socket? socket;
    StreamSubscription? sub;
    try {
      socket = await Socket.connect(leader.ip, leader.port, timeout: const Duration(milliseconds: 600));
      final inbox = StreamController<Map<String, dynamic>>();
      final buf = <int>[];
      sub = socket.listen((data) {
        buf.addAll(data);
        if (buf.length > 8192) { buf.clear(); return; }
        int nl;
        while ((nl = buf.indexOf(10)) != -1) {
          final lb = buf.sublist(0, nl);
          buf.removeRange(0, nl + 1);
          try {
            final m = jsonDecode(utf8.decode(lb, allowMalformed: true));
            if (m is Map<String, dynamic> && !inbox.isClosed) inbox.add(m);
          } catch (_) {}
        }
      }, onError: (_) { if (!inbox.isClosed) inbox.close(); },
         onDone: () { if (!inbox.isClosed) inbox.close(); }, cancelOnError: true);

      final nonce = _randomNonce();
      _send(socket, {'type': type, 'nonce': nonce, 'proof': _hmac(nonce), 'table_id': tableId, 'claimant': _deviceId});
      final reply = await inbox.stream.first
          .timeout(const Duration(milliseconds: 1000), onTimeout: () => <String, dynamic>{});
      if (reply['type'] != 'lease_result') return null;
      final leaderProof = reply['proof']?.toString() ?? '';
      if (!_constantTimeEquals(leaderProof, _hmac(nonce))) return null;
      return reply;
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      socket?.destroy();
    }
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
          'is_main': _cachedIsMain, // lider seciminde peer'in bilmesi icin
        });
      }
    } else if (type == 'state_request') {
      // Faz 2: peer (dogrulanmis, ayni bayi) acik masalarimizi istiyor. HMAC ile teyit (yabanci cekemesin).
      final nonce = msg['nonce']?.toString() ?? '';
      final got = msg['proof']?.toString() ?? '';
      if (nonce.isEmpty || nonce.length > 128) return;
      if (!_constantTimeEquals(got, _hmac(nonce))) return; // yanlis bayi -> state VERME
      // 🔴 7 Tem (Fable O3): cevaba da kendi HMAC kanitimizi koy (client nonce'una) -> client
      // liderin ayni bayi oldugunu dogrular; lider IP'sini ele geciren sahte cihaz masa enjekte edemez.
      _localDb.getLanLedgerForBroadcast().then((ledger) {
        _send(socket, {'type': 'state', 'tables': ledger, 'proof': _hmac(nonce)});
      }).catchError((_) {});
    } else if (type == 'lease_claim' || type == 'lease_renew' || type == 'lease_release') {
      _handleLeaseMessage(socket, type, msg);
    }
  }

  static const Duration leaseTtl = Duration(seconds: 45);

  Future<void> _handleLeaseMessage(Socket socket, String type, Map<String, dynamic> msg) async {
    final nonce = msg['nonce']?.toString() ?? '';
    final got = msg['proof']?.toString() ?? '';
    if (nonce.isEmpty || nonce.length > 128) return;
    if (!_constantTimeEquals(got, _hmac(nonce))) return;
    final tableId = msg['table_id'];
    final claimant = msg['claimant']?.toString();
    if (tableId is! int || claimant == null || claimant.isEmpty) {
      _send(socket, {'type': 'lease_result', 'ok': false, 'reason': 'bad_request', 'proof': _hmac(nonce)});
      return;
    }
    final leader = await _electLeader();
    if (leader != _deviceId) {
      _send(socket, {'type': 'lease_result', 'ok': false, 'reason': 'not_leader', 'leader': leader, 'proof': _hmac(nonce)});
      return;
    }
    try {
      if (type == 'lease_release') {
        await _localDb.clearLease(tableId, claimant);
        _send(socket, {'type': 'lease_result', 'ok': true, 'released': true, 'proof': _hmac(nonce)});
        return;
      }
      final res = await _localDb.tryGrantLease(
        tableId: tableId, claimant: claimant, leaseTtl: leaseTtl, isRenew: type == 'lease_renew');
      final granted = res['granted'] == true;
      _send(socket, {
        'type': 'lease_result',
        'ok': granted,
        'owner': res['owner'],
        'reason': res['reason'],
        'takeover': res['takeover'] == true,
        'lease_ms': granted ? leaseTtl.inMilliseconds : 0,
        'proof': _hmac(nonce),
      });
    } catch (_) {
      _send(socket, {'type': 'lease_result', 'ok': false, 'reason': 'error', 'proof': _hmac(nonce)});
    }
  }

  bool _cachedIsMain = false; // isThisMainDevice() cache (senkron erisim icin, prefs'ten periyodik tazelenir)

  final Map<Socket, _Pending> _pending = {};

  // ---------------- CLIENT (digerlerini bul + dogrula) ----------------

  bool _scanning = false; // FIX (Fable #3): re-entry guard — tarama uste binmesin (fd tukenmesi katlanmasin)
  String _lastPeerSig = '__init__'; // log firtinasi onleme: peer listesi degisince logla
  final Set<String> _rejectedLogged = {}; // ayni yabanci'yi tekrar tekrar loglama

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
      // LOG FIRTINASI ONLEME (Mustafa uyarisi + selftest dersi): keşif her 15sn calisir ama
      // discovery logunu SADECE peer listesi DEGISTIGINDE bas (ayni durumu tekrar tekrar loglama).
      // Boylece kararli durumda sunucuya log gitmez; sadece cihaz gelince/gidince 1 log.
      final sig = (peers.map((p) => p.deviceId).toList()..sort()).join(',');
      if (sig != _lastPeerSig) {
        _lastPeerSig = sig;
        print('[LanSync] Peer listesi degisti: ${_peers.length} peer');
        _log('discovery', msg: 'Peer listesi degisti: ${_peers.length} peer (ayni bayi)', extra: {
          'subnet': subnet.prefix,
          'peers': peers.map((p) => {'id': p.deviceId, 'ip': p.ip, 'port': p.port}).toList(),
        });
      }
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
        // Ayni yabanciyi her 15sn loglamayalim (firtina onleme) — ip:port bazli tek log.
        final k = '$ip:$port';
        if (_rejectedLogged.add(k)) {
          _log('peer_rejected', msg: 'Peer REDDEDILDI (farkli bayi): $ip:$port', warn: true,
              extra: {'peer_ip': ip, 'peer_port': port});
        }
        return true;
      }
      final peerDeviceId = r2['device_id']?.toString();
      if (peerDeviceId == null || peerDeviceId == _deviceId) return true;
      final replyPort = (r2['port'] is int) ? r2['port'] as int : port;
      final isMain = r2['is_main'] == true;
      final isNew = !_peers.containsKey(peerDeviceId);
      _peers[peerDeviceId] = LanPeer(deviceId: peerDeviceId, ip: ip, port: replyPort,
          deviceName: r2['device_name']?.toString(), isMain: isMain);
      if (isNew) {
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
        // K-3 kill-switch: flag kapatilmadan ONCE held sync'leri backend'e KURTAR (yoksa demote
        // edilmis satislar kalici mühürlenip sessiz ciro kaybi olur). _deviceId null ise (hic
        // baslamamis) reconcile bos doner — guvenli. Sonra dispose LAN yansimalarini temizler.
        if (_deviceId != null) {
          await _localDb.reconcileHeldSyncs(_deviceId!).catchError((_) => 0);
        }
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
    _cachedIsMain = isMain;
  }

  Future<bool> isThisMainDevice() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_mainDeviceKey) ?? 'auto') == 'this';
  }

  void dispose() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _server?.close();
    _server = null;
    _listenPort = null;
    _peers.clear();
    // LAN kapaninca yansimis masalari temizle (UI'da hayalet kalmasin).
    _localDb.pruneLanTickets(const {}).catchError((_) {});
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
