import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'local_db_service.dart';
import 'connectivity_service.dart';
import 'image_cache_service.dart';
import 'log_service.dart';

/// API key geçersiz veya pasif olduğunda fırlatılır
class ApiKeyInvalidException implements Exception {
  final String message;
  ApiKeyInvalidException(this.message);

  @override
  String toString() => message;
}

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final LocalDbService _localDb = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();
  final ImageCacheService _imageCache = ImageCacheService();
  final LogService _logService = LogService();

  Dio? _dio;
  Timer? _syncTimer;
  // 11 Haz 2026 LEAK FIX: 30sn cache timer eskiden değişkene atanmıyordu →
  // dispose'da cancel EDİLEMİYORDU (init tekrar çağrılırsa ölümsüz timer birikir).
  Timer? _cacheUpdateTimer;
  StreamSubscription? _connectivitySub; // eskiden tutulmuyordu → cancel edilemiyordu
  bool _isBgUpdating = false;           // backgroundCacheUpdate re-entry guard
  bool _isSyncing = false;
  // 6 Tem 2026 (offline fix Adim 5): 10sn sync tick sayaci. Her 3. tikta (~30sn) tablo-sync +
  // cleanup da calisir. Boylece connectionStream event'i gelmeyen (fake-online->gercek-online,
  // NIC hic dusmemis) durumda da toparlanma olur.
  int _syncTick = 0;
  bool _isTableReconciling = false;     // _syncTablesFromServer+cleanup re-entry guard
  // 17 Tem 2026: tarama 30sn→5dk gevşetildi (push canlı); açık-masa aynası AYRI 90sn döngüye alındı.
  Timer? _mirrorTimer;
  bool _isMirroring = false;            // _runMirrorCycle re-entry guard
  DateTime? _lastBgUpdateAt;            // sweepAfterReconnect debounce için (SADECE başarılı taramada set)
  DateTime? _lastDisconnectAt;          // kesinti-farkındalıklı debounce (Fable filo bulgusu #11)
  bool _pendingSweep = false;           // tarama sürerken gelen reconnect telafisi kuyruğu (#0)
  final Random _jitterRandom = Random(); // thundering herd jitter (#12)
  bool _isInitialSyncDone = false;
  String? _backendUrl;

  // Progress callback for UI
  void Function(String message, double progress)? onSyncProgress;

  // Settings callback for theme updates
  void Function(Map<String, dynamic> settings)? onSettingsLoaded;

  // 21 Tem 2026: settings fan-out — onSettingsLoaded TEK-SLOT (tema, initial_sync sahibi).
  // tables_screen poll süresini (table_poll_sec/badge_poll_sec) backend'den okuyabilsin diye EK
  // listener; TEK-SLOT EZILMEZ (websocket_service fan-out deseniyle aynı). Bir listener'ın
  // exception'ı diğerlerini/slotu öldürmez (her biri try/catch).
  final List<void Function(Map<String, dynamic>)> _settingsListeners = [];
  void addSettingsListener(void Function(Map<String, dynamic>) l) {
    if (!_settingsListeners.contains(l)) _settingsListeners.add(l);
  }
  void removeSettingsListener(void Function(Map<String, dynamic>) l) {
    _settingsListeners.remove(l);
  }
  void _notifySettingsLoaded(Map<String, dynamic> settings) {
    onSettingsLoaded?.call(settings);
    for (final l in List<void Function(Map<String, dynamic>)>.from(_settingsListeners)) {
      try { l(settings); } catch (e) { print('[Sync] settings listener hata: $e'); }
    }
  }

  void setBackendUrl(String? url) {
    _backendUrl = url;
  }

  String _getFullImageUrl(String path) {
    if (path.startsWith('http')) return path;
    if (_backendUrl == null) return path;
    return '$_backendUrl$path';
  }

  Future<void> init(Dio dio) async {
    _dio = dio;

    // Image cache'i başlat
    await _imageCache.init();

    // 11 Haz 2026 LEAK FIX: init tekrar çağrılırsa (ileride) eski timer/sub birikmesin.
    _syncTimer?.cancel();
    _cacheUpdateTimer?.cancel();
    _mirrorTimer?.cancel();
    _connectivitySub?.cancel();

    // İnternet durumu değişince sync başlat (sub saklanıyor → dispose'da cancel)
    _connectivitySub = _connectivity.connectionStream.listen((isOnline) async {
      if (isOnline) {
        print('[Sync] Online oldu, sync başlatılıyor...');
        // 17 Tem 2026 (filo #2): her adım kendi try/catch'inde — biri patlarsa zincirin
        // gerisi (özellikle reconnect telafisi) atlanmasın.
        try { await syncPendingItems(); } catch (e) { print('[Sync] online sync hatası: $e'); }
        try { await _syncTablesFromServer(); } catch (e) { print('[Sync] online tablo-sync hatası: $e'); }
        try { await _localDb.cleanupSyncedTickets(); } catch (e) { print('[Sync] cleanup hatası: $e'); }
        // İnternet kesikken kaçan cache:invalidate eventlerini telafi et (debounce'lu)
        try { await sweepAfterReconnect(); } catch (e) { print('[Sync] reconnect tarama hatası: $e'); }
      } else {
        markDisconnected(); // filo #11: kesinti anını kaydet (debounce referansı)
      }
    });

    // Periyodik sync (her 10 saniye)
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_connectivity.isOnline) return;
      await syncPendingItems();
      // 6 Tem 2026 (offline fix Adim 5): Her ~30sn'de (3. tik) tablo-sync + cleanup DA calis.
      // connectionStream event'i SADECE NIC degisince gelir; fake-online->gercek-online (WiFi
      // hic dusmemis) durumda o event gelmez -> _syncTablesFromServer/cleanup HIC calismazdi.
      // Periyodik cagri bu bosslugu kapatir. re-entry guard ile uste binmeyi onle.
      _syncTick++;
      if (_syncTick % 3 == 0 && !_isTableReconciling) {
        _isTableReconciling = true;
        try {
          await _syncTablesFromServer();
          await _localDb.cleanupSyncedTickets();
        } catch (e) {
          print('[Sync] Periyodik tablo-sync hatasi: $e');
        } finally {
          _isTableReconciling = false;
        }
      }
    });

    // Periyodik cache güncelleme — 17 Tem 2026: 30sn → 5dk GEVŞETİLDİ. Push (cache:invalidate,
    // 'panel-<id>' odası) artık canlı ve 11/11 tip kanıtlı; bu tarama yalnızca push'u kaçıran
    // durumlar için EMNİYET süpürgesi (reconnect telafisi ayrıca sweepAfterReconnect'te).
    // 11 Haz 2026: değişkene atandı (eskiden anonimdi, cancel edilemiyordu).
    _cacheUpdateTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_connectivity.isOnline) {
        backgroundCacheUpdate();
      }
    });

    // 17 Tem 2026: Açık-masa offline AYNASI taramadan ayrıldı — tarama 5dk'ya çıkınca ayna
    // bayatlamasın diye kendi hafif döngüsünde döner (masa listesi + açık masaların ticket'ı).
    _mirrorTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (_connectivity.isOnline) {
        _runMirrorCycle();
      }
    });
  }

  /// İlk girişte tüm verileri indir ve cache'le
  Future<void> performInitialSync() async {
    if (!_connectivity.isOnline || _dio == null) {
      print('[Sync] İlk sync için internet gerekli!');
      _logService.warning(LogType.sync, 'Ilk sync basarisiz: internet yok');
      return;
    }

    if (_isInitialSyncDone) {
      print('[Sync] İlk sync zaten yapıldı');
      return;
    }

    print('[Sync] ========== İLK SYNC BAŞLIYOR ==========');
    _logService.logSync('Ilk sync baslatildi', operation: 'initial_sync_start');

    try {
      // 1. Kategoriler
      _reportProgress('Kategoriler indiriliyor...', 0.1);
      final categoriesResponse = await _dio!.get('/api/pos/categories');
      if (categoriesResponse.data is List) {
        await _localDb.cacheCategories(List<Map<String, dynamic>>.from(categoriesResponse.data));
        print('[Sync] Kategoriler: ${(categoriesResponse.data as List).length}');
      }

      // 2. Ürünler
      _reportProgress('Ürünler indiriliyor...', 0.2);
      final productsResponse = await _dio!.get('/api/pos/products');
      List<Map<String, dynamic>> products = [];
      if (productsResponse.data is List) {
        products = List<Map<String, dynamic>>.from(productsResponse.data);
        await _localDb.cacheProducts(products);
        print('[Sync] Ürünler: ${products.length}');
      }

      // 3. Ürün görselleri
      _reportProgress('Ürün görselleri indiriliyor...', 0.3);
      await _downloadProductImages(products);

      // 4. Salonlar
      _reportProgress('Salonlar indiriliyor...', 0.5);
      final sectionsResponse = await _dio!.get('/api/pos/tables/sections');
      if (sectionsResponse.data is List) {
        await _localDb.cacheSections(List<Map<String, dynamic>>.from(sectionsResponse.data));
        print('[Sync] Salonlar: ${(sectionsResponse.data as List).length}');
      }

      // 5. Masalar
      _reportProgress('Masalar indiriliyor...', 0.6);
      final tablesResponse = await _dio!.get('/api/pos/tables');
      if (tablesResponse.data is List) {
        await _localDb.cacheTables(List<Map<String, dynamic>>.from(tablesResponse.data));
        print('[Sync] Masalar: ${(tablesResponse.data as List).length}');
      }

      // 6. Tüm garsonlar
      _reportProgress('Garsonlar indiriliyor...', 0.8);
      await _cacheAllWaiters();

      // 7a. Yazicilar (offline mutfak fisi icin)
      try {
        final printersResponse = await _dio!.get('/api/pos/printers');
        if (printersResponse.data is List) {
          await _localDb.cachePrinters(List<Map<String, dynamic>>.from(printersResponse.data));
          print('[Sync] Yazicilar: ${(printersResponse.data as List).length}');
        }
      } catch (e) {
        print('[Sync] Yazicilar alinamadi (opsiyonel): $e');
      }

      // 7b. Lookup verileri (cancel_reasons, product_notes, global_variants, global_extras,
      //     ikram_reasons). Offline'da iptal popup, urun notu, varyant, ekstra, ikram calismasi icin
      _reportProgress('Tanimlamalar indiriliyor...', 0.85);
      try {
        await Future.wait([
          _dio!.get('/api/pos/cancel-reasons').then((r) async {
            final list = (r.data as List?) ?? [];
            final rows = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            await _localDb.cacheLookups(lookupType: 'cancel_reasons', rows: rows);
            // v20: dedicated tablo (offline iptal sebep garantisi) — cift kaynak degil,
            // okuma once dedicated'a bakar (getCachedCancelReasons).
            await _localDb.cacheCancelReasons(rows);
          }),
          // v20 IKRAM: sebep listesi offline'da da secilebilsin
          _dio!.get('/api/pos/settings-extra/ikram-reasons').then((r) async {
            final data = r.data;
            final list = data is List ? data : (data is Map ? ((data['reasons'] as List?) ?? []) : []);
            await _localDb.cacheIkramReasons(
              list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
            );
          }).catchError((e) {
            // Uc eski backend'de olmayabilir — ikram cache atlanir, DIGER lookuplar etkilenmez
            print('[Sync] ikram-reasons alinamadi (opsiyonel): $e');
          }),
          _dio!.get('/api/pos/product-notes').then((r) async {
            final list = (r.data as List?) ?? [];
            await _localDb.cacheLookups(
              lookupType: 'product_notes',
              rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
          _dio!.get('/api/pos/global/variants/active').then((r) async {
            final list = (r.data as List?) ?? [];
            await _localDb.cacheLookups(
              lookupType: 'global_variants',
              rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
          _dio!.get('/api/pos/global/extras/active').then((r) async {
            final list = (r.data as List?) ?? [];
            await _localDb.cacheLookups(
              lookupType: 'global_extras',
              rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
        ]);
        print('[Sync] Lookup verileri cache\'lendi');
      } catch (e) {
        print('[Sync] Lookup cache hatasi (opsiyonel): $e');
      }

      // 8. Ayarlar (varsa)
      _reportProgress('Ayarlar indiriliyor...', 0.9);
      try {
        final settingsResponse = await _dio!.get('/api/pos/settings');
        if (settingsResponse.data != null) {
          final settings = Map<String, dynamic>.from(settingsResponse.data);
          await _localDb.cacheSettings(settings);
          print('[Sync] Ayarlar cache\'lendi');

          // Tema güncellemesi için callback + fan-out (poll süresi vb)
          _notifySettingsLoaded(settings);
        }
      } catch (e) {
        print('[Sync] Ayarlar alınamadı (opsiyonel): $e');
      }

      _reportProgress('Sync tamamlandı!', 1.0);
      _isInitialSyncDone = true;

      // Cache boyutunu göster
      final cacheSize = await _imageCache.getCacheSizeFormatted();
      print('[Sync] ========== İLK SYNC TAMAMLANDI ==========');
      print('[Sync] Görsel cache boyutu: $cacheSize');

      _logService.logSync('Ilk sync tamamlandi', operation: 'initial_sync_complete', count: products.length);

    } on DioException catch (e) {
      print('[Sync] İlk sync DioException: ${e.response?.statusCode}');

      // 401/403 = API key geçersiz veya pasif
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        _logService.error(LogType.sync, 'API key gecersiz veya pasif', details: {
          'status': e.response?.statusCode,
          'error': e.response?.data?['error'],
        });
        throw ApiKeyInvalidException(
          e.response?.data?['error'] ?? 'API key geçersiz veya lisans pasif edilmiş.',
        );
      }

      _logService.logSyncError('Ilk sync hatasi', operation: 'initial_sync', error: e);
      rethrow;
    } catch (e) {
      print('[Sync] İlk sync hatası: $e');
      _logService.logSyncError('Ilk sync hatasi', operation: 'initial_sync', error: e);
      rethrow;
    }
  }

  void _reportProgress(String message, double progress) {
    print('[Sync] $message (${(progress * 100).toInt()}%)');
    onSyncProgress?.call(message, progress);
  }

  /// Tüm ürün görsellerini indir
  Future<void> _downloadProductImages(List<Map<String, dynamic>> products) async {
    final imageUrls = <String>[];

    for (final product in products) {
      final image = product['image'];
      if (image != null && image.toString().isNotEmpty) {
        // Tam URL oluştur
        String imageUrl = image.toString();
        if (!imageUrl.startsWith('http')) {
          imageUrl = _getFullImageUrl(imageUrl);
        }
        imageUrls.add(imageUrl);
      }
    }

    print('[Sync] ${imageUrls.length} görsel indirilecek...');

    // 1 Haz 2026 (v1.5.6) — Menüde olmayan resimleri sil (stale cache prune)
    // Fire-and-forget: download ile paralel çalışır, UI bloklamaz.
    unawaited(_imageCache.pruneByActiveUrls(imageUrls.toSet()));

    int downloaded = 0;
    int failed = 0;

    // Paralel indirme (5'er 5'er)
    for (var i = 0; i < imageUrls.length; i += 5) {
      final batch = imageUrls.skip(i).take(5).toList();
      final results = await _imageCache.downloadMultiple(batch);
      downloaded += results.length;
      failed += batch.length - results.length;

      final progress = 0.3 + (0.2 * (i + batch.length) / imageUrls.length);
      _reportProgress('Görseller: ${i + batch.length}/${imageUrls.length}', progress);
    }

    print('[Sync] Görseller: $downloaded başarılı, $failed başarısız');
  }

  /// Tüm garsonları API'den al ve cache'le
  Future<void> _cacheAllWaiters() async {
    try {
      final response = await _dio!.get('/api/pos/waiters');
      if (response.data is List) {
        final waiters = List<Map<String, dynamic>>.from(response.data);
        for (final waiter in waiters) {
          await cacheWaiter(waiter);
        }
        print('[Sync] Garsonlar: ${waiters.length}');
      }
    } catch (e) {
      print('[Sync] Garsonlar alınamadı: $e');
      // Hata olsa bile devam et
    }
  }

  /// Cache'in dolu olup olmadığını kontrol et
  Future<bool> isCacheReady() async {
    final categories = await _localDb.getCachedCategories();
    final products = await _localDb.getCachedProducts();
    final tables = await _localDb.getCachedTables();

    return categories.isNotEmpty && products.isNotEmpty && tables.isNotEmpty;
  }

  /// Cache'in güncel olup olmadığını kontrol et
  /// Online ise ve 1 saatten eskiyse güncelleme öner
  Future<bool> shouldUpdateCache() async {
    if (!_connectivity.isOnline) return false;

    final isStale = await _localDb.isCacheStale('cached_products', maxAge: const Duration(hours: 1));
    return isStale;
  }

  /// Arka planda cache'i güncelle (kullanıcıyı bekletmeden)
  Future<void> backgroundCacheUpdate() async {
    if (!_connectivity.isOnline || _dio == null) return;
    // 11 Haz 2026 GUARD: yavaş ağda bir update 30sn'den uzun sürerse 2. timer tetiği
    // üst üste binmesin (CPU/ağ birikmesi → donma). syncPendingItems'taki _isSyncing pattern'i.
    if (_isBgUpdating) {
      print('[Sync] Arka plan güncelleme zaten çalışıyor, atlandı');
      return;
    }
    _isBgUpdating = true;
    // NOT: _lastBgUpdateAt burada DEĞİL, taramanın BAŞARILI sonunda set edilir (filo bulgusu #0/#20:
    // başarısız tarama da 'yapıldı' sayılıp reconnect telafisini 5dk erteliyordu).

    // 23 Tem 2026: rutin baslatildi/tamamlandi sunucu loglari KALDIRILDI (5dk'lik dongu
    // kasa basina gunde ~576 satir pos_logs sisiriyordu). Hata dali sunucuya loglanmaya
    // DEVAM eder (asagida, artik hangi URL oldugu da yazilir). Lokal print yeterli.
    print('[Sync] Arka plan güncelleme başlıyor...');

    try {
      // 1. Ürünleri güncelle
      final productsResponse = await _dio!.get('/api/pos/products');
      if (productsResponse.data is List) {
        final products = List<Map<String, dynamic>>.from(productsResponse.data);
        final cachedProducts = await _localDb.getCachedProducts();

        // Değişen ürünleri bul (ad, fiyat, görsel, içerik vb.)
        final changedProducts = <Map<String, dynamic>>[];
        final newImageUrls = <String>[];

        for (final product in products) {
          final cached = cachedProducts.firstWhere(
            (c) => c['id'] == product['id'],
            orElse: () => <String, dynamic>{},
          );

          if (cached.isEmpty) {
            // Yeni ürün
            changedProducts.add(product);
            if (product['image'] != null && product['image'].toString().isNotEmpty) {
              newImageUrls.add(_getFullImageUrl(product['image']));
            }
          } else {
            // Mevcut ürün - değişiklik var mı?
            final changed = _isProductChanged(cached, product);
            if (changed) {
              changedProducts.add(product);
              // Görsel değiştiyse yeni görseli indir
              if (cached['image'] != product['image'] &&
                  product['image'] != null &&
                  product['image'].toString().isNotEmpty) {
                newImageUrls.add(_getFullImageUrl(product['image']));
              }
            }
          }
        }

        // 17 Tem 2026 (filo KRİTİK bulgusu #4): cacheProducts KOŞULSUZ çağrılır. Diff sadece
        // GÖRSEL indirme içindir — çünkü (a) /api/pos/products sadece aktif+stokta ürünleri döner,
        // listeden ÇIKAN ürün (stok bitti/pasif/silindi) diff'e hiç girmez; (b) variants/extras/
        // combo/printer_id alanları diff'te yok. Full yazım 5dk'da bir = eski 30sn davranışına göre
        // yine 10x az yük, ama silinen/değişen her şey garantili yakalanır.
        await _localDb.cacheProducts(products);
        if (changedProducts.isNotEmpty) {
          print('[Sync] ${changedProducts.length} ürün değişti (görsel diff)');
        }
        if (newImageUrls.isNotEmpty) {
          print('[Sync] ${newImageUrls.length} yeni görsel indiriliyor...');
          await _imageCache.downloadMultiple(newImageUrls);
        }
      }

      // 2. Kategorileri güncelle
      final categoriesResponse = await _dio!.get('/api/pos/categories');
      if (categoriesResponse.data is List) {
        await _localDb.cacheCategories(List<Map<String, dynamic>>.from(categoriesResponse.data));
      }

      // 3. Masaları güncelle
      final tablesResponse = await _dio!.get('/api/pos/tables');
      if (tablesResponse.data is List) {
        final tables = List<Map<String, dynamic>>.from(tablesResponse.data);
        await _localDb.cacheTables(tables);
        // 7 Tem 2026: BULK MIRROR — acik masalarin TAM iceriğini (urunler+tutar) lokale indir
        // ki internet gidince masaya tiklayinca detay + kapatma + mutfak fisi hazir olsun.
        // Kapanan masalarin mirror'u prune edilir (DB SISMEZ). Best-effort; hata online akisi bozmaz.
        try {
          await _mirrorOpenTables(tables);
        } catch (e) {
          print('[Sync] Bulk mirror atlandi: $e');
        }
      }

      // 4. Salonları güncelle
      final sectionsResponse = await _dio!.get('/api/pos/tables/sections');
      if (sectionsResponse.data is List) {
        await _localDb.cacheSections(List<Map<String, dynamic>>.from(sectionsResponse.data));
      }

      // 5. Garsonları güncelle
      await _cacheAllWaiters();

      // 6. Ayarları güncelle (tema için önemli)
      try {
        final settingsResponse = await _dio!.get('/api/pos/settings');
        if (settingsResponse.data != null) {
          final settings = Map<String, dynamic>.from(settingsResponse.data);
          await _localDb.cacheSettings(settings);
          print('[Sync] Ayarlar güncellendi');

          // Tema güncellemesi için callback + fan-out (poll süresi vb)
          _notifySettingsLoaded(settings);
        }
      } catch (e) {
        print('[Sync] Ayarlar güncellenemedi: $e');
      }

      // 6b. Yazicilar (offline mutfak fisi icin)
      try {
        final printersResponse = await _dio!.get('/api/pos/printers');
        if (printersResponse.data is List) {
          await _localDb.cachePrinters(List<Map<String, dynamic>>.from(printersResponse.data));
        }
      } catch (e) {
        print('[Sync] Yazici cache update hatasi: $e');
      }

      // 7. Lookup verileri (cancel_reasons, product_notes, global_variants, global_extras,
      //    ikram_reasons)
      try {
        await Future.wait([
          _dio!.get('/api/pos/cancel-reasons').then((r) async {
            final rows = ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            await _localDb.cacheLookups(lookupType: 'cancel_reasons', rows: rows);
            await _localDb.cacheCancelReasons(rows); // v20 dedicated tablo
          }),
          // v20 IKRAM: sebep listesi cache guncelle (uc yoksa opsiyonel — digerleri etkilenmez)
          _dio!.get('/api/pos/settings-extra/ikram-reasons').then((r) async {
            final data = r.data;
            final list = data is List ? data : (data is Map ? ((data['reasons'] as List?) ?? []) : []);
            await _localDb.cacheIkramReasons(
              list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
            );
          }).catchError((e) {
            print('[Sync] ikram-reasons cache update hatasi (opsiyonel): $e');
          }),
          _dio!.get('/api/pos/product-notes').then((r) async {
            await _localDb.cacheLookups(
              lookupType: 'product_notes',
              rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
          _dio!.get('/api/pos/global/variants/active').then((r) async {
            await _localDb.cacheLookups(
              lookupType: 'global_variants',
              rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
          _dio!.get('/api/pos/global/extras/active').then((r) async {
            await _localDb.cacheLookups(
              lookupType: 'global_extras',
              rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
            );
          }),
        ]);
      } catch (e) {
        print('[Sync] Lookup cache update hatasi: $e');
      }

      _lastBgUpdateAt = DateTime.now(); // BAŞARILI tamamlanma — debounce referansı (filo #0)
      print('[Sync] Arka plan güncelleme tamamlandı');
    } catch (e) {
      print('[Sync] Arka plan güncelleme hatası: $e');
      // 23 Tem 2026: DioException toString'i URL icermiyor, hangi endpoint'in timeout
      // oldugu teshis edilemiyordu — path'i mesaja ekle.
      final hataYolu = (e is DioException) ? (e.requestOptions.path) : '';
      _logService.logSyncError(
        hataYolu.isNotEmpty
            ? 'Arka plan cache guncellemesi hatasi ($hataYolu)'
            : 'Arka plan cache guncellemesi hatasi',
        operation: 'background_update', error: e);
    } finally {
      // 11 Haz 2026: guard mutlaka serbest bırakılmalı (yoksa kalıcı kilit → bir daha hiç çalışmaz)
      _isBgUpdating = false;
      // 17 Tem 2026 (filo #0): tarama sürerken reconnect telafisi geldiyse bir tur daha —
      // süren tarama kesinti ÖNCESİ fetch'lenmiş bayat veriyle çalışmış olabilir.
      if (_pendingSweep) {
        _pendingSweep = false;
        Timer.run(() {
          if (_connectivity.isOnline) backgroundCacheUpdate();
        });
      }
    }
  }

  /// 17 Tem 2026: Soket/internet KESİLDİĞİNDE çağrılır (main.dart onConnectionChange(false) +
  /// connectivity offline) — kesinti-farkındalıklı debounce referansı (filo #11).
  void markDisconnected() {
    _lastDisconnectAt = DateTime.now();
  }

  /// 17 Tem 2026: Soket/internet geri geldiğinde kaçan cache:invalidate eventlerini telafi eden
  /// tam tarama. Debounce kuralı (filo #0/#11): son BAŞARILI tarama, son KESİNTİDEN SONRA bittiyse
  /// ve 60sn'den tazeyse atla; kesintiden önce bittiyse veri bayat olabilir → tara. Tarama sürüyorsa
  /// kuyruğa yaz (finally'de bir tur daha koşar). Jitter (filo #12): panel restart'ında tüm kasalar
  /// aynı anda bağlanır — 0.5-15sn rastgele gecikme thundering herd'ü dağıtır.
  Future<void> sweepAfterReconnect() async {
    final last = _lastBgUpdateAt;
    final disc = _lastDisconnectAt;
    if (last != null &&
        (disc == null || last.isAfter(disc)) &&
        DateTime.now().difference(last) < const Duration(seconds: 60)) {
      print('[Sync] Reconnect taraması atlandı (son tarama taze ve kesinti sonrası)');
      return;
    }
    if (_isBgUpdating) {
      _pendingSweep = true;
      print('[Sync] Reconnect taraması kuyruklandı (tarama sürüyor)');
      return;
    }
    await Future.delayed(Duration(milliseconds: 500 + _jitterRandom.nextInt(14500)));
    if (!_connectivity.isOnline) return; // jitter sırasında tekrar koptuysa boşuna deneme
    await backgroundCacheUpdate();
  }

  /// 17 Tem 2026: Hafif ayna döngüsü (90sn) — SADECE masa listesi + açık masaların ticket mirror'ı.
  /// Tam tarama 5dk'ya gevşetilince offline açık-masa aynasının tazeliğini bu döngü korur.
  Future<void> _runMirrorCycle() async {
    // filo #1/#13: bg tarama zaten mirror yapıyor — eşzamanlı çift prune/upsert yarışına girme
    if (_isMirroring || _isBgUpdating || _dio == null) return;
    if (!_connectivity.isOnline) return;
    _isMirroring = true;
    try {
      final r = await _dio!.get('/api/pos/tables');
      if (r.data is List) {
        final tables = List<Map<String, dynamic>>.from(r.data);
        await _localDb.cacheTables(tables);
        await _mirrorOpenTables(tables);
      }
    } catch (e) {
      print('[Sync] Ayna döngüsü hatası: $e');
    } finally {
      _isMirroring = false;
    }
  }

  /// 7 Tem 2026: Açık masaların tam içeriğini (ürünler+tutar) lokale mirror'la + kapananları prune et.
  /// Toplu açık-ticket endpoint YOK (504) -> her açık masa için ayrı /tickets/table/{id}, havuz-limitli
  /// (aynı anda 4 istek) ki 2sn'lik poll yükünü artırmasın. Çağıranlar: backgroundCacheUpdate (5dk
  /// tam tarama) + _runMirrorCycle (90sn hafif döngü, 17 Tem 2026).
  Future<void> _mirrorOpenTables(List<Map<String, dynamic>> tables) async {
    if (_dio == null) return;
    final openIds = <int>{};
    for (final t in tables) {
      final id = t['id'];
      final occupied = t['status'] == 'occupied' || t['current_ticket_id'] != null;
      if (id is int && occupied) openIds.add(id);
    }
    // Kapanan masaların mirror'unu temizle (DB şişmesin) — açık olmayan tüm mirror'lar.
    try {
      await _localDb.pruneMirroredTicketsExcept(openIds);
    } catch (_) {}
    if (openIds.isEmpty) return;

    // Havuz-limitli mirror (aynı anda 4).
    const poolSize = 4;
    final idList = openIds.toList();
    for (var i = 0; i < idList.length; i += poolSize) {
      final batch = idList.skip(i).take(poolSize);
      await Future.wait(batch.map((tableId) async {
        try {
          final resp = await _dio!.get('/api/pos/tickets/table/$tableId');
          final t = resp.data is Map ? resp.data['ticket'] : null;
          if (t is Map<String, dynamic>) {
            await _localDb.upsertServerTicket(t);
          }
        } catch (_) {
          // tek masa hatası diğerlerini etkilemez
        }
      }));
    }
  }

  /// İki ürün arasında değişiklik var mı kontrol et.
  /// 17 Tem 2026 FIX: kaynaklar tip-farklı (SQLite REAL/0-1 vs JSON "430.00"/true/false) —
  /// düz toString karşılaştırması HER ürünü her taramada "değişti" sayıyordu ("315 ürün
  /// güncellendi" seli = gereksiz cache yazımı + görsel indirme). Sayısal alanlar double,
  /// boolean alanlar bool, metin alanları null≡'' normalize edilerek karşılaştırılır.
  double? _asDouble(dynamic v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse(v.toString()));

  bool _asBool(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  bool _isProductChanged(Map<String, dynamic> cached, Map<String, dynamic> newProduct) {
    const numFields = ['price', 'restaurant_price'];
    const boolFields = ['is_active', 'is_out_of_stock'];
    const textFields = ['name', 'description', 'image', 'category_id'];

    for (final field in numFields) {
      if (_asDouble(cached[field]) != _asDouble(newProduct[field])) {
        print('[Sync] Ürün ${newProduct['id']} değişti: $field');
        return true;
      }
    }
    for (final field in boolFields) {
      if (_asBool(cached[field]) != _asBool(newProduct[field])) {
        print('[Sync] Ürün ${newProduct['id']} değişti: $field');
        return true;
      }
    }
    for (final field in textFields) {
      final a = cached[field]?.toString() ?? '';
      final b = newProduct[field]?.toString() ?? '';
      if (a != b) {
        print('[Sync] Ürün ${newProduct['id']} değişti: $field');
        return true;
      }
    }
    return false;
  }

  Future<void> syncPendingItems() async {
    if (_isSyncing || _dio == null) return;
    if (!_connectivity.isOnline) return;

    _isSyncing = true;
    print('[Sync] Bekleyen işlemler kontrol ediliyor...');

    try {
      // Dependency-aware sync: Bağımlılığı olmayan veya bağımlılığı tamamlanmış olanları sırala
      final allPending = await _localDb.getPendingSyncItems();
      print('[Sync] Toplam ${allPending.length} bekleyen işlem');

      // Tamamlanmış sync_id'leri takip et
      final completedSyncIds = <int>{};

      // Önce bağımlılığı olmayanları işle
      for (final item in allPending) {
        final dependsOn = item['depends_on_sync_id'] as int?;

        if (dependsOn == null) {
          // Bağımlılık yok, direkt işle
          final success = await _processSyncItem(item);
          if (success) {
            completedSyncIds.add(item['id'] as int);
          }
        }
      }

      // Sonra bağımlılığı tamamlanmış olanları işle
      for (final item in allPending) {
        final dependsOn = item['depends_on_sync_id'] as int?;
        final syncId = item['id'] as int;

        if (dependsOn != null && !completedSyncIds.contains(syncId)) {
          // Bağımlılık tamamlandı mı kontrol et
          if (await _isDependencyCompleted(dependsOn)) {
            final success = await _processSyncItem(item);
            if (success) {
              completedSyncIds.add(syncId);
            }
          } else {
            // 🟠 FINAL-FIX B5: parent failed/dead_letter ise child SONSUZA bekler (retry islemez,
            // dead_letter'a asla gecmez). Kalici olu parent'ta child'i da fail'e dusur.
            if (await _failIfParentDead(syncId, 'dependency')) continue;
            print('[Sync] Bağımlılık henüz tamamlanmadı: $syncId depends on $dependsOn');
          }
        }
      }

      print('[Sync] Tüm işlemler tamamlandı');

      if (completedSyncIds.isNotEmpty) {
        _logService.logSync('Sync tamamlandi', count: completedSyncIds.length, operation: 'sync_complete');
      }

      // Sync tamamlandıktan sonra sunucudan güncel verileri çek ve cache'i güncelle
      if (completedSyncIds.isNotEmpty) {
        print('[Sync] Cache güncelleniyor...');
        await _refreshCacheAfterSync();
      }
    } catch (e) {
      print('[Sync] Hata: $e');
      _logService.logSyncError('Sync islemi basarisiz', operation: 'sync_pending', error: e);
    } finally {
      _isSyncing = false;
    }
  }

  // Sync sonrası cache'i güncelle
  Future<void> _refreshCacheAfterSync() async {
    try {
      // Masaları güncelle
      final tablesResponse = await _dio!.get('/api/pos/tables');
      if (tablesResponse.data is List) {
        await _localDb.cacheTables(List<Map<String, dynamic>>.from(tablesResponse.data));
        print('[Sync] Masa cache güncellendi');
      }

      // Salonları güncelle
      final sectionsResponse = await _dio!.get('/api/pos/tables/sections');
      if (sectionsResponse.data is List) {
        await _localDb.cacheSections(List<Map<String, dynamic>>.from(sectionsResponse.data));
        print('[Sync] Salon cache güncellendi');
      }

      // Sync edilmiş local ticket'ları temizle
      await _localDb.cleanupSyncedTickets();
      print('[Sync] Eski ticket\'lar temizlendi');
    } catch (e) {
      print('[Sync] Cache güncelleme hatası: $e');
    }
  }

  // Bağımlılık tamamlandı mı kontrol et
  Future<bool> _isDependencyCompleted(int syncId) async {
    final db = await _localDb.database;
    final result = await db.query(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [syncId],
    );

    if (result.isEmpty) {
      // Kayıt yok = tamamlanmış ve silinmiş olabilir
      return true;
    }

    final status = result.first['status'] as String?;
    return status == 'completed';
  }

  Future<bool> _processSyncItem(Map<String, dynamic> item) async {
    final syncId = item['id'] as int;
    final action = item['action'] as String;
    final entityType = item['entity_type'] as String;
    final localId = item['local_id'] as int?;
    final payload = _parsePayload(item['payload'] as String);
    final description = item['description'] as String? ?? '$action $entityType';

    print('[Sync] İşleniyor: $description (sync_id: $syncId)');

    try {
      switch (entityType) {
        case 'ticket':
          return await _syncTicket(action, localId, payload, syncId);
        case 'ticket_item':
          return await _syncTicketItem(action, localId, payload, syncId);
        default:
          print('[Sync] Bilinmeyen entity type: $entityType');
          await _localDb.markSyncFailed(syncId, 'Unknown entity type');
          return false;
      }
    } catch (e) {
      print('[Sync] İşlem hatası: $e');
      _logService.logSyncError(
        'Sync islemi basarisiz: $description',
        operation: '$action $entityType',
        error: e,
      );
      await _localDb.markSyncFailed(syncId, e.toString());
      return false;
    }
  }

  Map<String, dynamic> _parsePayload(String payloadStr) {
    try {
      // JSON olarak parse et
      return jsonDecode(payloadStr) as Map<String, dynamic>;
    } catch (e) {
      print('[Sync] Payload parse error: $e');
      // Eski format için fallback (geçiş dönemi)
      try {
        final cleaned = payloadStr.substring(1, payloadStr.length - 1);
        final pairs = cleaned.split(', ');
        final result = <String, dynamic>{};
        for (final pair in pairs) {
          final colonIndex = pair.indexOf(': ');
          if (colonIndex > 0) {
            final key = pair.substring(0, colonIndex).trim();
            var value = pair.substring(colonIndex + 2).trim();
            if (int.tryParse(value) != null) {
              result[key] = int.parse(value);
            } else if (double.tryParse(value) != null) {
              result[key] = double.parse(value);
            } else if (value == 'null') {
              result[key] = null;
            } else {
              result[key] = value;
            }
          }
        }
        return result;
      } catch (e2) {
        print('[Sync] Fallback parse error: $e2');
        return {};
      }
    }
  }

  Future<bool> _syncTicket(String action, int? localId, Map<String, dynamic> payload, int syncId) async {
    switch (action) {
      case 'create':
        // Önce local ticket bilgisini al (ticket_number için)
        final localTicket = await _localDb.getLocalTicket(localId!);
        final offlineTicketNumber = localTicket?['ticket_number'] as String?;

        // Adisyon aç
        final response = await _dio!.post('/api/pos/tickets/open', data: {
          'table_id': payload['table_id'],
          'waiter_id': payload['waiter_id'],
          'customer_count': payload['customer_count'] ?? 1,
          'is_offline': true, // Server'a offline'dan geldiğini bildir
          'offline_ticket_number': offlineTicketNumber, // OFFLINE-5-A1B2C3D4 formatında
        });

        if (response.data['success'] == true) {
          final serverId = response.data['ticket_id'] as int;
          final merged = response.data['merged'] == true;

          await _localDb.updateTicketServerId(localId!, serverId);
          await _localDb.markSyncComplete(syncId, serverId: serverId);

          // Ticket sync olduktan sonra tüm item'ların server_ticket_id'sini güncelle
          final items = await _localDb.getItemsByLocalTicketId(localId);
          for (final item in items) {
            await _localDb.updateItemServerTicketId(item['local_id'] as int, serverId);
          }

          if (merged) {
            print('[Sync] Ticket mevcut adisyona birleştirildi: local=$localId -> server=$serverId');
            _logService.logSync('Offline ticket birlesitirildi', operation: 'ticket_merge', count: 1);
          } else {
            print('[Sync] Ticket sync başarılı: local=$localId, server=$serverId');
            _logService.logSync('Ticket sync basarili', operation: 'ticket_create', count: 1);
          }
          return true;
        }
        _logService.logSyncError('Ticket create sync basarisiz', operation: 'ticket_create');
        return false;

      case 'close':
        // server_id resolve: payload'tan, lokal ticket'tan veya sync_queue.server_id'den
        final closeServerId = await _resolveServerTicketId(localId, syncId);
        if (closeServerId == null) {
          // FINAL-FIX B: parent kalici oluyse fail (sonsuz pending zombi onle), canliysa bekle.
          if (await _failIfParentDead(syncId, 'close')) return false;
          // Server'da henuz olusturulmamis -> tekrar dene
          print('[Sync] Close: Server ID resolve edilemedi, bekleniyor...');
          return false;
        }
        // 31 Tem 2026 — 404 = ISLEM ZATEN TAMAM. Backend verifyTicketOwnership SADECE
        // id+panel_id bakar; 404 "boyle bir adisyon yok" demektir (online kapatma zaten
        // gecti, adisyon silindi, ya da kayit baska kiraciya ait yetim). Yeniden denemek
        // ASLA basaramaz -> 3 tur sonra dead_letter -> kasada KALICI kirmizi "senkronize
        // olmuyor" uyarisi, oysa hicbir sey kayip degil. Kapatma/iptal dogasi geregi
        // idempotent: hedef durum zaten saglanmis. Diger hatalar (500/timeout) eskisi gibi
        // retry'a gider — SADECE 404 tamamlanmis sayilir.
        Response? closeResponse;
        try {
          closeResponse = await _dio!.post('/api/pos/tickets/$closeServerId/close', data: {
            'payment_method': payload['payment_method'],
            'waiter_id': payload['waiter_id'] ?? 1,
            'discount_amount': payload['discount_amount'] ?? 0,
            if (payload['discount_type'] != null) 'discount_type': payload['discount_type'],
            'is_offline': true, // yetki bypass icin
          });
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] Ticket close 404 -> sunucuda yok, ZATEN TAMAM sayildi: server=$closeServerId');
            _logService.logSync('Ticket close 404 (zaten kapali/yok) tamam sayildi', operation: 'ticket_close', count: 1);
            return true;
          }
          rethrow; // 500/timeout vs. -> _processSyncItem retry akisi
        }
        if (closeResponse.statusCode == 200) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Ticket close sync başarılı: server=$closeServerId');
          _logService.logSync('Ticket close sync basarili', operation: 'ticket_close', count: 1);
          return true;
        }
        _logService.logSyncError('Ticket close sync basarisiz', operation: 'ticket_close');
        return false;

      case 'void':
        final voidServerId = await _resolveServerTicketId(localId, syncId);
        if (voidServerId == null) {
          if (await _failIfParentDead(syncId, 'void')) return false; // FINAL-FIX B
          print('[Sync] Void: Server ID resolve edilemedi, bekleniyor...');
          return false;
        }
        // 31 Tem 2026 — 404 = ISLEM ZATEN TAMAM (close ile ayni gerekce, yukariya bak).
        // Yasanmis vaka: kiraci degisiminden kalma yetim adisyonun iptali 3 kez 404 alip
        // dead_letter'a dustu; kasada kalici kirmizi uyari cikti, oysa kayip YOKTU.
        Response? voidResponse;
        try {
          voidResponse = await _dio!.post('/api/pos/tickets/$voidServerId/void', data: {
            if (payload['reason'] != null) 'reason': payload['reason'],
            'waiter_id': payload['waiter_id'] ?? 1,
            'is_offline': true,
          });
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] Ticket void 404 -> sunucuda yok, ZATEN TAMAM sayildi: server=$voidServerId');
            _logService.logSync('Ticket void 404 (zaten iptal/yok) tamam sayildi', operation: 'ticket_void', count: 1);
            return true;
          }
          rethrow;
        }
        if (voidResponse.statusCode == 200) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Ticket void sync başarılı: server=$voidServerId');
          _logService.logSync('Ticket void sync basarili', operation: 'ticket_void', count: 1);
          return true;
        }
        _logService.logSyncError('Ticket void sync basarisiz', operation: 'ticket_void');
        return false;

      case 'mark_printed':
        // Offline mutfak fisi yazdirildi -> backend'e printed=1 sync
        // payload: { item_local_ids: [int], waiter_id?: int }
        final markServerId = await _resolveServerTicketId(localId, syncId);
        if (markServerId == null) {
          if (await _failIfParentDead(syncId, 'mark_printed')) return false; // FINAL-FIX B
          print('[Sync] mark_printed: Server ID resolve edilemedi, bekliyor...');
          return false;
        }
        // Lokal item_local_ids -> server_item_id'ye cevir (lokal cache'ten)
        final localIds = (payload['item_local_ids'] as List?)?.cast<int>() ?? [];
        if (localIds.isEmpty) {
          await _localDb.markSyncComplete(syncId);
          return true;
        }
        // Lokal -> server item ID resolve
        final db = await _localDb.database;
        final placeholders = List.generate(localIds.length, (i) => '?').join(',');
        final mapping = await db.rawQuery(
          'SELECT local_id, server_id FROM local_ticket_items WHERE local_id IN ($placeholders)',
          localIds,
        );
        final serverItemIds = mapping
            .map((r) => r['server_id'] as int?)
            .where((id) => id != null)
            .cast<int>()
            .toList();
        // 🟠 FINAL-FIX B (partial-resolve): TUM item'lar cozulmeden POST ETME. Eski kod kismen
        // cozulmus listeyle POST edip markSyncComplete yapiyordu -> gecikmis item'larin printed=1'i
        // SONSUZA kaybolur -> online devamda o urunler tekrar basilir (cift fis).
        if (serverItemIds.length < localIds.length) {
          if (await _failIfParentDead(syncId, 'mark_printed')) return false;
          print('[Sync] mark_printed: ${localIds.length - serverItemIds.length} item henuz sync olmamis, bekliyor');
          return false;
        }
        try {
          final r = await _dio!.post('/api/pos/tickets/$markServerId/mark-items-printed', data: {
            'item_ids': serverItemIds,
          });
          if (r.statusCode == 200) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] mark_printed sync basarili: ${serverItemIds.length} item');
            _logService.logSync('Mutfak fisi printed=1 sync basarili', operation: 'mark_printed', count: serverItemIds.length);
            return true;
          }
          await _localDb.markSyncFailed(syncId, 'mark_printed HTTP ${r.statusCode}');
        } catch (e) {
          // 🔴 Fable: zombi olmasin -> markSyncFailed (retry/dead_letter).
          print('[Sync] mark_printed sync hatasi: $e');
          _logService.logSyncError('mark_printed sync hatasi', operation: 'mark_printed', error: e);
          await _localDb.markSyncFailed(syncId, e.toString());
        }
        return false;

      case 'mark_job_printed':
        // Faz 2 (22 Tem 2026): Lokal yazici kuyrugu fisi basildi — panel_print_jobs
        // 'printed' telemetri raporu (offline'da/rapor hatasi sonrasi replay).
        // Server id'ler payload'da HAZIR (backend printKitchen yanitindan gomuldu),
        // resolve GEREKMEZ. Idempotent: backend job status set'i tekrar zararsiz.
        final mjTicketId = (payload['server_ticket_id'] as num?)?.toInt();
        final mjJobId = (payload['server_job_id'] as num?)?.toInt();
        if (mjTicketId == null || mjJobId == null) {
          await _localDb.markSyncFailed(syncId, 'mark_job_printed: server id eksik');
          return false;
        }
        try {
          final mjResp = await _dio!.post('/api/pos/tickets/$mjTicketId/mark-items-printed', data: {
            'item_ids': const <int>[],
            'job_ids': [mjJobId],
          });
          if (mjResp.statusCode == 200) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] mark_job_printed sync basarili: job=$mjJobId');
            _logService.logSync('Print job printed raporu sync basarili', operation: 'mark_job_printed', count: 1);
            return true;
          }
          await _localDb.markSyncFailed(syncId, 'mark_job_printed HTTP ${mjResp.statusCode}');
        } catch (e) {
          // Zombi olmasin -> markSyncFailed (retry_count -> max_retries -> dead_letter).
          print('[Sync] mark_job_printed sync hatasi: $e');
          _logService.logSyncError('mark_job_printed sync hatasi', operation: 'mark_job_printed', error: e);
          await _localDb.markSyncFailed(syncId, e.toString());
        }
        return false;
    }
    // Bilinmeyen action -> sonsuz pending olmasin.
    await _localDb.markSyncFailed(syncId, 'Bilinmeyen sync action (ticket switch)');
    return false;
  }

  // Server ticket ID resolve: 3 yol — sync_queue.server_id, local cache, depends_on
  Future<int?> _resolveServerTicketId(int? localId, int syncId) async {
    final db = await _localDb.database;
    // 1) sync_queue.server_id direkt set edilmis mi (recovery enqueue)
    final syncRow = await db.query('sync_queue', where: 'id = ?', whereArgs: [syncId], limit: 1);
    if (syncRow.isNotEmpty) {
      final sid = syncRow.first['server_id'] as int?;
      if (sid != null) return sid;
    }
    // 2) Lokal ticket cache'inden
    if (localId != null) {
      final ticket = await _localDb.getLocalTicket(localId);
      if (ticket != null && ticket['server_id'] != null) {
        return ticket['server_id'] as int;
      }
    }
    return null;
  }

  /// 🟠 6 Tem 2026 FINAL-FIX B: Bu sync kaydinin parent'i (depends_on) KALICI olarak oldu mu?
  /// (status failed/dead_letter VEYA 30 gun temizliginde silinmis). Oyleyse child'i markSyncFailed
  /// yap (retry_count isler -> o da dead_letter yoluna girer) -> SONSUZ 'pending' zombi kayit ve
  /// her 10sn bosa deneme onlenir. Parent yok + resolve zaten null ise kayit hicbir zaman
  /// cozulemeyecegi icin fail dogru karardir. Parent canli (pending/in_progress) ise false doner
  /// (bekle, retry HARCAMA — normal davranis korunur). close/void/add_item/mark_printed ortak.
  /// Lokal kuyrukta extras JSON METIN olarak durur; backend dizi bekler.
  /// Bozuk/eski kayitta sessizce bos dizi -> kalem yine de eklenir (veri kaybi yok).
  static List<dynamic> _decodeExtras(dynamic raw) {
    if (raw is List) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is List) return d;
      } catch (_) {}
    }
    return const [];
  }

  Future<bool> _failIfParentDead(int syncId, String context) async {
    final db = await _localDb.database;
    final row = await db.query('sync_queue',
        columns: ['depends_on_sync_id'], where: 'id = ?', whereArgs: [syncId], limit: 1);
    final depId = row.isNotEmpty ? row.first['depends_on_sync_id'] as int? : null;
    if (depId == null) return false; // bagimliligi yok -> bu helper karar veremez
    final parent = await db.query('sync_queue',
        columns: ['status'], where: 'id = ?', whereArgs: [depId], limit: 1);
    final parentGone = parent.isEmpty;
    final parentDead = parent.isNotEmpty &&
        (parent.first['status'] == 'dead_letter' || parent.first['status'] == 'failed');
    if (parentGone || parentDead) {
      await _localDb.markSyncFailed(syncId,
          '$context: parent sync kalici basarisiz (${parentGone ? "silinmis" : parent.first['status']})');
      print('[Sync] $context: parent kalici oldu -> kayit basarisiz isaretlendi (syncId=$syncId)');
      return true;
    }
    return false;
  }

  Future<bool> _syncTicketItem(String action, int? localId, Map<String, dynamic> payload, int syncId) async {
    switch (action) {
      case 'add_item':
        // Local ticket'ın server_id'sini al
        final localTicketId = payload['local_ticket_id'] as int?;
        if (localTicketId == null) {
          await _localDb.markSyncFailed(syncId, 'local_ticket_id eksik');
          return false;
        }

        int? serverTicketId;

        // Önce local_tickets tablosundan dene
        final ticket = await _localDb.getLocalTicket(localTicketId);
        if (ticket != null) {
          serverTicketId = ticket['server_id'] as int?;
        }

        // Ticket silinmiş olabilir - depends_on_sync_id üzerinden server_id'yi bul
        if (serverTicketId == null) {
          final db = await _localDb.database;

          // Bu sync kaydının depends_on_sync_id'sini al
          final syncRecord = await db.query(
            'sync_queue',
            columns: ['depends_on_sync_id'],
            where: 'id = ?',
            whereArgs: [syncId],
          );

          if (syncRecord.isNotEmpty && syncRecord.first['depends_on_sync_id'] != null) {
            final dependsOnId = syncRecord.first['depends_on_sync_id'] as int;

            // depends_on kaydından server_id'yi al
            final parentSync = await db.query(
              'sync_queue',
              columns: ['server_id'],
              where: 'id = ?',
              whereArgs: [dependsOnId],
            );

            if (parentSync.isNotEmpty && parentSync.first['server_id'] != null) {
              serverTicketId = parentSync.first['server_id'] as int;
              print('[Sync] Server ticket ID depends_on üzerinden bulundu: $serverTicketId');
            }
          }
        }

        if (serverTicketId == null) {
          // 🟡 6 Tem 2026 DÜZELTME 5 + FINAL-FIX B: parent create kalici olduysa child'i da fail'e
          // dusur (sonsuz pending zombi onle); parent canliysa bekle (retry harcama). Ortak helper.
          if (await _failIfParentDead(syncId, 'add_item')) return false;
          print('[Sync] Item için ticket henüz sync olmamış, bekleniyor...');
          return false;
        }

        final response = await _dio!.post('/api/pos/tickets/$serverTicketId/items', data: {
          'product_id': payload['product_id'],
          'product_name': payload['product_name'],
          'unit_price': payload['unit_price'],
          'quantity': payload['quantity'] ?? 1,
          'notes': payload['notes'],
          'waiter_id': payload['waiter_id'] ?? 1,
          if (payload['portion'] != null) 'portion': payload['portion'], // v11: offline porsiyon backend'e
          // v16 (31 Tem 2026): combo paket kimligi cevrimdisi eklemede de KORUNSUN — yoksa
          // internet gelince sync olan combo kalemleri fiste gruplanmaz, duz liste kalirdi.
          if (payload['combo_group_id'] != null) 'combo_group_id': payload['combo_group_id'],
          if (payload['combo_group_name'] != null) 'combo_group_name': payload['combo_group_name'],
          if (payload['combo_pick_name'] != null) 'combo_pick_name': payload['combo_pick_name'],
          // 31 Tem 2026: POS coklu varyant secimleri (extras) cevrimdisi replay'de de gitsin.
          // Lokalde JSON METIN olarak saklanir; backend JSON dizi bekler -> coz.
          if (payload['extras'] != null) 'extras': _decodeExtras(payload['extras']),
          'is_offline': true, // Offline sync - kapalı ticket'a da eklenebilir
        });

        if (response.data['success'] == true) {
          final serverItemId = response.data['item_id'];
          await _localDb.updateItemServerId(localId!, serverItemId);
          await _localDb.updateItemServerTicketId(localId, serverTicketId);
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Item sync başarılı: local=$localId, server=$serverItemId');
          _logService.logSync('Item sync basarili', operation: 'item_add', count: 1);
          return true;
        }
        _logService.logSyncError('Item sync basarisiz', operation: 'item_add');
        return false;

      case 'cancel_item':
        // Item iptal sync'i
        final localTicketIdCancel = payload['local_ticket_id'] as int?;
        if (localTicketIdCancel == null) {
          await _localDb.markSyncComplete(syncId); // Eksik veri, atla
          return true;
        }

        int? serverTicketIdCancel;

        // Önce local_tickets tablosundan dene
        final ticketCancel = await _localDb.getLocalTicket(localTicketIdCancel);
        if (ticketCancel != null) {
          serverTicketIdCancel = ticketCancel['server_id'] as int?;
        }

        // Ticket silinmiş olabilir - depends_on üzerinden server_id'yi bul
        if (serverTicketIdCancel == null) {
          final db = await _localDb.database;
          final syncRecord = await db.query(
            'sync_queue',
            columns: ['depends_on_sync_id'],
            where: 'id = ?',
            whereArgs: [syncId],
          );

          if (syncRecord.isNotEmpty && syncRecord.first['depends_on_sync_id'] != null) {
            final dependsOnId = syncRecord.first['depends_on_sync_id'] as int;
            final parentSync = await db.query(
              'sync_queue',
              columns: ['server_id'],
              where: 'id = ?',
              whereArgs: [dependsOnId],
            );
            if (parentSync.isNotEmpty && parentSync.first['server_id'] != null) {
              serverTicketIdCancel = parentSync.first['server_id'] as int;
            }
          }
        }

        if (serverTicketIdCancel == null) {
          // 🔴 Fable: parent (ticket) kalıcı ölüyse sonsuz bekleme yerine fail (guard eklendi).
          if (await _failIfParentDead(syncId, 'cancel_item')) return false;
          print('[Sync] Item cancel için ticket henüz sync olmamış');
          return false;
        }

        final serverTicketId = serverTicketIdCancel;
        final serverItemId = payload['server_item_id'];

        if (serverItemId != null) {
          try {
            await _dio!.delete('/api/pos/tickets/$serverTicketId/items/$serverItemId');
            print('[Sync] Item cancel sync başarılı: server_item=$serverItemId');
            _logService.logSync('Item cancel sync basarili', operation: 'item_cancel', count: 1);
          } catch (e) {
            // 🔴 Fable: eski kod hata yutup YINE DE markSyncComplete yapiyordu -> basarisiz iptal
            // "tamamlandi" sanilir (sessiz veri kaybi — urun backend'de iptal EDILMEDI). markSyncFailed.
            print('[Sync] Item cancel API hatası: $e');
            _logService.logSyncError('Item cancel sync hatasi', operation: 'item_cancel', error: e);
            await _localDb.markSyncFailed(syncId, e.toString());
            return false;
          }
        }

        await _localDb.markSyncComplete(syncId);
        return true;

      case 'mark_served':
        // v11: masa takip ekrani offline teslim toggle push.
        // payload: {item_local_id, item_server_id?, ticket_local_id, waiter_id?, delivered}
        final msTicketLocalId = payload['ticket_local_id'] as int?;
        int? msTicketServerId;
        if (msTicketLocalId != null) {
          final tk = await _localDb.getLocalTicket(msTicketLocalId);
          msTicketServerId = tk?['server_id'] as int?;
        }
        // Item server_id: payload'da varsa onu, yoksa local item'dan tazele (add_item sync olmus olabilir).
        int? msItemServerId = (payload['item_server_id'] as num?)?.toInt();
        final msItemLocalId = payload['item_local_id'] as int?;
        if (msItemServerId == null && msItemLocalId != null) {
          final db = await _localDb.database;
          final r = await db.query('local_ticket_items', columns: ['server_id'], where: 'local_id = ?', whereArgs: [msItemLocalId], limit: 1);
          if (r.isNotEmpty) msItemServerId = r.first['server_id'] as int?;
        }
        // KRITIK: gecerli item server_id YOKSA POST ETME — backend gecersiz id'de "son eklenen kalem"
        // fallback'i yapar = YANLIS URUN toggle. dependsOn add_item'i bekletir; bekle.
        if (msTicketServerId == null || msItemServerId == null || msItemServerId <= 0) {
          if (await _failIfParentDead(syncId, 'mark_served')) return false;
          print('[Sync] mark_served: ticket/item server_id yok, bekleniyor...');
          return false;
        }
        // POST'u try/catch'e ALMA — Dio 404 THROW -> _processSyncItem catch -> markSyncFailed (retry).
        final msResp = await _dio!.post(
          '/api/pos/tickets/$msTicketServerId/items/$msItemServerId/mark-served',
          data: { if (payload['waiter_id'] != null) 'waiter_id': payload['waiter_id'] },
        );
        if (msResp.statusCode == 200) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] mark_served sync başarılı: item=$msItemServerId');
          _logService.logSync('Kalem teslim sync basarili', operation: 'mark_served', count: 1);
          return true;
        }
        _logService.logSyncError('Kalem teslim sync basarisiz', operation: 'mark_served');
        return false;

      case 'update_item':
        // Server item update (offline'da garson qty/notes/fiyat degistirdi)
        // payload: {ticket_id, local_ticket_id?, item_local_id?, quantity?, notes?, unit_price?, extras_amount?, waiter_id?}
        // server_id: itemId (sync_queue'da set edildi via enqueueServerTicketAction)
        int? updateItemId = await _resolveServerEntityId(syncId);
        int? updateTicketId = payload['ticket_id'] as int?;
        // 🔴 7 Tem 2026 (Fable): payload'da lokal id'ler varsa GERCEK server id'leri lokal
        // satirlardan yeniden coz (mark_served deseni). Eski davranis payload/server_id'yi
        // VERBATIM kullaniyordu -> offline enqueue'da LOKAL id'ler yanlis URL'e gidiyordu
        // (404 retry -> dead_letter = guncelleme kaybi). Server id henuz yoksa BEKLE.
        final updLocalTicketId = payload['local_ticket_id'] as int?;
        if (updLocalTicketId != null) {
          final utk = await _localDb.getLocalTicket(updLocalTicketId);
          final usid = utk?['server_id'] as int?;
          if (usid != null) {
            updateTicketId = usid;
          } else if (utk != null) {
            // Lokal ticket var ama create henuz sync olmamis -> bekle. Parent kalici olduyse fail (Fable).
            if (await _failIfParentDead(syncId, 'update_item')) return false;
            print('[Sync] update_item: ticket server_id yok, bekleniyor... (local=$updLocalTicketId)');
            return false;
          }
          // utk == null (ticket lokalden temizlenmis) -> payload.ticket_id fallback (eski davranis)
        }
        final updItemLocalId = payload['item_local_id'] as int?;
        if (updItemLocalId != null) {
          final udb = await _localDb.database;
          final ur = await udb.query('local_ticket_items',
              columns: ['server_id'], where: 'local_id = ?', whereArgs: [updItemLocalId], limit: 1);
          final uisid = ur.isNotEmpty ? ur.first['server_id'] as int? : null;
          if (uisid != null) {
            updateItemId = uisid;
          } else if (ur.isNotEmpty) {
            // Item lokalde var ama add_item sync'i henuz server_id yazmamis -> bekle (parent oldu ise fail).
            if (await _failIfParentDead(syncId, 'update_item')) return false;
            print('[Sync] update_item: item server_id yok, bekleniyor... (item_local=$updItemLocalId)');
            return false;
          }
          // ur empty (item temizlenmis) -> sync_queue.server_id fallback (eski davranis)
        }
        if (updateItemId == null || updateTicketId == null) {
          await _localDb.markSyncFailed(syncId, 'item_id veya ticket_id eksik');
          return false;
        }
        try {
          final updRes = await _dio!.put('/api/pos/tickets/$updateTicketId/items/$updateItemId', data: {
            if (payload['quantity'] != null) 'quantity': payload['quantity'],
            if (payload['notes'] != null) 'notes': payload['notes'],
            if (payload['unit_price'] != null) 'unit_price': payload['unit_price'],
            if (payload['extras_amount'] != null) 'extras_amount': payload['extras_amount'],
            if (payload['waiter_id'] != null) 'waiter_id': payload['waiter_id'],
            'is_offline': true,
          });
          if (updRes.statusCode == 200) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] Item update sync başarılı: item=$updateItemId');
            _logService.logSync('Item update sync basarili', operation: 'item_update', count: 1);
            return true;
          }
          // 200 dışı (nadir) — başarısız say, retry/dead_letter'a düşsün (zombi olmasın).
          await _localDb.markSyncFailed(syncId, 'update_item HTTP ${updRes.statusCode}');
        } catch (e) {
          // 🔴 Fable: 404/hata iç catch'te YUTULUP markSyncFailed cagrilmiyordu -> retry_count artmaz,
          // sonsuz PENDING zombi. markSyncFailed -> retry_count++ -> 3'te failed -> dead_letter (kullanici gorur/siler).
          print('[Sync] Item update sync hatası: $e');
          _logService.logSyncError('Item update sync hatasi', operation: 'item_update', error: e);
          await _localDb.markSyncFailed(syncId, e.toString());
        }
        return false;

      case 'delete_item':
        // Server item delete (offline iptal)
        // payload: {ticket_id, local_ticket_id?, item_local_id?, cancel_reason, waiter_id?}
        // server_id: itemId
        int? deleteItemId = await _resolveServerEntityId(syncId);
        int? deleteTicketId = payload['ticket_id'] as int?;
        // 🔴 7 Tem 2026 (Fable): update_item ile ayni server-id re-resolve (aciklama yukarida).
        final delLocalTicketId = payload['local_ticket_id'] as int?;
        if (delLocalTicketId != null) {
          final dtk = await _localDb.getLocalTicket(delLocalTicketId);
          final dsid = dtk?['server_id'] as int?;
          if (dsid != null) {
            deleteTicketId = dsid;
          } else if (dtk != null) {
            if (await _failIfParentDead(syncId, 'delete_item')) return false;
            print('[Sync] delete_item: ticket server_id yok, bekleniyor... (local=$delLocalTicketId)');
            return false;
          }
        }
        final delItemLocalId = payload['item_local_id'] as int?;
        if (delItemLocalId != null) {
          final ddb = await _localDb.database;
          final dr = await ddb.query('local_ticket_items',
              columns: ['server_id'], where: 'local_id = ?', whereArgs: [delItemLocalId], limit: 1);
          final disid = dr.isNotEmpty ? dr.first['server_id'] as int? : null;
          if (disid != null) {
            deleteItemId = disid;
          } else if (dr.isNotEmpty) {
            if (await _failIfParentDead(syncId, 'delete_item')) return false;
            print('[Sync] delete_item: item server_id yok, bekleniyor... (item_local=$delItemLocalId)');
            return false;
          }
        }
        if (deleteItemId == null || deleteTicketId == null) {
          await _localDb.markSyncFailed(syncId, 'item_id veya ticket_id eksik');
          return false;
        }
        try {
          final delRes = await _dio!.delete('/api/pos/tickets/$deleteTicketId/items/$deleteItemId', data: {
            'cancel_reason': payload['cancel_reason'] ?? 'Musteri istegi',
            if (payload['waiter_id'] != null) 'waiter_id': payload['waiter_id'],
            'is_offline': true,
          });
          if (delRes.statusCode == 200) {
            await _localDb.markSyncComplete(syncId);
            print('[Sync] Item delete sync başarılı: item=$deleteItemId');
            _logService.logSync('Item delete sync basarili', operation: 'item_delete', count: 1);
            return true;
          }
          await _localDb.markSyncFailed(syncId, 'delete_item HTTP ${delRes.statusCode}');
        } catch (e) {
          // 🔴 Fable: 404 yutulup zombi olmasin -> markSyncFailed (retry/dead_letter).
          print('[Sync] Item delete sync hatası: $e');
          _logService.logSyncError('Item delete sync hatasi', operation: 'item_delete', error: e);
          await _localDb.markSyncFailed(syncId, e.toString());
        }
        return false;

      // 16 May 2026: Tek ürün taşıma (offline → online sync)
      // payload: { ticket_id, item_id, new_table_id, waiter_id }
      case 'move_item':
        final moveTicketId = payload['ticket_id'] as int?;
        final moveItemId = payload['item_id'] as int?;
        final moveNewTableId = payload['new_table_id'] as int?;
        if (moveTicketId == null || moveItemId == null || moveNewTableId == null) {
          await _localDb.markSyncFailed(syncId, 'move_item parametreleri eksik');
          return false;
        }
        try {
          final mvRes = await _dio!.post(
            '/api/pos/tickets/$moveTicketId/items/$moveItemId/move',
            data: {
              'new_table_id': moveNewTableId,
              if (payload['waiter_id'] != null) 'waiter_id': payload['waiter_id'],
              'is_offline': true,
            },
          );
          if (mvRes.statusCode == 200 && mvRes.data['success'] == true) {
            await _localDb.markSyncComplete(syncId, serverId: mvRes.data['target_ticket_id'] as int?);
            print('[Sync] Move item başarılı: item=$moveItemId → table=$moveNewTableId');
            _logService.logSync('Item move sync basarili', operation: 'item_move', count: 1);
            return true;
          }
          await _localDb.markSyncFailed(syncId, 'move_item basarisiz HTTP ${mvRes.statusCode}');
        } catch (e) {
          // 🔴 Fable: zombi olmasin -> markSyncFailed.
          print('[Sync] Move item hatası: $e');
          _logService.logSyncError('Item move sync hatasi', operation: 'item_move', error: e);
          await _localDb.markSyncFailed(syncId, e.toString());
        }
        return false;
    }
    // Bilinmeyen action -> sonsuz pending olmasin, failed'a düşür.
    await _localDb.markSyncFailed(syncId, 'Bilinmeyen sync action');
    return false;
  }

  // Server entity ID resolve (sync_queue.server_id'den) — update/delete item icin
  Future<int?> _resolveServerEntityId(int syncId) async {
    final db = await _localDb.database;
    final row = await db.query('sync_queue', where: 'id = ?', whereArgs: [syncId], limit: 1);
    if (row.isNotEmpty) {
      return row.first['server_id'] as int?;
    }
    return null;
  }

  // ==================== CACHE INVALIDATE (push-based) ====================
  // Socket.io 'cache:invalidate' event'i geldiginde backend'in degisen tipi
  // anlik refresh eder. 30dk poll bekleme olmadan fiyat/yazici/menu degisikligi
  // saniyeler icinde POS'a yansir. Multi-tenant: panel_id event'te.
  // Type listesi: products, categories, sections, tables, waiters, printers,
  //                cancel_reasons, ikram_reasons, product_notes, global_variants,
  //                global_extras, settings

  Future<void> refreshCacheType(String type) async {
    if (!_connectivity.isOnline || _dio == null) {
      print('[Sync] refreshCacheType skip (offline): $type');
      return;
    }
    try {
      switch (type) {
        case 'products':
          final r = await _dio!.get('/api/pos/products');
          if (r.data is List) {
            final products = List<Map<String, dynamic>>.from(r.data);
            // 17 Tem 2026 FIX: (a) görsel URL'leri _getFullImageUrl ile MUTLAK yap — relatif
            // '/uploads/..' yolları "No host specified in URI" hatası veriyordu (indirme hep
            // başarısızdı); (b) TÜM görselleri değil sadece YENİ/DEĞİŞEN ürün görsellerini indir
            // (sweep'teki diff deseni — push her tetiklendiğinde 300+ görsel çekiliyordu).
            final cachedProducts = await _localDb.getCachedProducts();
            final cachedById = {for (final c in cachedProducts) c['id']: c};
            final newImageUrls = <String>[];
            for (final p in products) {
              final img = p['image']?.toString();
              if (img == null || img.isEmpty) continue;
              final cached = cachedById[p['id']];
              if (cached == null || cached['image']?.toString() != img) {
                newImageUrls.add(_getFullImageUrl(img));
              }
            }
            await _localDb.cacheProducts(products);
            if (newImageUrls.isNotEmpty) {
              await _imageCache.downloadMultiple(newImageUrls);
            }
            print('[CacheInvalidate] products refresh: ${products.length} (yeni görsel: ${newImageUrls.length})');
          }
          break;
        case 'categories':
          final r = await _dio!.get('/api/pos/categories');
          if (r.data is List) {
            await _localDb.cacheCategories(List<Map<String, dynamic>>.from(r.data));
            print('[CacheInvalidate] categories refresh: ${(r.data as List).length}');
          }
          break;
        case 'sections':
          final r = await _dio!.get('/api/pos/tables/sections');
          if (r.data is List) {
            await _localDb.cacheSections(List<Map<String, dynamic>>.from(r.data));
            print('[CacheInvalidate] sections refresh: ${(r.data as List).length}');
          }
          break;
        case 'tables':
          final r = await _dio!.get('/api/pos/tables');
          if (r.data is List) {
            await _localDb.cacheTables(List<Map<String, dynamic>>.from(r.data));
            print('[CacheInvalidate] tables refresh: ${(r.data as List).length}');
          }
          break;
        case 'waiters':
          await _cacheAllWaiters();
          break;
        case 'printers':
          final r = await _dio!.get('/api/pos/printers');
          if (r.data is List) {
            await _localDb.cachePrinters(List<Map<String, dynamic>>.from(r.data));
            print('[CacheInvalidate] printers refresh: ${(r.data as List).length}');
          }
          break;
        case 'cancel_reasons':
          final r = await _dio!.get('/api/pos/cancel-reasons');
          final crRows = ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          await _localDb.cacheLookups(lookupType: 'cancel_reasons', rows: crRows);
          await _localDb.cacheCancelReasons(crRows); // v20 dedicated tablo
          break;
        case 'ikram_reasons':
          // v20 IKRAM: panel Ikram Sebepleri degisince push ile anlik yenile
          final r = await _dio!.get('/api/pos/settings-extra/ikram-reasons');
          final data = r.data;
          final list = data is List ? data : (data is Map ? ((data['reasons'] as List?) ?? []) : []);
          await _localDb.cacheIkramReasons(
            list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
          );
          break;
        case 'product_notes':
          final r = await _dio!.get('/api/pos/product-notes');
          await _localDb.cacheLookups(
            lookupType: 'product_notes',
            rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
          break;
        case 'global_variants':
          final r = await _dio!.get('/api/pos/global/variants/active');
          await _localDb.cacheLookups(
            lookupType: 'global_variants',
            rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
          break;
        case 'global_extras':
          final r = await _dio!.get('/api/pos/global/extras/active');
          await _localDb.cacheLookups(
            lookupType: 'global_extras',
            rows: ((r.data as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
          break;
        case 'settings':
          final r = await _dio!.get('/api/pos/settings');
          if (r.data != null) {
            final settings = Map<String, dynamic>.from(r.data);
            await _localDb.cacheSettings(settings);
            _notifySettingsLoaded(settings); // fan-out (poll süresi push'ta canlı güncellenir)
          }
          break;
        default:
          print('[CacheInvalidate] Bilinmeyen type: $type');
      }
    } catch (e) {
      print('[CacheInvalidate] $type refresh hatasi: $e');
    }
  }

  // Birden fazla type'i paralel refresh
  Future<void> refreshCacheTypes(List<String> types) async {
    if (types.isEmpty) return;
    print('[CacheInvalidate] Bulk refresh: $types');
    await Future.wait(types.map((t) => refreshCacheType(t)));
  }

  // Server'dan masa durumlarını al ve local'i güncelle
  Future<void> _syncTablesFromServer() async {
    if (!_connectivity.isOnline || _dio == null) return;

    try {
      print('[Sync] Server\'dan masa durumları alınıyor...');
      final response = await _dio!.get('/api/pos/tables');
      if (response.data is List) {
        final tables = List<Map<String, dynamic>>.from(response.data);
        // Local DB'yi güncelle
        await _localDb.syncOpenTicketsFromServer(tables);
        // Cache'i de güncelle
        await _localDb.cacheTables(tables);
        print('[Sync] Masa durumları güncellendi: ${tables.length} masa');
      }
    } catch (e) {
      print('[Sync] Masa sync hatası: $e');
    }
  }

  // Cache'leri sunucudan güncelle
  Future<void> refreshCache() async {
    if (!_connectivity.isOnline || _dio == null) return;

    print('[Sync] Cache güncelleniyor...');

    try {
      // Kategoriler
      final categoriesResponse = await _dio!.get('/api/pos/categories');
      if (categoriesResponse.data is List) {
        await _localDb.cacheCategories(List<Map<String, dynamic>>.from(categoriesResponse.data));
        print('[Sync] Kategoriler cache\'lendi: ${(categoriesResponse.data as List).length}');
      }

      // Ürünler
      final productsResponse = await _dio!.get('/api/pos/products');
      List<Map<String, dynamic>> products = [];
      if (productsResponse.data is List) {
        products = List<Map<String, dynamic>>.from(productsResponse.data);
        await _localDb.cacheProducts(products);
        print('[Sync] Ürünler cache\'lendi: ${products.length}');
      }

      // Ürün görsellerini indir
      if (products.isNotEmpty) {
        print('[Sync] Ürün görselleri indiriliyor...');
        await _downloadProductImages(products);
      }

      // Salonlar
      final sectionsResponse = await _dio!.get('/api/pos/tables/sections');
      if (sectionsResponse.data is List) {
        await _localDb.cacheSections(List<Map<String, dynamic>>.from(sectionsResponse.data));
        print('[Sync] Salonlar cache\'lendi: ${(sectionsResponse.data as List).length}');
      }

      // Masalar
      final tablesResponse = await _dio!.get('/api/pos/tables');
      if (tablesResponse.data is List) {
        await _localDb.cacheTables(List<Map<String, dynamic>>.from(tablesResponse.data));
        print('[Sync] Masalar cache\'lendi: ${(tablesResponse.data as List).length}');
      }

      print('[Sync] Cache güncelleme tamamlandı');
    } catch (e) {
      print('[Sync] Cache güncelleme hatası: $e');
    }
  }

  // Garson bilgisini cache'le
  Future<void> cacheWaiter(Map<String, dynamic> waiter) async {
    final db = await _localDb.database;
    final now = DateTime.now().toIso8601String();

    // PIN'i string olarak kaydet (API'den int gelebilir)
    final pinValue = waiter['pin']?.toString() ?? '';

    // Eğer PIN boşsa ve bu garson zaten cache'de varsa, PIN'i ezme
    if (pinValue.isEmpty) {
      final existing = await db.query(
        'cached_waiters',
        where: 'id = ?',
        whereArgs: [waiter['id']],
      );
      if (existing.isNotEmpty && (existing.first['pin'] as String?)?.isNotEmpty == true) {
        // Mevcut PIN'i koru, sadece diğer alanları güncelle
        // 🔴 3 Agu 2026 — SALON KISITI SESSIZ SILINIYORDU.
        // GET /api/pos/waiters (liste ucu) `sections`/`permissions` DONDURMUYOR.
        // _cacheAllWaiters bu listeyi her senkronda basdigi icin login'in dogru
        // cache'ledigi salon atamasi '[]' ile EZILIYOR, sonraki cevrimdisi PIN
        // girisinde "atama yok" sanilip garson TUM salonlari goruyordu (sessiz).
        // ARTIK: gelen kayitta alan YOKSA cache'teki deger KORUNUR.
        // (Alan VARSA — login yanitinda oldugu gibi — normal sekilde guncellenir.)
        await db.update(
          'cached_waiters',
          {
            'name': waiter['name'],
            if (waiter.containsKey('permissions'))
              'permissions': jsonEncode(waiter['permissions'] is Map ? waiter['permissions'] : {}),
            if (waiter.containsKey('sections'))
              'sections': jsonEncode(waiter['sections'] ?? []),
            'cached_at': now,
          },
          where: 'id = ?',
          whereArgs: [waiter['id']],
        );
        if (kDebugMode) print('[Sync] Garson güncellendi: ${waiter['name']}');
        return;
      }
    }

    // 3 Agu 2026 — REPLACE insert TUM satiri siler/yeniden yazar; gelen kayitta
    // sections/permissions yoksa (liste ucu) cache'teki degeri ELDE TASI, yoksa
    // yukaridaki update dalindaki ayni sessiz silinme buradan gerceklesirdi.
    Map<String, dynamic> _eskiler = {};
    try {
      final onceki = await db.query('cached_waiters',
          columns: ['permissions', 'sections'], where: 'id = ?', whereArgs: [waiter['id']], limit: 1);
      if (onceki.isNotEmpty) _eskiler = Map<String, dynamic>.from(onceki.first);
    } catch (_) {}

    final _perm = waiter.containsKey('permissions')
        ? jsonEncode(waiter['permissions'] ?? [])
        : (_eskiler['permissions']?.toString() ?? jsonEncode([]));
    final _sect = waiter.containsKey('sections')
        ? jsonEncode(waiter['sections'] ?? [])
        : (_eskiler['sections']?.toString() ?? jsonEncode([]));

    await db.insert(
      'cached_waiters',
      {
        'id': waiter['id'],
        'name': waiter['name'],
        'pin': _hashPin(pinValue),
        'permissions': _perm,
        'sections': _sect,
        'cached_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (kDebugMode) print('[Sync] Garson cache\'lendi: ${waiter['name']}');
  }

  /// PIN hash'le (SHA-256 + salt)
  String _hashPin(String pin) {
    if (pin.isEmpty) return '';
    final bytes = utf8.encode('SyncRestoPOS:$pin');
    return sha256.convert(bytes).toString();
  }

  // Cache'den garson getir (PIN ile)
  Future<Map<String, dynamic>?> getCachedWaiterByPin(String pin) async {
    final db = await _localDb.database;
    final hashedPin = _hashPin(pin);
    final results = await db.query(
      'cached_waiters',
      where: 'pin = ?',
      whereArgs: [hashedPin],
    );

    if (results.isEmpty) return null;

    final waiter = Map<String, dynamic>.from(results.first);
    // JSON alanları parse et. permissions Map olmalı (backend bazen [] array dönebilir -> Map'e normalize).
    final decodedPerms = jsonDecode(waiter['permissions'] as String? ?? '{}');
    waiter['permissions'] = decodedPerms is Map ? decodedPerms : <String, dynamic>{};
    waiter['sections'] = jsonDecode(waiter['sections'] as String? ?? '[]');

    return waiter;
  }

  // UI için sync durumu
  Future<Map<String, dynamic>> getSyncStatus() async {
    return await _localDb.getOfflineDataSummary();
  }

  // Hatalı işlemi tekrar dene
  Future<void> retrySyncItem(int syncId) async {
    await _localDb.retrySyncItem(syncId);
    // Hemen sync başlat
    syncPendingItems();
  }

  // Hatalı işlemi sil
  Future<void> deleteSyncItem(int syncId) async {
    await _localDb.deleteSyncItem(syncId);
  }

  // Tüm hatalı işlemleri temizle
  Future<void> clearFailedItems() async {
    await _localDb.clearFailedSyncItems();
  }

  /// Tüm cache'i temizle (API key pasif olduğunda çağrılır).
  /// clearAllTenantData'ya delege (tek dogru kaynak — gercek sema tablolarini siler; eski kod
  /// var olmayan offline_tickets tablosundan delete deneyip exception'la temizligi yarim birakiyordu).
  Future<void> clearAllCache() async {
    try {
      await _localDb.clearAllTenantData();
      _isInitialSyncDone = false;
      _logService.warning(LogType.sync, 'Tum cache temizlendi (API key pasif)');
      print('[Sync] Tüm cache temizlendi');
    } catch (e) {
      print('[Sync] Cache temizleme hatası: $e');
      _logService.error(LogType.sync, 'Cache temizleme hatasi', details: {'error': e.toString()});
    }
  }

  void dispose() {
    _syncTimer?.cancel();
    _cacheUpdateTimer?.cancel();   // 11 Haz 2026 LEAK FIX
    _mirrorTimer?.cancel();        // 17 Tem 2026: ayna döngüsü
    _connectivitySub?.cancel();    // 11 Haz 2026 LEAK FIX
  }
}
