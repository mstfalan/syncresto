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
  // 16 May 2026: Aynı tenant POS'lar arası kitchen print broadcast
  // payload: { ticket_id, ticket_number, table_number, printer_groups, source_socket_id, ... }
  Function(Map<String, dynamic>)? onKitchenPrint;

  bool get isConnected => _isConnected;
  String? _authToken;

  // 16 May 2026: panel.syncresto.com'a ek 2. socket (sadece kitchen_print için)
  IO.Socket? _panelSocket;
  String? _apiKey;

  Future<void> connect(String serverUrl, {String? token}) async {
    var url = serverUrl.replaceAll('/api', '');
    // HTTP → HTTPS, ws → wss
    if (url.startsWith('http://')) url = url.replaceFirst('http://', 'https://');
    _serverUrl = url;
    _authToken = token;
    _connect();
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

          // Telemetry: server tags each print request with a job_id; immediately
          // ack receipt so the panel sees status='delivered'. Carry the job_id
          // on the order object so PrinterService can emit done/failed later.
          final jobId = data['job_id'];
          if (jobId != null) {
            order['_job_id'] = jobId;
            try {
              _socket?.emit('print_ack', {'job_id': jobId});
            } catch (_) {}
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
            _logService.info(LogType.sync, 'Cache invalidate alindi', details: {'types': types});
          }
        } catch (e) {
          print('[WebSocket] cache:invalidate hata: $e');
        }
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
