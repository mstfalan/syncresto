import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'services/storage_service.dart';
import 'services/api_service.dart';
import 'services/printer_service.dart';
import 'services/sound_service.dart';
import 'services/websocket_service.dart';
import 'services/print_queue_service.dart';
import 'providers/theme_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/initial_sync_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop icin SQLite FFI kullan
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final storageService = StorageService();
  await storageService.init();

  final apiService = ApiService();
  final printerService = PrinterService();
  final soundService = SoundService();
  final webSocketService = WebSocketService();

  // Theme provider
  final themeProvider = ThemeProvider();
  await themeProvider.loadCachedTheme();

  final savedApiUrl = storageService.getApiUrl();
  if (savedApiUrl != null) {
    apiService.setBaseUrl(savedApiUrl);
  }
  final savedApiKey = storageService.getApiKey();
  if (savedApiKey != null) {
    apiService.setApiKey(savedApiKey);
  }

  // Backend URL (for images/assets)
  final savedBackendUrl = storageService.getBackendUrl();
  if (savedBackendUrl != null) {
    apiService.setBackendUrl(savedBackendUrl);
  }

  await apiService.initOfflineServices();

  // Yazici ayarlarini yukle
  await printerService.loadSettings();

  // Yazici kuyrugu otomatik retry servisini baslat
  final printQueueService = PrintQueueService();
  printQueueService.startAutoRetry();

  // WebSocket event handler'larini ayarla
  webSocketService.onNewOrder = (order) {
    print('[Main] Yeni siparis alindi: ${order['order_number']}');
    soundService.playNewOrderSound();
    // Otomatik yazdirma ayarli ise yazdir
    if (printerService.isConfigured) {
      printerService.printOrderReceipt(order, 'MUTFAK');
    }
  };

  webSocketService.onConnectionChange = (connected) {
    print('[Main] WebSocket baglantisi: ${connected ? 'Bagli' : 'Bagli degil'}');
  };

  // Web panelden yazdırma isteği gelince (dinamik yazıcı yönlendirmesi)
  webSocketService.onPrintRequest = (order) {
    final printType = order['_print_type'] as String?;
    final printer = order['_printer'] as Map<String, dynamic>?;

    print('[Main] ========== ONLINE SIPARIS YAZDIRMA ==========');
    print('[Main] order_number: ${order['order_number']}');
    print('[Main] printType: $printType');
    print('[Main] printer: $printer');
    print('[Main] ===============================================');

    soundService.playNewOrderSound();

    // Hedef yazıcı bilgisi varsa ona gönder
    if (printer != null && printerService.isConfigured) {
      final department = printType == 'cashier_print' ? 'KASA' : 'MUTFAK';
      print('[Main] Department: $department, yaziciya gonderiliyor...');
      printerService.printOrderReceipt(order, department, targetPrinter: printer);
    } else if (printerService.isConfigured) {
      // Eski davranış: varsayılan yazıcıya gönder
      print('[Main] Varsayilan yaziciya gonderiliyor (printer null veya bos)');
      printerService.printOrderReceipt(order, 'WEB SIPARIS');
    }
  };

  runApp(
    ChangeNotifierProvider.value(
      value: themeProvider,
      child: SyncRestoPosApp(
        storageService: storageService,
        apiService: apiService,
        printerService: printerService,
        soundService: soundService,
        webSocketService: webSocketService,
        themeProvider: themeProvider,
      ),
    ),
  );
}

class SyncRestoPosApp extends StatelessWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final SoundService soundService;
  final WebSocketService webSocketService;
  final ThemeProvider themeProvider;

  const SyncRestoPosApp({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.soundService,
    required this.webSocketService,
    required this.themeProvider,
  });

  @override
  Widget build(BuildContext context) {
    // Check if API key exists
    final hasApiKey = storageService.getApiKey() != null;

    return Consumer<ThemeProvider>(
      builder: (context, theme, child) {
        return MaterialApp(
          title: theme.brandName,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: theme.primaryColor,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
          ),
          home: hasApiKey
              ? InitialSyncScreen(
                  storageService: storageService,
                  apiService: apiService,
                  printerService: printerService,
                  webSocketService: webSocketService,
                )
              : SetupScreen(
                  storageService: storageService,
                  apiService: apiService,
                  printerService: printerService,
                  webSocketService: webSocketService,
                ),
        );
      },
    );
  }
}
