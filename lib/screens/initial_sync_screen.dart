import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/sync_service.dart';
import '../services/connectivity_service.dart';
import '../services/version_service.dart';
import '../services/log_service.dart';
import '../services/license_service.dart';
import '../providers/theme_provider.dart';
import '../widgets/update_modal.dart';
import 'pin_login_screen.dart';
import 'setup_screen.dart';

// Re-export ApiKeyInvalidException for this file
export '../services/sync_service.dart' show ApiKeyInvalidException;

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
  final VersionService _versionService = VersionService();
  final LogService _logService = LogService();
  final LicenseService _licenseService = LicenseService();

  String _statusMessage = 'Kontrol ediliyor...';
  double _progress = 0;
  bool _hasError = false;
  String? _errorMessage;
  bool _updateCheckDone = false;

  @override
  void initState() {
    super.initState();
    _checkAndSync();
  }

  Future<void> _checkAndSync() async {
    try {
      // Servisleri başlat
      final apiKey = widget.storageService.getApiKey();
      if (apiKey != null) {
        _versionService.init(widget.apiService.dio, apiKey);
        await _logService.init(widget.apiService.dio, apiKey);
        _licenseService.init(widget.apiService.dio, apiKey);
      }

      // Lisans kontrolü
      setState(() {
        _statusMessage = 'Lisans kontrol ediliyor...';
        _progress = 0.02;
      });

      final licenseResult = await _licenseService.checkLicense();

      if (!licenseResult.isValid && !licenseResult.canUseOffline) {
        // Lisans geçersiz ve offline kullanım da mümkün değil
        String errorMsg;
        if (licenseResult.status == LicenseStatus.expired) {
          errorMsg = 'Lisans süresi doldu!\n\nLütfen lisansınızı yenileyiniz.\n\nSon kontrol: ${licenseResult.licenseInfo?.checkedAt.toString().substring(0, 16)}';
        } else if (licenseResult.status == LicenseStatus.inactive) {
          errorMsg = 'Lisans devre dışı!\n\nLütfen SyncResto yöneticinize başvurunuz.';
        } else if (licenseResult.status == LicenseStatus.notFound) {
          errorMsg = 'Lisans bulunamadı!\n\nLütfen internete bağlanın ve tekrar deneyin.';
        } else {
          errorMsg = 'Lisans doğrulanamadı!\n\n${licenseResult.errorMessage ?? 'Bilinmeyen hata'}';
        }

        setState(() {
          _hasError = true;
          _errorMessage = errorMsg;
        });
        return;
      }

      // Lisans uyarısı (yakında sona erecek)
      if (licenseResult.licenseInfo != null &&
          licenseResult.licenseInfo!.daysRemaining > 0 &&
          licenseResult.licenseInfo!.daysRemaining <= 7) {
        _logService.warning(
          LogType.general,
          'Lisans ${licenseResult.licenseInfo!.daysRemaining} gun icinde sona erecek',
        );
      }

      // Versiyon kontrolü (internet varsa)
      if (_connectivity.isOnline && apiKey != null && !_updateCheckDone) {
        setState(() {
          _statusMessage = 'Guncelleme kontrol ediliyor...';
          _progress = 0.05;
        });

        final updateResult = await _versionService.checkForUpdates();
        _updateCheckDone = true;

        if (updateResult.isUpdateRequired || updateResult.isUpdateAvailable) {
          // Güncelleme modal'ını göster
          if (mounted) {
            await UpdateModal.show(
              context,
              updateResult,
              onLater: () {
                // Opsiyonel güncelleme reddedildi, devam et
                _logService.info(
                  LogType.update,
                  'Guncelleme reddedildi: ${updateResult.versionInfo?.currentVersion}',
                );
              },
            );

            // Zorunlu güncelleme ise modal kapanmaz, uygulama güncellenir
            // Opsiyonel güncelleme reddedildiyse devam ediyoruz
            if (updateResult.isUpdateRequired) {
              // Modal açık kalacak, buraya ulaşılmaz
              return;
            }
          }
        }
      }

      // Cache dolu mu kontrol et
      final cacheReady = await _syncService.isCacheReady();

      if (cacheReady) {
        // Cache dolu
        setState(() {
          _statusMessage = 'Veriler kontrol ediliyor...';
          _progress = 0.5;
        });

        // Cache'den tema yükle
        final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
        await themeProvider.loadCachedTheme();

        // Settings callback for theme (arka plan güncellemesi için de gerekli)
        _syncService.onSettingsLoaded = (settings) {
          if (mounted) {
            themeProvider.updateFromSettings(settings);
          }
        };

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

      // Settings callback for theme
      _syncService.onSettingsLoaded = (settings) {
        if (mounted) {
          final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
          themeProvider.updateFromSettings(settings);
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

    } on ApiKeyInvalidException catch (e) {
      // API key geçersiz veya pasif
      setState(() {
        _hasError = true;
        _errorMessage = 'Lisans Hatası\n\n$e\n\nLütfen SyncResto yöneticinize başvurun.';
      });

      // Cache'i temizle
      await _syncService.clearAllCache();
      await _licenseService.clearLicense();
    } catch (e) {
      // Genel hata - ama önce 401/403 kontrol et
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('401') || errorStr.contains('403') || errorStr.contains('unauthorized')) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Lisans Hatası\n\nAPI key geçersiz veya lisans pasif edilmiş.\n\nLütfen SyncResto yöneticinize başvurun.';
        });

        // Cache'i temizle
        await _syncService.clearAllCache();
        await _licenseService.clearLicense();
      } else {
        setState(() {
          _hasError = true;
          _errorMessage = 'Veri indirme hatasi:\n$e\n\nLutfen tekrar deneyin.';
        });
      }
    }
  }

  void _connectWebSocket() {
    // WebSocket için tenant backend URL'ini kullan (Socket.io orada çalışıyor)
    final backendUrl = widget.storageService.getBackendUrl();
    if (backendUrl != null && backendUrl.isNotEmpty) {
      print('[InitialSync] WebSocket tenant backend\'e bağlanıyor: $backendUrl');
      widget.webSocketService.connect(backendUrl);
    } else {
      // Fallback: API URL kullan (eski davranış)
      final apiUrl = widget.storageService.getApiUrl() ?? 'https://api.syncresto.com';
      print('[InitialSync] WebSocket API URL\'e bağlanıyor (fallback): $apiUrl');
      widget.webSocketService.connect(apiUrl);
    }
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

  Future<void> _goToSetup() async {
    // Tüm verileri temizle (SharedPreferences + SQLite cache + License)
    try {
      await widget.storageService.clearAll();
    } catch (e) {
      print('[Setup] Storage temizleme hatası: $e');
    }

    try {
      await _syncService.clearAllCache();
    } catch (e) {
      print('[Setup] Cache temizleme hatası: $e');
    }

    try {
      await _licenseService.clearLicense();
    } catch (e) {
      print('[Setup] License temizleme hatası: $e');
    }

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => SetupScreen(
          storageService: widget.storageService,
          apiService: widget.apiService,
          printerService: widget.printerService,
          webSocketService: widget.webSocketService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: theme.backgroundGradient,
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
                Image.asset(
                  'assets/images/logo.png',
                  width: 200,
                  height: 70,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),

                // Title
                const Text(
                  'SyncResto POS',
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
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _goToSetup,
                      icon: const Icon(Icons.key),
                      label: const Text('Yeni API Key Gir'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey[700],
                        side: BorderSide(color: Colors.grey[400]!),
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
                          valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor),
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
