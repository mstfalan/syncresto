import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'local_db_service.dart';
import 'connectivity_service.dart';
import 'image_cache_service.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final LocalDbService _localDb = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();
  final ImageCacheService _imageCache = ImageCacheService();

  Dio? _dio;
  Timer? _syncTimer;
  bool _isSyncing = false;
  bool _isInitialSyncDone = false;
  String? _backendUrl;

  // Progress callback for UI
  void Function(String message, double progress)? onSyncProgress;

  // Settings callback for theme updates
  void Function(Map<String, dynamic> settings)? onSettingsLoaded;

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

    // İnternet durumu değişince sync başlat
    _connectivity.connectionStream.listen((isOnline) async {
      if (isOnline) {
        print('[Sync] Online oldu, sync başlatılıyor...');
        // Önce bekleyen işlemleri sync et
        await syncPendingItems();
        // Sonra server'dan güncel durumu al ve local'i güncelle
        await _syncTablesFromServer();
        // Kapatılmış ticketları temizle
        await _localDb.cleanupSyncedTickets();
      }
    });

    // Periyodik sync (her 10 saniye)
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_connectivity.isOnline) {
        syncPendingItems();
      }
    });

    // Periyodik cache güncelleme (her 5 dakika)
    Timer.periodic(const Duration(minutes: 5), (_) {
      if (_connectivity.isOnline) {
        backgroundCacheUpdate();
      }
    });
  }

  /// İlk girişte tüm verileri indir ve cache'le
  Future<void> performInitialSync() async {
    if (!_connectivity.isOnline || _dio == null) {
      print('[Sync] İlk sync için internet gerekli!');
      return;
    }

    if (_isInitialSyncDone) {
      print('[Sync] İlk sync zaten yapıldı');
      return;
    }

    print('[Sync] ========== İLK SYNC BAŞLIYOR ==========');

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

      // 7. Ayarlar (varsa)
      _reportProgress('Ayarlar indiriliyor...', 0.9);
      try {
        final settingsResponse = await _dio!.get('/api/pos/settings');
        if (settingsResponse.data != null) {
          final settings = Map<String, dynamic>.from(settingsResponse.data);
          await _localDb.cacheSettings(settings);
          print('[Sync] Ayarlar cache\'lendi');

          // Tema güncellemesi için callback
          onSettingsLoaded?.call(settings);
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

    } catch (e) {
      print('[Sync] İlk sync hatası: $e');
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

        if (changedProducts.isNotEmpty) {
          print('[Sync] ${changedProducts.length} ürün güncellendi');
          await _localDb.cacheProducts(products);

          // Yeni görselleri indir
          if (newImageUrls.isNotEmpty) {
            print('[Sync] ${newImageUrls.length} yeni görsel indiriliyor...');
            await _imageCache.downloadMultiple(newImageUrls);
          }
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
        await _localDb.cacheTables(List<Map<String, dynamic>>.from(tablesResponse.data));
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

          // Tema güncellemesi için callback
          onSettingsLoaded?.call(settings);
        }
      } catch (e) {
        print('[Sync] Ayarlar güncellenemedi: $e');
      }

      print('[Sync] Arka plan güncelleme tamamlandı');
    } catch (e) {
      print('[Sync] Arka plan güncelleme hatası: $e');
    }
  }

  /// İki ürün arasında değişiklik var mı kontrol et
  bool _isProductChanged(Map<String, dynamic> cached, Map<String, dynamic> newProduct) {
    // Önemli alanları karşılaştır
    final fieldsToCheck = ['name', 'price', 'description', 'image', 'is_active', 'is_out_of_stock', 'category_id'];

    for (final field in fieldsToCheck) {
      if (cached[field]?.toString() != newProduct[field]?.toString()) {
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
            print('[Sync] Bağımlılık henüz tamamlanmadı: $syncId depends on $dependsOn');
          }
        }
      }

      print('[Sync] Tüm işlemler tamamlandı');

      // Sync tamamlandıktan sonra sunucudan güncel verileri çek ve cache'i güncelle
      if (completedSyncIds.isNotEmpty) {
        print('[Sync] Cache güncelleniyor...');
        await _refreshCacheAfterSync();
      }
    } catch (e) {
      print('[Sync] Hata: $e');
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
          } else {
            print('[Sync] Ticket sync başarılı: local=$localId, server=$serverId');
          }
          return true;
        }
        return false;

      case 'close':
        // Önce local ticket'ın server_id'sini al
        final ticketClose = await _localDb.getLocalTicket(localId!);
        if (ticketClose == null) {
          await _localDb.markSyncComplete(syncId); // Ticket yok, atla
          print('[Sync] Close: Ticket bulunamadı, atlanıyor');
          return true;
        }

        if (ticketClose['server_id'] == null) {
          // Server'da henüz oluşturulmamış - sonraki döngüde tekrar denenecek
          print('[Sync] Close: Ticket henüz sunucuda yok, bekleniyor...');
          return false; // markSyncComplete çağırmıyoruz, tekrar denenecek
        }

        final serverIdClose = ticketClose['server_id'];
        final closeResponse = await _dio!.post('/api/pos/tickets/$serverIdClose/close', data: {
          'payment_method': payload['payment_method'],
          'waiter_id': payload['waiter_id'] ?? 1,
          'discount_amount': payload['discount_amount'] ?? 0,
          'discount_type': payload['discount_type'],
          'is_offline': true, // Offline'dan geldiğini bildir - yetki bypass için
        });

        if (closeResponse.statusCode == 200) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Ticket close sync başarılı: server=$serverIdClose');
          return true;
        }
        return false;

      case 'void':
        final ticketVoid = await _localDb.getLocalTicket(localId!);
        if (ticketVoid == null) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Void: Ticket bulunamadı, atlanıyor');
          return true;
        }

        if (ticketVoid['server_id'] == null) {
          // Server'da henüz oluşturulmamış - sonraki döngüde tekrar denenecek
          print('[Sync] Void: Ticket henüz sunucuda yok, bekleniyor...');
          return false;
        }

        final serverIdVoid = ticketVoid['server_id'];
        final voidResponse = await _dio!.post('/api/pos/tickets/$serverIdVoid/void', data: {
          'waiter_id': payload['waiter_id'] ?? 1,
          'is_offline': true, // Offline'dan geldiğini bildir - yetki bypass için
        });

        if (voidResponse.statusCode == 200) {
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Ticket void sync başarılı: server=$serverIdVoid');
          return true;
        }
        return false;
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
          // Ticket henüz sync olmamış - sonraki döngüde tekrar denenecek
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
          'is_offline': true, // Offline sync - kapalı ticket'a da eklenebilir
        });

        if (response.data['success'] == true) {
          final serverItemId = response.data['item_id'];
          await _localDb.updateItemServerId(localId!, serverItemId);
          await _localDb.updateItemServerTicketId(localId, serverTicketId);
          await _localDb.markSyncComplete(syncId);
          print('[Sync] Item sync başarılı: local=$localId, server=$serverItemId');
          return true;
        }
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
          print('[Sync] Item cancel için ticket henüz sync olmamış');
          return false;
        }

        final serverTicketId = serverTicketIdCancel;
        final serverItemId = payload['server_item_id'];

        if (serverItemId != null) {
          try {
            await _dio!.delete('/api/pos/tickets/$serverTicketId/items/$serverItemId');
            print('[Sync] Item cancel sync başarılı: server_item=$serverItemId');
          } catch (e) {
            print('[Sync] Item cancel API hatası: $e');
          }
        }

        await _localDb.markSyncComplete(syncId);
        return true;
    }
    return false;
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
        await db.update(
          'cached_waiters',
          {
            'name': waiter['name'],
            'permissions': jsonEncode(waiter['permissions'] ?? []),
            'sections': jsonEncode(waiter['sections'] ?? []),
            'cached_at': now,
          },
          where: 'id = ?',
          whereArgs: [waiter['id']],
        );
        print('[Sync] Garson güncellendi (PIN korundu): ${waiter['name']}');
        return;
      }
    }

    await db.insert(
      'cached_waiters',
      {
        'id': waiter['id'],
        'name': waiter['name'],
        'pin': pinValue,
        'permissions': jsonEncode(waiter['permissions'] ?? []),
        'sections': jsonEncode(waiter['sections'] ?? []),
        'cached_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    print('[Sync] Garson cache\'lendi: ${waiter['name']} (PIN: $pinValue)');
  }

  // Cache'den garson getir (PIN ile)
  Future<Map<String, dynamic>?> getCachedWaiterByPin(String pin) async {
    final db = await _localDb.database;
    final results = await db.query(
      'cached_waiters',
      where: 'pin = ?',
      whereArgs: [pin],
    );

    if (results.isEmpty) return null;

    final waiter = Map<String, dynamic>.from(results.first);
    // JSON alanları parse et
    waiter['permissions'] = jsonDecode(waiter['permissions'] as String? ?? '[]');
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

  void dispose() {
    _syncTimer?.cancel();
  }
}
