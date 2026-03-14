import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class LocalDbService {
  static Database? _database;
  static final LocalDbService _instance = LocalDbService._internal();

  factory LocalDbService() => _instance;
  LocalDbService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // Init metodu - main.dart'tan cagrilir
  Future<void> init() async {
    await database; // Veritabani baglantisini baslat
  }

  Future<Database> _initDatabase() async {
    // macOS/Windows için FFI kullan
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'syncresto_pos.db');

    return await openDatabase(
      path,
      version: 2, // v2: depends_on_sync_id, offline_permissions eklendi
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Kategoriler cache
    await db.execute('''
      CREATE TABLE cached_categories (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT,
        sort_order INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        cached_at TEXT NOT NULL
      )
    ''');

    // Ürünler cache
    await db.execute('''
      CREATE TABLE cached_products (
        id INTEGER PRIMARY KEY,
        category_id INTEGER,
        name TEXT NOT NULL,
        description TEXT,
        price REAL NOT NULL,
        image TEXT,
        is_active INTEGER DEFAULT 1,
        is_out_of_stock INTEGER DEFAULT 0,
        extras TEXT,
        cached_at TEXT NOT NULL
      )
    ''');

    // Masalar cache
    await db.execute('''
      CREATE TABLE cached_tables (
        id INTEGER PRIMARY KEY,
        section_id INTEGER,
        section_name TEXT,
        table_number TEXT NOT NULL,
        capacity INTEGER DEFAULT 4,
        status TEXT DEFAULT 'available',
        current_ticket_id INTEGER,
        cached_at TEXT NOT NULL
      )
    ''');

    // Salonlar cache
    await db.execute('''
      CREATE TABLE cached_sections (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        color TEXT,
        table_count INTEGER DEFAULT 0,
        cached_at TEXT NOT NULL
      )
    ''');

    // Garsonlar cache
    await db.execute('''
      CREATE TABLE cached_waiters (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        pin TEXT,
        permissions TEXT,
        sections TEXT,
        cached_at TEXT NOT NULL
      )
    ''');

    // Yerel adisyonlar (offline açılanlar)
    await db.execute('''
      CREATE TABLE local_tickets (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        ticket_number TEXT NOT NULL,
        table_id INTEGER NOT NULL,
        table_number TEXT,
        waiter_id INTEGER NOT NULL,
        customer_count INTEGER DEFAULT 1,
        status TEXT DEFAULT 'open',
        subtotal REAL DEFAULT 0,
        discount_amount REAL DEFAULT 0,
        discount_type TEXT,
        total REAL DEFAULT 0,
        payment_method TEXT,
        opened_at TEXT NOT NULL,
        closed_at TEXT,
        synced INTEGER DEFAULT 0,
        synced_at TEXT,
        created_at TEXT NOT NULL,
        offline_permissions TEXT
      )
    ''');

    // Yerel adisyon kalemleri
    await db.execute('''
      CREATE TABLE local_ticket_items (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id INTEGER,
        local_ticket_id INTEGER NOT NULL,
        server_ticket_id INTEGER,
        product_id INTEGER NOT NULL,
        product_name TEXT NOT NULL,
        quantity INTEGER DEFAULT 1,
        unit_price REAL NOT NULL,
        custom_price REAL,
        notes TEXT,
        extras TEXT,
        status TEXT DEFAULT 'pending',
        synced INTEGER DEFAULT 0,
        synced_at TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (local_ticket_id) REFERENCES local_tickets(local_id)
      )
    ''');

    // Senkronizasyon kuyruğu
    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        local_id INTEGER,
        server_id INTEGER,
        payload TEXT NOT NULL,
        priority INTEGER DEFAULT 0,
        retry_count INTEGER DEFAULT 0,
        max_retries INTEGER DEFAULT 3,
        status TEXT DEFAULT 'pending',
        error_message TEXT,
        created_at TEXT NOT NULL,
        processed_at TEXT,
        depends_on_sync_id INTEGER,
        description TEXT
      )
    ''');

    // İndeksler
    await db.execute('CREATE INDEX idx_products_category ON cached_products(category_id)');
    await db.execute('CREATE INDEX idx_tables_section ON cached_tables(section_id)');
    await db.execute('CREATE INDEX idx_tickets_synced ON local_tickets(synced)');
    await db.execute('CREATE INDEX idx_items_ticket ON local_ticket_items(local_ticket_id)');
    await db.execute('CREATE INDEX idx_sync_status ON sync_queue(status)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('[LocalDb] Migration: $oldVersion -> $newVersion');

    if (oldVersion < 2) {
      // v2: sync_queue'ya depends_on_sync_id ve description ekle
      try {
        await db.execute('ALTER TABLE sync_queue ADD COLUMN depends_on_sync_id INTEGER');
        print('[LocalDb] sync_queue.depends_on_sync_id eklendi');
      } catch (e) {
        print('[LocalDb] depends_on_sync_id zaten var: $e');
      }

      try {
        await db.execute('ALTER TABLE sync_queue ADD COLUMN description TEXT');
        print('[LocalDb] sync_queue.description eklendi');
      } catch (e) {
        print('[LocalDb] description zaten var: $e');
      }

      // v2: local_tickets'a offline_permissions ve table_number ekle
      try {
        await db.execute('ALTER TABLE local_tickets ADD COLUMN offline_permissions TEXT');
        print('[LocalDb] local_tickets.offline_permissions eklendi');
      } catch (e) {
        print('[LocalDb] offline_permissions zaten var: $e');
      }

      try {
        await db.execute('ALTER TABLE local_tickets ADD COLUMN table_number TEXT');
        print('[LocalDb] local_tickets.table_number eklendi');
      } catch (e) {
        print('[LocalDb] table_number zaten var: $e');
      }
    }
  }

  // ==================== CACHE İŞLEMLERİ ====================

  // Kategorileri cache'le
  Future<void> cacheCategories(List<Map<String, dynamic>> categories) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.delete('cached_categories');
      for (final cat in categories) {
        await txn.insert('cached_categories', {
          'id': cat['id'],
          'name': cat['name'],
          'icon': cat['icon'],
          'sort_order': cat['sort_order'] ?? 0,
          'is_active': cat['is_active'] ?? 1,
          'cached_at': now,
        });
      }
    });
  }

  // Kategorileri getir
  Future<List<Map<String, dynamic>>> getCachedCategories() async {
    final db = await database;
    return await db.query('cached_categories', orderBy: 'sort_order ASC');
  }

  // Ürünleri cache'le
  Future<void> cacheProducts(List<Map<String, dynamic>> products) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.delete('cached_products');
      for (final prod in products) {
        await txn.insert('cached_products', {
          'id': prod['id'],
          'category_id': prod['category_id'],
          'name': prod['name'],
          'description': prod['description'],
          'price': prod['price'],
          'image': prod['image'],
          'is_active': prod['is_active'] ?? 1,
          'is_out_of_stock': prod['is_out_of_stock'] ?? 0,
          'extras': prod['extras']?.toString(),
          'cached_at': now,
        });
      }
    });
  }

  // Ürünleri getir
  Future<List<Map<String, dynamic>>> getCachedProducts() async {
    final db = await database;
    return await db.query('cached_products', where: 'is_active = 1');
  }

  // Salonları cache'le
  Future<void> cacheSections(List<Map<String, dynamic>> sections) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.delete('cached_sections');
      for (final sec in sections) {
        await txn.insert('cached_sections', {
          'id': sec['id'],
          'name': sec['name'],
          'color': sec['color'],
          'table_count': sec['table_count'] ?? 0,
          'cached_at': now,
        });
      }
    });
  }

  // Salonları getir
  Future<List<Map<String, dynamic>>> getCachedSections() async {
    final db = await database;
    return await db.query('cached_sections');
  }

  // Masaları cache'le
  Future<void> cacheTables(List<Map<String, dynamic>> tables) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.delete('cached_tables');
      for (final table in tables) {
        await txn.insert('cached_tables', {
          'id': table['id'],
          'section_id': table['section_id'],
          'section_name': table['section_name'],
          'table_number': table['table_number'],
          'capacity': table['capacity'] ?? 4,
          'status': table['status'] ?? 'available',
          'current_ticket_id': table['current_ticket_id'],
          'cached_at': now,
        });
      }
    });
  }

  // Masaları getir
  Future<List<Map<String, dynamic>>> getCachedTables() async {
    final db = await database;
    return await db.query('cached_tables');
  }

  // ==================== YEREL ADİSYON İŞLEMLERİ ====================

  // Yerel adisyon aç
  Future<int> createLocalTicket({
    required int tableId,
    required int waiterId,
    required String tableNumber,
    int customerCount = 1,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // Benzersiz ticket numarası: OFFLINE-{masa_no}-{UUID8}
    final uuid = const Uuid().v4().substring(0, 8).toUpperCase();
    final ticketNumber = 'OFFLINE-$tableNumber-$uuid';

    // Offline'da tüm yetkiler açık
    final offlinePermissions = jsonEncode({
      'close_ticket': true,
      'void_ticket': true,
      'payment_cash': true,
      'payment_card': true,
      'add_item': true,
      'cancel_item': true,
    });

    final localId = await db.insert('local_tickets', {
      'ticket_number': ticketNumber,
      'table_id': tableId,
      'table_number': tableNumber,
      'waiter_id': waiterId,
      'customer_count': customerCount,
      'status': 'open',
      'opened_at': now,
      'created_at': now,
      'synced': 0,
      'offline_permissions': offlinePermissions,
    });

    // Sync kuyruğuna ekle (bu sync_id'yi döndürmeli)
    final syncId = await addToSyncQueueWithReturn(
      action: 'create',
      entityType: 'ticket',
      localId: localId,
      payload: {
        'table_id': tableId,
        'waiter_id': waiterId,
        'customer_count': customerCount,
      },
      description: 'Masa $tableNumber: Adisyon açıldı',
    );

    // Local ticket'a sync_id'yi kaydet (item'lar bağımlılık için kullanacak)
    await db.update(
      'local_tickets',
      {'synced': syncId}, // synced alanını geçici olarak sync_id olarak kullan
      where: 'local_id = ?',
      whereArgs: [localId],
    );

    // Masa durumunu güncelle
    await db.update(
      'cached_tables',
      {'status': 'occupied'},
      where: 'id = ?',
      whereArgs: [tableId],
    );

    print('[LocalDb] Offline ticket oluşturuldu: $ticketNumber (local_id: $localId, sync_id: $syncId)');
    return localId;
  }

  // Yerel adisyonu getir
  Future<Map<String, dynamic>?> getLocalTicket(int localId) async {
    final db = await database;
    final results = await db.query(
      'local_tickets',
      where: 'local_id = ?',
      whereArgs: [localId],
    );

    if (results.isEmpty) return null;

    final ticket = Map<String, dynamic>.from(results.first);

    // local_id'yi id olarak da ekle (uyumluluk için)
    ticket['id'] = ticket['local_id'];

    // Kalemleri de getir
    final items = await db.query(
      'local_ticket_items',
      where: 'local_ticket_id = ?',
      whereArgs: [localId],
    );

    // Item'lara da id alanı ekle
    final processedItems = items.map((item) {
      final newItem = Map<String, dynamic>.from(item);
      newItem['id'] = newItem['local_id'];
      return newItem;
    }).toList();

    ticket['items'] = processedItems;

    // Subtotal hesapla
    double subtotal = 0;
    for (final item in items) {
      if (item['status'] != 'cancelled') {
        subtotal += (item['unit_price'] as num) * (item['quantity'] as num);
      }
    }
    ticket['subtotal'] = subtotal;
    ticket['total'] = subtotal - (ticket['discount_amount'] ?? 0);

    return ticket;
  }

  // Masanın açık adisyonunu getir
  Future<Map<String, dynamic>?> getTableTicket(int tableId) async {
    final db = await database;
    final results = await db.query(
      'local_tickets',
      where: 'table_id = ? AND status = ?',
      whereArgs: [tableId, 'open'],
    );

    if (results.isEmpty) return null;

    return getLocalTicket(results.first['local_id'] as int);
  }

  // Alias for getTableTicket
  Future<Map<String, dynamic>?> getLocalTicketByTable(int tableId) async {
    return getTableTicket(tableId);
  }

  // Adisyona ürün ekle (alias for addLocalTicketItem)
  Future<Map<String, dynamic>> addLocalTicketItem({
    required int localTicketId,
    required int productId,
    required String productName,
    required double unitPrice,
    int quantity = 1,
    String? notes,
    int waiterId = 1,
  }) async {
    final localId = await addTicketItem(
      localTicketId: localTicketId,
      productId: productId,
      productName: productName,
      unitPrice: unitPrice,
      quantity: quantity,
      notes: notes,
    );
    return {'id': localId, 'success': true};
  }

  // Adisyona ürün ekle
  Future<int> addTicketItem({
    required int localTicketId,
    required int productId,
    required String productName,
    required double unitPrice,
    int quantity = 1,
    String? notes,
    String? extras,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final localItemId = await db.insert('local_ticket_items', {
      'local_ticket_id': localTicketId,
      'product_id': productId,
      'product_name': productName,
      'quantity': quantity,
      'unit_price': unitPrice,
      'notes': notes,
      'extras': extras,
      'status': 'pending',
      'created_at': now,
      'synced': 0,
    });

    // Ticket'ın sync_id'sini al (bağımlılık için)
    final ticket = await getLocalTicket(localTicketId);
    final ticketSyncId = ticket?['synced'] as int?; // synced alanında sync_id tutuyoruz
    final tableNumber = ticket?['table_number'] ?? '';

    // Sync kuyruğuna ekle - ticket create'e bağımlı
    await addToSyncQueue(
      action: 'add_item',
      entityType: 'ticket_item',
      localId: localItemId,
      payload: {
        'local_ticket_id': localTicketId,
        'product_id': productId,
        'product_name': productName,
        'unit_price': unitPrice,
        'quantity': quantity,
        'notes': notes,
      },
      description: 'Masa $tableNumber: $productName x$quantity eklendi',
      dependsOnSyncId: (ticketSyncId != null && ticketSyncId > 0) ? ticketSyncId : null,
    );

    return localItemId;
  }

  // Adisyon kalemini iptal et
  Future<void> cancelTicketItem(int localItemId) async {
    final db = await database;

    await db.update(
      'local_ticket_items',
      {'status': 'cancelled'},
      where: 'local_id = ?',
      whereArgs: [localItemId],
    );

    // Sync kuyruğuna ekle
    await addToSyncQueue(
      action: 'cancel_item',
      entityType: 'ticket_item',
      localId: localItemId,
      payload: {'local_item_id': localItemId},
    );
  }

  // Adisyonu kapat (alias with waiterId)
  Future<void> closeLocalTicketWithWaiter({
    required int localTicketId,
    required String paymentMethod,
    double discountAmount = 0,
    String? discountType,
    int waiterId = 1,
  }) async {
    await closeLocalTicket(
      localTicketId: localTicketId,
      paymentMethod: paymentMethod,
      discountAmount: discountAmount,
      discountType: discountType,
    );
  }

  // Adisyonu kapat
  Future<void> closeLocalTicket({
    required int localTicketId,
    required String paymentMethod,
    double discountAmount = 0,
    String? discountType,
    int waiterId = 1,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // Subtotal hesapla
    final ticket = await getLocalTicket(localTicketId);
    if (ticket == null) return;

    final total = (ticket['subtotal'] as num) - discountAmount;
    final tableNumber = ticket['table_number'] ?? '';
    final ticketSyncId = ticket['synced'] as int?;

    await db.update(
      'local_tickets',
      {
        'status': 'closed',
        'payment_method': paymentMethod,
        'discount_amount': discountAmount,
        'discount_type': discountType,
        'total': total,
        'closed_at': now,
      },
      where: 'local_id = ?',
      whereArgs: [localTicketId],
    );

    // Masayı boşalt
    await db.update(
      'cached_tables',
      {'status': 'empty', 'current_ticket_id': null},
      where: 'id = ?',
      whereArgs: [ticket['table_id']],
    );
    print('[LocalDb] Masa boşaltıldı (close): ${ticket['table_id']}');

    // Ödeme yöntemi label
    final paymentLabel = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Kartı';

    // Sync kuyruğuna ekle - ticket create'e bağımlı
    await addToSyncQueue(
      action: 'close',
      entityType: 'ticket',
      localId: localTicketId,
      payload: {
        'payment_method': paymentMethod,
        'discount_amount': discountAmount,
        'discount_type': discountType,
        'waiter_id': waiterId,
      },
      priority: 1, // Yüksek öncelik
      description: 'Masa $tableNumber: Hesap kapatıldı ($paymentLabel)',
      dependsOnSyncId: (ticketSyncId != null && ticketSyncId > 0) ? ticketSyncId : null,
    );
  }

  // Adisyonu iptal et
  Future<void> voidLocalTicket({
    required int localTicketId,
    int waiterId = 1,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final ticket = await getLocalTicket(localTicketId);
    if (ticket == null) return;

    final tableNumber = ticket['table_number'] ?? '';
    final ticketSyncId = ticket['synced'] as int?;

    await db.update(
      'local_tickets',
      {
        'status': 'voided',
        'closed_at': now,
      },
      where: 'local_id = ?',
      whereArgs: [localTicketId],
    );

    // Masayı boşalt
    await db.update(
      'cached_tables',
      {'status': 'empty', 'current_ticket_id': null},
      where: 'id = ?',
      whereArgs: [ticket['table_id']],
    );
    print('[LocalDb] Masa boşaltıldı (void): ${ticket['table_id']}');

    // Sync kuyruğuna ekle - ticket create'e bağımlı
    await addToSyncQueue(
      action: 'void',
      entityType: 'ticket',
      localId: localTicketId,
      payload: {'waiter_id': waiterId},
      priority: 1,
      description: 'Masa $tableNumber: Adisyon iptal edildi',
      dependsOnSyncId: (ticketSyncId != null && ticketSyncId > 0) ? ticketSyncId : null,
    );
  }

  // ==================== SYNC KUYRUĞU ====================

  Future<void> addToSyncQueue({
    required String action,
    required String entityType,
    int? localId,
    int? serverId,
    required Map<String, dynamic> payload,
    int priority = 0,
    String? description,
    int? dependsOnSyncId,
  }) async {
    await addToSyncQueueWithReturn(
      action: action,
      entityType: entityType,
      localId: localId,
      serverId: serverId,
      payload: payload,
      priority: priority,
      description: description,
      dependsOnSyncId: dependsOnSyncId,
    );
  }

  // Sync kuyruğuna ekle ve sync_id döndür
  Future<int> addToSyncQueueWithReturn({
    required String action,
    required String entityType,
    int? localId,
    int? serverId,
    required Map<String, dynamic> payload,
    int priority = 0,
    String? description,
    int? dependsOnSyncId,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final syncId = await db.insert('sync_queue', {
      'action': action,
      'entity_type': entityType,
      'local_id': localId,
      'server_id': serverId,
      'payload': jsonEncode(payload),
      'priority': priority,
      'status': 'pending',
      'created_at': now,
      'description': description,
      'depends_on_sync_id': dependsOnSyncId,
    });

    print('[LocalDb] Sync queue eklendi: $action $entityType (sync_id: $syncId, depends_on: $dependsOnSyncId)');
    return syncId;
  }

  // Bekleyen sync işlemlerini getir
  Future<List<Map<String, dynamic>>> getPendingSyncItems() async {
    final db = await database;
    return await db.query(
      'sync_queue',
      where: 'status = ? AND retry_count < max_retries',
      whereArgs: ['pending'],
      orderBy: 'priority DESC, created_at ASC',
    );
  }

  // Belirli tip ve action için bekleyen sync işlemlerini getir
  Future<List<Map<String, dynamic>>> getPendingSyncItemsByType(
    String entityType,
    String action,
  ) async {
    final db = await database;
    return await db.query(
      'sync_queue',
      where: 'status = ? AND entity_type = ? AND action = ? AND retry_count < 3',
      whereArgs: ['pending', entityType, action],
      orderBy: 'created_at ASC',
    );
  }

  // Belirli entity type için bekleyen sync işlemlerini getir
  Future<List<Map<String, dynamic>>> getPendingSyncItemsByEntityType(
    String entityType,
  ) async {
    final db = await database;
    return await db.query(
      'sync_queue',
      where: 'status = ? AND entity_type = ? AND retry_count < 3',
      whereArgs: ['pending', entityType],
      orderBy: 'created_at ASC',
    );
  }

  // Sync işlemini tamamla
  Future<void> markSyncComplete(int syncId, {int? serverId}) async {
    final db = await database;
    final updateData = <String, dynamic>{
      'status': 'completed',
      'processed_at': DateTime.now().toIso8601String(),
    };
    if (serverId != null) {
      updateData['server_id'] = serverId;
    }
    await db.update(
      'sync_queue',
      updateData,
      where: 'id = ?',
      whereArgs: [syncId],
    );
  }

  // Sync işlemini hatalı işaretle
  Future<void> markSyncFailed(int syncId, String error) async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE sync_queue
      SET retry_count = retry_count + 1,
          error_message = ?,
          status = CASE WHEN retry_count + 1 >= max_retries THEN 'failed' ELSE 'pending' END
      WHERE id = ?
    ''', [error, syncId]);
  }

  // Yerel ticket'ı sunucu ID ile güncelle
  Future<void> updateTicketServerId(int localId, int serverId) async {
    final db = await database;
    await db.update(
      'local_tickets',
      {
        'server_id': serverId,
        'synced': 1,
        'synced_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // Yerel item'ı sunucu ID ile güncelle
  Future<void> updateItemServerId(int localId, int serverId) async {
    final db = await database;
    await db.update(
      'local_ticket_items',
      {
        'server_id': serverId,
        'synced': 1,
        'synced_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // Item'ın server ticket ID'sini güncelle
  Future<void> updateItemServerTicketId(int localItemId, int serverTicketId) async {
    final db = await database;
    await db.update(
      'local_ticket_items',
      {'server_ticket_id': serverTicketId},
      where: 'local_id = ?',
      whereArgs: [localItemId],
    );
  }

  // Cache'in ne kadar eski olduğunu kontrol et
  Future<bool> isCacheStale(String tableName, {Duration maxAge = const Duration(minutes: 30)}) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(cached_at) as last_cached FROM $tableName',
    );

    if (result.isEmpty || result.first['last_cached'] == null) {
      return true;
    }

    final lastCached = DateTime.parse(result.first['last_cached'] as String);
    return DateTime.now().difference(lastCached) > maxAge;
  }

  // Ayarları cache'le
  Future<void> cacheSettings(Map<String, dynamic> settings) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // settings tablosu yoksa oluştur
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cached_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');

    // Her ayarı kaydet
    for (final entry in settings.entries) {
      await db.insert(
        'cached_settings',
        {
          'key': entry.key,
          'value': entry.value?.toString() ?? '',
          'cached_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  // Ayarları getir
  Future<Map<String, dynamic>> getCachedSettings() async {
    final db = await database;
    try {
      final results = await db.query('cached_settings');
      final settings = <String, dynamic>{};
      for (final row in results) {
        settings[row['key'] as String] = row['value'];
      }
      return settings;
    } catch (e) {
      return {};
    }
  }

  // Tüm cache'i temizle
  Future<void> clearAllCache() async {
    final db = await database;
    await db.delete('cached_categories');
    await db.delete('cached_products');
    await db.delete('cached_tables');
    await db.delete('cached_sections');
  }

  // Masa durumunu güncelle
  Future<void> updateTableStatus(int tableId, String status, int? ticketId) async {
    final db = await database;
    await db.update(
      'cached_tables',
      {
        'status': status,
        'current_ticket_id': ticketId,
      },
      where: 'id = ?',
      whereArgs: [tableId],
    );
    print('[LocalDb] Masa durumu güncellendi: $tableId -> $status');
  }

  // Local ticket'ı kapatılmış olarak işaretle (server'da artık yok)
  Future<void> markTicketAsSynced(int localTicketId) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // Ticket'ı closed olarak işaretle
    await db.update(
      'local_tickets',
      {
        'status': 'closed',
        'closed_at': now,
      },
      where: 'local_id = ?',
      whereArgs: [localTicketId],
    );

    // İlgili sync queue kayıtlarını temizle
    await db.delete(
      'sync_queue',
      where: "entity_type = 'ticket' AND local_id = ?",
      whereArgs: [localTicketId],
    );

    print('[LocalDb] Ticket synced olarak işaretlendi: $localTicketId');
  }

  // Kapatılmış/sync edilmiş ticketları temizle
  // Online olunca çağrılır - server'daki güncel duruma göre local temizlenir
  Future<void> cleanupSyncedTickets() async {
    final db = await database;

    // Server'a sync edilmiş VE kapatılmış ticketları sil
    // (server_id != null AND status IN ('closed', 'voided'))
    final closedTickets = await db.query(
      'local_tickets',
      where: 'server_id IS NOT NULL AND status IN (?, ?)',
      whereArgs: ['closed', 'voided'],
    );

    for (final ticket in closedTickets) {
      final localId = ticket['local_id'] as int;

      // Bu ticket için pending sync işlemi var mı kontrol et
      final pendingSync = await db.query(
        'sync_queue',
        where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ?)",
        whereArgs: [localId, '%"local_ticket_id":$localId%'],
      );

      if (pendingSync.isNotEmpty) {
        print('[LocalDb] Ticket $localId için pending işlem var, temizlik atlanıyor');
        continue;
      }

      // Önce itemları sil
      await db.delete(
        'local_ticket_items',
        where: 'local_ticket_id = ?',
        whereArgs: [localId],
      );
      // Sonra ticketı sil
      await db.delete(
        'local_tickets',
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      print('[LocalDb] Kapatılmış ticket temizlendi: $localId');
    }

    // Tamamlanmış sync işlemlerini temizle (1 günden eski)
    final oneDayAgo = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
    await db.delete(
      'sync_queue',
      where: "status = 'completed' AND created_at < ?",
      whereArgs: [oneDayAgo],
    );

    // Başarısız sync işlemlerini temizle (retry_count >= 3)
    await db.delete(
      'sync_queue',
      where: "status = 'failed' AND retry_count >= 3",
    );

    print('[LocalDb] Cleanup tamamlandı');
  }

  // Server'daki açık ticketları local'e sync et
  // Bu masanın server'da ticket'ı var mı kontrol eder ve local'i günceller
  Future<void> syncOpenTicketsFromServer(List<Map<String, dynamic>> serverTables) async {
    final db = await database;

    for (final table in serverTables) {
      final tableId = table['id'] as int;
      final serverTicketId = table['current_ticket_id'];
      final status = table['status']?.toString() ?? 'empty';

      // Local'de bu masa için açık ticket var mı?
      final localTickets = await db.query(
        'local_tickets',
        where: 'table_id = ? AND status = ?',
        whereArgs: [tableId, 'open'],
      );

      if (status == 'empty' || serverTicketId == null) {
        // Server'da masa boş - local'deki açık ticketları kapat
        for (final localTicket in localTickets) {
          final localId = localTicket['local_id'] as int;
          // Server'da kapatılmış, local'de de kapat
          await db.update(
            'local_tickets',
            {'status': 'closed', 'closed_at': DateTime.now().toIso8601String()},
            where: 'local_id = ?',
            whereArgs: [localId],
          );
          print('[LocalDb] Server\'da kapalı masa, local ticket kapatıldı: $localId');
        }
      }

      // Cached tables tablosunu güncelle
      await db.update(
        'cached_tables',
        {
          'status': status,
          'current_ticket_id': serverTicketId,
        },
        where: 'id = ?',
        whereArgs: [tableId],
      );
    }
  }

  // Local ticket'ın item'larını getir
  Future<List<Map<String, dynamic>>> getItemsByLocalTicketId(int localTicketId) async {
    final db = await database;
    return await db.query(
      'local_ticket_items',
      where: 'local_ticket_id = ?',
      whereArgs: [localTicketId],
    );
  }

  // Offline data özeti (UI için)
  Future<Map<String, dynamic>> getOfflineDataSummary() async {
    final db = await database;

    // Bekleyen işlemler
    final pending = await db.query(
      'sync_queue',
      where: "status = 'pending'",
      orderBy: 'created_at ASC',
    );

    // Hatalı işlemler
    final failed = await db.query(
      'sync_queue',
      where: "status = 'failed' OR (status = 'pending' AND retry_count >= max_retries)",
    );

    // Son 24 saatte tamamlanan
    final oneDayAgo = DateTime.now().subtract(const Duration(days: 1)).toIso8601String();
    final completedResult = await db.rawQuery(
      "SELECT COUNT(*) as count FROM sync_queue WHERE status = 'completed' AND processed_at > ?",
      [oneDayAgo],
    );
    final completedCount = completedResult.first['count'] as int? ?? 0;

    return {
      'pending': pending.map((item) {
        return {
          'id': item['id'],
          'action': item['action'],
          'entity_type': item['entity_type'],
          'description': item['description'] ?? _generateDescription(item),
          'created_at': item['created_at'],
          'retry_count': item['retry_count'],
          'error_message': item['error_message'],
        };
      }).toList(),
      'failed': failed.map((item) {
        return {
          'id': item['id'],
          'action': item['action'],
          'entity_type': item['entity_type'],
          'description': item['description'] ?? _generateDescription(item),
          'created_at': item['created_at'],
          'retry_count': item['retry_count'],
          'error_message': item['error_message'],
        };
      }).toList(),
      'completed_count': completedCount,
      'pending_count': pending.length,
      'failed_count': failed.length,
    };
  }

  // Açıklama oluştur (eski kayıtlar için)
  String _generateDescription(Map<String, dynamic> item) {
    final action = item['action'] as String?;
    final entityType = item['entity_type'] as String?;

    if (entityType == 'ticket') {
      if (action == 'create') return 'Adisyon açıldı';
      if (action == 'close') return 'Hesap kapatıldı';
      if (action == 'void') return 'Adisyon iptal edildi';
    } else if (entityType == 'ticket_item') {
      if (action == 'add_item') return 'Ürün eklendi';
      if (action == 'cancel_item') return 'Ürün iptal edildi';
    }
    return '$action $entityType';
  }

  // Hatalı işlemi tekrar dene
  Future<void> retrySyncItem(int syncId) async {
    final db = await database;
    await db.update(
      'sync_queue',
      {
        'status': 'pending',
        'retry_count': 0,
        'error_message': null,
      },
      where: 'id = ?',
      whereArgs: [syncId],
    );
    print('[LocalDb] Sync item retry: $syncId');
  }

  // Hatalı işlemi sil
  Future<void> deleteSyncItem(int syncId) async {
    final db = await database;
    await db.delete(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [syncId],
    );
    print('[LocalDb] Sync item silindi: $syncId');
  }

  // Tüm hatalı işlemleri sil
  Future<void> clearFailedSyncItems() async {
    final db = await database;
    await db.delete(
      'sync_queue',
      where: "status = 'failed' OR (status = 'pending' AND retry_count >= max_retries)",
    );
    print('[LocalDb] Tüm hatalı işlemler temizlendi');
  }

  // Offline'da kapatılmış ama henüz sync olmamış masaların table_id'lerini getir
  // Bu methodla sunucudan gelen masa listesini güncelleyebiliriz
  Future<Set<int>> getOfflineClosedTableIds() async {
    final db = await database;

    // Closed veya voided olup, henüz sync olmamış ticketlar
    // synced = sync_id (0 değilse bir bağımlılık var demek), server_id = null (henüz sunucuya sync olmamış)
    final results = await db.query(
      'local_tickets',
      columns: ['table_id'],
      where: "status IN ('closed', 'voided') AND server_id IS NULL",
    );

    return results.map((r) => r['table_id'] as int).toSet();
  }

  // Offline'da açılmış ama henüz sync olmamış masaların table_id'lerini getir
  Future<Set<int>> getOfflineOpenTableIds() async {
    final db = await database;

    // Open olup, henüz sunucuya sync olmamış ticketlar
    final results = await db.query(
      'local_tickets',
      columns: ['table_id'],
      where: "status = 'open' AND server_id IS NULL",
    );

    return results.map((r) => r['table_id'] as int).toSet();
  }

  // Sunucu tablosunu offline değişikliklerle birleştir
  Future<List<Map<String, dynamic>>> mergeTablesWithOfflineChanges(
    List<Map<String, dynamic>> serverTables,
  ) async {
    final closedTableIds = await getOfflineClosedTableIds();
    final openTableIds = await getOfflineOpenTableIds();

    if (closedTableIds.isEmpty && openTableIds.isEmpty) {
      return serverTables;
    }

    print('[LocalDb] Offline değişiklikler birleştiriliyor - kapalı: $closedTableIds, açık: $openTableIds');

    return serverTables.map((table) {
      final tableId = table['id'] as int;
      final newTable = Map<String, dynamic>.from(table);

      // Offline'da kapatılan masa: boş göster
      if (closedTableIds.contains(tableId)) {
        newTable['status'] = 'empty';
        newTable['current_ticket_id'] = null;
        print('[LocalDb] Masa $tableId offline kapatıldı, empty gösteriliyor');
      }
      // Offline'da açılan masa: dolu göster
      else if (openTableIds.contains(tableId)) {
        newTable['status'] = 'occupied';
        print('[LocalDb] Masa $tableId offline açıldı, occupied gösteriliyor');
      }

      return newTable;
    }).toList();
  }

  // Veritabanını kapat
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
