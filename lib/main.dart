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
import 'services/log_service.dart';
import 'services/failed_prints_notifier.dart';
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
    // 20 Ağu 2026 [F4 / K4] — storageService.init() içindeki
    // SharedPreferences.getInstance() bozuk prefs'te .timeout'tan ÖNCE senkron
    // throw edebilir → runZonedGuarded zone'u ölür → runApp HİÇ çağrılmaz =
    // BEYAZ EKRAN (K4'ün kapatmaya çalıştığı sınıf). try/catch ile yakala: hata
    // olsa da AKIŞ DEVAM ETSİN, runApp çalışsın.
    try {
      await storageService.init().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          if (kDebugMode) print('[Main] storageService.init timeout');
        },
      );
    } catch (e, st) {
      if (kDebugMode) {
        print('[Main] storageService.init HATA (akış devam, uygulama yine de açılır): $e');
      }
      try {
        LogService().error(
          LogType.error,
          'storageService.init basarisiz — uygulama yine de acildi (beyaz ekran onlendi)',
          error: e,
          stackTrace: st,
        );
      } catch (_) {}
    }

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

    // 20 Ağu 2026 [F4 / K4] — storageService.init() yukarıda başarısız olduysa
    // _prefs (late) atanmamıştır → bu getter'lar LateInitializationError atar.
    // Korumasız bırakılırsa zone ölür, runApp çalışmaz = BEYAZ EKRAN (init'i
    // sarmanın anlamı kalmazdı). Bu blok da yakalanır: hata olursa saved-* boş
    // kalır, uygulama Setup/InitialSync ekranıyla açılır.
    try {
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
    } catch (e) {
      if (kDebugMode) {
        print('[Main] storageService okuma HATA (akış devam): $e');
      }
    }

    // 20 Ağu 2026 [K4] — initOfflineServices (LocalDbService.init dahil) hatası
    // uygulamayı ÖLDÜRMESİN. Bozuk DB self-heal edilemezse (2. corruption / lock /
    // izin / disk-dolu / migration) burada yakala; AKIŞ DEVAM ETSİN, runApp MUTLAKA
    // çalışsın → InitialSyncScreen'in mevcut "Tekrar Dene" ekranı görünür (beyaz
    // ekran DEĞİL). LocalDbService.init içindeki corruption ise zaten sessizce
    // self-heal edilir (yeni DB); bu catch onun ÖTESİNDEKİ hatalar içindir.
    try {
      await apiService.initOfflineServices().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          if (kDebugMode) print('[Main] apiService.initOfflineServices timeout');
        },
      );
    } catch (e, st) {
      if (kDebugMode) {
        print('[Main] initOfflineServices HATA (akış devam, hata ekranı gösterilecek): $e');
      }
      // Uygulamayı ÖLDÜRME — sadece logla (uzaktan #poslogs).
      try {
        LogService().error(
          LogType.error,
          'initOfflineServices basarisiz — uygulama hata ekraniyla devam etti (beyaz ekran onlendi)',
          error: e,
          stackTrace: st,
        );
      } catch (_) {}
    }

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
    // 14 Haz 2026 (v1.6.1) — SELF-CLEAN: kullanıcının elle açtığı eski portable
    // kopyaları (Desktop/Downloads SyncResto-Windows*, .zip) sil. Adam yanlışlıkla
    // ESKİ exe açamasın. Çalışan exe'nin kendi klasörü korunur.
    unawaited(() async {
      try {
        await VersionService().cleanupStalePortableCopies();
      } catch (e) {
        if (kDebugMode) print('[Main] portable cleanup error: $e');
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
        try {
          await VersionService().cleanupStalePortableCopies();
        } catch (e) {
          if (kDebugMode) print('[Main] periyodik portable cleanup error: $e');
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

  // Faz 2 (22 Tem 2026): lokal yazici kuyrugu basarili basinca sunucuya 'printed'
  // raporu. PrinterService ApiService'i import etmez — kablo burada (webpos deseni).
  printerService.onQueueKitchenPrinted = (serverTicketId, serverJobId) =>
      apiService.markItemsPrinted(
        ticketId: serverTicketId,
        itemIds: const [],
        jobIds: [serverJobId],
      );

  // 24 Tem 2026: retry TÜKENDİ (5/5, mutfak fişi çıkmadı) → (a) SUNUCU LOGU (pos_logs
  // error — biz uzaktan adminsync #poslogs'ta görürüz; gürültü filtresi error'ı elemez),
  // (b) POS sağ-üst "çıkmayan fiş" rozetini yenile (global notifier tik). FAZ 3 UYUMU:
  // online'da badge sunucu 'printed'i görüp otomatik düşürür (kurtarılmışsa gösterilmez).
  printerService.onQueueKitchenFailed = (info) {
    // (a) SUNUCU LOGU — biz uzaktan adminsync #poslogs'ta görürüz (error, gürültü filtresi elemez).
    // Fable H1: printer_service zaten job başına 1 kez çağırır (dedup orada), burada spam yok.
    try {
      LogService().error(
        LogType.error,
        'Mutfak fisi RETRY TUKENDI cikmadi (masa ${info['table']})',
        details: {
          'table': info['table'],
          'printer_name': info['printer_name'],
          'item_count': info['item_count'],
          'ticket_id': info['ticket_id'],
          'server_job_id': info['server_job_id'],
          'error': info['error'],
          'event': 'kitchen_print_exhausted',
        },
      );
    } catch (_) {}
    // (b) PANEL HARD-FAILED SİNYALİ (Fable H4) — fişi giren kasa kapansa bile panel/başka
    // kasa "masa X fişi hiç çıkmadı" görsün, kalıcı kayıp olmasın. reportPrintFailed
    // (amaca özel endpoint) panel_print_jobs.status='failed' set eder + cross-kasa push.
    // Backend guard: `status NOT IN ('printed','failed')` → zaten basılmış işi bozmaz
    // (çift-fiş/yanlış-alarm koruması). Online'da çalışır (offline false döner, güvenli).
    // server_ticket_id + server_job_id GEREKLİ (offline-origin job'da yoksa atla — sunucuya
    // hiç değmemiş, panel zaten bilmiyor). fire-and-forget, akışı etkilemez.
    final serverTicketId = info['server_ticket_id'];
    final serverJobId = info['server_job_id'];
    if (serverTicketId is int && serverJobId is int) {
      unawaited(apiService.reportPrintFailed(
        ticketId: serverTicketId,
        jobId: serverJobId,
        error: 'retry_exhausted_5_5',
      ).catchError((_) => false));
    }
    // (c) Badge'i anlik yenile (poll beklemeden)
    failedKitchenPrintsChanged.value = failedKitchenPrintsChanged.value + 1;
  };

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
      // 21 Tem 2026: 'table_status' SQLite cache tipi DEGIL, masa gridi UI push sinyalidir.
      // TablesScreen fan-out listener'i _loadData ile yeniler (getTables zaten cacheTables
      // yazar → SQLite de tazelenir). SyncService'e gecirirsek AYNI event icin cift
      // /api/pos/tables fetch'i olur → filtrele.
      final cacheTypes = types.where((t) => t != 'table_status').toList();
      if (cacheTypes.isNotEmpty) {
        await SyncService().refreshCacheTypes(cacheTypes);
      }
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
      // 17 Tem 2026: soket kesikken kaçan cache:invalidate eventlerini telafi et
      // (debounce'lu tam tarama; tarama 5dk'ya gevşetildiği için reconnect telafisi ŞART).
      SyncService().sweepAfterReconnect();
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

    // 14 Haz 2026 — CLAIM-FIRST tek-basim guard:
    // print_order panel-room TUM socket'lere broadcast olur (listener_count ~10:
    // 1-2 gercek cihaz + hayalet socket). Dedup yoktu → her socket bu fisi
    // basiyordu (online/telefon MUKERRER). COZUM: basmadan ONCE atomik claim et.
    // Ilk claim eden (HTTP 200 & claimed==true) basar; digerleri 409 alir → atlar.
    // job_id YOKSA (retry/replay re-emit yollari) claim atlanir, DOGRUDAN basilir
    // (yoksa o fisler HIC basilmaz = hic-fis incident → job_id-null fallback ZORUNLU).
    if (jobId != null) {
      final jobIdInt = jobId is int ? jobId : int.tryParse(jobId.toString());
      if (jobIdInt == null) {
        print('[Main] job_id parse edilemedi ($jobId) — claim atlaniyor, basma iptal');
        return;
      }
      final claimed = await apiService.claimPrintJob(jobIdInt);
      if (!claimed) {
        // 409 (baska socket kapti) veya hata → MUKERRER onlendi, sessizce cik.
        print('[Main] Print job #$jobIdInt claim edilemedi (baska socket bastı veya hata) — atlanıyor');
        return;
      }
      print('[Main] Print job #$jobIdInt claim edildi — bu socket basacak');
    }

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

      final Map<String, List<Map<String, dynamic>>> byIp = {};
      for (final g in printerGroups) {
        final group = (g as Map).cast<String, dynamic>();
        final ip = ((group['printer_ip'] ?? '') as String).trim();
        final items = (group['items'] as List?) ?? [];
        if (ip.isEmpty || items.isEmpty) continue;
        byIp.putIfAbsent(ip, () => []).add(group);
      }

      await Future.wait(byIp.values.map((sameIpGroups) async {
        for (final group in sameIpGroups) {
          try {
            final ip = (group['printer_ip'] ?? '') as String;
            final port = (group['printer_port'] as num?)?.toInt() ?? 9100;
            final items = (group['items'] as List?) ?? [];
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
      }));
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
