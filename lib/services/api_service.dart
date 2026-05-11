import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_db_service.dart';
import 'connectivity_service.dart';
import 'sync_service.dart';
import 'log_service.dart';

class ApiService {
  static const String defaultBaseUrl = 'https://api.syncresto.com';

  late Dio _dio;
  String? _waiterToken;
  String? _apiKey;
  String _baseUrl = defaultBaseUrl;
  String? _backendUrl;

  String? get backendUrl => _backendUrl;

  void setBackendUrl(String? url) {
    _backendUrl = url;
    _syncService.setBackendUrl(url);
  }

  /// Converts relative image path to full URL using backend URL
  String getImageUrl(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) return '';
    if (imagePath.startsWith('http')) return imagePath;
    if (_backendUrl == null) return imagePath;
    return '$_backendUrl$imagePath';
  }

  final LocalDbService _localDb = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();
  final SyncService _syncService = SyncService();
  final LogService _logService = LogService();

  bool get isOnline => _connectivity.isOnline;

  ApiService() {
    _initDio();
  }

  void _initDio() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    _dio.interceptors.add(LogInterceptor(
      requestBody: false,
      responseBody: false,
      requestHeader: false,
      responseHeader: false,
      error: true,
      logPrint: (obj) { if (kDebugMode) print('[API] $obj'); },
    ));
  }

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _initDio();
    if (_apiKey != null) {
      _dio.options.headers['X-API-Key'] = _apiKey;
    }
    if (_waiterToken != null) {
      _dio.options.headers['Authorization'] = 'Bearer $_waiterToken';
    }
  }

  void setApiKey(String apiKey) {
    _apiKey = apiKey;
    _dio.options.headers['X-API-Key'] = apiKey;
  }

  Dio get dio => _dio;

  Future<void> initOfflineServices() async {
    await _localDb.init();
    await _connectivity.init();
    _syncService.init(_dio);

    // Online ise cache'i guncelle
    if (_connectivity.isOnline) {
      await _syncService.refreshCache();
    }
  }

  void setWaiterToken(String token) {
    _waiterToken = token;
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearWaiterToken() {
    _waiterToken = null;
    _dio.options.headers.remove('Authorization');
  }

  // =============================================
  // API Key Validation
  // =============================================

  Future<Map<String, dynamic>> validateApiKey(String apiKey, {bool force = false}) async {
    try {
      setApiKey(apiKey);

      // Device ID oluştur (cihaza özgü)
      final deviceId = await _getDeviceId();
      final deviceName = await _getDeviceName();

      final body = <String, dynamic>{
        'device_id': deviceId,
        'device_name': deviceName,
      };
      if (force) body['force'] = true;

      final response = await _dio.post('/api/pos/validate-key', data: body);

      if (response.data['valid'] == true) {
        return response.data;
      }
      return {
        'valid': false,
        'error': response.data['error'] ?? 'Gecersiz API Key',
      };
    } on DioException catch (e) {
      // 409 = Başka cihazda kullanılıyor
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        return {
          'valid': false,
          'error': 'DEVICE_CONFLICT',
          'message': data?['message'] ?? 'Bu API key baska bir cihazda kullanilmaktadir',
          'existing_device': data?['existing_device'] ?? 'Bilinmeyen Cihaz',
          'can_force': data?['can_force'] == true,
        };
      }
      return {
        'valid': false,
        'error': e.response?.data?['error'] ?? 'Baglanti hatasi',
      };
    }
  }

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('pos_device_id');
    if (id == null) {
      // Platform bilgisi + unique ID
      final info = await DeviceInfoPlugin().deviceInfo;
      final raw = '${info.data['systemName'] ?? Platform.operatingSystem}:${info.data['model'] ?? 'unknown'}:${DateTime.now().microsecondsSinceEpoch}';
      id = sha256.convert(utf8.encode(raw)).toString().substring(0, 32);
      await prefs.setString('pos_device_id', id);
    }
    return id;
  }

  Future<String> _getDeviceName() async {
    try {
      final info = await DeviceInfoPlugin().deviceInfo;
      return '${info.data['computerName'] ?? info.data['model'] ?? Platform.operatingSystem}';
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  // =============================================
  // Waiter Auth (Offline destekli)
  // =============================================

  Future<Map<String, dynamic>> waiterLogin(String pin) async {
    // Oncelikle online dene
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.post('/api/pos/waiters/login', data: {
          'pin': pin,
        });

        // Basarili ise garsonu cache'le
        if (response.data['success'] == true && response.data['waiter'] != null) {
          await _syncService.cacheWaiter(response.data['waiter']);
          _logService.logLogin(
            response.data['waiter']['id'] as int? ?? 0,
            response.data['waiter']['name'] as String? ?? 'Bilinmeyen',
          );
        } else {
          _logService.warning(LogType.login, 'Basarisiz giris denemesi (online)');
        }

        return response.data;
      } on DioException catch (e) {
        // 401/403 = API key geçersiz veya pasif - offline'a fallback YAPMA
        if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
          print('[API] API key gecersiz veya pasif: ${e.response?.statusCode}');
          _logService.error(LogType.login, 'API key gecersiz veya pasif', details: {
            'status': e.response?.statusCode,
            'error': e.response?.data?['error'],
          });
          // Cache'i temizle - kullanıcı artık bu cihazı kullanamaz
          await _syncService.clearAllCache();
          return {
            'success': false,
            'error': e.response?.data?['error'] ?? 'API key gecersiz veya pasif. Lutfen yoneticiyle iletisime gecin.',
            'api_key_invalid': true,
          };
        }

        // Network hatasi - offline dene
        print('[API] Online login basarisiz (network), offline deneniyor: ${e.message}');
        _logService.warning(LogType.login, 'Online login basarisiz, offline deneniyor', details: {'error': e.message});
      }
    }

    // Offline login - cache'den kontrol et
    print('[API] Offline login deneniyor...');
    final cachedWaiter = await _syncService.getCachedWaiterByPin(pin);

    if (cachedWaiter != null) {
      print('[API] Offline login basarili: ${cachedWaiter['name']}');
      _logService.logLogin(
        cachedWaiter['id'] as int? ?? 0,
        cachedWaiter['name'] as String? ?? 'Bilinmeyen',
      );
      _logService.info(LogType.login, 'Offline giris basarili', details: {'waiter': cachedWaiter['name']});
      return {
        'success': true,
        'waiter': cachedWaiter,
        'offline': true,
      };
    }

    _logService.warning(LogType.login, 'Basarisiz giris denemesi', details: {'offline': !_connectivity.isOnline});
    return {
      'success': false,
      'error': _connectivity.isOnline
          ? 'Giris basarisiz'
          : 'Internet yok ve bu PIN onceden giris yapmamis',
    };
  }

  // =============================================
  // Tables (Offline destekli)
  // =============================================

  Future<List<dynamic>> getSections() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/tables/sections');
        // Cache'e kaydet
        await _localDb.cacheSections(List<Map<String, dynamic>>.from(response.data));
        return response.data;
      } on DioException catch (e) {
        print('[API] Online sections basarisiz: ${e.message}');
      }
    }

    // Offline - cache'den getir
    print('[API] Sections cache\'den yukleniyor...');
    return await _localDb.getCachedSections();
  }

  Future<List<dynamic>> getTables() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/tables');
        final serverTables = List<Map<String, dynamic>>.from(response.data);

        // Cache'e kaydet
        await _localDb.cacheTables(serverTables);

        // Online modda server verisi doğrudur, offline merge yapma
        return serverTables;
      } on DioException catch (e) {
        print('[API] Online tables basarisiz: ${e.message}');
      }
    }

    // Offline - cache'den getir
    print('[API] Tables cache\'den yukleniyor...');
    return await _localDb.getCachedTables();
  }

  // Online olunca masa durumlarını sunucudan yenile
  Future<void> refreshTablesFromServer() async {
    if (!_connectivity.isOnline) return;

    try {
      final response = await _dio.get('/api/pos/tables');
      await _localDb.cacheTables(List<Map<String, dynamic>>.from(response.data));
      print('[API] Masa durumları server\'dan güncellendi');
    } catch (e) {
      print('[API] Masa güncelleme hatası: $e');
    }
  }

  // =============================================
  // Products & Categories (Offline destekli)
  // =============================================

  Future<List<dynamic>> getCategories() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/categories');
        // Cache'e kaydet
        await _localDb.cacheCategories(List<Map<String, dynamic>>.from(response.data));
        return response.data;
      } on DioException catch (e) {
        print('[API] Online categories basarisiz: ${e.message}');
      }
    }

    // Offline - cache'den getir
    print('[API] Categories cache\'den yukleniyor...');
    return await _localDb.getCachedCategories();
  }

  Future<List<dynamic>> getProducts() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/products');
        await _localDb.cacheProducts(List<Map<String, dynamic>>.from(response.data));
        return response.data;
      } on DioException catch (e) {
        if (kDebugMode) print('[API] Online products basarisiz: ${e.message}');
      }
    }
    return await _localDb.getCachedProducts();
  }

  // Cache-first (UI aninda yuklensin)
  Future<List<dynamic>> getCachedCategories() async => await _localDb.getCachedCategories();
  Future<List<dynamic>> getCachedProducts() async => await _localDb.getCachedProducts();

  // =============================================
  // Tickets (Adisyonlar) - Offline destekli
  // =============================================

  Future<Map<String, dynamic>> openTicket({
    required int tableId,
    required int waiterId,
    int customerCount = 1,
  }) async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.post('/api/pos/tickets/open', data: {
          'table_id': tableId,
          'waiter_id': waiterId,
          'customer_count': customerCount,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Masa acildi (online)', details: {
            'table_id': tableId,
            'ticket_id': response.data['ticket_id'],
            'waiter_id': waiterId,
          });
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online openTicket basarisiz: ${e.message}');
        _logService.warning(LogType.action, 'Online masa acma basarisiz', details: {'table_id': tableId, 'error': e.message});
      }
    }

    // Offline - local'de olustur ve sync queue'ya ekle
    print('[API] Offline ticket olusturuluyor...');

    // Masa numarasını bul
    final tables = await _localDb.getCachedTables();
    final table = tables.firstWhere(
      (t) => t['id'] == tableId,
      orElse: () => {'table_number': tableId.toString()},
    );
    final tableNumber = table['table_number']?.toString() ?? tableId.toString();

    final localTicketId = await _localDb.createLocalTicket(
      tableId: tableId,
      waiterId: waiterId,
      customerCount: customerCount,
      tableNumber: tableNumber,
    );

    // Oluşturulan ticket'ı getir
    final ticket = await _localDb.getLocalTicket(localTicketId);

    _logService.logAction('Masa acildi (offline)', details: {
      'table_id': tableId,
      'table_number': tableNumber,
      'local_ticket_id': localTicketId,
      'waiter_id': waiterId,
    });

    return {
      'success': true,
      'ticket_id': localTicketId,
      'ticket_number': ticket?['ticket_number'] ?? 'OFFLINE-$tableNumber',
      'offline': true,
      'offline_permissions': ticket?['offline_permissions'],
    };
  }

  Future<Map<String, dynamic>?> getTableTicket(int tableId) async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/tickets/table/$tableId');
        return response.data;
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          // Server'da ticket yok - local'deki açık ticket'ı da kapat
          final localTicket = await _localDb.getLocalTicketByTable(tableId);
          if (localTicket != null && localTicket['status'] == 'open') {
            // Server'da yoksa local'de de kapatılmalı (sync edilmiş demek)
            print('[API] Server\'da ticket yok, local ticket kapatılıyor...');
            await _localDb.markTicketAsSynced(localTicket['local_id'] ?? localTicket['id']);
          }
          // Masa tablosunu da güncelle - boş olarak işaretle
          await _localDb.updateTableStatus(tableId, 'empty', null);
          return null;
        }
        print('[API] Online getTableTicket basarisiz: ${e.message}');
      }
    }

    // Offline - local'den getir
    print('[API] Ticket cache\'den yukleniyor...');
    final localTicket = await _localDb.getLocalTicketByTable(tableId);
    if (localTicket != null && localTicket['status'] == 'open') {
      return _formatLocalTicket(localTicket);
    }
    return null;
  }

  Map<String, dynamic> _formatLocalTicket(Map<String, dynamic> localTicket) {
    return {
      'ticket': {
        'id': localTicket['server_id'] ?? localTicket['local_id'] ?? localTicket['id'],
        'local_id': localTicket['local_id'] ?? localTicket['id'],
        'table_id': localTicket['table_id'],
        'waiter_id': localTicket['waiter_id'],
        'waiter_name': 'Garson',
        'customer_count': localTicket['customer_count'],
        'ticket_number': localTicket['ticket_number'],
        'status': localTicket['status'],
        'subtotal': localTicket['subtotal'] ?? localTicket['total'] ?? 0,
        'total_amount': localTicket['total'] ?? localTicket['total_amount'] ?? 0,
        'discount_amount': localTicket['discount_amount'] ?? 0,
        'created_at': localTicket['created_at'] ?? localTicket['opened_at'],
        'duration_minutes': _calculateDuration(localTicket['opened_at']),
        'items': localTicket['items'] ?? [],
        'offline': localTicket['server_id'] == null,
      }
    };
  }

  int _calculateDuration(String? openedAt) {
    if (openedAt == null) return 0;
    try {
      final opened = DateTime.parse(openedAt);
      return DateTime.now().difference(opened).inMinutes;
    } catch (e) {
      return 0;
    }
  }

  Future<Map<String, dynamic>> addTicketItem({
    required int ticketId,
    required int productId,
    required String productName,
    required double unitPrice,
    int quantity = 1,
    String? notes,
    String? portion,
    int? waiterId,
    int? clientTempId,
    double extrasAmount = 0,
  }) async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.post('/api/pos/tickets/$ticketId/items', data: {
          'product_id': productId,
          'name': productName,
          'product_name': productName,
          'unit_price': unitPrice,
          'extras_amount': extrasAmount,
          'quantity': quantity,
          if (notes != null) 'notes': notes,
          if (portion != null) 'portion': portion,
          if (waiterId != null) 'waiter_id': waiterId,
          if (clientTempId != null) 'client_temp_id': clientTempId,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Urun eklendi (online)', details: {
            'ticket_id': ticketId,
            'product_id': productId,
            'product_name': productName,
            'quantity': quantity,
            'unit_price': unitPrice,
          });
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online addTicketItem basarisiz: ${e.message}');
        _logService.warning(LogType.action, 'Online urun ekleme basarisiz', details: {'ticket_id': ticketId, 'product_name': productName, 'error': e.message});
      }
    }

    // Offline - local'e ekle ve sync queue'ya ekle
    print('[API] Offline item ekleniyor...');

    // Ticket local mi server mi kontrol et
    final localTicket = await _localDb.getLocalTicket(ticketId);
    final localTicketId = localTicket != null ? ticketId : null;

    final localItem = await _localDb.addLocalTicketItem(
      localTicketId: localTicketId ?? ticketId,
      productId: productId,
      productName: productName,
      unitPrice: unitPrice,
      quantity: quantity,
      notes: notes,
      waiterId: waiterId ?? 1,
    );

    _logService.logAction('Urun eklendi (offline)', details: {
      'local_ticket_id': localTicketId ?? ticketId,
      'product_id': productId,
      'product_name': productName,
      'quantity': quantity,
      'unit_price': unitPrice,
    });

    return {
      'success': true,
      'item_id': localItem['id'],
      'offline': true,
    };
  }

  Future<Map<String, dynamic>> updateTicketItem({
    required int ticketId,
    required int itemId,
    int? quantity,
    String? notes,
    int? waiterId,
    double? unitPrice,
    double? extrasAmount,
  }) async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.put('/api/pos/tickets/$ticketId/items/$itemId', data: {
          if (quantity != null) 'quantity': quantity,
          if (notes != null) 'notes': notes,
          if (waiterId != null) 'waiter_id': waiterId,
          if (extrasAmount != null) 'extras_amount': extrasAmount,
          if (unitPrice != null && extrasAmount == null) 'unit_price': unitPrice,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Urun guncellendi', details: {
            'ticket_id': ticketId,
            'item_id': itemId,
            'quantity': quantity,
          });
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online updateTicketItem basarisiz: ${e.message}');
        _logService.error(LogType.error, 'Urun guncelleme hatasi', error: e, details: {'ticket_id': ticketId, 'item_id': itemId});
        rethrow;
      }
    }

    // OFFLINE — sync queue'ya update_item ekle, server_id resolve sync sirasinda yapilir
    _logService.logAction('Urun guncellendi (offline-queued)', details: {'ticket_id': ticketId, 'item_id': itemId, 'quantity': quantity});
    await _localDb.enqueueServerTicketAction(
      action: 'update_item',
      entityType: 'ticket_item',
      serverId: itemId, // backend itemId'yi PUT path'inde kullanacak
      payload: {
        'ticket_id': ticketId,
        if (quantity != null) 'quantity': quantity,
        if (notes != null) 'notes': notes,
        if (waiterId != null) 'waiter_id': waiterId,
        if (extrasAmount != null) 'extras_amount': extrasAmount,
        if (unitPrice != null && extrasAmount == null) 'unit_price': unitPrice,
      },
      description: 'Urun #$itemId offline guncellendi',
    );
    return {'success': true, 'offline': true, 'queued': true};
  }

  Future<Map<String, dynamic>> deleteTicketItem({
    required int ticketId,
    required int itemId,
    String? cancelReason,
    int? waiterId,
  }) async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.delete('/api/pos/tickets/$ticketId/items/$itemId', data: {
          'cancel_reason': cancelReason ?? 'Musteri istegi',
          if (waiterId != null) 'waiter_id': waiterId,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Urun silindi', details: {
            'ticket_id': ticketId,
            'item_id': itemId,
            'cancel_reason': cancelReason,
          });
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online deleteTicketItem basarisiz, offline path: ${e.message}');
        _logService.warning(LogType.action, 'Online delete basarisiz, offline path', details: {'ticket_id': ticketId, 'item_id': itemId});
        // Network hatasinda offline yola dus
      }
    }

    // OFFLINE — sync queue'ya delete_item (backend cancel_item) ekle
    _logService.logAction('Urun silindi (offline-queued)', details: {'ticket_id': ticketId, 'item_id': itemId, 'cancel_reason': cancelReason});
    await _localDb.enqueueServerTicketAction(
      action: 'delete_item',
      entityType: 'ticket_item',
      serverId: itemId,
      payload: {
        'ticket_id': ticketId,
        'cancel_reason': cancelReason ?? 'Musteri istegi',
        if (waiterId != null) 'waiter_id': waiterId,
      },
      description: 'Urun #$itemId offline silindi',
    );
    return {'success': true, 'offline': true, 'queued': true};
  }

  Future<Map<String, dynamic>> closeTicket({
    required int ticketId,
    required String paymentMethod,
    double discountAmount = 0,
    String? discountType,
    int? waiterId,
  }) async {
    // Lokal cache'te kayit varsa al
    final localTicket = await _localDb.getLocalTicket(ticketId);
    final serverId = localTicket != null ? localTicket['server_id'] as int? : null;

    // ONLINE + (saf server ticket VEYA cache'lenmis sync edilmis) -> direkt backend POST
    if (_connectivity.isOnline && (localTicket == null || serverId != null)) {
      final realTicketId = serverId ?? ticketId;
      try {
        final response = await _dio.post('/api/pos/tickets/$realTicketId/close', data: {
          'payment_method': paymentMethod,
          'discount_amount': discountAmount,
          if (discountType != null) 'discount_type': discountType,
          if (waiterId != null) 'waiter_id': waiterId,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Adisyon kapatildi (online)', details: {
            'ticket_id': realTicketId,
            'payment_method': paymentMethod,
            'discount_amount': discountAmount,
          });
          // Lokal cache'te de kapat (masa anlik bosalsin)
          if (localTicket != null) {
            await _localDb.closeLocalTicket(
              localTicketId: ticketId,
              paymentMethod: paymentMethod,
              discountAmount: discountAmount,
              discountType: discountType,
              waiterId: waiterId ?? 1,
            );
          }
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online closeTicket basarisiz, offline path: ${e.message}');
        _logService.warning(LogType.action, 'Online close basarisiz, offline path', details: {'ticket_id': realTicketId});
        // Network hatasinda offline path'e dus
      }
    }

    // OFFLINE veya henuz sync olmamis lokal ticket -> lokal kapat + sync queue
    if (localTicket != null) {
      print('[API] Local ticket kapatiliyor: $ticketId (server_id=$serverId)');
      await _localDb.closeLocalTicket(
        localTicketId: ticketId,
        paymentMethod: paymentMethod,
        discountAmount: discountAmount,
        discountType: discountType,
        waiterId: waiterId ?? 1,
      );

      _logService.logAction('Adisyon kapatildi (local)', details: {
        'local_ticket_id': ticketId,
        'server_id': serverId,
        'payment_method': paymentMethod,
        'discount_amount': discountAmount,
        'total': localTicket['total'],
      });

      // Online ise hemen sync'i tetikle (arka planda)
      if (_connectivity.isOnline) {
        _syncService.syncPendingItems();
      }
      return {'success': true, 'offline': true};
    }

    // SADECE server ticket'i + offline + lokal cache yok -> manuel cache + sync queue (recovery)
    // Bu nadir senaryo: kullanici online iken masaya bakmadan internet kesildi, masa zaten acik (server'da var)
    // Bu durumda ticketId'yi server_id olarak kabul et, sync_queue'ya ekle
    print('[API] Server ticket offline kapama (cache yok, recovery): $ticketId');
    await _localDb.enqueueServerTicketAction(
      action: 'close',
      serverId: ticketId,
      payload: {
        'payment_method': paymentMethod,
        'discount_amount': discountAmount,
        if (discountType != null) 'discount_type': discountType,
        if (waiterId != null) 'waiter_id': waiterId,
      },
      description: 'Server ticket #$ticketId offline kapatildi',
    );
    _logService.logAction('Adisyon kapatildi (offline-recovery)', details: {
      'server_ticket_id': ticketId,
      'payment_method': paymentMethod,
    });
    return {'success': true, 'offline': true, 'queued': true};
  }

  Future<Map<String, dynamic>> voidTicket({
    required int ticketId,
    String? reason,
    int? waiterId,
  }) async {
    // Lokal cache'te kayit varsa al — server_id'sine bakacagiz
    final localTicket = await _localDb.getLocalTicket(ticketId);
    final serverId = localTicket != null ? localTicket['server_id'] as int? : null;

    // ONLINE + (saf server ticket VEYA lokal cache'i sync edilmis ticket) -> direkt backend'e POST
    // Bu sayede log'a dusuyor, panel anlik gosteriyor, sebep dogru kayit oluyor.
    if (_connectivity.isOnline && (localTicket == null || serverId != null)) {
      final realTicketId = serverId ?? ticketId;
      try {
        final response = await _dio.post('/api/pos/tickets/$realTicketId/void', data: {
          'reason': reason ?? 'Iptal',
          if (waiterId != null) 'waiter_id': waiterId,
        });
        if (response.data['success'] == true) {
          _logService.logAction('Adisyon iptal edildi (online)', details: {
            'ticket_id': realTicketId,
            'reason': reason,
          });
          // Lokal cache'te de void isaretle ki masa hemen bosalsin
          if (localTicket != null) {
            await _localDb.voidLocalTicket(
              localTicketId: ticketId,
              waiterId: waiterId ?? 1,
              reason: reason,
            );
            // Lokal sync queue'ya eklenen 'void' action'i temizle (cunku zaten online yaptik)
            // Not: voidLocalTicket sync_queue'ya 'void' ekledi, ama biz online basardik. Yine kalsin
            // (sync_service zaten server_id varsa skip eder).
          }
        }
        return response.data;
      } on DioException catch (e) {
        print('[API] Online voidTicket basarisiz: ${e.message}');
        _logService.error(LogType.error, 'Adisyon iptal hatasi', error: e, details: {'ticket_id': realTicketId});
        return {'success': false, 'error': e.message};
      }
    }

    // OFFLINE veya henuz sync olmamis (server_id NULL) lokal ticket -> sadece lokal void + queue
    if (localTicket != null) {
      print('[API] Local ticket iptal ediliyor: $ticketId (server_id=$serverId)');
      await _localDb.voidLocalTicket(
        localTicketId: ticketId,
        waiterId: waiterId ?? 1,
        reason: reason,
      );

      _logService.logAction('Adisyon iptal edildi (local)', details: {
        'local_ticket_id': ticketId,
        'reason': reason,
      });

      // Online geri gelirse hemen sync tetikle
      if (_connectivity.isOnline) {
        _syncService.syncPendingItems();
      }
      return {'success': true, 'offline': true};
    }

    // SADECE server ticket'i + offline + lokal cache yok -> recovery: sync_queue'ya ekle
    print('[API] Server ticket offline iptal (cache yok, recovery): $ticketId');
    await _localDb.enqueueServerTicketAction(
      action: 'void',
      serverId: ticketId,
      payload: {
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (waiterId != null) 'waiter_id': waiterId,
      },
      description: 'Server ticket #$ticketId offline iptal edildi${reason != null ? " ($reason)" : ""}',
    );
    _logService.logAction('Adisyon iptal edildi (offline-recovery)', details: {
      'server_ticket_id': ticketId,
      'reason': reason,
    });
    return {'success': true, 'offline': true, 'queued': true};
  }

  /// İptal sebeplerini getir — online cache update + offline cache fallback
  Future<List<dynamic>> getCancelReasons() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/cancel-reasons');
        final list = (response.data as List?) ?? [];
        // Cache update — offline icin
        try {
          await _localDb.cacheLookups(
            lookupType: 'cancel_reasons',
            rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
        } catch (_) {}
        return list;
      } catch (e) {
        print('[API] getCancelReasons hatası, cache fallback: $e');
        // Network hatasinda cache fallback
        return await _localDb.getCachedLookups(lookupType: 'cancel_reasons');
      }
    }
    // Offline: direkt cache
    final cached = await _localDb.getCachedLookups(lookupType: 'cancel_reasons');
    print('[API] getCancelReasons offline cache: ${cached.length} kayit');
    return cached;
  }

  /// Ürün notlarını getir — online cache update + offline cache fallback
  Future<List<dynamic>> getProductNotes() async {
    if (_connectivity.isOnline) {
      try {
        final response = await _dio.get('/api/pos/product-notes');
        final list = (response.data as List?) ?? [];
        try {
          await _localDb.cacheLookups(
            lookupType: 'product_notes',
            rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
        } catch (_) {}
        return list;
      } catch (e) {
        print('[API] getProductNotes hatası, cache fallback: $e');
        return await _localDb.getCachedLookups(lookupType: 'product_notes');
      }
    }
    final cached = await _localDb.getCachedLookups(lookupType: 'product_notes');
    print('[API] getProductNotes offline cache: ${cached.length} kayit');
    return cached;
  }

  Future<List<dynamic>> getGlobalVariants({int? categoryId}) async {
    if (_connectivity.isOnline) {
      try {
        final url = categoryId != null
            ? '/api/pos/global/variants/active?category_id=$categoryId'
            : '/api/pos/global/variants/active';
        final response = await _dio.get(url);
        final list = (response.data as List?) ?? [];
        try {
          await _localDb.cacheLookups(
            lookupType: 'global_variants',
            categoryId: categoryId,
            rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
        } catch (_) {}
        return list;
      } catch (e) {
        print('[API] getGlobalVariants error, cache fallback: $e');
        return await _localDb.getCachedLookups(lookupType: 'global_variants', categoryId: categoryId);
      }
    }
    return await _localDb.getCachedLookups(lookupType: 'global_variants', categoryId: categoryId);
  }

  Future<List<dynamic>> getGlobalExtras({int? categoryId}) async {
    if (_connectivity.isOnline) {
      try {
        final url = categoryId != null
            ? '/api/pos/global/extras/active?category_id=$categoryId'
            : '/api/pos/global/extras/active';
        final response = await _dio.get(url);
        final list = (response.data as List?) ?? [];
        try {
          await _localDb.cacheLookups(
            lookupType: 'global_extras',
            categoryId: categoryId,
            rows: list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
        } catch (_) {}
        return list;
      } catch (e) {
        print('[API] getGlobalExtras error, cache fallback: $e');
        return await _localDb.getCachedLookups(lookupType: 'global_extras', categoryId: categoryId);
      }
    }
    return await _localDb.getCachedLookups(lookupType: 'global_extras', categoryId: categoryId);
  }

  /// Parçalı ödeme - seçili ürünleri öde
  Future<Map<String, dynamic>> payItems({
    required int ticketId,
    required List<int> itemIds,
    required String paymentMethod,
    int? waiterId,
  }) async {
    if (!_connectivity.isOnline) {
      return {'success': false, 'error': 'Parçalı ödeme için internet gerekli'};
    }
    try {
      final response = await _dio.post('/api/pos/tickets/$ticketId/pay-items', data: {
        'item_ids': itemIds,
        'payment_method': paymentMethod,
        if (waiterId != null) 'waiter_id': waiterId,
      });
      return response.data;
    } on DioException catch (e) {
      print('[API] payItems hatası: status=${e.response?.statusCode} body=${e.response?.data}');
      String errorMsg;
      if (e.response?.statusCode == 404) {
        errorMsg = 'Adisyon sunucuda bulunamadi. Lutfen sayfayi tazeleyip tekrar deneyin.';
      } else {
        errorMsg = e.response?.data is Map
            ? (e.response!.data['error']?.toString() ?? 'Odeme basarisiz')
            : (e.message ?? 'Odeme basarisiz');
      }
      return {'success': false, 'error': errorMsg};
    }
  }

  Future<Map<String, dynamic>> transferTable({
    required int ticketId,
    required int newTableId,
    required int waiterId,
  }) async {
    if (!_connectivity.isOnline) {
      _logService.warning(LogType.action, 'Masa degistirme basarisiz: internet yok', details: {'ticket_id': ticketId, 'new_table_id': newTableId});
      return {'success': false, 'error': 'Masa degistirme icin internet gerekli'};
    }

    try {
      final response = await _dio.post(
        '/api/pos/tickets/$ticketId/transfer',
        data: {
          'new_table_id': newTableId,
          'waiter_id': waiterId,
        },
      );
      if (response.data['success'] == true) {
        _logService.logAction('Masa degistirildi', details: {
          'ticket_id': ticketId,
          'new_table_id': newTableId,
          'waiter_id': waiterId,
        });
      }
      return response.data;
    } catch (e) {
      print('[API] transferTable error: $e');
      _logService.error(LogType.error, 'Masa degistirme hatasi', error: e, details: {'ticket_id': ticketId, 'new_table_id': newTableId});
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> applyDiscount({
    required int ticketId,
    required String discountType,
    required double discountValue,
    required int waiterId,
  }) async {
    try {
      final response = await _dio.post('/api/pos/tickets/$ticketId/discount', data: {
        'discount_type': discountType,
        'discount_value': discountValue,
        'waiter_id': waiterId,
      });
      return Map<String, dynamic>.from(response.data);
    } catch (e) {
      print('[API] applyDiscount error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // =============================================
  // Settings
  // =============================================

  Future<Map<String, dynamic>> getSettings() async {
    final response = await _dio.get('/api/pos/settings');
    return response.data;
  }

  // =============================================
  // Printers (Yazıcılar) - SADECE OKUMA
  // =============================================

  /// Sunucudan yazıcı listesini çek (read-only)
  /// Güvenlik: Sadece GET isteği, veri değişikliği yok
  Future<List<Map<String, dynamic>>> getPrinters() async {
    if (!_connectivity.isOnline) {
      print('[API] getPrinters: Çevrimdışı, boş liste dönüyor');
      return [];
    }

    try {
      final response = await _dio.get(
        '/api/pos/printers',
        options: Options(
          receiveTimeout: const Duration(seconds: 5), // Kısa timeout
        ),
      );

      if (response.data is List) {
        // Sadece gerekli alanları al, hassas veri filtrele
        return (response.data as List).map((p) {
          // IP ve port validation
          final ip = p['ip_address']?.toString() ?? '';
          final port = p['port'] is int ? p['port'] : 9100;

          // Basit IP formatı kontrolü (güvenlik)
          if (!_isValidIpAddress(ip)) {
            print('[API] Geçersiz IP formatı atlandı: $ip');
            return null;
          }

          return <String, dynamic>{
            'id': p['id'],
            'name': p['name']?.toString() ?? 'Yazıcı',
            'ip': ip,
            'port': port,
            'type': p['type']?.toString() ?? 'thermal',
            'departments': p['departments'] ?? [],
            'is_active': p['is_active'] == 1,
          };
        }).whereType<Map<String, dynamic>>().toList();
      }

      return [];
    } on DioException catch (e) {
      print('[API] getPrinters hatası: ${e.message}');
      return [];
    } catch (e) {
      print('[API] getPrinters beklenmeyen hata: $e');
      return [];
    }
  }

  /// IP adresi formatı doğrulama (güvenlik)
  bool _isValidIpAddress(String ip) {
    if (ip.isEmpty) return false;

    // IPv4 formatı: x.x.x.x (her segment 0-255)
    final parts = ip.split('.');
    if (parts.length != 4) return false;

    for (final part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }

    // Sadece private IP aralıklarına izin ver (güvenlik)
    // 10.x.x.x, 172.16-31.x.x, 192.168.x.x
    final first = int.parse(parts[0]);
    final second = int.parse(parts[1]);

    if (first == 10) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && second == 168) return true;

    print('[API] Public IP reddedildi (güvenlik): $ip');
    return false;
  }

  // =============================================
  // Kitchen Print (Mutfak Fişi)
  // =============================================

  /// Yazdırılmamış ürünleri getir ve yazdırıldı olarak işaretle
  // =============================================
  // MASA TAKIP (Sipariş Takip)
  // =============================================

  // Tum acik adisyonlarin acik item'larini tek sorguda getir
  Future<List<dynamic>> getPendingOrders() async {
    if (!_connectivity.isOnline) return [];
    try {
      final response = await _dio.get('/api/pos/tickets/pending-orders');
      return (response.data['rows'] as List?) ?? [];
    } on DioException catch (_) {
      return [];
    } catch (_) {
      return [];
    }
  }

  // Kalem teslim toggle (delivered_at null<->now())
  Future<Map<String, dynamic>> markItemAsServed({
    required int ticketId,
    required int itemId,
    int? waiterId,
  }) async {
    if (!_connectivity.isOnline) {
      return {'success': false, 'error': 'Internet gerekli'};
    }
    try {
      final response = await _dio.post(
        '/api/pos/tickets/$ticketId/items/$itemId/mark-served',
        data: { if (waiterId != null) 'waiter_id': waiterId },
      );
      if (response.data['success'] == true) {
        _logService.logAction('Kalem teslim toggle', details: {
          'ticket_id': ticketId, 'item_id': itemId,
          'action': response.data['action'],
        });
      }
      return response.data;
    } on DioException catch (e) {
      return {'success': false, 'error': e.response?.data?['error'] ?? e.message};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> printKitchen({
    required int ticketId,
    int? waiterId,
  }) async {
    // OFFLINE PATH: lokal cache'lerden urun + yazici hesaplamasi yap, ayni format don.
    // - cached_products.printer_id (urun yazicisi)
    // - cached_sections.summary_printer_id (ozet fis)
    // - cached_printers (ip+port)
    // - local_ticket_items.printed=0 (yazdirilmamis urunler)
    // Yazdirma sonrasi mark_printed sync_queue'ya eklenir, online olunca backend'e printed=1 sync.
    if (!_connectivity.isOnline) {
      try {
        final result = await _buildOfflineKitchenResult(ticketId);
        if (result == null) {
          return {'success': false, 'error': 'Lokal ticket bulunamadi (offline)'};
        }
        // Sync queue'ya mark_printed ekle
        final items = result['items'] as List? ?? [];
        if (items.isNotEmpty) {
          final localItemIds = items.map((i) => i['local_id']).whereType<int>().toList();
          if (localItemIds.isNotEmpty) {
            await _localDb.markLocalItemsPrinted(localItemIds);
          }
          // Online olunca backend'e printed=1 sync icin enqueue
          await _localDb.enqueueServerTicketAction(
            action: 'mark_printed',
            entityType: 'ticket',
            serverId: ticketId, // server_id resolve sync sirasinda
            payload: {
              'item_local_ids': localItemIds,
              if (waiterId != null) 'waiter_id': waiterId,
            },
            description: 'Mutfak fisi offline yazdirildi (#$ticketId)',
          );
        }
        return result;
      } catch (e) {
        _logService.error(LogType.error, 'Offline mutfak fisi hesapla hatasi', error: e, details: {'ticket_id': ticketId});
        return {'success': false, 'error': 'Offline mutfak fisi hatasi: $e'};
      }
    }

    try {
      final response = await _dio.post('/api/pos/tickets/$ticketId/print-kitchen', data: {
        if (waiterId != null) 'waiter_id': waiterId,
      });
      if (response.data['success'] == true) {
        final itemCount = (response.data['items'] as List?)?.length ?? 0;
        _logService.logAction('Mutfak fisi gonderildi', details: {
          'ticket_id': ticketId,
          'item_count': itemCount,
        });
      }
      return response.data;
    } on DioException catch (e) {
      print('[API] printKitchen hatası: ${e.message}');
      _logService.error(LogType.error, 'Mutfak fisi gonderme hatasi', error: e, details: {'ticket_id': ticketId});
      return {'success': false, 'error': e.response?.data?['error'] ?? e.message};
    }
  }

  /// Yaziciya basariyla bastiktan sonra item'lari printed=1 isaretle.
  /// Yazici fail olursa BU CAGRI YAPILMAZ; printed=0 kalir, sonraki "Mutfaga
  /// Gonder" tekrar dener (sessiz kayip onleme).
  ///
  /// jobIds: panel_print_jobs telemetri kayitlari (printed olarak isaretlenir).
  Future<bool> markItemsPrinted({
    required int ticketId,
    required List<int> itemIds,
    List<int>? jobIds,
  }) async {
    if (itemIds.isEmpty && (jobIds == null || jobIds.isEmpty)) return true;
    if (!_connectivity.isOnline) {
      _logService.warning(LogType.action, 'mark-items-printed atlandi: cevrimdisi', details: {
        'ticket_id': ticketId,
        'item_ids': itemIds,
        'job_ids': jobIds,
      });
      return false;
    }
    try {
      final response = await _dio.post(
        '/api/pos/tickets/$ticketId/mark-items-printed',
        data: {
          'item_ids': itemIds,
          if (jobIds != null && jobIds.isNotEmpty) 'job_ids': jobIds,
        },
      );
      return response.data['success'] == true;
    } on DioException catch (e) {
      print('[API] markItemsPrinted hatasi: ${e.message}');
      _logService.error(LogType.error, 'mark-items-printed hatasi', error: e, details: {
        'ticket_id': ticketId,
        'item_ids': itemIds,
        'job_ids': jobIds,
      });
      return false;
    }
  }

  /// Yazdirma fail oldu — telemetriye bildir.
  /// Sunucuda panel_print_jobs.status = 'failed', failed_at = NOW(), error doldurulur.
  Future<bool> reportPrintFailed({
    required int ticketId,
    required int jobId,
    required String error,
  }) async {
    if (!_connectivity.isOnline) return false;
    try {
      final response = await _dio.post(
        '/api/pos/tickets/$ticketId/report-print-failed',
        data: {'job_id': jobId, 'error': error},
      );
      return response.data['success'] == true;
    } on DioException catch (e) {
      print('[API] reportPrintFailed hatasi: ${e.message}');
      return false;
    }
  }

  /// Yazici heartbeat — periyodik olarak DLE EOT 1 sonucunu sunucuya yaz.
  /// Sunucuda panel_pos_printers.last_seen_at, last_status, last_error guncellenir.
  Future<bool> printerHeartbeat({
    required int printerId,
    required String status, // 'online' | 'offline' | 'paper_out' | 'cover_open'
    String? error,
  }) async {
    if (!_connectivity.isOnline) return false;
    try {
      final response = await _dio.post(
        '/api/pos/printers/$printerId/heartbeat',
        data: {
          'status': status,
          if (error != null) 'error': error,
        },
      );
      return response.data['success'] == true;
    } on DioException catch (e) {
      // Heartbeat patlamasi POS akisini etkilemesin — sadece sessiz logla
      print('[API] printerHeartbeat hatasi: ${e.message}');
      return false;
    }
  }

  // =============================================
  // Sync & Connectivity
  // =============================================

  Future<void> syncPendingItems() async {
    await _syncService.syncPendingItems();
  }

  Future<void> refreshCache() async {
    await _syncService.refreshCache();
  }

  // =============================================
  // Offline Data Management
  // =============================================

  /// Offline işlemlerin özetini getir (UI için)
  Future<Map<String, dynamic>> getOfflineDataSummary() async {
    return await _syncService.getSyncStatus();
  }

  /// Hatalı işlemi tekrar dene
  Future<void> retrySyncItem(int syncId) async {
    await _syncService.retrySyncItem(syncId);
  }

  /// Hatalı işlemi sil
  Future<void> deleteSyncItem(int syncId) async {
    await _syncService.deleteSyncItem(syncId);
  }

  /// Tüm hatalı işlemleri temizle
  Future<void> clearFailedSyncItems() async {
    await _syncService.clearFailedItems();
  }

  // OFFLINE MUTFAK FISI HESABI — backend printKitchen mantigi lokal'de
  // Cikti formati backend ile birebir ayni ki add_item_modal._sendToKitchen
  // hem online hem offline ayni kodla calissin.
  // Format: { success, items, ticket, printerGroups: [{printer_id, printer_name,
  //          printer_ip, printer_port, items, type}] }
  Future<Map<String, dynamic>?> _buildOfflineKitchenResult(int ticketId) async {
    // Lokal ticket cache + section + summary_printer_id
    final ticketRow = await _localDb.getLocalTicketWithSection(ticketId);
    if (ticketRow == null) return null;
    // summary_printer_id JOIN'le geldi (cached_sections.summary_printer_id)
    int? summaryPrinterId = ticketRow['summary_printer_id'] as int?;

    // Yazdirilmamis itemlar (printed=0 + active)
    final unprinted = await _localDb.getUnprintedLocalItems(ticketId);
    if (unprinted.isEmpty) {
      return {
        'success': true,
        'message': 'Yazdirilacak yeni urun yok',
        'items': [],
        'ticket': {
          'ticket_number': ticketRow['ticket_number'],
          'table_number': ticketRow['table_number'],
          'section_name': ticketRow['section_name'],
          'waiter_name': ticketRow['waiter_name'],
        },
        'printerGroups': [],
      };
    }

    // Yazici gruplari olustur
    final Map<String, Map<String, dynamic>> printerGroups = {};
    for (final item in unprinted) {
      final printerId = item['printer_id'] as int?;
      final groupKey = printerId != null ? printerId.toString() : 'default';
      if (!printerGroups.containsKey(groupKey)) {
        Map<String, dynamic>? printer = printerId != null
            ? await _localDb.getCachedPrinterById(printerId)
            : null;
        printerGroups[groupKey] = {
          'printer_id': printerId,
          'printer_name': printer?['name'] ?? 'Varsayilan',
          'printer_ip': printer?['ip_address'],
          'printer_port': printer?['port'] ?? 9100,
          'items': <Map<String, dynamic>>[],
          'type': 'kitchen',
        };
      }
      (printerGroups[groupKey]!['items'] as List).add(item);
    }

    // Ozet fis yazicisi (varsa, tum unprinted itemlari icerir)
    if (summaryPrinterId != null) {
      final summaryPrinter = await _localDb.getCachedPrinterById(summaryPrinterId);
      if (summaryPrinter != null) {
        printerGroups['summary_$summaryPrinterId'] = {
          'printer_id': summaryPrinterId,
          'printer_name': summaryPrinter['name'] ?? 'Ozet Fis',
          'printer_ip': summaryPrinter['ip_address'],
          'printer_port': summaryPrinter['port'] ?? 9100,
          'items': unprinted,
          'type': 'summary',
        };
      }
    }

    return {
      'success': true,
      'offline': true,
      'items': unprinted,
      'ticket': {
        'ticket_number': ticketRow['ticket_number'],
        'table_number': ticketRow['table_number'],
        'section_name': ticketRow['section_name'],
        'waiter_name': ticketRow['waiter_name'],
      },
      'printerGroups': printerGroups.values.toList(),
    };
  }

  void dispose() {
    _syncService.dispose();
    _connectivity.dispose();
  }
}
