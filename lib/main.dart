import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'services/storage_service.dart';
import 'services/api_service.dart';
import 'services/printer_service.dart';
import 'services/sound_service.dart';
import 'services/websocket_service.dart';
import 'services/webpos_print_service.dart';
import 'services/print_queue_service.dart';
import 'services/sync_service.dart';
// 1 Haz 2026 (v1.5.6): Boot audit servisleri (donma fix)
import 'services/image_cache_service.dart';
import 'services/local_db_service.dart';
import 'services/version_service.dart';
import 'providers/theme_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/initial_sync_screen.dart';

/// 19 May 2026 — IPv4-only + Mozilla CA bundle HttpOverrides
///
/// Iki problemi birden cozer:
/// 1. IPv4-only DNS lookup — IPv6 lookup OK + connect timeout sorunu
///    (CF IPv6 routing'i olmayan TT ADSL'lerinde 15sn beklemeden direkt IPv4)
/// 2. CERTIFICATE_VERIFY_FAILED — Dart boringssl Windows certificate store'una
///    erismez, kendi root CA listesi yok. Cloudflare/Let's Encrypt cert'lerini
///    dogrulayamiyor → HandshakeException. Cozum: Mozilla CA bundle'i asset
///    olarak ekle + SecurityContext'e yukle.
///
/// Tum HttpClient'lara (Dio, http, socket_io_client) otomatik yansir.
class _SyncRestoHttpOverrides extends HttpOverrides {
  SecurityContext? _ctx;

  Future<void> loadCaBundle() async {
    try {
      final bytes = await rootBundle.load('assets/certs/cacert.pem');
      _ctx = SecurityContext(withTrustedRoots: true);
      _ctx!.setTrustedCertificatesBytes(bytes.buffer.asUint8List());
      if (kDebugMode) print('[CA] Mozilla CA bundle yuklendi (${bytes.lengthInBytes} byte)');
    } catch (e) {
      if (kDebugMode) print('[CA] CA bundle yukleme HATA: $e — fallback default trust');
      _ctx = null;
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Bizim Mozilla CA bundle'imiz varsa onu kullan, yoksa default
    final ctx = _ctx ?? context;
    final client = super.createHttpClient(ctx);
    client.connectionTimeout = const Duration(seconds: 10);
    return client;
  }

  @override
  Future<List<InternetAddress>> lookup(String host, {int? port}) {
    return InternetAddress.lookup(host, type: InternetAddressType.IPv4);
  }
}

/// Global instance — main()'de loadCaBundle() ile beslenir
final _syncRestoOverrides = _SyncRestoHttpOverrides();

/// 7 May 2026 — Self-healing init: bozuk SharedPreferences cache'i tara, JSON parse fail
/// olan key'leri otomatik temizle. Bir daha "FormatException Unexpected character"
/// nedeniyle uygulama acilmama sorunu yasanmasin.
Future<void> _selfHealCorruptCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    int healed = 0;
    for (final key in keys) {
      final value = prefs.getString(key);
      if (value == null) continue;
      // Sadece JSON-vari (obje veya dizi) basliyorsa kontrol et
      final trimmed = value.trim();
      if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) continue;
      try {
        jsonDecode(trimmed);
      } catch (_) {
        // Bozuk JSON — temizle
        await prefs.remove(key);
        healed++;
        if (kDebugMode) print('[SelfHeal] Bozuk SharedPreferences key silindi: $key');
      }
    }
    if (healed > 0 && kDebugMode) print('[SelfHeal] Toplam $healed bozuk key temizlendi');
  } catch (e) {
    if (kDebugMode) print('[SelfHeal] Hata: $e');
  }
}

