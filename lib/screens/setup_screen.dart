import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
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

  Future<void> _validateAndConnect() async {
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
      final apiUrl = _apiUrlController.text.trim();
      widget.apiService.setBaseUrl(apiUrl);
      final result = await widget.apiService.validateApiKey(apiKey);

      if (result['valid'] == true) {
        await widget.storageService.saveApiUrl(apiUrl);
        await widget.storageService.saveApiKey(apiKey, result['restaurant_name'] ?? 'POS');

        // Save backend URL for images/assets
        if (result['backend_url'] != null) {
          await widget.storageService.saveBackendUrl(result['backend_url']);
          widget.apiService.setBackendUrl(result['backend_url']);
        }

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
        setState(() {
          _errorMessage = result['error'] ?? 'Gecersiz API Key';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Baglanti hatasi: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
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
