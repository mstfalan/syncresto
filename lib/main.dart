import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
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

  Timer? printerHealthTimer;
  Future<void> runPrinterHealthCheck() async {
    try {
      final results = await printerService.probeAllPrintersHealth();
      for (final r in results) {
        final id = r['id'];
        if (id is! int) continue;
        final status = (r['status'] as String?) ?? 'unknown';
        final error = r['error'] as String?;

        // 1) WebSocket emit (eski sistem — transient bildirim)
        webSocketService.emitPrinterHealth(id, status, error: error);

        // 2) REST heartbeat → panel_pos_printers.last_seen_at/last_status/last_error
        //    Admin UI "Yazici Sagligi" tablosunda bu veri okunuyor.
        apiService.printerHeartbeat(printerId: id, status: status, error: error);
      }
    } catch (e) {
      print('[Main] Printer health check error: $e');
    }
  }

  webSocketService.onConnectionChange = (connected) {
    print('[Main] WebSocket baglantisi: ${connected ? 'Bagli' : 'Bagli degil'}');
    if (connected) {
      // First check immediately, then every 60s
      runPrinterHealthCheck();
      printerHealthTimer?.cancel();
      printerHealthTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => runPrinterHealthCheck(),
      );
    } else {
      printerHealthTimer?.cancel();
      printerHealthTimer = null;
    }
  };

  // Web panelden yazdırma isteği gelince (dinamik yazıcı yönlendirmesi)
  webSocketService.onPrintRequest = (order) async {
    final printType = order['_print_type'] as String?;
    final printer = order['_printer'] as Map<String, dynamic>?;
    final jobId = order['_job_id'];

    print('[Main] ========== ONLINE SIPARIS YAZDIRMA ==========');
    print('[Main] order_number: ${order['order_number']}');
    print('[Main] printType: $printType');
    print('[Main] printer: $printer');
    print('[Main] job_id: $jobId');
    print('[Main] ===============================================');

    soundService.playNewOrderSound();

    bool printed = false;
    String? errorMsg;
    try {
      if (printer != null && printerService.isConfigured) {
        final department = printType == 'cashier_print' ? 'KASA' : 'MUTFAK';
        print('[Main] Department: $department, yaziciya gonderiliyor...');
        printed = await printerService.printOrderReceipt(order, department, targetPrinter: printer);
      } else if (printerService.isConfigured) {
        print('[Main] Varsayilan yaziciya gonderiliyor (printer null veya bos)');
        printed = await printerService.printOrderReceipt(order, 'WEB SIPARIS');
      } else {
        errorMsg = 'POS uygulamasinda yazici ayarlanmamis';
      }
    } catch (e) {
      errorMsg = e.toString();
      print('[Main] Yazdirma istisnasi: $e');
    }

    // Telemetry: only emit when we have a job_id from server
    if (jobId != null) {
      if (printed) {
        webSocketService.emitPrintDone(jobId);
      } else {
        webSocketService.emitPrintFailed(jobId, errorMsg ?? 'Yazici cevap vermedi');
      }
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
    return Consumer<ThemeProvider>(
      builder: (context, theme, child) {
        return MaterialApp(
          title: theme.brandName,
          debugShowCheckedModeBanner: false,
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.unknown,
            },
          ),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: theme.primaryColor,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
            splashFactory: NoSplash.splashFactory,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
          home: storageService.getApiKey() != null
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
