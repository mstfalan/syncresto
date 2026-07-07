import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/license_service.dart';
import '../services/local_db_service.dart';
import '../services/image_cache_service.dart';
import '../providers/theme_provider.dart';
import 'pin_login_screen.dart';

class SetupScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;

  const SetupScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _apiKeyController = TextEditingController();
  final _apiUrlController = TextEditingController(text: 'https://api.syncresto.com');
  bool _isLoading = false;
  String? _errorMessage;
  bool _showAdvanced = false;

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _validateAndConnect({bool force = false}) async {
    final apiKey = _apiKeyController.text.trim();

    if (apiKey.isEmpty) {
      setState(() => _errorMessage = 'API Key giriniz');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      var apiUrl = _apiUrlController.text.trim();
      if (apiUrl.startsWith('http://')) {
        apiUrl = apiUrl.replaceFirst('http://', 'https://');
      }
      if (!apiUrl.startsWith('https://')) {
        apiUrl = 'https://$apiUrl';
      }
      widget.apiService.setBaseUrl(apiUrl);
      final result = await widget.apiService.validateApiKey(apiKey, force: force);

      if (result['valid'] == true) {
        // Yeni API key kaydedilmeden ÖNCE eski lisans cache'ini temizle
        // (aksi halde eski "inactive" cache "Lisans devre dışı" gösterebilir)
        try {
          final licSvc = LicenseService();
          await licSvc.clearLicense();
        } catch (_) {}

        // MULTI-TENANT guvenlik (7 Tem 2026): tenant degisimini KEY HASH'i ile tespit et
        // (setup ekranina gelmeden once key silinmis olabilir -> eski previousKey==null ile
        // wipe ATLANIYORDU = eski bayinin cache/adisyon/sync_queue'su yeni tenant'a sizardi).
        // Hash clear'larda silinmez; hangi yoldan gelinirse gelinsin degisim yakalanir.
        final prevHash = widget.storageService.getTenantHash();
        final newHash = widget.storageService.hashKey(apiKey);
        if (prevHash != null && prevHash != newHash) {
          print('[Setup] Tenant degisti (hash farkli) -> eski bayinin TUM verisi temizleniyor');
          try { await LocalDbService().clearAllTenantData(); } catch (e) { print('[Setup] SQLite temizleme hatasi: $e'); }
          try { await ImageCacheService().clearCache(); } catch (e) { print('[Setup] Gorsel cache temizleme hatasi: $e'); }
          try { await widget.storageService.clearWaiterSession(); } catch (_) {}
          try {
            final tp = Provider.of<ThemeProvider>(context, listen: false);
            tp.resetToDefaults();
            await tp.clearThemePrefs();
          } catch (e) { print('[Setup] Tema temizleme hatasi: $e'); }
        }

        await widget.storageService.saveApiUrl(apiUrl);
        await widget.storageService.saveApiKey(apiKey, result['restaurant_name'] ?? 'POS');

        // Save backend URL for images/assets
        // image_base_url: backend_url varsa onu, yoksa panel.syncresto.com'u kullan
        final imageBaseUrl = result['image_base_url'] ?? result['backend_url'];
        if (imageBaseUrl != null) {
          await widget.storageService.saveBackendUrl(imageBaseUrl);
          widget.apiService.setBackendUrl(imageBaseUrl);
        }

        // Yeni firmanin temasini (renk/logo/marka) HEMEN yukle -> login ekrani ESKI firma temasiyla
        // acilmasin (settings validate-key'de gelmiyor, ayri /pos/settings cagrisi gerekiyor).
        try {
          final settings = await widget.apiService.getSettings();
          if (mounted) {
            Provider.of<ThemeProvider>(context, listen: false).updateFromSettings(settings);
          }
        } catch (e) { print('[Setup] Tema on-yukleme atlandi: $e'); }

        if (mounted) {
          // Navigate to PIN login
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
      } else {
        if (result['error'] == 'DEVICE_CONFLICT' && result['can_force'] == true && !force) {
          if (mounted) setState(() => _isLoading = false);
          final accept = await _showDeviceConflictDialog(result['existing_device']?.toString() ?? 'Bilinmeyen Cihaz');
          if (accept == true) {
            await _validateAndConnect(force: true);
            return;
          } else {
            setState(() => _errorMessage = 'Iptal edildi. API key hala diger cihazda aktif.');
            return;
          }
        }
        setState(() {
          if (result['error'] == 'DEVICE_CONFLICT') {
            _errorMessage = 'Bu API key baska bir cihazda kullanilmaktadir: ${result['existing_device'] ?? 'Bilinmeyen Cihaz'}.';
          } else {
            // 19 May 2026: detail varsa onu goster (root cause analizi)
            final err = result['error']?.toString() ?? 'Gecersiz API Key';
            final detail = result['detail']?.toString();
            _errorMessage = (detail != null && detail.isNotEmpty && detail != err)
                ? '$err\n\n[Detay] $detail'
                : err;
          }
        });
      }
    } catch (e, st) {
      setState(() {
        _errorMessage = 'Beklenmeyen hata: ${e.runtimeType}: $e\n\n${st.toString().split("\n").take(3).join("\n")}';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<bool?> _showDeviceConflictDialog(String existingDeviceName) async {
    if (!mounted) return false;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('API Key Baska Cihazda'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bu API key su anda baska bir cihazda kullaniliyor:',
              style: TextStyle(color: Colors.grey[700]),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.devices, color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      existingDeviceName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Diger cihazdan otomatik cikis yapilarak bu cihazda devam edilsin mi?',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'Not: Diger cihazda tekrar API key girilmesi gerekecek.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600], fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgec'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange[700],
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Burada Kullan'),
          ),
        ],
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
                  color: Colors.black.withOpacity(0.2),
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
                  width: 180,
                  height: 60,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),

                // Title
                const Text(
                  'SyncResto POS',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Baslangic Kurulumu',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 32),

                // Error message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Color(0xFFDC2626), fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // API Key input
                TextField(
                  controller: _apiKeyController,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'Admin panelden alinan API key',
                    prefixIcon: const Icon(Icons.key),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                  ),
                  enabled: !_isLoading,
                  onSubmitted: (_) => _validateAndConnect(),
                ),
                const SizedBox(height: 16),

                // Advanced options toggle
                TextButton(
                  onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showAdvanced ? Icons.expand_less : Icons.expand_more,
                        color: const Color(0xFF6B7280),
                        size: 20,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Gelismis Ayarlar',
                        style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      ),
                    ],
                  ),
                ),

                if (_showAdvanced) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiUrlController,
                    decoration: InputDecoration(
                      labelText: 'API URL',
                      hintText: 'https://api.syncresto.com',
                      prefixIcon: const Icon(Icons.cloud),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF9FAFB),
                    ),
                    enabled: !_isLoading,
                  ),
                ],
                const SizedBox(height: 24),

                // Connect button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _validateAndConnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Baglan',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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
