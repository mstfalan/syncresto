import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'log_service.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _serverUrl;
  final LogService _logService = LogService();

  // Event callbacks
  Function(Map<String, dynamic>)? onNewOrder;
  Function(Map<String, dynamic>)? onOrderUpdate;
  Function(Map<String, dynamic>)? onPrintRequest;
  Function(bool)? onConnectionChange;
  // Cache invalidate — backend bir entity degisince anlik refresh tetikler
  // payload: { types: ['products', 'printers', ...] }
  Function(List<String>)? onCacheInvalidate;
  // 21 Tem 2026 FAN-OUT: TEK-SLOT onCacheInvalidate'i EZMEDEN ek dinleyiciler.
  // main.dart global handler (11/11 tip: products/printers/...) slotta AYNEN kalır;
  // ekranlar (TablesScreen 'table_status' masa push) buraya kayit olur. Servis-seviyesi
  // liste → _connect() reconnect/dispose dongusunden ETKILENMEZ (soket handler'lari
  // yeniden kurulur ama liste yasar). Bir listener'in exception'i digerlerini/slotu OLDURMEZ.
  final List<void Function(List<String>)> _cacheInvalidateListeners = [];
  void addCacheInvalidateListener(void Function(List<String>) l) {
    if (!_cacheInvalidateListeners.contains(l)) _cacheInvalidateListeners.add(l);
  }
  void removeCacheInvalidateListener(void Function(List<String>) l) {
    _cacheInvalidateListeners.remove(l);
  }
  // 16 May 2026: Aynı tenant POS'lar arası kitchen print broadcast
  // payload: { ticket_id, ticket_number, table_number, printer_groups, source_socket_id, ... }
  Function(Map<String, dynamic>)? onKitchenPrint;
  // 12 Haz 2026: Web POS print job hint — backend yeni fiş işi oluşunca emit eder.
  // Basım YETKİSİ taşımaz; sadece "hemen poll et" tetiğidir
  // (tek-basım garantisi DB'deki atomic claim'den gelir → WebposPrintService).
  Function()? onWebposJobsHint;

  bool get isConnected => _isConnected;
  String? _authToken;

  // 16 May 2026: panel.syncresto.com'a ek 2. socket (sadece kitchen_print için)
  IO.Socket? _panelSocket;
  String? _apiKey;

  // 12 Haz 2026: KALICI ÖLÜM FİX. reconnectionAttempts (10/20) tükenince
  // socket.io Manager 'reconnect_failed' emit eder ve bir daha ASLA denemez
  // → POS açıkken ~1dk internet kesintisi = fiş/cache eventleri kalıcı ölü.
  // DİKKAT: 'reconnect_failed' Socket'te DEĞİL Manager'da emit edilir
  // (paket kaynağı manager.dart:418) — bu yüzden _socket.io.on(...) ile dinlenir.
  Timer? _watchdogTimer;             // 45sn'de bir bağlantı sağlığı kontrolü
  Timer? _reconnectFailedTimer;      // _socket reconnect_failed → 30sn sonra tekrar
  Timer? _panelReconnectFailedTimer; // _panelSocket reconnect_failed → 30sn sonra tekrar
  bool _isReconnecting = false;      // watchdog üst üste binme koruması

  Future<void> connect(String serverUrl, {String? token}) async {
    var url = serverUrl.replaceAll('/api', '');
    // HTTP → HTTPS, ws → wss
    if (url.startsWith('http://')) url = url.replaceFirst('http://', 'https://');
    _serverUrl = url;
    _authToken = token;
    _connect();
    // 12 Haz 2026: watchdog'u başlat (bağlantı parametreleri artık elde)
    _startWatchdog();
  }

  // 12 Haz 2026: 45sn watchdog — reconnect_failed handler'ı herhangi bir
  // sebeple kaçarsa bağlantıyı toparlayan son emniyet kemeri. Her iki socket
  // için de geçerli. _isReconnecting guard'ı üst üste binmeyi engeller.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_isReconnecting) return;
      try {
        _isReconnecting = true;
        if (_serverUrl != null && (_socket == null || _socket!.connected != true)) {
          print('[WebSocket] Watchdog: tenant socket kopuk, yeniden baglaniliyor');
          _connect();
        }
        if (_apiKey != null && (_panelSocket == null || _panelSocket!.connected != true)) {
          print('[PanelSocket] Watchdog: panel socket kopuk, yeniden baglaniliyor');
          connectPanelSocket(_apiKey!);
        }
      } catch (e) {
        print('[WebSocket] Watchdog hata: $e');
      } finally {
        _isReconnecting = false;
      }
    });
  }

  void _connect() {
    if (_serverUrl == null) return;

    // 11 Haz 2026: SOCKET LEAK FIX. Eski socket dispose EDİLMEDEN yenisi açılınca
    // (lisans hatası / 12sa offline / "Tekrar Dene" → InitialSyncScreen tekrar açılıp
    // connect() yeniden çağrılınca) eski socket + 6 event handler asılı kalıyordu.
    // Asılı socket'ler reconnect timer çalıştırmaya devam (CPU) + aynı event N kez
    // işleniyor (N kez ses/yazdırma → ÇİFT FİŞ). Uzun açık kalınca birikip donduruyordu.
    // connectPanelSocket'teki (satır ~261) mevcut pattern'in AYNISI — eskiyi kapat.
    try {
      // 12 Haz 2026: Manager-level listener'ı da temizle (reconnect_failed
      // Manager'a bağlanır, clearListeners sadece Socket'inkileri siler)
      _socket?.io.off('reconnect_failed');
      _socket?.clearListeners();
      _socket?.disconnect();
      _socket?.dispose();
    } catch (_) {}
    _socket = null;

    try {
      print('[WebSocket] Connecting to: $_serverUrl');

      final isPosApiKey = _authToken != null && _authToken!.startsWith('SR_');
      _socket = IO.io(_serverUrl!, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionDelay': 5000,
        'reconnectionAttempts': 10,
        if (_authToken != null)
          'auth': isPosApiKey
              ? {'api_key': _authToken}
              : {'token': _authToken},
      });

      _socket!.onConnect((_) {
        print('[WebSocket] Connected successfully');
        _isConnected = true;
        onConnectionChange?.call(true);
        _logService.info(LogType.general, 'WebSocket baglantisi kuruldu', details: {'server': _serverUrl});

        // Join as POS client with auth
        _socket!.emit('pos_join', {
          'device': 'syncresto_pos',
          if (_authToken != null) 'token': _authToken,
        });
      });

      _socket!.onDisconnect((_) {
        print('[WebSocket] Disconnected');
        _isConnected = false;
        onConnectionChange?.call(false);
        _logService.warning(LogType.general, 'WebSocket baglantisi kesildi');
      });

      _socket!.onConnectError((error) {
        print('[WebSocket] Connect error: $error');
        _isConnected = false;
        onConnectionChange?.call(false);
        _logService.error(LogType.error, 'WebSocket baglanti hatasi', details: {'error': error.toString()});
      });

      _socket!.onError((error) {
        print('[WebSocket] Error: $error');
        _logService.error(LogType.error, 'WebSocket hatasi', details: {'error': error.toString()});
      });

      // Listen for new orders
      _socket!.on('new_web_order', (data) {
        print('[WebSocket] New order received');
        if (data != null && data['order'] != null) {
          final order = Map<String, dynamic>.from(data['order']);
          _logService.logAction('Yeni web siparisi alindi', details: {
            'order_number': order['order_number'],
            'customer_name': order['customer_name'],
          });
          onNewOrder?.call(order);
        }
      });

      // Listen for order updates
      _socket!.on('order_update', (data) {
        print('[WebSocket] Order update received');
        if (data != null && data['order'] != null) {
          final order = Map<String, dynamic>.from(data['order']);
          _logService.logAction('Siparis guncellendi (websocket)', details: {
            'order_number': order['order_number'],
            'status': order['status'],
          });
          onOrderUpdate?.call(order);
        }
      });

      // Listen for print requests from web admin
      _socket!.on('print_order', (data) {
        print('[WebSocket] Print request received');
        if (data != null && data['order'] != null) {
          final order = Map<String, dynamic>.from(data['order']);

          // 14 Haz 2026 — CLAIM-FIRST tek-basim fix:
          // print_order panel-room TUM socket'lere broadcast olur. Eski sistemde
          // burada hemen print_ack emit ediliyordu (status='delivered'). Ama
          // claimPrintJob da AYNI 'delivered' set'ini WHERE status IN(emitted,timeout)
          // ile yapiyor → erken print_ack job'u 'delivered' yapinca tum socket'lerin
          // claim'i 409 doner → HIC-FIS. Cozum: print_ack EMIT'INI KALDIR. Claim
          // (main.dart onPrintRequest) zaten 'delivered' set ediyor. job_id'yi
          // order'a tasi → onPrintRequest claim ve telemetri icin kullanir.
          final jobId = data['job_id'];
          if (jobId != null) {
            order['_job_id'] = jobId;
          }

          // Settings varsa order'a ekle
          if (data['settings'] != null) {
            order['_settings'] = Map<String, dynamic>.from(data['settings']);
          }
          // Printer bilgisi varsa ekle (online sipariş yönlendirmesi için)
          if (data['printer'] != null) {
            order['_printer'] = Map<String, dynamic>.from(data['printer']);
          }
          // Print type ekle (kitchen_print veya cashier_print)
          if (data['type'] != null) {
            order['_print_type'] = data['type'];
          }
          _logService.logAction('Yazdirma istegi alindi (websocket)', details: {
            'order_number': order['order_number'],
            'print_type': data['type'],
            'printer_name': data['printer']?['name'],
            if (jobId != null) 'job_id': jobId,
          });
          onPrintRequest?.call(order);
        }
      });

      // Pong for keep-alive
      _socket!.on('pong', (_) {
        // Keep-alive response
      });

      // Cache invalidate — backend admin paneli ile bir entity degisince emit eder
      // Payload: { types: ['products', 'printers'] } veya { type: 'products' }
      _socket!.on('cache:invalidate', (data) {
        try {
          List<String> types = [];
          if (data is Map) {
            if (data['types'] is List) {
              types = List<String>.from((data['types'] as List).map((e) => e.toString()));
            } else if (data['type'] is String) {
              types = [data['type'] as String];
            }
          }
          if (types.isNotEmpty) {
            print('[WebSocket] cache:invalidate -> $types');
            onCacheInvalidate?.call(types);
            // 21 Tem 2026 fan-out — kopya liste (iterasyon sirasinda remove guvenli);
            // bir listener'in exception'i digerlerini ve global slotu OLDURMEZ.
            for (final l in List<void Function(List<String>)>.from(_cacheInvalidateListeners)) {
              try { l(types); } catch (e) { print('[WebSocket] cacheInvalidate listener hata: $e'); }
            }
            _logService.info(LogType.sync, 'Cache invalidate alindi', details: {'types': types});
          }
        } catch (e) {
          print('[WebSocket] cache:invalidate hata: $e');
        }
      });

      // 12 Haz 2026: Web POS print job hint — payload önemsiz, sadece tetik.
      // Yazdırma kararı/yetkisi burada DEĞİL; WebposPrintService poll + claim yapar.
      _socket!.on('webpos_jobs_hint', (_) {
        onWebposJobsHint?.call();
      });

      // 12 Haz 2026: KALICI ÖLÜM FİX — reconnectionAttempts (10) tükenince
      // Manager 'reconnect_failed' emit eder ve bir daha ASLA denemez.
      // 30sn sonra temiz _connect() ile sıfırdan dene (dispose pattern'i güvenli).
      _socket!.io.on('reconnect_failed', (_) {
        print('[WebSocket] reconnect_failed — 30sn sonra yeniden denenecek');
        _logService.error(LogType.error, 'WebSocket reconnect_failed, 30sn sonra tekrar denenecek');
        _reconnectFailedTimer?.cancel();
        _reconnectFailedTimer = Timer(const Duration(seconds: 30), () {
          if (_socket == null || _socket!.connected != true) {
            _connect();
          }
        });
      });

    } catch (e) {
      print('[WebSocket] Connection error: $e');
      _isConnected = false;
      onConnectionChange?.call(false);
      _logService.error(LogType.error, 'WebSocket baglanti hatasi', error: e);
    }
  }

  /// Tells the server: "the print job ran on the printer and bytes were sent."
  /// Server flips status to 'printed'. Safe no-op when offline or no job_id.
  void emitPrintDone(dynamic jobId) {
    if (jobId == null) return;
    try {
      _socket?.emit('print_done', {'job_id': jobId});
    } catch (e) {
      print('[WebSocket] emitPrintDone failed: $e');
    }
  }

  /// Tells the server the print attempt failed with the given reason.
  /// Server flips status to 'failed' and stores the error.
  void emitPrintFailed(dynamic jobId, String error) {
    if (jobId == null) return;
    try {
      _socket?.emit('print_failed', {'job_id': jobId, 'error': error});
    } catch (e) {
      print('[WebSocket] emitPrintFailed failed: $e');
    }
  }

  /// Reports printer reachability to the server (60s heartbeat).
  /// Server updates panel_pos_printers.last_seen_at/last_status/last_error.
  void emitPrinterHealth(int printerId, String status, {String? error}) {
    try {
      final body = <String, dynamic>{
        'printer_id': printerId,
        'status': status,
      };
      if (error != null) body['error'] = error;
      _socket?.emit('printer_health', body);
    } catch (e) {
      print('[WebSocket] emitPrinterHealth failed: $e');
    }
  }

  void disconnect() {
    // 12 Haz 2026: bilinçli kapanışta reconnect timer'ları da durdur
    // (watchdog/reconnect_failed bağlantıyı geri açmasın)
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _reconnectFailedTimer?.cancel();
    _reconnectFailedTimer = null;
    _panelReconnectFailedTimer?.cancel();
    _panelReconnectFailedTimer = null;
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    onConnectionChange?.call(false);
    // 16 May 2026: panel socket'i de kapat
    try {
      _panelSocket?.disconnect();
      _panelSocket?.dispose();
      _panelSocket = null;
    } catch (_) {}
  }

  void dispose() {
    disconnect();
  }

  // ============================================================
  // 16 May 2026 — PANEL.SYNCRESTO.COM EK SOCKET (kitchen_print için)
  // Mevcut tenant WS bağlantısı bozulmaz, paralel 2. bağlantı kurulur.
  // SR_xxx API key ile authentication.
  // ============================================================
  /// Panel.syncresto.com socket'ine bağlan (sadece kitchen_print event'i için)
  /// API key SR_xxxxxxxx_xxx... — POS storage'dan alınır.
  void connectPanelSocket(String apiKey) {
    if (apiKey.isEmpty || !apiKey.startsWith('SR_')) {
      print('[PanelSocket] Geçersiz API key, bağlanılmadı');
      return;
    }
    _apiKey = apiKey;
    // Eski bağlantıyı kapat (11 Haz 2026: clearListeners eklendi — handler leak'i tam kapat)
    try {
      // 12 Haz 2026: Manager-level listener'ı da temizle (reconnect_failed
      // Manager'a bağlanır, clearListeners sadece Socket'inkileri siler)
      _panelSocket?.io.off('reconnect_failed');
      _panelSocket?.clearListeners();
      _panelSocket?.disconnect();
      _panelSocket?.dispose();
    } catch (_) {}
    _panelSocket = null;

    const panelUrl = 'https://panel.syncresto.com';
    try {
      print('[PanelSocket] Connecting to: $panelUrl');
      _panelSocket = IO.io(panelUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionDelay': 5000,
        'reconnectionAttempts': 20,
        'auth': {'api_key': apiKey},
      });

      _panelSocket!.onConnect((_) {
        print('[PanelSocket] Connected: ${_panelSocket?.id}');
        _logService.info(LogType.general, 'Panel socket baglantisi kuruldu');
      });

      _panelSocket!.onDisconnect((_) {
        print('[PanelSocket] Disconnected');
      });

      _panelSocket!.onConnectError((error) {
        print('[PanelSocket] Connect error: $error');
      });

      // 12 Haz 2026: KALICI ÖLÜM FİX — reconnectionAttempts (20) tükenince
      // panel socket de bir daha denemez; 30sn sonra temiz yeniden bağlan.
      _panelSocket!.io.on('reconnect_failed', (_) {
        print('[PanelSocket] reconnect_failed — 30sn sonra yeniden denenecek');
        _panelReconnectFailedTimer?.cancel();
        _panelReconnectFailedTimer = Timer(const Duration(seconds: 30), () {
          if (_apiKey != null && (_panelSocket == null || _panelSocket!.connected != true)) {
            connectPanelSocket(_apiKey!);
          }
        });
      });

      // KITCHEN PRINT — başka POS'tan gelen mutfak fişi
      _panelSocket!.on('kitchen_print', (data) {
        print('[PanelSocket] kitchen_print received');
        if (data == null) return;
        try {
          final payload = Map<String, dynamic>.from(data as Map);
          // Çift baskı önleme: kendi socketsiz değilse skip
          final srcId = payload['source_socket_id']?.toString();
          if (srcId != null && srcId == _panelSocket?.id) {
            print('[PanelSocket] kitchen_print own emit, skip');
            return;
          }
          _logService.logAction('Mutfak fisi broadcast alindi', details: {
            'ticket_id': payload['ticket_id'],
            'ticket_number': payload['ticket_number'],
            'source': srcId,
          });
          onKitchenPrint?.call(payload);
        } catch (e) {
          print('[PanelSocket] kitchen_print parse error: $e');
        }
      });

      // 12 Haz 2026: Web POS print job hint — internal-print-emit.js:101
      // io.to('panel-' + panelId) PANEL sunucusundan emit eder ve Flutter o
      // room'a BU socket ile join olur (panel-server.js:339). Tenant _socket'e
      // bu event gelmez; asil alici burasi. Yetki tasimaz, sadece poll tetigi
      // (tek-basim garantisi DB atomic claim'de — cift dinleme risksiz).
      _panelSocket!.on('webpos_jobs_hint', (_) {
        onWebposJobsHint?.call();
      });
    } catch (e) {
      print('[PanelSocket] connect exception: $e');
    }
  }

  /// Outgoing request'lere panel socket id'sini koyar (X-Socket-Id header)
  /// Böylece backend broadcast'inde "source_socket_id" set edilir,
  /// kendi POS'umuza geri gelen event skip edilir.
  String? get panelSocketId => _panelSocket?.id;
  bool get isPanelConnected => _panelSocket?.connected == true;
}
