import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'services/storage_service.dart';
import 'services/api_service.dart';
import 'services/printer_service.dart';
import 'services/sound_service.dart';
import 'services/websocket_service.dart';
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

  // Offline servisleri baslat
  await apiService.initOfflineServices();

  // Yazici ayarlarini yukle
  await printerService.loadSettings();

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

  // Web panelden yazdırma isteği gelince
  webSocketService.onPrintRequest = (order) {
    print('[Main] Yazdirma istegi alindi: ${order['order_number']}');
    soundService.playNewOrderSound();
    if (printerService.isConfigured) {
      printerService.printOrderReceipt(order, 'WEB SIPARIS');
    }
  };

  runApp(GreenChefPosApp(
    storageService: storageService,
    apiService: apiService,
    printerService: printerService,
    soundService: soundService,
    webSocketService: webSocketService,
  ));
}

class GreenChefPosApp extends StatelessWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final SoundService soundService;
  final WebSocketService webSocketService;

  const GreenChefPosApp({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.soundService,
    required this.webSocketService,
  });

  @override
  Widget build(BuildContext context) {
    // Check if API key exists
    final hasApiKey = storageService.getApiKey() != null;

    return MaterialApp(
      title: 'GreenChef POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16A34A),
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
  }
}
