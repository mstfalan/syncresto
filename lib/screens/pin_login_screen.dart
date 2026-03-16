import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../providers/theme_provider.dart';
import 'tables_screen.dart';
import 'setup_screen.dart';

class PinLoginScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;

  const PinLoginScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
  });

  @override
  State<PinLoginScreen> createState() => _PinLoginScreenState();
}

class _PinLoginScreenState extends State<PinLoginScreen> {
  String _pin = '';
  bool _isLoading = false;
  String? _errorMessage;

  void _addDigit(String digit) {
    if (_pin.length >= 4) return;

    setState(() {
      _pin += digit;
      _errorMessage = null;
    });

    if (_pin.length == 4) {
      _attemptLogin();
    }
  }

  void _deleteDigit() {
    if (_pin.isEmpty) return;

    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  void _clearPin() {
    setState(() {
      _pin = '';
      _errorMessage = null;
    });
  }

  Future<void> _attemptLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.apiService.waiterLogin(_pin);

      if (result['success'] == true) {
        // Save waiter session (token offline modda null olabilir)
        final token = result['token'] as String?;
        final waiterJson = jsonEncode(result['waiter']);

        if (token != null) {
          await widget.storageService.saveWaiterSession(token, waiterJson);
          widget.apiService.setWaiterToken(token);
        }

        // Log artık api_service.waiterLogin içinde tutuluyor

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => TablesScreen(
                storageService: widget.storageService,
                apiService: widget.apiService,
                printerService: widget.printerService,
                webSocketService: widget.webSocketService,
                waiter: result['waiter'],
              ),
            ),
          );
        }
      } else {
        // Log artık api_service.waiterLogin içinde tutuluyor
        setState(() {
          _errorMessage = result['error'] ?? 'Gecersiz PIN';
          _pin = '';
        });
      }
    } catch (e) {
      // Log artık api_service.waiterLogin içinde tutuluyor
      setState(() {
        _errorMessage = 'Giris hatasi';
        _pin = '';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _changeApiKey() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('API Key Degistir'),
        content: const Text('Mevcut API key silinecek. Devam etmek istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () async {
              await widget.storageService.clearApiKey();
              if (mounted) {
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
            },
            child: const Text('Degistir', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyName = widget.storageService.getApiKeyName() ?? 'POS';
    final theme = Provider.of<ThemeProvider>(context);

    return Scaffold(
      body: RawKeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
              _addDigit('0');
            } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
              _addDigit('1');
            } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
              _addDigit('2');
            } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
              _addDigit('3');
            } else if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
              _addDigit('4');
            } else if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
              _addDigit('5');
            } else if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
              _addDigit('6');
            } else if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
              _addDigit('7');
            } else if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
              _addDigit('8');
            } else if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
              _addDigit('9');
            } else if (key == LogicalKeyboardKey.backspace) {
              _deleteDigit();
            } else if (key == LogicalKeyboardKey.escape) {
              _clearPin();
            }
          }
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: theme.backgroundGradient,
          ),
          child: Center(
            child: SingleChildScrollView(
              child: Container(
                width: 360,
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
                    'Garson Girisi',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '4 Haneli PIN Kodunuzu Giriniz',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Error message
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
                          const SizedBox(width: 8),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(color: Color(0xFFDC2626), fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // PIN dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (index) {
                      final filled = index < _pin.length;
                      return Container(
                        width: 50,
                        height: 50,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: filled ? theme.primaryColor : const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: filled ? theme.primaryColor : const Color(0xFFE5E7EB),
                            width: 2,
                          ),
                        ),
                        child: Center(
                          child: filled
                              ? const Icon(Icons.circle, color: Colors.white, size: 16)
                              : null,
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),

                  // Numpad
                  if (_isLoading)
                    CircularProgressIndicator(color: theme.primaryColor)
                  else
                    _buildNumpad(),

                  const SizedBox(height: 24),

                  // Connection info
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle, color: theme.primaryColor, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          keyName,
                          style: TextStyle(
                            color: theme.primaryColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Change API Key button
                  TextButton(
                    onPressed: _changeApiKey,
                    child: const Text(
                      'API Key Degistir',
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNumpad() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('1'),
            _buildNumButton('2'),
            _buildNumButton('3'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('4'),
            _buildNumButton('5'),
            _buildNumButton('6'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumButton('7'),
            _buildNumButton('8'),
            _buildNumButton('9'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildActionButton('C', Colors.orange, _clearPin),
            _buildNumButton('0'),
            _buildActionButton(null, Colors.red, _deleteDigit, icon: Icons.backspace),
          ],
        ),
      ],
    );
  }

  Widget _buildNumButton(String digit) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: 70,
        height: 56,
        child: ElevatedButton(
          onPressed: () => _addDigit(digit),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF3F4F6),
            foregroundColor: const Color(0xFF1F2937),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            digit,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(String? label, Color color, VoidCallback onPressed, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        width: 70,
        height: 56,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withOpacity(0.1),
            foregroundColor: color,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: icon != null
              ? Icon(icon, size: 24)
              : Text(
                  label!,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}
