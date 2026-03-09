import 'package:socket_io_client/socket_io_client.dart' as IO;

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _serverUrl;

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

        // Join as POS client
        _socket!.emit('pos_join', {'device': 'greenchef_pos'});
      });

      _socket!.onDisconnect((_) {
        print('[WebSocket] Disconnected');
        _isConnected = false;
        onConnectionChange?.call(false);
      });

      _socket!.onConnectError((error) {
        print('[WebSocket] Connect error: $error');
        _isConnected = false;
        onConnectionChange?.call(false);
      });

      _socket!.onError((error) {
        print('[WebSocket] Error: $error');
      });

      // Listen for new orders
      _socket!.on('new_web_order', (data) {
        print('[WebSocket] New order received');
        if (data != null && data['order'] != null) {
          onNewOrder?.call(Map<String, dynamic>.from(data['order']));
        }
      });

      // Listen for order updates
      _socket!.on('order_update', (data) {
        print('[WebSocket] Order update received');
        if (data != null && data['order'] != null) {
          onOrderUpdate?.call(Map<String, dynamic>.from(data['order']));
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
