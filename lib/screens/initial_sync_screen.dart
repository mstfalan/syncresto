import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/sync_service.dart';
import '../services/connectivity_service.dart';
import 'pin_login_screen.dart';

class InitialSyncScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;

  const InitialSyncScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
  });

  @override
  State<InitialSyncScreen> createState() => _InitialSyncScreenState();
}

class _InitialSyncScreenState extends State<InitialSyncScreen> {
  final SyncService _syncService = SyncService();
  final ConnectivityService _connectivity = ConnectivityService();

  String _statusMessage = 'Kontrol ediliyor...';
  double _progress = 0;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkAndSync();
  }

  Future<void> _checkAndSync() async {
    try {
      // Cache dolu mu kontrol et
      final cacheReady = await _syncService.isCacheReady();

      if (cacheReady) {
        // Cache dolu
        setState(() {
          _statusMessage = 'Veriler kontrol ediliyor...';
          _progress = 0.5;
        });

        // Online ise arka planda güncelleme yap
        if (_connectivity.isOnline) {
          setState(() {
            _statusMessage = 'Guncellemeler kontrol ediliyor...';
            _progress = 0.7;
          });

          // Arka planda güncelle (beklemeden)
          _syncService.backgroundCacheUpdate();
        }

        setState(() {
          _statusMessage = 'Hazir!';
          _progress = 1.0;
        });

        // WebSocket bağlantısını başlat
        _connectWebSocket();

        await Future.delayed(const Duration(milliseconds: 300));
        _navigateToLogin();
        return;
      }

      // Cache bos - internet var mi?
      if (!_connectivity.isOnline) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Ilk kullanim icin internet baglantisi gerekli.\n\nLutfen internete baglanin ve tekrar deneyin.';
        });
        return;
      }

      // Internet var, sync baslat
      setState(() {
        _statusMessage = 'Veriler indiriliyor...';
        _progress = 0.1;
      });

      // Progress callback
      _syncService.onSyncProgress = (message, progress) {
        if (mounted) {
          setState(() {
            _statusMessage = message;
            _progress = progress;
          });
        }
      };

      // Sync baslat
      await _syncService.performInitialSync();

      // Basarili
      setState(() {
        _statusMessage = 'Tamamlandi!';
        _progress = 1.0;
      });

      // WebSocket bağlantısını başlat
      _connectWebSocket();

      await Future.delayed(const Duration(milliseconds: 500));
      _navigateToLogin();

    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = 'Veri indirme hatasi:\n$e\n\nLutfen tekrar deneyin.';
      });
    }
  }

  void _connectWebSocket() {
    // WebSocket bağlantısını başlat
    widget.webSocketService.connect('https://greenchef.com.tr/api');
  }

  void _navigateToLogin() {
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PinLoginScreen(
          storageService: widget.storageService,
          apiService: widget.apiService,
          printerService: widget.printerService,
          webSocketService: widget.webSocketService,
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _errorMessage = null;
      _progress = 0;
      _statusMessage = 'Kontrol ediliyor...';
    });
    _checkAndSync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF16A34A), Color(0xFF15803D)],
          ),
        ),
        child: Center(
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.restaurant,
                    size: 56,
                    color: Color(0xFF16A34A),
                  ),
                ),
                const SizedBox(height: 24),

                // Title
                const Text(
                  'GreenChef POS',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Offline Calisma Icin Hazirlaniyor',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 32),

                // Error state
                if (_hasError) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_off, color: Color(0xFFDC2626), size: 48),
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage ?? 'Bir hata olustu',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tekrar Dene'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  // Progress
                  Column(
                    children: [
                      Text(
                        _statusMessage,
                        style: const TextStyle(
                          color: Color(0xFF1F2937),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 12,
                          backgroundColor: Colors.grey[200],
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF16A34A)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_progress * 100).toInt()}%',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 24),

                // Info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue[700], size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Menu, urunler ve gorseller indiriliyor.\nBu islem bir kez yapilir.',
                          style: TextStyle(
                            color: Colors.blue[700],
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