/// Main entry — 7 May 2026: runZonedGuarded ile sarmalandi.
/// Yakalanmayan herhangi bir exception app'i oldurmesin.
void main() {
  // 19 May 2026: IPv4-only + Mozilla CA bundle override GLOBAL set
  // main() ilk satirinda, herhangi bir Dio/HttpClient olusmadan ONCE.
  HttpOverrides.global = _syncRestoOverrides;

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 19 May 2026: CA bundle'i asset'ten yukle (Cloudflare cert dogrulamasi icin)
    // WidgetsFlutterBinding.ensureInitialized() SONRASI olmali (rootBundle hazir)
    await _syncRestoOverrides.loadCaBundle().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (kDebugMode) print('[CA] yukleme timeout — default trust ile devam');
      },
    );

    // 7 May 2026: Bozuk cache'leri ilk acilista temizle (FormatException onlemi)
    await _selfHealCorruptCache().timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        if (kDebugMode) print('[SelfHeal] Timeout — devam ediliyor');
      },
    );

    // Desktop icin SQLite FFI kullan
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final storageService = StorageService();
    await storageService.init().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (kDebugMode) print('[Main] storageService.init timeout');
      },
    );

    final apiService = ApiService();
    final printerService = PrinterService();
    final soundService = SoundService();
    final webSocketService = WebSocketService();

    // Theme provider
    final themeProvider = ThemeProvider();
    await themeProvider.loadCachedTheme().timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        if (kDebugMode) print('[Main] themeProvider.loadCachedTheme timeout');
      },
    );

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

    await apiService.initOfflineServices().timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        if (kDebugMode) print('[Main] apiService.initOfflineServices timeout');
      },
    );

    // 1 Haz 2026 (v1.5.6) — Boot cache audit (donma fix)
    // Fire-and-forget: UI'ı bloklamaz, arka planda çalışır.
    //   1) Image cache LRU 200MB altına çek (sahada GB'lara çıkıyordu)
    //   2) SQLite DB > 50MB ise VACUUM (silinen ticket'ların boş alanı)
    //   3) %temp% eski update artefakt'ları (3 günden eski) sil
    unawaited(() async {
      try {
        await ImageCacheService().init();
        await ImageCacheService().audit();
      } catch (e) {
        if (kDebugMode) print('[Main] image audit error: $e');
      }
    }());
    unawaited(() async {
      try {
        await LocalDbService().compactDatabase();
      } catch (e) {
        if (kDebugMode) print('[Main] db compact error: $e');
      }
    }());
    unawaited(() async {
      try {
        await VersionService().cleanupOldUpdateFiles();
      } catch (e) {
        if (kDebugMode) print('[Main] update cleanup error: $e');
      }
    }());

    // 12 Haz 2026 — PERİYODİK BAKIM (donma fix devamı)
    // Yukarıdaki 3 temizlik yalnız boot'ta çalışıyordu; POS haftalarca
    // kapanmadığı için hiç tetiklenmiyordu. Aynı 3 işlem 6 saatte bir
    // tekrar çalışır. Tek timer + guard: bir tur bitmeden yenisi başlamaz.
    // Her işlem kendi try/catch'inde — biri patlarsa diğerleri çalışır.
    // unawaited (fire-and-forget): UI'ı bloklamaz.
    bool isMaintenanceRunning = false;
    Future<void> runPeriodicMaintenance() async {
      if (isMaintenanceRunning) return;
      isMaintenanceRunning = true;
      try {
        if (kDebugMode) print('[Main] Periyodik bakim basladi');
        try {
          await ImageCacheService().init();
          await ImageCacheService().audit();
        } catch (e) {
          if (kDebugMode) print('[Main] periyodik image audit error: $e');
        }
        try {
          await LocalDbService().compactDatabase();
        } catch (e) {
          if (kDebugMode) print('[Main] periyodik db compact error: $e');
        }
        try {
          await VersionService().cleanupOldUpdateFiles();
        } catch (e) {
          if (kDebugMode) print('[Main] periyodik update cleanup error: $e');
        }
      } finally {
        isMaintenanceRunning = false;
      }
    }
    Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(runPeriodicMaintenance());
    });

    // Yazici ayarlarini yukle
    await printerService.loadSettings().timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        if (kDebugMode) print('[Main] printerService.loadSettings timeout');
      },
    );

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

  // Cache invalidate — backend admin paneli ile bir entity degisince
  // (ornek: urun fiyati, yazici ayari) anlik refresh tetikler.
  // Multi-tenant: backend io.to('panel_X') ile yalnizca dogru panele gonderir.
  webSocketService.onCacheInvalidate = (types) async {
    print('[Main] Cache invalidate: $types');
    try {
      await SyncService().refreshCacheTypes(types);
    } catch (e) {
      print('[Main] Cache invalidate refresh hata: $e');
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

  // 16 May 2026: Başka POS'tan gelen "Mutfağa Gönder" event'i
  // Mevcut local print akışı bozulmaz, sadece YEDEK olarak başka POS basar
  webSocketService.onKitchenPrint = (payload) async {
    try {
      if (!printerService.isConfigured) {
        print('[KitchenPrint] Yazici ayarlanmamis, skip');
        return;
      }
      final printerGroups = payload['printer_groups'] as List? ?? [];
      if (printerGroups.isEmpty) return;
      print('[KitchenPrint] ${printerGroups.length} yazici grubu icin fis basiliyor');
      soundService.playNewOrderSound();

      final ticket = {
        'id': payload['ticket_id'],
        'ticket_number': payload['ticket_number'],
        'table_number': payload['table_number'],
        'section_name': payload['section_name'],
        'waiter_name': payload['waiter_name'],
      };

      for (final g in printerGroups) {
        try {
          final ip = (g['printer_ip'] ?? '') as String;
          final port = (g['printer_port'] as num?)?.toInt() ?? 9100;
          final items = (g['items'] as List?) ?? [];
          if (ip.isEmpty || items.isEmpty) continue;
          await printerService.printKitchenReceiptToIp(
            ticket: ticket,
            items: items,
            ip: ip,
            port: port,
          );
        } catch (e) {
          print('[KitchenPrint] grup basilamadi: $e');
        }
      }
    } catch (e) {
      print('[KitchenPrint] hata: $e');
    }
  };

  // 12 Haz 2026: Web POS fiş işleri — DB-polling + atomic claim istemcisi.
  // Socket 'webpos_jobs_hint' SADECE poll'u öne çeker; basım yetkisi DB'deki
  // atomic claim'den gelir (2 POS açıkken bile tek fiş). 5sn timer + guard
  // WebposPrintService içinde. Kill-switch: SharedPreferences
  // 'webpos_poll_enabled' (default true) — kapalıysa start() no-op.
  final webposPrintService = WebposPrintService();
  webposPrintService.configure(
    apiService: apiService,
    printerService: printerService,
  );
  webSocketService.onWebposJobsHint = () {
    webposPrintService.triggerNow();
  };
  // Fire-and-forget: boot'u bloklamaz; API key yokken poll kendini atlar
  // (api.hasApiKey guard), InitialSync sonrası key set olunca devreye girer.
  unawaited(webposPrintService.start());

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
  }, (error, stack) {
    // 7 May 2026: runZonedGuarded — yakalanmayan exception app'i oldurmesin
    if (kDebugMode) {
      print('[FATAL] Yakalanmayan hata: $error');
      print(stack);
    }
  });
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
            // 22 May 2026: Dokunmatik POS feedback iyilestirmesi.
            // Eskiden NoSplash idi — kullanici tikladigini anlayamiyordu, tekrar
            // basiyor ya da kaciriyordu. InkSparkle hem daha hizli hem daha
            // belirgin ripple verir.
            splashFactory: InkSparkle.splashFactory,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            // Tum ElevatedButton'lara min boy + bold yazi (POS standardi)
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(88, 56),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                minimumSize: const Size(88, 52),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(88, 52),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
            ),
            // IconButton'larin tap area'sini buyut
            iconButtonTheme: IconButtonThemeData(
              style: IconButton.styleFrom(
                minimumSize: const Size(52, 52),
                padding: const EdgeInsets.all(12),
              ),
            ),
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
