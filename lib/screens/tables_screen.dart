import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:async';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/connectivity_service.dart';
import '../services/log_service.dart';
import '../services/license_service.dart';
import '../services/sync_service.dart';
import '../services/local_db_service.dart';
import '../providers/theme_provider.dart';
import 'pin_login_screen.dart';
import 'initial_sync_screen.dart';
import 'printer_settings_screen.dart';
import '../widgets/ticket_modal.dart';
import '../widgets/add_item_modal.dart';
import '../widgets/offline_data_modal.dart';
import 'order_tracking_screen.dart';
import '../services/version_service.dart';
import '../widgets/update_modal.dart';

class TablesScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;
  final Map<String, dynamic> waiter;

  const TablesScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
    required this.waiter,
  });

  @override
  State<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends State<TablesScreen> {
  List<dynamic> _sections = [];
  List<dynamic> _tables = [];
  bool _isLoading = true;
  int? _selectedSectionId;
  Timer? _clockTimer;
  Timer? _refreshTimer;
  String _currentTime = '';
  String _currentDate = '';
  int _pendingItemCount = 0; // MASA TAKIP buton badge'i icin
  // Masa rengi icin: tableId -> en eski bekleyen item'in created_at (UTC ISO).
  // Tum urunler teslim edildiyse o masa map'te yer almaz -> renk normale doner.
  Map<int, DateTime> _oldestPendingByTable = {};
  // 19 May 2026: Mutfaga gitmemis (printed=0) urun olan masalar. Kart ustunde
  // kirmizi badge "MUTFAGA GITMEMIS URUN VAR" gosterimi icin.
  Set<int> _unprintedByTable = {};
  // 11 Haz 2026: FIS CIKMADI. Backend printed=1 SET etti AMA panel_print_jobs
  // status=timeout/failed (fiziksel fis cikmadi olabilir). printed=1 oldugu icin
  // _unprintedByTable'a girmiyor -> ayri TURUNCU "FIS CIKMADI" badge gosterilir.
  Set<int> _printFailedByTable = {};

  // 11 Haz 2026 DONMA FIX: silent (2sn/5sn otomatik) poll'ler yavaş ağda üst üste
  // binmesin diye guard. Manuel/ilk yükleme guard'a takılmaz (kullanıcı aksiyonu bloklanmaz).
  bool _isFetchingData = false;
  bool _isFetchingPending = false;

  // Offline monitoring
  final ConnectivityService _connectivity = ConnectivityService();
  final LogService _logService = LogService();
  final LicenseService _licenseService = LicenseService();
  final SyncService _syncService = SyncService();
  final VersionService _versionService = VersionService();
  Timer? _versionCheckTimer;
  bool _updateModalOpen = false; // Ayni anda 2 modal acilmasin
  bool _isOnline = true;
  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _licenseCheckTimer;

  // Ayarlar
  bool _showProductImages = true;
  String _appVersion = '';

  int? _safeInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadSettings();
    _loadData();
    _startClock();
    _startAutoRefresh();
    _setupConnectivity();
    _startLicenseCheck();
    _startVersionCheck();
    // 21 Tem 2026: masa durumu PUSH dinleyicisi (fan-out — main.dart TEK-SLOT'unu EZMEZ).
    // Backend adisyon aç/kapa/taşı/böl/ürün-ekle sonrası 'table_status' yollar → o an yenile.
    widget.webSocketService.addCacheInvalidateListener(_onCachePush);
  }

  // ==================== UPDATE CHECK (3 saatte bir) ====================
  // POS uygulamasi acik kalirken yeni sürüm cikinca pop-up göster.
  // initial_sync_screen sadece ilk acilista kontrol ediyordu, calisma
  // sirasinda yeni sürüm bildirimi yoktu — bu fix onu çozer.
  // Idempotent: kullanici 'Sonra' derse 24 saat tekrar gosterme (VersionService).
  void _startVersionCheck() {
    // Ilk kontrol 60 saniye sonra (acilis sırasinda zaten initial_sync kontrol etti)
    Timer(const Duration(seconds: 60), () => _checkVersion());
    // Sonra her 3 saatte bir
    _versionCheckTimer = Timer.periodic(const Duration(hours: 3), (_) => _checkVersion());
  }

  Future<void> _checkVersion() async {
    if (!_isOnline || !mounted || _updateModalOpen) return;
    try {
      final result = await _versionService.checkForUpdates();
      if (!mounted) return;
      if (!result.isUpdateRequired && !result.isUpdateAvailable) return;
      // Idempotent: kullanici bu sürümu erteledi mi (24 saat icinde)?
      final newVersion = result.versionInfo!.currentVersion;
      if (!result.isUpdateRequired) {
        final dismissed = await _versionService.isVersionDismissed(newVersion);
        if (dismissed) {
          print('[Version] Surum $newVersion 24 saat icinde ertelendi, modal acilmiyor');
          return;
        }
      }
      if (!mounted) return;
      _updateModalOpen = true;
      await UpdateModal.show(
        context,
        result,
        onLater: () async {
          await _versionService.dismissUpdate(newVersion);
        },
      );
      _updateModalOpen = false;
    } catch (e) {
      print('[Version] Check hata: $e');
    }
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _appVersion = packageInfo.version);
    }
  }

  Future<void> _loadSettings() async {
    final showImages = await widget.storageService.getShowProductImages();
    if (mounted) {
      setState(() => _showProductImages = showImages);
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _refreshTimer?.cancel();
    _licenseCheckTimer?.cancel();
    _pendingCountTimer?.cancel();
    _versionCheckTimer?.cancel();
    _connectivitySubscription?.cancel();
    _pushDebounce?.cancel(); // 21 Tem 2026: masa push debounce
    widget.webSocketService.removeCacheInvalidateListener(_onCachePush); // 21 Tem 2026: fan-out kaydı kaldır
    super.dispose();
  }

  Timer? _pendingCountTimer;

  void _startAutoRefresh() {
    // 21 Tem 2026: 2sn → 6sn. Masa değişiklikleri artık PUSH ile ANINDA gelir ('table_status'
    // → _onCachePush → _loadData). Poll KALDIRILMADI: offline / reconnect'te kaçan event /
    // emit'i olmayan uç-yol için EMNİYET AĞI (offline'da lokal cache okur, ucuz).
    // 6 Tem 2026 (offline fix Adim 4b): OFFLINE'da da calis. Online -> server; offline ->
    // getTables lokal cache + offline merge doner (Adim 1).
    _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) {
        _loadData(silent: true);
      }
    });

    // MASA TAKIP badge + masa rengi icin pending data.
    // 21 Tem 2026: 5sn → 15sn. Badge artık PUSH ile de yenileniyor (_onCachePush → adisyon
    // aç/kapa/ürün-ekle/taşı sonrası anlık). Poll emniyet ağı (mark-served/printed gibi push'suz
    // yollar + reconnect). Badge eşikleri DAKİKA mertebesi (renk 10/20dk, FİŞ ÇIKMADI 2dk backend)
    // → 15sn granülarite hiçbir göstergeyi bozmaz. OFFLINE'da lokal print_queue'dan beslenir.
    _refreshPendingCount(); // ilk cagri hemen
    _pendingCountTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        _refreshPendingCount();
      }
    });
  }

  // 21 Tem 2026: Backend adisyon aç/kapa/taşı/böl/ürün-ekle/indirim sonrası
  // cache:invalidate {types:['table_status']} yollar. 400ms debounce: merge/split/ardışık
  // emit'leri TEK fetch'e indirger. _loadData(silent) zaten _isFetchingData guard'lı → 6sn
  // poll ile üst üste binmez. Offline'da soket kopuk → event gelmez; poll emniyet ağı devrede.
  // 'table_status' DIŞI tipler (products/printers...) main.dart global handler'ında işlenir.
  Timer? _pushDebounce;
  void _onCachePush(List<String> types) {
    if (!types.contains('table_status')) return;
    if (!mounted) return;
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      // 21 Tem 2026 SELF-ECHO GUARD + ardışık refresh (DONMA FIX):
      // Kullanıcının kendi aksiyonu (masa kapat/ürün ekle) zaten close/ekleme sonrası _loadData
      // çağırıp masayı taze yükler. AMA backend o aksiyonun push'unu KENDİ kasasına da yollar
      // (self-echo) → 400ms sonra TEKRAR _loadData = çift refresh = modal animasyonu anında takılma.
      // Son 1sn içinde masa gridi zaten tam yüklendiyse (kendi aksiyonunun sonucu) _loadData'yı ATLA;
      // yabancı-kasa olayını 6sn poll telafi eder. _loadData + _refreshPendingCount'u AYNI ANDA değil
      // ARDIŞIK await ile çağır → tek setState dalgası (çift rebuild yerine).
      // 21 Tem 2026: pencere 500ms (Fable: 1sn çok geniş, yabancı-kasa olayını kaçırma riski).
      // Sadece kendi aksiyonunun echo'sunu ele; yabancı olay 500ms'i aşarsa _loadData çalışır.
      final last = _lastLoadStartedAt;
      final freshLoad = last != null && DateTime.now().difference(last).inMilliseconds < 500;
      if (!freshLoad) {
        await _loadData(silent: true);
      }
      if (mounted) {
        // Badge push'suz yolu olmadığı için HER ZAMAN yenilenir (ürün ekle/close/FİŞ ÇIKMADI anlık).
        await _refreshPendingCount();
      }
    });
  }

  /// Periyodik lisans kontrolü - her 12 saatte bir
  /// Online: API'den kontrol et
  /// Offline: Local cache'den kontrol et (son 12 saat içinde online kontrol yapılmış olmalı)
  void _startLicenseCheck() {
    // İlk kontrol hemen (uygulama açıldığında)
    _checkLicense();

    // Her 12 saatte bir kontrol (43200 saniye = 12 saat)
    _licenseCheckTimer = Timer.periodic(const Duration(hours: 12), (_) {
      _checkLicense();
    });
  }

  Future<void> _checkLicense() async {
    if (!mounted) return;

    try {
      final result = await _licenseService.checkLicense(forceOnline: _isOnline);

      if (!mounted) return;

      // Lisans geçersiz ve offline kullanım da mümkün değil
      // VEYA 12 saatten fazla offline (internet bağlantısı gerekli)
      bool shouldBlock = !result.isValid && !result.canUseOffline;
      String errorMsg = '';

      // 12 saat kontrolü - son online kontrol ne zaman yapıldı?
      if (!shouldBlock && result.licenseInfo != null) {
        final hoursSinceCheck = result.licenseInfo!.hoursSinceLastCheck;
        if (hoursSinceCheck >= 12) {
          // 12 saatten fazla offline - internet bağlantısı gerekli
          if (!_isOnline) {
            shouldBlock = true;
            errorMsg = 'İnternet Bağlantısı Gerekli\n\n'
                'Son ${hoursSinceCheck} saattir offline çalışıyorsunuz.\n\n'
                'Lisans doğrulaması için lütfen internete bağlanın.';
            _logService.warning(LogType.general, 'Offline sure asimi - internet gerekli', details: {
              'hours_since_check': hoursSinceCheck,
              'waiter': widget.waiter['name'],
            });
          }
          // Online ise zaten checkLicense içinde kontrol yapılıyor
        }
      }

      if (!shouldBlock && !result.isValid && !result.canUseOffline) {
        shouldBlock = true;
      }

      if (shouldBlock) {
        // Hata mesajı belirlenmemişse lisans durumuna göre belirle
        if (errorMsg.isEmpty) {
          _logService.warning(LogType.general, 'Lisans gecersiz - oturum sonlandiriliyor', details: {
            'status': result.status.name,
            'waiter': widget.waiter['name'],
          });

          if (result.status == LicenseStatus.inactive) {
            errorMsg = 'Lisans devre dışı bırakıldı.\n\nLütfen SyncResto yöneticinize başvurun.';
          } else if (result.status == LicenseStatus.expired) {
            errorMsg = 'Lisans süresi doldu.\n\nLütfen lisansınızı yenileyiniz.';
          } else {
            errorMsg = 'Lisans doğrulanamadı.\n\nLütfen internet bağlantınızı kontrol edin.';
          }

          // Cache'i temizle (sadece lisans hatası durumunda)
          await _syncService.clearAllCache();
          await _licenseService.clearLicense();
        }

        // Hata mesajı göster ve InitialSyncScreen'e yönlendir
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red[700], size: 28),
                  const SizedBox(width: 12),
                  Text(errorMsg.contains('İnternet') ? 'Bağlantı Gerekli' : 'Lisans Hatası'),
                ],
              ),
              content: Text(errorMsg),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    // InitialSyncScreen'e yönlendir (tekrar lisans kontrolü için)
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (context) => InitialSyncScreen(
                          storageService: widget.storageService,
                          apiService: widget.apiService,
                          printerService: widget.printerService,
                          webSocketService: widget.webSocketService,
                        ),
                      ),
                      (route) => false,
                    );
                  },
                  child: const Text('Tamam'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      print('[License] Kontrol hatası: $e');
      // Hata olursa sessizce devam et, sonraki kontrolde tekrar denenecek
    }
  }

  void _setupConnectivity() {
    _isOnline = _connectivity.isOnline;
    _connectivitySubscription = _connectivity.connectionStream.listen((isOnline) {
      setState(() => _isOnline = isOnline);
      if (isOnline) {
        // Online olunca verileri yenile ve sync et
        _loadData();
        widget.apiService.syncPendingItems();
        // Masa durumlarını server'dan yenile
        widget.apiService.refreshTablesFromServer();
      }
    });
  }

  void _startClock() {
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
  }

  void _updateClock() {
    final now = DateTime.now();
    setState(() {
      _currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      _currentDate = '${now.day} ${_getMonthName(now.month)} ${now.year}';
    });
  }

  String _getMonthName(int month) {
    const months = ['Ocak', 'Subat', 'Mart', 'Nisan', 'Mayis', 'Haziran',
                    'Temmuz', 'Agustos', 'Eylul', 'Ekim', 'Kasim', 'Aralik'];
    return months[month - 1];
  }

  bool _reloadQueued = false; // 21 Tem 2026: silent load guard'a takılınca "bir kez daha çalış" bayrağı
  Future<void> _loadData({bool silent = false}) async {
    // 11 Haz 2026 DONMA FIX: silent (otomatik 6sn) poll yavaş ağda üst üste binmesin.
    // Manuel/ilk yükleme (silent=false) HER ZAMAN çalışır (kullanıcı aksiyonu bloklanmaz).
    // 21 Tem 2026: guard'a takılan silent load'u YUTMA — kuyruğa al, mevcut bitince tekrar çalış
    // (masa kapatınca onClose silent _loadData poll fetch'ine denk gelip yutulursa masa DOLU
    // kalırdı = REGRESYON. Trailing reload bunu kapatır).
    if (silent && _isFetchingData) { _reloadQueued = true; return; }
    _isFetchingData = true;
    _reloadQueued = false;
    // Self-echo guard için damgayı fetch BAŞLANGICINDA vur (bitişte değil — close'dan ÖNCE
    // başlamış bayat fetch'i "taze" saymamak için).
    final loadStartedAt = DateTime.now();
    // Sadece ilk yüklemede loading göster
    if (!silent) {
      setState(() => _isLoading = true);
    }
    try {
      final sections = await widget.apiService.getSections();
      final tables = await widget.apiService.getTables();

      if (!mounted) return;

      setState(() {
        _sections = sections;
        _tables = tables;
        if (sections.isNotEmpty && _selectedSectionId == null) {
          _selectedSectionId = _safeInt(sections[0]['id']);
        }
      });

    } catch (e) {
      if (!silent) {
        _showError('Veri yuklenemedi: $e');
      }
    } finally {
      _isFetchingData = false;
      // 21 Tem 2026: damgayı fetch BAŞLANGICIYLA vur (bitiş değil) — bu load ne kadar
      // ÖNCEKİ veriyi getirdi bilgisi self-echo guard için doğru olur.
      _lastLoadStartedAt = loadStartedAt;
      if (!silent) {
        setState(() => _isLoading = false);
      }
      // Guard'a takılan silent load kuyruğa alındıysa bir kez daha çalış (yutma yok).
      if (_reloadQueued && mounted) {
        _reloadQueued = false;
        _loadData(silent: true);
      }
    }
  }

  // 21 Tem 2026: masa gridi son yüklemesinin BAŞLANGIÇ zamanı (self-echo guard).
  DateTime? _lastLoadStartedAt;

  Future<void> _refreshPendingCount() async {
    // 11 Haz 2026 DONMA FIX: 5sn otomatik poll yavaş ağda üst üste binmesin.
    if (_isFetchingPending) return;
    _isFetchingPending = true;
    try {
      // 6 Tem 2026 (offline fix Adim 4b): OFFLINE'da getPendingOrders bos doner ->
      // "FIS CIKMADI" badge'i kaybolur. Bunun yerine LOKAL print_queue'dan cikmamis
      // (pending/failed) mutfak fisi olan masalari isaretle -> masa kartinda badge gorunur
      // (online'daki gibi ama lokal kaynaktan). Diger sayaclar (total/oldest/unprinted)
      // offline'da guvenilir olmadigi icin dokunulmaz.
      if (!_isOnline) {
        final offlinePrintFailed = await LocalDbService().getPrintFailedTableIds();
        if (mounted) {
          setState(() => _printFailedByTable = offlinePrintFailed);
        }
        _isFetchingPending = false;
        return;
      }
      final rows = await widget.apiService.getPendingOrders();
      // Hem badge sayisi hem masa-bazli en eski bekleyen zamani — masa rengi icin.
      int total = 0;
      final Map<int, DateTime> oldest = {};
      // 19 May 2026: Mutfaga gitmemis (printed=0) urun olan masalari topla
      final Set<int> unprintedTables = {};
      // 11 Haz 2026: FIS CIKMADI (backend print_failed=true) olan masalar
      final Set<int> printFailedTables = {};
      for (final r in rows) {
        if (r is! Map) continue;
        if (r['delivered_at'] != null) continue;
        total++;
        final tidRaw = r['table_id'];
        final tid = tidRaw is int ? tidRaw : int.tryParse(tidRaw?.toString() ?? '');
        // Mutfaga gitmemis (printed=0/false) ise masayi isaretle.
        // skip_pos_print=true (icecek/su gibi) ürünler hic basilmadigi icin
        // unprinted sayilmaz; aksi halde masa bos yere kirmizi badge alir.
        final isPrinted = r['printed'] == 1 || r['printed'] == true;
        final isSkip = r['skip_pos_print'] == true;
        if (!isPrinted && !isSkip && tid != null) {
          unprintedTables.add(tid);
        }
        // 11 Haz 2026: Backend print_failed=true -> bu ticket'in mutfak fisi
        // timeout/failed (printed=1 olsa bile fiziksel cikmamis olabilir).
        if (r['print_failed'] == true && tid != null) {
          printFailedTables.add(tid);
        }
        final iso = r['item_created_at']?.toString();
        if (tid == null || iso == null || iso.isEmpty) continue;
        try {
          final dt = DateTime.parse(iso).toLocal();
          final cur = oldest[tid];
          if (cur == null || dt.isBefore(cur)) oldest[tid] = dt;
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _pendingItemCount = total;
          _oldestPendingByTable = oldest;
          _unprintedByTable = unprintedTables;
          _printFailedByTable = printFailedTables;
        });
      }
    } catch (_) {
      // Sessiz: bu endpoint henuz deploy edilmemis olabilir
    } finally {
      _isFetchingPending = false; // 11 Haz 2026: guard mutlaka serbest (kalıcı kilit önle)
    }
  }

  void _openTableTracking() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrderTrackingScreen(
          apiService: widget.apiService,
          storageService: widget.storageService,
          waiter: widget.waiter,
        ),
      ),
    ).then((_) => _loadData(silent: true));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  List<dynamic> get _filteredTables {
    final filtered = _tables.where((t) => t['section_id'] == _selectedSectionId).toList();
    // Masa numarasına göre sırala
    filtered.sort((a, b) {
      final numA = int.tryParse(a['table_number']?.toString() ?? '0') ?? 0;
      final numB = int.tryParse(b['table_number']?.toString() ?? '0') ?? 0;
      return numA.compareTo(numB);
    });
    return filtered;
  }

  int get _emptyCount => _filteredTables.where((t) => t['status'] != 'occupied' && t['current_ticket_id'] == null).length;
  int get _occupiedCount => _filteredTables.where((t) => t['status'] == 'occupied' || t['current_ticket_id'] != null).length;

  Future<void> _openTable(Map<String, dynamic> table) async {
    final tableId = table['id'] as int;

    // Online ise önce server'dan güncel masa durumunu al
    if (widget.apiService.isOnline) {
      try {
        final ticketData = await widget.apiService.getTableTicket(tableId);

        if (ticketData == null && (table['status'] == 'occupied' || table['current_ticket_id'] != null)) {
          print('[Tables] Server\'da ticket yok, masa durumu güncelleniyor...');
          table['status'] = 'empty';
          table['current_ticket_id'] = null;
          await _loadData();
          final updatedTable = _tables.firstWhere(
            (t) => t['id'] == tableId,
            orElse: () => table,
          );
          table = Map<String, dynamic>.from(updatedTable);
        }
      } catch (e) {
        print('[Tables] Masa durumu kontrol hatası: $e');
      }
    }

    final currentSection = _sections.firstWhere(
      (s) => s['id'] == _selectedSectionId,
      orElse: () => <String, dynamic>{},
    );

    // Ticket var mı kontrol et
    final ticketData = await widget.apiService.getTableTicket(tableId);
    Map<String, dynamic>? ticket;
    if (ticketData != null && ticketData['ticket'] != null) {
      ticket = ticketData['ticket'] as Map<String, dynamic>?;
    } else if (ticketData != null && !ticketData.containsKey('ticket') && ticketData['id'] != null) {
      ticket = ticketData;
    }

    // 🔴 7 Tem 2026 (LAN Faz 2 — Fable K1/KRİTİK): Masa SADECE LAN yansimasiyla dolu ise
    // (baska kasada acik, bu cihaz sadece goruyor) uzerine YENI adisyon ACTIRMA -> cift kayit/
    // ciro karismasi olur. Masayi ACAN cihaz backend'e sync eder. Bu cihazda SALT-OKUNUR: uyar.
    if (ticket == null) {
      final lanOnly = await LocalDbService().hasLanOnlyOpenTicket(tableId);
      if (lanOnly) {
        // 17 Tem 2026 (filo #26): SnackBar yerine SALT-OKUMA özet — tutar + adisyon no + hangi kasa.
        // Hiçbir yazma yok (K1 kuralı korunur), garson masanın durumunu görebilir.
        final summary = await LocalDbService().getLanTicketSummary(tableId);
        if (mounted) {
          final total = (summary?['total'] as num?)?.toDouble() ?? 0.0;
          final ticketNo = summary?['ticket_number']?.toString() ?? '-';
          final dev = summary?['opened_by_device']?.toString();
          final tableNo = summary?['table_number']?.toString() ?? tableId.toString();
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Masa $tableNo — Başka Kasada Açık'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Toplam: ${total.toStringAsFixed(2)} TL',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Adisyon No: $ticketNo'),
                  if (dev != null && dev.isNotEmpty) Text('Açan Kasa: $dev'),
                  const SizedBox(height: 12),
                  const Text('Bu masada işlem, masayı açan kasadan yapılmalıdır.',
                      style: TextStyle(color: Color(0xFFB45309), fontSize: 13)),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Kapat')),
              ],
            ),
          );
        }
        return;
      }
    }

    if (ticket != null) {
      // Adisyon var → direkt ürün ekle ekranını aç
      final ticketId = (ticket['id'] as num?)?.toInt() ?? (ticket['local_id'] as num?)?.toInt();
      if (ticketId == null) return;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AddItemModal(
          apiService: widget.apiService,
          printerService: widget.printerService,
          ticketId: ticketId,
          waiterId: (widget.waiter['id'] as num).toInt(),
          tableId: tableId,
          table: table,
          waiter: widget.waiter,
          section: currentSection.isNotEmpty ? currentSection : null,
          showProductImages: _showProductImages,
          onItemAdded: () {},
          onClose: () {
            Navigator.of(context).pop();
            _loadData(silent: true); // 21 Tem 2026: spinner flash kalksın (grid yerinde güncellenir, donma azalır)
          },
        ),
      );
    } else {
      // Adisyon yok
      final skipCount = table['skip_customer_count'] == true || table['skip_customer_count'] == 1;

      if (skipCount) {
        // Kişi sayısı sorma → direkt adisyon aç + ürün ekle
        try {
          final result = await widget.apiService.openTicket(
            tableId: tableId,
            waiterId: (widget.waiter['id'] as num).toInt(),
            customerCount: 1,
          );
          if (result['lan_denied'] == true) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Bu masa başka kasada açık'), backgroundColor: Color(0xFFF59E0B)));
            }
            return;
          }
          if (result['success'] == true) {
            // Yeni açılan ticket'ı al
            final newTicketData = await widget.apiService.getTableTicket(tableId);
            Map<String, dynamic>? newTicket;
            if (newTicketData != null && newTicketData['ticket'] != null) {
              newTicket = newTicketData['ticket'] as Map<String, dynamic>?;
            }
            if (newTicket != null) {
              final newTicketId = (newTicket['id'] as num?)?.toInt() ?? (newTicket['local_id'] as num?)?.toInt();
              if (newTicketId != null) {
                await showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => AddItemModal(
                    apiService: widget.apiService,
                    printerService: widget.printerService,
                    ticketId: newTicketId,
                    waiterId: (widget.waiter['id'] as num).toInt(),
                    tableId: tableId,
                    table: table,
                    waiter: widget.waiter,
                    section: currentSection.isNotEmpty ? currentSection : null,
                    showProductImages: _showProductImages,
                    onItemAdded: () {},
                    onClose: () {
                      Navigator.of(context).pop();
                      _loadData(silent: true); // 21 Tem 2026: spinner flash kalksın (donma azalır)
                    },
                  ),
                );
                return;
              }
            }
          }
        } catch (e) {
          print('[Tables] Otomatik adisyon açma hatası: $e');
        }
      }

      // Normal akış → kişi sayısı seç + adisyon aç popup'ı
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => TicketModal(
          table: table,
          apiService: widget.apiService,
          printerService: widget.printerService,
          waiter: widget.waiter,
          showProductImages: _showProductImages,
          section: currentSection.isNotEmpty ? currentSection : null,
          onClose: () {
            Navigator.of(context).pop();
            _loadData(silent: true); // 21 Tem 2026: spinner flash kalksın (donma azalır)
          },
        ),
      );
    }
  }

  /// Garson değiştir — mevcut session'ı kapatıp PIN ekranına dön.
  /// Restoran açıkken farklı garson devreye girebilir.
  Future<void> _switchWaiter() async {
    _logService.logAction('Garson değiştir tıklandı', details: {
      'previous_waiter_id': widget.waiter['id'],
      'previous_waiter_name': widget.waiter['name'],
    });
    await widget.storageService.clearWaiterSession();
    widget.apiService.clearWaiterToken();
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

  void _logout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cikis Yap'),
        content: const Text('Oturumu kapatmak istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () async {
              // Logout log'u
              _logService.logAction('Oturum kapatildi', details: {
                'waiter_id': widget.waiter['id'],
                'waiter_name': widget.waiter['name'],
              });

              await widget.storageService.clearWaiterSession();
              widget.apiService.clearWaiterToken();
              if (mounted) {
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
            },
            child: const Text('Cikis', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);

    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Column(
        children: [
          // Header
          _buildHeader(theme),

          // Section Tabs
          _buildSectionTabs(),

          // Tables Grid
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: theme.primaryColor))
                : _buildTablesGrid(theme),
          ),

          // Status Legend
          _buildStatusLegend(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeProvider theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          // Logo + Version
          Row(
            children: [
              Image.asset(
                'assets/images/logo.png',
                width: 140,
                height: 45,
                fit: BoxFit.contain,
              ),
              if (_appVersion.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'v$_appVersion',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const Spacer(),

          // Offline indicator
          if (!_isOnline)
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange[100],
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.orange),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, color: Colors.orange[800], size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Offline Mod',
                    style: TextStyle(
                      color: Colors.orange[800],
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

          // Clock
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _currentTime,
                style: const TextStyle(
                  color: Color(0xFF1F2937),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                _currentDate,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ],
          ),

          const Spacer(),

          // Garson Değiştir (Kilit) — tıklayınca PIN ekranı açılır, garson değiştirilebilir
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Material(
              color: theme.primaryColor.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: _switchWaiter,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  child: Icon(Icons.lock_outline, color: theme.primaryColor, size: 32),
                ),
              ),
            ),
          ),

          // Waiter info
          PopupMenuButton<String>(
            offset: const Offset(0, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) async {
              if (value == 'toggle_images') {
                setState(() => _showProductImages = !_showProductImages);
                await widget.storageService.setShowProductImages(_showProductImages);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'toggle_images',
                child: Row(
                  children: [
                    Icon(
                      _showProductImages ? Icons.image : Icons.image_not_supported,
                      color: _showProductImages ? theme.primaryColor : Colors.grey,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    const Text('Urun Gorselleri'),
                    const Spacer(),
                    Switch(
                      value: _showProductImages,
                      onChanged: null,
                      activeColor: theme.primaryColor,
                    ),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.primaryColor,
                    radius: 18,
                    child: Text(
                      (widget.waiter['name'] ?? 'G')[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.waiter['name'] ?? 'Garson',
                        style: const TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w500),
                      ),
                      Text(
                        'Garson',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_drop_down, color: Colors.grey[600]),
                ],
              ),
            ),
          ),

          const SizedBox(width: 16),

          // Offline data button (Sync + Print Queue)
          FutureBuilder<List<dynamic>>(
            future: Future.wait([
              widget.apiService.getOfflineDataSummary(),
              LocalDbService().getPrintQueueSummary(),
            ]),
            builder: (context, snapshot) {
              // Sync queue
              final syncData = snapshot.data?[0] as Map<String, dynamic>? ?? {};
              final syncPending = syncData['pending_count'] ?? 0;
              final syncFailed = syncData['failed_count'] ?? 0;

              // Print queue
              final printData = snapshot.data?[1] as Map<String, int>? ?? {};
              final printPending = printData['pending_count'] ?? 0;
              final printFailed = printData['failed_count'] ?? 0;

              // Toplam
              final totalPending = syncPending + printPending;
              final totalFailed = syncFailed + printFailed;
              final hasData = totalPending > 0 || totalFailed > 0;

              return Stack(
                children: [
                  IconButton(
                    onPressed: _openOfflineDataModal,
                    icon: Icon(
                      Icons.cloud_sync,
                      color: totalFailed > 0
                          ? Colors.red
                          : (hasData ? Colors.orange : Colors.grey[700]),
                    ),
                    tooltip: 'Offline Veriler',
                  ),
                  if (hasData)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: totalFailed > 0 ? Colors.red : Colors.orange,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${totalPending + totalFailed}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),

          // Printer settings button
          IconButton(
            onPressed: _openPrinterSettings,
            icon: Icon(
              Icons.print,
              color: widget.printerService.isConfigured ? theme.primaryColor : Colors.grey[700],
            ),
            tooltip: 'Yazici Ayarlari',
          ),

          // Logout button
          IconButton(
            onPressed: _logout,
            icon: Icon(Icons.logout, color: Colors.grey[700]),
            tooltip: 'Cikis Yap',
          ),
        ],
      ),
    );
  }

  void _openPrinterSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PrinterSettingsScreen(
          printerService: widget.printerService,
          apiService: widget.apiService, // Sunucudan yazıcı çekmek için
        ),
      ),
    ).then((_) {
      // Ayarlar değiştiğinde UI'ı güncelle
      setState(() {});
    });
  }

  void _openOfflineDataModal() {
    showDialog(
      context: context,
      builder: (context) => OfflineDataModal(
        apiService: widget.apiService,
        onSyncComplete: () {
          _loadData(); // Masaları yenile
          setState(() {}); // Badge'i güncelle
        },
      ),
    );
  }

  Widget _buildSectionTabs() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      color: Colors.white,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            ..._sections.map((section) {
              final sectionId = _safeInt(section['id']);
              final isSelected = sectionId == _selectedSectionId;
              final color = _parseColor(section['color'] ?? '#16A34A');

              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() => _selectedSectionId = sectionId),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56, minWidth: 120),
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                      decoration: BoxDecoration(
                        color: isSelected ? color : Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? color : Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            section['name'],
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.grey[700],
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white.withValues(alpha: 0.2) : Colors.grey[200],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${section['table_count'] ?? 0}',
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.grey[600],
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            // MASA TAKIP butonu — en sağda, badge overlay'li
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, top: 4, bottom: 4),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _openTableTracking,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFEA580C), Color(0xFFDC2626)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.track_changes, color: Colors.white, size: 22),
                          SizedBox(width: 10),
                          Text(
                            'MASA TAKİP',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  if (_pendingItemCount > 0)
                    Positioned(
                      top: -10,
                      right: -10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.amber[700],
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Text(
                          'Bekleyen Ürün: $_pendingItemCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTablesGrid(ThemeProvider theme) {
    final tables = _filteredTables;

    if (tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_restaurant, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'Bu salonda masa yok',
              style: TextStyle(color: Colors.grey[500], fontSize: 18),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableCount = tables.length;
        final availableWidth = constraints.maxWidth - 48; // padding
        final availableHeight = constraints.maxHeight - 48;

        // En uygun grid boyutunu bul (tüm masalar ekrana sığmalı)
        int bestCols = 1;
        int bestRows = tableCount;
        double bestCellSize = 0;

        for (int cols = 1; cols <= tableCount; cols++) {
          final rows = (tableCount / cols).ceil();
          final cellWidth = (availableWidth - (cols - 1) * 12) / cols;
          final cellHeight = (availableHeight - (rows - 1) * 12) / rows;
          final cellSize = cellWidth < cellHeight ? cellWidth : cellHeight;

          if (cellSize > bestCellSize) {
            bestCellSize = cellSize;
            bestCols = cols;
            bestRows = rows;
          }
        }

        final cellWidth = (availableWidth - (bestCols - 1) * 12) / bestCols;
        final cellHeight = (availableHeight - (bestRows - 1) * 12) / bestRows;

        return GridView.builder(
          padding: const EdgeInsets.all(24),
          physics: const NeverScrollableScrollPhysics(), // Scroll kapalı
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: bestCols,
            childAspectRatio: cellWidth / cellHeight,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: tables.length,
          itemBuilder: (context, index) {
            final table = tables[index];
            return _buildTableCard(table, theme);
          },
        );
      },
    );
  }

  Widget _buildTableCard(Map<String, dynamic> table, ThemeProvider theme) {
    final isOccupied = table['status'] == 'occupied' || table['current_ticket_id'] != null || table['active_ticket_id'] != null;
    final tableNumber = (table['table_number'] ?? 'M${table['id']}').toString().replaceAll('Masa ', '');
    final totalRaw = table['current_total'];
    final total = totalRaw is num ? totalRaw.toDouble() : double.tryParse(totalRaw?.toString() ?? '') ?? 0.0;
    final openedAt = table['ticket_opened_at'];
    final lastItemAt = table['last_item_at'];
    // 17 Tem 2026: masayı hangi kasa açtı (opened_by_device). null/boş ise satır render edilmez.
    final openedByDeviceRaw = table['opened_by_device']?.toString();
    final openedByDevice = (openedByDeviceRaw != null && openedByDeviceRaw.isNotEmpty) ? openedByDeviceRaw : null;
    final paidRaw = table['paid_total'];
    final paidTotal = paidRaw is num ? paidRaw.toDouble() : double.tryParse(paidRaw?.toString() ?? '') ?? 0.0;
    final unpaidRaw = table['unpaid_total'];
    final unpaidTotal = unpaidRaw is num ? unpaidRaw.toDouble() : double.tryParse(unpaidRaw?.toString() ?? '') ?? 0.0;
    final hasPartialPayment = paidTotal > 0 && unpaidTotal > 0;

    // Bekleme süresi rengi — masada TESLIM EDILMEMIS bekleyen urun varsa,
    // o urunun girilis zamanina gore renk degisir. Tum urunler teslimse normal renk.
    // 0-10 dk yesil (taze), 10-20 dk sari (uyari), 20+ dk kirmizi (gec kaldi).
    final tableId = table['id'] as int?;
    final oldestPending = tableId != null ? _oldestPendingByTable[tableId] : null;
    final hasPending = oldestPending != null;
    final waitSeconds = hasPending ? DateTime.now().difference(oldestPending).inSeconds : 0;
    // 19 May 2026: Mutfaga gitmemis urun var mi (printed=0 olan item)
    final hasUnprinted = tableId != null && _unprintedByTable.contains(tableId);
    // 11 Haz 2026: Fis cikmadi mi (backend print_failed=true, printed=1 olsa bile
    // mutfak fisi timeout/failed). hasUnprinted'tan ayri TURUNCU badge.
    final hasPrintFailed = tableId != null && _printFailedByTable.contains(tableId);

    Color tableBorder;
    Gradient? tableGradient;
    if (!isOccupied) {
      tableBorder = Colors.grey[300]!;
      tableGradient = null;
    } else if (hasPending && waitSeconds >= 1200) {
      tableBorder = const Color(0xFFB91C1C);
      tableGradient = const LinearGradient(
        colors: [Color(0xFFDC2626), Color(0xFFB91C1C)],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      );
    } else if (hasPending && waitSeconds >= 600) {
      tableBorder = const Color(0xFFD97706);
      tableGradient = const LinearGradient(
        colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      );
    } else {
      // Hic bekleyen yok VEYA bekleyen var ama 10dk altinda -> normal tema rengi
      tableBorder = theme.primaryColor;
      tableGradient = theme.backgroundGradient;
    }

    return GestureDetector(
      onTap: () => _openTable(table),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // 22 May 2026: Tum metin/padding kutu boyutuna gore olcekleniyor.
          // Bug: Alt katta cok masa olunca kartlar kucuk, sabit font'lar
          // (8/10/14/24) tasiyordu. Olcum: 140px referans width — bunun
          // altinda font'lar kuculur, ustunde olceklenir (max 1.35x).
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final scale = ((w + h) / 2 / 140).clamp(0.55, 1.35);

          // Olcekli font/padding hesaplari
          double fs(double base) => (base * scale).clamp(7.0, 48.0);
          double sp(double base) => (base * scale).clamp(1.0, 24.0);

          return Container(
            decoration: BoxDecoration(
              gradient: isOccupied ? tableGradient : null,
              color: isOccupied ? null : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasUnprinted
                    ? const Color(0xFFDC2626)
                    : (hasPrintFailed
                        ? const Color(0xFFF97316)
                        : (isOccupied ? tableBorder : Colors.grey[300]!)),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: hasUnprinted
                      ? const Color(0xFFDC2626).withValues(alpha: 0.4)
                      : (hasPrintFailed
                          ? const Color(0xFFF97316).withValues(alpha: 0.4)
                          : Colors.black.withValues(alpha: 0.05)),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            padding: EdgeInsets.symmetric(horizontal: sp(4), vertical: sp(6)),
            child: Column(
              mainAxisAlignment: isOccupied ? MainAxisAlignment.start : MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isOccupied) SizedBox(height: sp(4)),
                // Table number (en buyuk)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    tableNumber,
                    maxLines: 1,
                    style: TextStyle(
                      color: isOccupied ? Colors.white : const Color(0xFF1F2937),
                      fontSize: fs(isOccupied ? 24 : 32),
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                    ),
                  ),
                ),
                SizedBox(height: sp(isOccupied ? 4 : 6)),

                // Status badge (Dolu / Bos / MUTFAGA GITMEDI / FIS CIKMADI)
                // Oncelik: hasUnprinted (kirmizi, hic gonderilmemis) > hasPrintFailed
                // (turuncu, gonderildi ama fis cikmadi) > Dolu/Bos.
                Container(
                  padding: EdgeInsets.symmetric(horizontal: sp(8), vertical: sp(2)),
                  decoration: BoxDecoration(
                    color: hasUnprinted
                        ? const Color(0xFFDC2626)
                        : (hasPrintFailed
                            ? const Color(0xFFF97316)
                            : (isOccupied
                                ? Colors.white.withValues(alpha: 0.2)
                                : Colors.grey[100])),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      hasUnprinted
                          ? 'MUTFAĞA GİTMEDİ'
                          : (hasPrintFailed ? 'FİŞ ÇIKMADI' : (isOccupied ? 'Dolu' : 'Boş')),
                      maxLines: 1,
                      style: TextStyle(
                        color: (hasUnprinted || hasPrintFailed || isOccupied)
                            ? Colors.white
                            : Colors.grey[600],
                        fontSize: fs(isOccupied ? 10 : 12),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),

                // Total (occupied)
                if (isOccupied) ...[
                  SizedBox(height: sp(3)),
                  if (hasPartialPayment) ...[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${unpaidTotal.toStringAsFixed(0)} TL',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.orange[200],
                          fontSize: fs(14),
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                        ),
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Ödenen: ${paidTotal.toStringAsFixed(0)} TL',
                        maxLines: 1,
                        style: TextStyle(color: Colors.green[200], fontSize: fs(9), fontWeight: FontWeight.w600),
                      ),
                    ),
                  ] else ...[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${total.toStringAsFixed(0)} TL',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: fs(14),
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ],
                ],

                // Açılış + son sipariş + süre (occupied)
                if (isOccupied && openedByDevice != null) ...[
                  SizedBox(height: sp(2)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Kasa: $openedByDevice',
                      maxLines: 1,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: fs(9),
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ),
                ],
                if (isOccupied && openedAt != null) ...[
                  SizedBox(height: sp(2)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Açılış: ${_formatTime(openedAt)}',
                      maxLines: 1,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: fs(9),
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                  ),
                  if (lastItemAt != null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Son: ${_formatTime(lastItemAt)}',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: fs(9),
                          height: 1.1,
                        ),
                      ),
                    ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _formatDuration(openedAt),
                      maxLines: 1,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: fs(9),
                        height: 1.1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }


  Widget _buildStatusLegend(ThemeProvider theme) {
    // Bekleme threshold'una gore aciklama (0-10 yesil, 10-20 sari, 20+ kirmizi)
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 24,
        runSpacing: 8,
        children: [
          _buildLegendItem('Bos', _emptyCount, Colors.grey[300]!),
          _buildLegendItem('Yeni (0-10dk)', null, theme.primaryColor),
          _buildLegendItem('Bekliyor (10-20dk)', null, const Color(0xFFF59E0B)),
          _buildLegendItem('Geç Kaldı (20+dk)', null, const Color(0xFFDC2626)),
          _buildLegendItem('Dolu Toplam', _occupiedCount, Colors.grey[600]!),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, int? count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          count == null ? label : '$label: $count',
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _formatTime(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return '';
    }
  }

  // Verilen ISO tarihinden bu yana geçen dakika (UTC parse + lokal compare).
  // Masa rengi threshold'u (10/20 dk) için kullanılır.
  int _minutesSince(String iso) {
    try {
      return DateTime.now().difference(DateTime.parse(iso).toLocal()).inMinutes;
    } catch (_) {
      return 0;
    }
  }

  String _formatDuration(String openedAt) {
    try {
      final opened = DateTime.parse(openedAt).toLocal();
      final now = DateTime.now();
      final diff = now.difference(opened);

      if (diff.inMinutes < 60) {
        return '${diff.inMinutes} dk';
      } else {
        final hours = diff.inHours;
        final mins = diff.inMinutes % 60;
        return '${hours}s ${mins}dk';
      }
    } catch (e) {
      return '';
    }
  }

  Color _parseColor(String colorStr) {
    try {
      // # işaretini kaldır ve parse et
      String hex = colorStr.replaceAll('#', '');
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    } catch (e) {
      print('[Tables] Renk parse hatası: $colorStr - $e');
      return Provider.of<ThemeProvider>(context, listen: false).primaryColor;
    }
  }
}
