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

  bool get isConnected => _isConnected;

  Future<void> connect(String serverUrl) async {
    _serverUrl = serverUrl.replaceAll('/api', '');
    _connect();
  }

  void _connect() {
    if (_serverUrl == null) return;

    try {
      print('[WebSocket] Connecting to: $_serverUrl');

      _socket = IO.io(_serverUrl!, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionDelay': 5000,
        'reconnectionAttempts': 10,
      });

      _socket!.onConnect((_) {
        print('[WebSocket] Connected successfully');
        _isConnected = true;
        onConnectionChange?.call(true);
        _logService.info(LogType.general, 'WebSocket baglantisi kuruldu', details: {'server': _serverUrl});

        // Join as POS client
        _socket!.emit('pos_join', {'device': 'syncresto_pos'});
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
          // Settings varsa order'a ekle
          if (data['settings'] != null) {
            order['_settings'] = Map<String, dynamic>.from(data['settings']);
          }
          _logService.logAction('Yazdirma istegi alindi (websocket)', details: {
            'order_number': order['order_number'],
          });
          onPrintRequest?.call(order);
        }
      });

      // Pong for keep-alive
      _socket!.on('pong', (_) {
        // Keep-alive response
      });

    } catch (e) {
      print('[WebSocket] Connection error: $e');
      _isConnected = false;
      onConnectionChange?.call(false);
      _logService.error(LogType.error, 'WebSocket baglanti hatasi', error: e);
    }
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    onConnectionChange?.call(false);
  }

  void dispose() {
    disconnect();
  }
}
