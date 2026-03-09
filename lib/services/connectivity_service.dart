import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  Stream<bool> get connectionStream => _connectionController.stream;

  Future<void> init() async {
    // İlk durumu kontrol et
    final result = await _connectivity.checkConnectivity();
    _updateConnectionStatus(result);

    // Değişiklikleri dinle
    _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final wasOnline = _isOnline;

    // Herhangi bir bağlantı varsa online say
    _isOnline = results.any((r) =>
      r == ConnectivityResult.wifi ||
      r == ConnectivityResult.ethernet ||
      r == ConnectivityResult.mobile
    );

    // Durum değiştiyse bildir
    if (wasOnline != _isOnline) {
      _connectionController.add(_isOnline);
      print('[Connectivity] Status changed: ${_isOnline ? "ONLINE" : "OFFLINE"}');
    }
  }

  Future<bool> checkConnection() async {
    final result = await _connectivity.checkConnectivity();
    _updateConnectionStatus(result);
    return _isOnline;
  }

  void dispose() {
    _connectionController.close();
  }
}
