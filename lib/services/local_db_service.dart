import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class LocalDbService {
  static Database? _database;
  // 12 Haz 2026: sabitlenmiş mutlak DB yolu (cache) — _resolveDbPath() doldurur
  static String? _dbPath;
  // 12 Haz 2026: cacheTables/cacheSections hash-diff — aynı veri tekrar yazılmasın
  // (2sn'lik masa poll'u günde ~86K gereksiz delete+insert transaction'ı yapıyordu)
  static String? _lastTablesHash;
  static String? _lastSectionsHash;
  // 12 Haz 2026: print_queue completed temizliği throttle (getPendingPrintJobs içinde)
  static DateTime? _lastPrintCleanupAt;
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

    final path = await _resolveDbPath();

    // 12 Haz 2026: eski CWD-relatif konumdaki DB varsa yeni konuma taşı (tek seferlik)
    await _migrateLegacyDbIfNeeded(path);

    return await openDatabase(
      path,
      version: 9, // v9 (7 Tem 2026): LAN-senkron — local_tickets'e owner_device_id/lan_lease_until/lan_origin
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      // Sahada: sync_service + print_queue_service + tables_screen aynı anda
      // BEGIN IMMEDIATE acinca lock çatisiyor → masalar yuklenemiyor (kirmizi bar).
      onConfigure: (db) async {
        // WAL mode: write-ahead logging — bircok reader + 1 writer paralel calisir,
        // SHARED lock ile EXCLUSIVE lock catismaz. Default DELETE journal modunda
        // her transaction tum DB'yi locklar → busy hatalari kaciniilmaz.
        await db.execute('PRAGMA journal_mode = WAL');
        // busy_timeout: 5sn boyunca lock'un acilmasini bekle (default 0 = anlik fail)
        await db.execute('PRAGMA busy_timeout = 5000');
        // synchronous NORMAL: WAL ile uyumlu, hizli + guvenli
        await db.execute('PRAGMA synchronous = NORMAL');
        // foreign_keys aktif
        await db.execute('PRAGMA foreign_keys = ON');
        // 1 Haz 2026 (v1.5.6): auto_vacuum INCREMENTAL — DELETE sonrası boş alan
        // tutulmasın. SADECE yeni create'lerde etkili (mevcut DB'ler için
        // compactDatabase() boot'ta VACUUM çalıştırır).
        await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
      },
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 12 Haz 2026 — DB YOLU SABİTLEME
  // sqflite_common_ffi'de getDatabasesPath() CWD-relatif
  // '.dart_tool/sqflite_common_ffi/databases' döner. Uygulama nasıl başlatıldıysa
  // (çift tık / kısayol / terminal) CWD değişir → her seferinde FARKLI DB açılabilir!
  // Artık path_provider getApplicationSupportDirectory() altında sabit mutlak yol kullanılır.
  // ───────────────────────────────────────────────────────────────────────

  /// Sabit mutlak DB yolu: {ApplicationSupport}/databases/syncresto_pos.db
  Future<String> _resolveDbPath() async {
    if (_dbPath != null) return _dbPath!;
    final supportDir = await getApplicationSupportDirectory();
    final dbDir = Directory(join(supportDir.path, 'databases'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    _dbPath = join(dbDir.path, 'syncresto_pos.db');
    return _dbPath!;
  }

  /// Eski CWD-relatif konumdaki DB'yi yeni sabit konuma kopyala (tek seferlik).
  /// Adaylar: 1) Directory.current altı (terminal/kısayol "start in" senaryosu)
  ///          2) Platform.resolvedExecutable dizini altı (çift tık senaryosu)
  /// Kopyalama başarılı olsa bile ESKİ DOSYALAR SİLİNMEZ (güvenlik için bırakılır).
  /// Hata olursa migration atlanır — açılış ASLA bloklanmaz.
  Future<void> _migrateLegacyDbIfNeeded(String newPath) async {
    try {
      if (await File(newPath).exists()) return; // Yeni konumda DB zaten var

      final legacyRelative = join('.dart_tool', 'sqflite_common_ffi', 'databases', 'syncresto_pos.db');
      final candidates = <String>[
        join(Directory.current.path, legacyRelative),
        join(File(Platform.resolvedExecutable).parent.path, legacyRelative),
      ];

      for (final oldPath in candidates) {
        final oldFile = File(oldPath);
        if (!await oldFile.exists()) continue;

        // .db + .db-wal + .db-shm kopyala (WAL mode yan dosyaları)
        await oldFile.copy(newPath);
        for (final suffix in ['-wal', '-shm']) {
          final sideFile = File('$oldPath$suffix');
          if (await sideFile.exists()) {
            await sideFile.copy('$newPath$suffix');
          }
        }
        print('[LocalDb] DB migration: $oldPath -> $newPath (eski dosyalar güvenlik için silinmedi)');
        return; // İlk bulunan adaydan kopyalandı, diğerine bakma
      }
    } catch (e) {
      print('[LocalDb] DB migration hatası (atlandı, normal devam): $e');
    }
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
        restaurant_price REAL,
        image TEXT,
        is_active INTEGER DEFAULT 1,
        is_out_of_stock INTEGER DEFAULT 0,
        extras TEXT,
        show_variants_pos INTEGER DEFAULT 0,
        variants TEXT,
        printer_id INTEGER,
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
        summary_printer_id INTEGER,
        cached_at TEXT NOT NULL
      )
    ''');

    // Yazicilar cache (v8) — offline mutfak fisi icin
    await db.execute('''
      CREATE TABLE cached_printers (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        ip_address TEXT NOT NULL,
        port INTEGER DEFAULT 9100,
        type TEXT,
        is_active INTEGER DEFAULT 1,
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
        offline_permissions TEXT,
        owner_device_id TEXT,
        lan_lease_until TEXT,
        lan_origin TEXT DEFAULT 'self'
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
        printed INTEGER DEFAULT 0,
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

    // Yazıcı kuyruğu (başarısız yazdırma işlemleri)
    await db.execute('''
      CREATE TABLE print_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        print_type TEXT NOT NULL,
        printer_ip TEXT NOT NULL,
        printer_port INTEGER DEFAULT 9100,
        printer_name TEXT,
        receipt_data TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        max_retries INTEGER DEFAULT 5,
        error_message TEXT,
        created_at TEXT NOT NULL,
        last_attempt_at TEXT,
        completed_at TEXT
      )
    ''');

    // v7: Lookup cache — cancel_reasons, product_notes, global_variants, global_extras
    // Tek tablo + lookup_type ile ayrim. Offline'da iptal popup, urun notu, varyant/ekstra hala calisir.
    // payload: API'den gelen ham JSON (string olarak saklanir, parse edilir)
    await db.execute('''
      CREATE TABLE cached_lookups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lookup_type TEXT NOT NULL,
        category_id INTEGER,
        payload TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');

    // İndeksler
    await db.execute('CREATE INDEX idx_products_category ON cached_products(category_id)');
    await db.execute('CREATE INDEX idx_tables_section ON cached_tables(section_id)');
    await db.execute('CREATE INDEX idx_tickets_synced ON local_tickets(synced)');
    await db.execute('CREATE INDEX idx_items_ticket ON local_ticket_items(local_ticket_id)');
    await db.execute('CREATE INDEX idx_sync_status ON sync_queue(status)');
    await db.execute('CREATE INDEX idx_print_queue_status ON print_queue(status)');
    await db.execute('CREATE INDEX idx_lookups_type ON cached_lookups(lookup_type)');
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

    if (oldVersion < 3) {
      // v3: print_queue tablosu ekle

      try {
        await db.execute('''
          CREATE TABLE print_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            print_type TEXT NOT NULL,
            printer_ip TEXT NOT NULL,
            printer_port INTEGER DEFAULT 9100,
            printer_name TEXT,
            receipt_data TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            retry_count INTEGER DEFAULT 0,
            max_retries INTEGER DEFAULT 5,
            error_message TEXT,
            created_at TEXT NOT NULL,
            last_attempt_at TEXT,
            completed_at TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_print_queue_status ON print_queue(status)');
        print('[LocalDb] print_queue tablosu eklendi');
      } catch (e) {
        print('[LocalDb] print_queue zaten var: $e');
      }
    }

    if (oldVersion < 4) {
      // v4: cached_products'a restaurant_price ekle
      try {
        await db.execute('ALTER TABLE cached_products ADD COLUMN restaurant_price REAL');
        print('[LocalDb] cached_products.restaurant_price eklendi');
      } catch (e) {
        print('[LocalDb] restaurant_price zaten var: $e');
      }
    }

    if (oldVersion < 5) {
      // v5: Mevcut plaintext PIN'leri hash'le
      try {
        final waiters = await db.query('cached_waiters');
        for (final w in waiters) {
          final pin = w['pin'] as String?;
          if (pin != null && pin.isNotEmpty && !pin.startsWith('sha256:')) {
            final hashed = sha256.convert(utf8.encode('SyncRestoPOS:$pin')).toString();
            await db.update('cached_waiters', {'pin': hashed}, where: 'id = ?', whereArgs: [w['id']]);
          }
        }
        print('[LocalDb] PIN hash migration tamamlandi');
      } catch (e) {
        print('[LocalDb] PIN migration hatasi: $e');
      }
    }

    if (oldVersion < 6) {
      // v6: cached_products'a variants desteği
      try {
        await db.execute('ALTER TABLE cached_products ADD COLUMN show_variants_pos INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE cached_products ADD COLUMN variants TEXT');
        print('[LocalDb] cached_products variants kolonları eklendi');
      } catch (e) {
        print('[LocalDb] variants kolonları zaten var: $e');
      }
    }

    if (oldVersion < 7) {
      // v7: cached_lookups (cancel_reasons, product_notes, global_variants, global_extras)
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cached_lookups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lookup_type TEXT NOT NULL,
            category_id INTEGER,
            payload TEXT NOT NULL,
            cached_at TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_lookups_type ON cached_lookups(lookup_type)');
        print('[LocalDb] v7 cached_lookups eklendi');
      } catch (e) {
        print('[LocalDb] cached_lookups zaten var: $e');
      }
    }

    if (oldVersion < 8) {
      // v8: Offline mutfak fisi
      try {
        await db.execute('ALTER TABLE cached_products ADD COLUMN printer_id INTEGER');
      } catch (e) {
        print('[LocalDb] cached_products.printer_id zaten var: $e');
      }
      try {
        await db.execute('ALTER TABLE cached_sections ADD COLUMN summary_printer_id INTEGER');
      } catch (e) {
        print('[LocalDb] cached_sections.summary_printer_id zaten var: $e');
      }
      try {
        await db.execute('ALTER TABLE local_ticket_items ADD COLUMN printed INTEGER DEFAULT 0');
      } catch (e) {
        print('[LocalDb] local_ticket_items.printed zaten var: $e');
      }
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cached_printers (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            ip_address TEXT NOT NULL,
            port INTEGER DEFAULT 9100,
            type TEXT,
            is_active INTEGER DEFAULT 1,
            cached_at TEXT NOT NULL
          )
        ''');
        print('[LocalDb] v8 cached_printers + printer_id + summary_printer_id + items.printed eklendi');
      } catch (e) {
        print('[LocalDb] cached_printers zaten var: $e');
      }
    }

    // v9 (7 Tem 2026): LAN-SENKRON. local_tickets'e cihaz-sahiplik + LAN-kaynak kolonlari.
    // owner_device_id: masayi acan/sahip cihazin id'si (lease icin). lan_lease_until: sahiplik suresi.
    // lan_origin: 'self' (bu cihaz olusturdu) VEYA 'lan' (baska cihazdan yansidi).
    // KRITIK AYRIM (Faz 2): lan_origin='lan' satirlar mergeTablesWithOfflineChanges (UI) yoluyla masayi
    // DOLU GOSTERIR (Kasa2 gorsun) AMA getPendingSyncItems (backend push) bunlari ALMAZ -> LAN'dan
    // yansiyan masa bu cihazin sync_queue'suyla backend'e GITMEZ (cift-kayit onlenir). Bu ayrim
    // create sirasinda sync_queue'ya HIC eklememe ile saglanir (Faz 2), UI merge'e dokunulmaz.
    if (oldVersion < 9) {
      for (final col in [
        'ALTER TABLE local_tickets ADD COLUMN owner_device_id TEXT',
        'ALTER TABLE local_tickets ADD COLUMN lan_lease_until TEXT',
        "ALTER TABLE local_tickets ADD COLUMN lan_origin TEXT DEFAULT 'self'",
      ]) {
        try {
          await db.execute(col);
        } catch (e) {
          print('[LocalDb] v9 kolon zaten var: $e');
        }
      }
      print('[LocalDb] v9 LAN-senkron kolonlari eklendi (owner_device_id/lan_lease_until/lan_origin)');
    }
  }

  // ==================== TRANSACTION RETRY HELPER (19 May 2026) ====================

  /// WAL mode + busy_timeout=5000 sayesinde lock'lar %95 kurtariliyor.
  /// Yine de cok nadir durumlarda SQLITE_BUSY (code 5) veya LOCKED gelebilir
  /// (ornek: 2+ writer ayni mikrosaniyede begin acarsa). Bu helper exponential
  /// backoff ile 3 kez retry eder, sonra exception firlatir.
  ///
  /// Kullanim:
  ///   await _runWithRetry(() => db.transaction((txn) async { ... }));
  Future<T> _runWithRetry<T>(Future<T> Function() op, {String? opName}) async {
    const delaysMs = [100, 200, 400]; // exponential backoff
    Object? lastError;
    StackTrace? lastSt;

    for (int attempt = 0; attempt <= delaysMs.length; attempt++) {
      try {
        return await op();
      } catch (e, st) {
        lastError = e;
        lastSt = st;
        // Sadece BUSY/LOCKED retry edilebilir, baska hata (constraint vs) anında firlatılır
        final msg = e.toString().toLowerCase();
        final isBusy = msg.contains('database is locked') ||
                       msg.contains('sqlite_busy') ||
                       msg.contains('database is busy') ||
                       msg.contains('sqlite_locked');
        if (!isBusy) {
          rethrow;
        }
        // Son denemeyse — rethrow
        if (attempt >= delaysMs.length) {
          print('[DB] ${opName ?? "op"} — ${delaysMs.length + 1} deneme sonrasi hala locked, vazgeciliyor');
          rethrow;
        }
        // Bekle ve tekrar dene
        final delay = delaysMs[attempt];
        print('[DB] ${opName ?? "op"} — locked, ${delay}ms sonra retry (${attempt + 1}/${delaysMs.length})');
        await Future.delayed(Duration(milliseconds: delay));
      }
    }
    // Unreachable ama Dart icin gerekli
    Error.throwWithStackTrace(lastError ?? StateError('retry exhausted'), lastSt ?? StackTrace.current);
  }

  // ==================== CACHE İŞLEMLERİ ====================

  // Kategorileri cache'le
  Future<void> cacheCategories(List<Map<String, dynamic>> categories) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await _runWithRetry(() => db.transaction((txn) async {
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
    }), opName: 'cacheCategories');
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

    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete('cached_products');
      for (final prod in products) {
        await txn.insert('cached_products', {
          'id': prod['id'],
          'category_id': prod['category_id'],
          'name': prod['name'],
          'description': prod['description'],
          'price': prod['price'],
          'restaurant_price': prod['restaurant_price'],
          'image': prod['image'],
          'is_active': prod['is_active'] ?? 1,
          'is_out_of_stock': prod['is_out_of_stock'] ?? 0,
          'extras': prod['extras'] is String ? prod['extras'] : (prod['extras'] != null ? prod['extras'].toString() : null),
          'show_variants_pos': prod['show_variants_pos'] ?? 0,
          'variants': prod['variants'] is String ? prod['variants'] : (prod['variants'] != null ? prod['variants'].toString() : null),
          'printer_id': prod['printer_id'], // v8: offline mutfak fisi icin
          'cached_at': now,
        });
      }
    }), opName: 'cacheProducts');
  }

  // Ürünleri getir
  Future<List<Map<String, dynamic>>> getCachedProducts() async {
    final db = await database;
    return await db.query('cached_products', where: 'is_active = 1');
  }

  // 12 Haz 2026: hash-diff yardımcısı — gelen listenin deterministik hash'i.
  // 'cached_at' alanı HARİÇ tutulur (onu zaten biz ekliyoruz, içerik karşılaştırmasına girmez).
  // Hash üretilemezse null döner → diff atlanır, normal yazma yapılır (davranış değişmez).
  static String? _computeCacheHash(List<Map<String, dynamic>> rows) {
    try {
      final body = jsonEncode(
        rows.map((r) => Map<String, dynamic>.from(r)..remove('cached_at')).toList(),
      );
      return sha256.convert(utf8.encode(body)).toString();
    } catch (_) {
      return null;
    }
  }

  // Salonları cache'le
  Future<void> cacheSections(List<Map<String, dynamic>> sections) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // 12 Haz 2026: hash-diff — gelen veri öncekiyle AYNIYSA delete+insert
    // transaction'ını hiç çalıştırma (gereksiz yazma önleme).
    // Guard: tablo dışarıdan boşaltıldıysa (örn. sync_service clearAllCache)
    // hash aynı olsa bile yaz — cache boş kalmasın.
    final hash = _computeCacheHash(sections);
    if (hash != null && hash == _lastSectionsHash) {
      final cnt = await db.rawQuery('SELECT COUNT(*) as count FROM cached_sections');
      if (((cnt.first['count'] as int?) ?? 0) > 0) return; // Veri değişmedi — yazma atlandı
    }

    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete('cached_sections');
      for (final sec in sections) {
        await txn.insert('cached_sections', {
          'id': sec['id'],
          'name': sec['name'],
          'color': sec['color'],
          'table_count': sec['table_count'] ?? 0,
          'summary_printer_id': sec['summary_printer_id'], // v8: ozet fis yazicisi
          'cached_at': now,
        });
      }
    }), opName: 'cacheSections');
    _lastSectionsHash = hash;
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

    // 12 Haz 2026: hash-diff — gelen veri öncekiyle AYNIYSA delete+insert
    // transaction'ını hiç çalıştırma (2sn'lik poll günde ~86K gereksiz yazma yapıyordu).
    // Guard: tablo dışarıdan boşaltıldıysa (örn. sync_service clearAllCache)
    // hash aynı olsa bile yaz — cache boş kalmasın.
    final hash = _computeCacheHash(tables);
    if (hash != null && hash == _lastTablesHash) {
      final cnt = await db.rawQuery('SELECT COUNT(*) as count FROM cached_tables');
      if (((cnt.first['count'] as int?) ?? 0) > 0) return; // Veri değişmedi — yazma atlandı
    }

    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete('cached_tables');
      // 16 May 2026: server bazen ayni id'de iki kayit gonderirse (panel + auto-created masa)
      // duplicate'ta REPLACE et, transaction'i koparma
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
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }), opName: 'cacheTables');
    _lastTablesHash = hash;
  }

  // Masaları getir
  Future<List<Map<String, dynamic>>> getCachedTables() async {
    final db = await database;
    return await db.query('cached_tables');
  }

  // ==================== YAZICI CACHE (v8) ====================
  // Offline mutfak fisi: ip+port lokal'den okunur, ESC/POS direkt TCP yazicaya gider

  Future<void> cachePrinters(List<Map<String, dynamic>> printers) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete('cached_printers');
      for (final p in printers) {
        await txn.insert('cached_printers', {
          'id': p['id'],
          'name': p['name'] ?? '',
          'ip_address': p['ip_address'] ?? '',
          'port': p['port'] ?? 9100,
          'type': p['type'],
          'is_active': p['is_active'] == false ? 0 : 1,
          'cached_at': now,
        });
      }
    }), opName: 'cachePrinters');
    print('[LocalDb] cached_printers: ${printers.length} kayit');
  }

  Future<List<Map<String, dynamic>>> getCachedPrinters() async {
    final db = await database;
    return await db.query('cached_printers', where: 'is_active = 1');
  }

  Future<Map<String, dynamic>?> getCachedPrinterById(int? id) async {
    if (id == null) return null;
    final db = await database;
    final r = await db.query('cached_printers', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isNotEmpty ? r.first : null;
  }

  // Bir urunun printer_id'sini lokal cache'ten cek (offline mutfak fisi gruplama)
  Future<int?> getProductPrinterId(int productId) async {
    final db = await database;
    final r = await db.query('cached_products',
        columns: ['printer_id'], where: 'id = ?', whereArgs: [productId], limit: 1);
    if (r.isEmpty) return null;
    return r.first['printer_id'] as int?;
  }

  // Lokal item'lari yazdirildi olarak isaretle (offline mutfak fisi sonrasi)
  Future<void> markLocalItemsPrinted(List<int> localIds) async {
    if (localIds.isEmpty) return;
    final db = await database;
    final placeholders = List.generate(localIds.length, (i) => '?').join(',');
    await db.rawUpdate(
      'UPDATE local_ticket_items SET printed = 1 WHERE local_id IN ($placeholders)',
      localIds,
    );
    print('[LocalDb] markLocalItemsPrinted: ${localIds.length} item');
  }

  // Lokal ticket'in printed=0 + status='active'/'pending' item'larini cek (offline mutfak fisi)
  // Format: [{local_id, server_id, product_id, product_name, quantity, unit_price, notes, printer_id}]
  Future<List<Map<String, dynamic>>> getUnprintedLocalItems(int localTicketId) async {
    final db = await database;
    // JOIN cached_products: printer_id'yi de al
    final r = await db.rawQuery('''
      SELECT i.local_id, i.server_id, i.product_id, i.product_name, i.quantity,
             i.unit_price, i.notes,
             p.printer_id
        FROM local_ticket_items i
   LEFT JOIN cached_products p ON p.id = i.product_id
       WHERE i.local_ticket_id = ?
         AND i.printed = 0
         AND (i.status IS NULL OR i.status != 'cancelled')
       ORDER BY i.created_at
    ''', [localTicketId]);
    return r;
  }

  // Lokal ticket bilgisi + masa + salon — offline mutfak fisi icin
  /// [ticketId] local_id VEYA server_id olabilir. 6 Tem 2026 (offline fix Adim 3): online
  /// acilan (mirror'lanan) ticket'ta printKitchen server_id ile gelir; server_id fallback
  /// eklenmezse 'Lokal ticket bulunamadi' olur ve offline mutfak fisi CIKMAZDI.
  /// Donen satirda gercek local_id de var (t.*) -> caller item'lari onunla ceker.
  /// [ticketId] local_id VEYA server_id olabilir.
  /// 🔴 6 Tem 2026 DÜZELTME 1 (KRİTİK-PRINT): local_id (1,2,3..AUTOINCREMENT) ve server_id (backend
  /// küçük tamsayı) AYNI sayı uzayında çakışabilir. Eski `WHERE local_id=? OR server_id=?` + ORDER BY
  /// YOK → belirsiz sonuç → offline printKitchen YANLIŞ ticket'ı (başka masa) döndürüp o masanın
  /// ürünlerini basıp printed=1 yazabiliyordu → gerçek fiş HİÇ çıkmaz. FIX: server_id eşleşmesini
  /// ÖNCELİKLENDİR (ORDER BY server_id=? DESC). server_id ile gelen çağrı gerçek server ticket'ı bulur;
  /// çakışan bir local_id varsa bile server_id eşleşen kazanır. Caller ayrıca table_id guard yapar.
  Future<Map<String, dynamic>?> getLocalTicketWithSection(int ticketId) async {
    final db = await database;
    // 🔴 7 Tem 2026 (LAN Faz 2 — Fable D1): lan_origin='lan' satirlar PRINT akisina GIRMEZ
    // (savunma-derinligi; LAN ticket'larinin item'i yok ama print kalbi tutarli filtreli olsun).
    final r = await db.rawQuery('''
      SELECT t.*, s.name as section_name, s.summary_printer_id, w.name as waiter_name
        FROM local_tickets t
   LEFT JOIN cached_tables tb ON tb.id = t.table_id
   LEFT JOIN cached_sections s ON s.id = tb.section_id
   LEFT JOIN cached_waiters w ON w.id = t.waiter_id
       WHERE (t.local_id = ? OR t.server_id = ?) AND COALESCE(t.lan_origin,'self') = 'self'
    ORDER BY (t.server_id = ?) DESC, t.local_id ASC
       LIMIT 1
    ''', [ticketId, ticketId, ticketId]);
    return r.isNotEmpty ? r.first : null;
  }

  // Bir salonun summary_printer_id'sini lokal cache'ten cek
  Future<int?> getSectionSummaryPrinterId(int sectionId) async {
    final db = await database;
    final r = await db.query('cached_sections',
        columns: ['summary_printer_id'], where: 'id = ?', whereArgs: [sectionId], limit: 1);
    if (r.isEmpty) return null;
    return r.first['summary_printer_id'] as int?;
  }

  // ==================== LOOKUP CACHE (v7) ====================
  // cancel_reasons / product_notes / global_variants / global_extras
  // Tek tablo, lookup_type ile ayrim. Offline'da iptal popup, urun notu,
  // varyant, ekstra hala calisir.

  Future<void> cacheLookups({
    required String lookupType,
    required List<Map<String, dynamic>> rows,
    int? categoryId,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await _runWithRetry(() => db.transaction((txn) async {
      // Sadece bu type'i temizle (digerleri korunur)
      if (categoryId != null) {
        await txn.delete('cached_lookups',
            where: 'lookup_type = ? AND category_id = ?',
            whereArgs: [lookupType, categoryId]);
      } else {
        await txn.delete('cached_lookups',
            where: 'lookup_type = ? AND category_id IS NULL',
            whereArgs: [lookupType]);
      }
      for (final r in rows) {
        await txn.insert('cached_lookups', {
          'lookup_type': lookupType,
          'category_id': categoryId,
          'payload': jsonEncode(r),
          'cached_at': now,
        });
      }
    }), opName: 'cacheLookups[$lookupType]');
    print('[LocalDb] cached_lookups [$lookupType' + (categoryId != null ? '/cat=$categoryId' : '') + ']: ${rows.length} kayit');
  }

  Future<List<Map<String, dynamic>>> getCachedLookups({
    required String lookupType,
    int? categoryId,
  }) async {
    final db = await database;
    final List<Map<String, dynamic>> rows;
    if (categoryId != null) {
      // Once kategori-ozel cache, yoksa global cache'e dus
      rows = await db.query('cached_lookups',
          where: 'lookup_type = ? AND category_id = ?',
          whereArgs: [lookupType, categoryId]);
      if (rows.isNotEmpty) {
        return rows.map((r) => Map<String, dynamic>.from(jsonDecode(r['payload'] as String))).toList();
      }
      // Fallback: global (categoryId IS NULL)
      final fallback = await db.query('cached_lookups',
          where: 'lookup_type = ? AND category_id IS NULL',
          whereArgs: [lookupType]);
      return fallback.map((r) => Map<String, dynamic>.from(jsonDecode(r['payload'] as String))).toList();
    } else {
      rows = await db.query('cached_lookups',
          where: 'lookup_type = ? AND category_id IS NULL',
          whereArgs: [lookupType]);
      return rows.map((r) => Map<String, dynamic>.from(jsonDecode(r['payload'] as String))).toList();
    }
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

    // 🟡 6 Tem 2026 FINAL-FIX D: Ayni masada BEKLEYEN close/void varsa yeni create ONA bagimli olsun.
    // Boylece kullanici senaryosu (offline masa kapat -> ayni masayi tekrar ac) tam zincir olur:
    // create1 -> item1 -> close1 -> create2 -> item2 -> close2. Eski masa backend'de KAPANMADAN
    // yeni create gitmez -> backend'in "ayni masada acik adisyona merge" tuzagi tetiklenmez (ciro karismaz).
    final priorClose = await db.rawQuery('''
      SELECT sq.id FROM sync_queue sq
        JOIN local_tickets lt ON lt.local_id = sq.local_id
       WHERE sq.action IN ('close','void') AND sq.status IN ('pending','in_progress')
         AND lt.table_id = ?
       ORDER BY sq.id DESC LIMIT 1
    ''', [tableId]);
    final createDependsOn = priorClose.isNotEmpty ? priorClose.first['id'] as int? : null;

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
      dependsOnSyncId: createDependsOn,
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

  // 16 May 2026: Local item taşıma (offline veya online cache senkron)
  // Hedef masada open ticket varsa o'na, yoksa yeni lokal ticket olustur, item'i bagla.
  // returns: { target_ticket_id, target_local_ticket_id }
  Future<Map<String, dynamic>> moveLocalItem({
    required int itemId,
    required int sourceTicketId,
    int? targetTicketId,
    required int targetTableId,
    required int waiterId,
  }) async {
    final db = await database;
    int? resolvedTargetTicketId = targetTicketId;
    int? resolvedTargetLocalId;

    // Hedef masada open ticket var mı (lokal cache)? LAN yansimasi (lan_origin='lan') HEDEF OLAMAZ —
    // aksi halde self item baska cihazin masasina baglanir, sync muhasebesinden kaybolur (Fable O1).
    if (resolvedTargetTicketId == null) {
      final existing = await db.query(
        'local_tickets',
        where: "table_id = ? AND status = ? AND COALESCE(lan_origin,'self') = 'self'",
        whereArgs: [targetTableId, 'open'],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        resolvedTargetLocalId = existing.first['local_id'] as int?;
        resolvedTargetTicketId = existing.first['server_id'] as int? ?? resolvedTargetLocalId;
      } else {
        // Yeni lokal ticket aç
        final ticketNumber = 'OFFLINE-$targetTableId-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
        final nowIso = DateTime.now().toIso8601String();
        final localId = await db.insert('local_tickets', {
          'table_id': targetTableId,
          'waiter_id': waiterId,
          'ticket_number': ticketNumber,
          'status': 'open',
          'subtotal': 0,
          'total': 0,
          'opened_at': nowIso,
          'created_at': nowIso,
        });
        resolvedTargetLocalId = localId;
        resolvedTargetTicketId = localId;
        // Hedef masayı dolu yap
        await db.update(
          'cached_tables',
          {'status': 'occupied', 'current_ticket_id': localId},
          where: 'id = ?',
          whereArgs: [targetTableId],
        );
      }
    }

    // Item'i hedef adisyona taşı (local_ticket_items üzerinden)
    await db.update(
      'local_ticket_items',
      {'local_ticket_id': resolvedTargetLocalId ?? resolvedTargetTicketId},
      where: 'local_id = ? OR server_id = ?',
      whereArgs: [itemId, itemId],
    );

    return {
      'target_ticket_id': resolvedTargetTicketId,
      'target_local_ticket_id': resolvedTargetLocalId,
    };
  }

  // 22 May 2026: server_id ile lokal ticket'i bul (FK constraint bug fix).
  // api_service offline fallback'i ticketId olarak SERVER id veriyordu ama
  // getLocalTicket sadece local_id'ye bakiyordu, FK hatasi olusuyordu.
  Future<Map<String, dynamic>?> getLocalTicketByServerId(int serverId) async {
    final db = await database;
    final results = await db.query(
      'local_tickets',
      where: 'server_id = ?',
      whereArgs: [serverId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return getLocalTicket(results.first['local_id'] as int);
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
    // 🟡 6 Tem 2026 DÜZELTME 4: Ayni masada HEM mirror (server_id'li, online acilmis) HEM
    // offline-yeni (server_id NULL) acik ticket olabilir. ORDER BY olmadan rastgele secince
    // item/kapama YANLIS ticket'a gidiyordu. Deterministik: offline-yeni (server_id NULL) ONCELIKLI
    // (garsonun fiilen uzerinde calistigi adisyon), ayni tipte en yeni (local_id DESC).
    // 🔴 7 Tem 2026 (LAN Faz 2 — Fable KRITIK): lan_origin='lan' (baska cihazdan yansiyan) satirlar
    // BU AKISA GIRMEZ. Aksi halde garson LAN masasina dokununca onun local_id'siyle islem acar ->
    // sync_queue'ya girer -> synced=1 tuzagi -> ciro kaybi/yanlis ticket. LAN masasi SALT-OKUNUR:
    // sadece UI'da dolu gorunur (getOfflineOpenTableIds), islem icin ASLA donmez.
    final results = await db.query(
      'local_tickets',
      where: "table_id = ? AND status = ? AND COALESCE(lan_origin,'self') = 'self'",
      whereArgs: [tableId, 'open'],
      orderBy: '(server_id IS NULL) DESC, local_id DESC',
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
    final tableNumber = ticket?['table_number'] ?? '';
    // 6 Tem 2026 (offline fix Adim 7): server_id varsa (mirror/sync olmus) item dogrudan
    // server ticket'a eklenir, depends_on gereksiz; yoksa create'e bagimli (synced=sync_id).
    final dependsOn = ticket != null ? _resolveDependsOn(ticket) : null;

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
      dependsOnSyncId: dependsOn,
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
  /// 6 Tem 2026 (offline fix Adim 7): close/void/item aksiyonlarinin depends_on_sync_id'sini
  /// DOGRU hesaplar. TUZAK: `synced` alani cift-anlamli — offline create'te sync_id (>0),
  /// ama MIRROR'lanan/sync olmus ticket'ta 1 (bayrak). Eski kod `synced>0` gorunce depends_on=1
  /// (bozuk referans) yapiyordu -> sync sirasi bozulup ciro karismasi olusuyordu.
  /// DOGRU MANTIK: ticket'in server_id'si VARSA (mirror veya sync olmus) close/void dogrudan
  /// server_id ile gider -> depends_on GEREKSIZ (null). SADECE server_id YOK + synced gercek
  /// bir create sync_id ise (offline-olusturulan, henuz sync olmamis) depends_on kullan.
  int? _resolveDependsOn(Map<String, dynamic> ticket) {
    final serverId = ticket['server_id'];
    if (serverId != null) return null; // zaten server'da var -> beklemeye gerek yok
    final syncId = ticket['synced'] as int?;
    return (syncId != null && syncId > 0) ? syncId : null;
  }

  /// 6 Tem 2026 (DÜZELTME 3): Backend fiyat alanini (num veya String) guvenli double'a cevirir.
  /// null/gecersiz -> 0.0. Boylece backend String fiyat donse bile mirror yazilir (offline fis kaynagi korunur).
  double _parseMoney(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  /// 🟡 6 Tem 2026 FINAL-FIX D: Bu ticket'a ait SON bekleyen add_item sync kaydinin id'si.
  /// close/void bu id'ye bagimli yapilir -> close, kendi item'larindan SONRA backend'e gider.
  /// Aksi halde close (prio 1) item'lardan (prio 0) ONCE gidiyordu -> backend final_total'i
  /// 0 itemla COALESCE(total,subtotal,0)=0 kilitliyordu -> offline adisyonlar raporda 0 TL (ciro kaybi).
  Future<int?> _lastPendingItemSyncId(int localTicketId) async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT id FROM sync_queue
       WHERE action = 'add_item' AND status IN ('pending','in_progress')
         AND (payload LIKE ? OR payload LIKE ?)
       ORDER BY id DESC LIMIT 1
    ''', ['%"local_ticket_id":$localTicketId,%', '%"local_ticket_id":$localTicketId}%']);
    return r.isNotEmpty ? r.first['id'] as int? : null;
  }

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
    // FINAL-FIX D: once bu ticket'in bekleyen SON item'ina bagimli ol (close item'lardan sonra
    // gitsin -> final_total dogru); bekleyen item yoksa eski mantik (_resolveDependsOn).
    final dependsOn = await _lastPendingItemSyncId(localTicketId) ?? _resolveDependsOn(ticket);

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
      dependsOnSyncId: dependsOn,
    );
  }

  // Adisyonu iptal et
  Future<void> voidLocalTicket({
    required int localTicketId,
    int waiterId = 1,
    String? reason,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final ticket = await getLocalTicket(localTicketId);
    if (ticket == null) return;

    final tableNumber = ticket['table_number'] ?? '';
    // FINAL-FIX D: void da item'lardan SONRA gitsin (close ile ayni gerekce).
    final dependsOn = await _lastPendingItemSyncId(localTicketId) ?? _resolveDependsOn(ticket);

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
    // reason artik payload'da: garson sebep secti (panel_pos_cancel_reasons'tan)
    await addToSyncQueue(
      action: 'void',
      entityType: 'ticket',
      localId: localTicketId,
      payload: {
        'waiter_id': waiterId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      },
      priority: 1,
      description: 'Masa $tableNumber: Adisyon iptal edildi${reason != null ? " ($reason)" : ""}',
      dependsOnSyncId: dependsOn,
    );
  }

  // Server ticket offline aksiyon — lokal cache yokken close/void/cancel_item gibi
  // sync_queue'ya direkt server_id ile koy. sync_service realTicketId olarak kullanir.
  // Idempotent — ayni server_id + ayni action + status='pending' varsa eklemez.
  Future<int?> enqueueServerTicketAction({
    required String action,        // 'close', 'void', 'cancel_item', 'update_item'
    required int serverId,         // Server ticket ID (veya item ID)
    required Map<String, dynamic> payload,
    String entityType = 'ticket',  // 'ticket' veya 'ticket_item'
    String? description,
  }) async {
    final db = await database;
    // Duplicate guard
    final existing = await db.query('sync_queue',
        where: "action = ? AND entity_type = ? AND server_id = ? AND status IN ('pending', 'in_progress')",
        whereArgs: [action, entityType, serverId]);
    if (existing.isNotEmpty) {
      print('[LocalDb] enqueueServerTicketAction: zaten kuyrukta — $action #$serverId');
      return (existing.first['id'] as int?);
    }
    return await addToSyncQueueWithReturn(
      action: action,
      entityType: entityType,
      serverId: serverId,
      payload: payload,
      priority: 1,
      description: description ?? 'Server $entityType #$serverId offline $action',
    );
  }

  /// 🟠 6 Tem 2026 FINAL-FIX B: Offline basilan mutfak fisinin printed=1 sync'ini DOGRU id
  /// uzaylariyla kuyruklar. ESKI yol (enqueueServerTicketAction(serverId: ticketId)) UC bug iceriyordu:
  /// (1) offline-acilan ticket'ta ticketId=LOKAL id'ydi ama server_id kolonuna yaziliyordu ->
  ///     _resolveServerTicketId onu sorgusuz server id sanip YANLIS URL'e POST ediyordu ->
  ///     backend'de printed=0 kalir -> online devamda ayni urunler IKINCI kez basilir (cift fis).
  /// (2) dup-guard ayni ticket'in IKINCI mark_printed'ini payload MERGE etmeden yutuyordu ->
  ///     ikinci partinin item listesi kayboluyordu.
  /// (3) local_id NULL oldugu icin cleanup/mirror pending-guard'lari kaydi GOREMIYORDU.
  /// SIMDI: localId = ticket'in GERCEK local_id'si (guard'lar gorur), serverId = varsa gercek
  /// server_id (yoksa NULL -> sync sirasinda local ticket'tan resolve edilir), ayni ticket icin
  /// bekleyen kayit varsa item_local_ids listeleri BIRLESTIRILIR (union).
  Future<int?> enqueueMarkPrinted({
    required int localTicketId,
    int? serverTicketId,
    required List<int> itemLocalIds,
    int? waiterId,
    String? description,
  }) async {
    if (itemLocalIds.isEmpty) return null;
    final db = await database;

    // Ayni ticket icin bekleyen mark_printed var mi? -> item listelerini BIRLESTIR (yutma!)
    final existing = await db.query('sync_queue',
        where: "action = 'mark_printed' AND status IN ('pending', 'in_progress') AND local_id = ?",
        whereArgs: [localTicketId],
        limit: 1);
    if (existing.isNotEmpty) {
      final row = existing.first;
      final syncId = row['id'] as int;
      Map<String, dynamic> payload = {};
      try {
        final raw = row['payload'];
        if (raw is String && raw.isNotEmpty) payload = Map<String, dynamic>.from(jsonDecode(raw));
      } catch (_) {}
      final mergedIds = <int>{
        ...((payload['item_local_ids'] as List?)?.whereType<int>() ?? const <int>[]),
        ...itemLocalIds,
      }.toList();
      payload['item_local_ids'] = mergedIds;
      if (waiterId != null) payload['waiter_id'] = waiterId;
      await db.update('sync_queue', {'payload': jsonEncode(payload)},
          where: 'id = ?', whereArgs: [syncId]);
      print('[LocalDb] mark_printed MERGE edildi (sync_id=$syncId, toplam ${mergedIds.length} item)');
      return syncId;
    }

    return await addToSyncQueueWithReturn(
      action: 'mark_printed',
      entityType: 'ticket',
      localId: localTicketId,
      serverId: serverTicketId, // null olabilir -> resolve local ticket'tan (dogru davranis)
      payload: {
        'item_local_ids': itemLocalIds,
        if (waiterId != null) 'waiter_id': waiterId,
      },
      priority: 1,
      description: description ?? 'Mutfak fisi offline yazdirildi (ticket local#$localTicketId)',
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

  /// 6 Tem 2026 (offline fix Adim 3): ONLINE acilan bir server ticket'ini item'lariyla
  /// lokale MIRROR eder. Amac: internet gidince online-acilmis masaya da offline mutfak
  /// fisi basilabilsin + adisyon gorulebilsin (eskiden sadece offline-acilanlar lokaldeydi).
  ///
  /// GUVENLIK KURALLARI (mevcut offline akisi BOZMA):
  /// 1. SADECE server_id'li (backend'de var olan) ticket'lari mirror eder.
  /// 2. OFFLINE-OLUSTURULAN (server_id IS NULL, sync bekleyen) ticket'lara ASLA DOKUNMAZ —
  ///    onlar sync_queue'da bekliyor, uzerine yazmak veri kaybi olur.
  /// 3. Item'larin `printed` durumunu KORUR (offline basilmis item'in printed=1'ini ezmez).
  /// 4. `synced=1` isaretler (bu mirror kaydi zaten backend ile uyumlu, sync_queue'ya GIRMEZ).
  /// [serverTicket] = backend GET /tickets/table/:id -> response.data['ticket'] objesi.
  Future<void> upsertServerTicket(Map<String, dynamic> serverTicket) async {
    final serverId = serverTicket['id'];
    if (serverId == null || serverId is! int) return; // server_id'siz mirror edilemez
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await _runWithRetry(() => db.transaction((txn) async {
      // Bu server_id lokalde var mi? (offline-olusturulup sync olmus da olabilir, mirror da)
      final existing = await txn.query('local_tickets',
          where: 'server_id = ?', whereArgs: [serverId], limit: 1);

      // Ticket alanlari (offline sema ile eslesir)
      final ticketRow = <String, dynamic>{
        'server_id': serverId,
        'ticket_number': serverTicket['ticket_number']?.toString() ?? 'SRV-$serverId',
        'table_id': serverTicket['table_id'],
        'table_number': serverTicket['table_number']?.toString(),
        'waiter_id': serverTicket['waiter_id'] ?? 0,
        'customer_count': serverTicket['customer_count'] ?? 1,
        'status': serverTicket['status']?.toString() ?? 'open',
        // 🟡 6 Tem 2026 DÜZELTME 3 (ORTA-PRINT): backend fiyat alanini num VEYA String donebilir.
        // Eski kod `(x as num?)?.toDouble()` String'de 0'a dusuruyordu; total'da operator onceligi
        // hatasi (as num? sadece 2. operanda) + kontrolsuz .toDouble() -> String gelirse EXCEPTION
        // -> upsertServerTicket TAMAMEN atlanir -> o masaya offline fis kaynagi OLUSMAZ. Guvenli parse:
        'subtotal': _parseMoney(serverTicket['subtotal']),
        'discount_amount': _parseMoney(serverTicket['discount_amount']),
        'total': _parseMoney(serverTicket['total_amount'] ?? serverTicket['total']),
        'opened_at': serverTicket['opened_at']?.toString() ??
            serverTicket['created_at']?.toString() ?? now,
        'synced': 1,
        'synced_at': now,
      };

      int localTicketId;
      if (existing.isNotEmpty) {
        localTicketId = existing.first['local_id'] as int;
        // GUVENLIK: offline-olusturulan (server_id NULL iken sync bekleyen) kayit BURAYA DUSMEZ
        // cunku where server_id=? ile ariyoruz; mirror sadece zaten server_id'li kaydi gunceller.
        await txn.update('local_tickets', ticketRow,
            where: 'local_id = ?', whereArgs: [localTicketId]);
      } else {
        ticketRow['created_at'] = now;
        localTicketId = await txn.insert('local_tickets', ticketRow);
      }

      // ITEM MIRROR: server item'larini server_id ile eslestir, printed durumunu KORU.
      final items = serverTicket['items'];
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final it = Map<String, dynamic>.from(raw);
          final itemServerId = it['id'];
          if (itemServerId == null || itemServerId is! int) continue;

          // Bu item lokalde (server_id ile) var mi? printed'i korumak icin.
          final existItem = await txn.query('local_ticket_items',
              columns: ['local_id', 'printed'],
              where: 'server_id = ?', whereArgs: [itemServerId], limit: 1);
          final existingPrinted = existItem.isNotEmpty
              ? (existItem.first['printed'] as int? ?? 0)
              : (it['printed'] == 1 || it['printed'] == true ? 1 : 0);

          final itemRow = <String, dynamic>{
            'server_id': itemServerId,
            'local_ticket_id': localTicketId,
            'server_ticket_id': serverId,
            'product_id': it['product_id'] ?? 0,
            'product_name': it['product_name']?.toString() ?? '',
            'quantity': (it['quantity'] as num?)?.toInt() ?? 1,
            'unit_price': (it['unit_price'] as num?)?.toDouble() ??
                (it['price'] as num?)?.toDouble() ?? 0,
            'custom_price': (it['custom_price'] as num?)?.toDouble(),
            'notes': it['notes']?.toString(),
            'extras': it['extras'] is String ? it['extras'] : (it['extras'] != null ? it['extras'].toString() : null),
            'status': it['status']?.toString() ?? 'pending',
            'printed': existingPrinted, // KORUNUR
            'synced': 1,
            'synced_at': now,
          };

          if (existItem.isNotEmpty) {
            await txn.update('local_ticket_items', itemRow,
                where: 'local_id = ?', whereArgs: [existItem.first['local_id']]);
          } else {
            itemRow['created_at'] = now;
            await txn.insert('local_ticket_items', itemRow);
          }
        }
      }
    }), opName: 'upsertServerTicket');
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
    // 12 Haz 2026: hash-diff sıfırla — temizlik sonrası ilk cache yazımı atlanmasın
    _lastTablesHash = null;
    _lastSectionsHash = null;
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

  /// 6 Tem 2026 (offline fix Adim 3): Bir masanin MIRROR'lanmis (online acilip lokale
  /// kopyalanmis) ticket + item kayitlarini siler. Masa server'da kapaninca (getTableTicket
  /// 404) cagrilir ki lokal DB sismesin.
  /// GUVENLIK: SADECE server_id IS NOT NULL (mirror/sync olmus) VE o ticket icin sync_queue'da
  /// pending/in_progress kayit OLMAYAN ticket'lari siler. Offline-olusturulan (server_id NULL,
  /// sync bekleyen) ticket'lara ASLA dokunmaz -> veri kaybi olmaz.
  Future<void> deleteMirroredTicketByTable(int tableId) async {
    final db = await database;
    // Bu masadaki server_id'li (mirror) ticket'lari bul
    final mirrored = await db.query('local_tickets',
        columns: ['local_id'],
        where: 'table_id = ? AND server_id IS NOT NULL',
        whereArgs: [tableId]);

    for (final t in mirrored) {
      final localId = t['local_id'] as int;
      // Guvenlik: bu ticket icin bekleyen sync var mi? (offline aksiyon uzerine mirror gelmis olabilir)
      final pending = await db.query('sync_queue',
          where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
          whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%']);
      if (pending.isNotEmpty) continue; // sync bekliyor -> dokunma

      await db.delete('local_ticket_items', where: 'local_ticket_id = ?', whereArgs: [localId]);
      await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [localId]);
    }
  }

  /// 6 Tem 2026 (offline fix Adim 3 + multi-tenant guvenlik): Cihazin key'i/tenant'i degisince
  /// (bayi degisimi) TUM lokal ticket/item/mirror + cache verisini temizle. Aksi halde eski
  /// bayinin table_id'leri yeni bayininkiyle CAKISIR (multi-tenant sizinti). setup/login akisi
  /// tenant degisimini tespit edince cagirmali.
  Future<void> clearAllTenantData() async {
    final db = await database;
    await _runWithRetry(() => db.transaction((txn) async {
      // Ticket/item/sync — tum tenant'a ozel operasyonel veri
      await txn.delete('local_ticket_items');
      await txn.delete('local_tickets');
      await txn.delete('sync_queue');
      await txn.delete('print_queue');
      // Cache — bir sonraki online sync yeniden dolduracak
      await txn.delete('cached_products');
      await txn.delete('cached_categories');
      await txn.delete('cached_tables');
      await txn.delete('cached_sections');
      await txn.delete('cached_printers');
      await txn.delete('cached_waiters');
      await txn.delete('cached_lookups');
    }), opName: 'clearAllTenantData');
    print('[LocalDb] Tenant verisi temizlendi (bayi/key degisimi)');
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
        where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
        whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%'],
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

    // 6 Tem 2026 (offline fix Adim 2): Basarisiz sync'leri SILME -> 'dead_letter' arsivle.
    // ESKIDEN: status='failed' AND retry_count>=3 KOSULSUZ DELETE ediliyordu. Bu, backend'e
    // hic gitmemis bir offline aksiyonun (adisyon/urun/kapama) re-sync talimatini KALICI yok
    // ediyordu (transient backend hatasi 3 kez tekrarlaninca). Simdi silmek yerine dead_letter'a
    // tasiniyor: getPendingSyncItems bunlari zaten almaz (retry_count>=max), offline_data_modal
    // basarisiz listesinde gorunur kalir, kullanici/gelistirici manuel retry (retrySyncItem
    // retry_count'u sifirlar) veya inceleme yapabilir. Ham veri kaybolmaz.
    await db.update(
      'sync_queue',
      {'status': 'dead_letter'},
      // 6 Tem 2026 DÜZELTME 7: hardcoded 3 yerine dinamik max_retries (diger tum yerlerle tutarli;
      // ileride ozel max_retries verilirse 'failed' asamasi atlanmasin).
      where: "status = 'failed' AND retry_count >= max_retries",
    );

    // dead_letter kayitlari sonsuza birikmesin: 30 gunden eski olanlari temizle (bu noktada
    // zaten kalici basarisiz + kullanicinin gormesi icin makul sure gecmis).
    final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    await db.delete(
      'sync_queue',
      where: "status = 'dead_letter' AND created_at < ?",
      whereArgs: [thirtyDaysAgo],
    );

    // 1 Haz 2026 (v1.5.6): DELETE sonrası boş alanı geri kazan
    // (auto_vacuum=INCREMENTAL aktifse hızlı; değilse no-op).
    await incrementalVacuum(pages: 1000);

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

      // Local'de bu masa için açık ticket var mı? LAN yansimalari (lan_origin='lan') HARIC —
      // onlar baska cihazin masasi, bu cihazin sync'i onlara dokunmaz (Fable Faz 2 duzeltmesi).
      final localTickets = await db.query(
        'local_tickets',
        where: "table_id = ? AND status = ? AND COALESCE(lan_origin,'self') = 'self'",
        whereArgs: [tableId, 'open'],
      );

      if (status == 'empty' || serverTicketId == null) {
        // Server'da masa boş - local'deki açık ticketları kapat
        for (final localTicket in localTickets) {
          final localId = localTicket['local_id'] as int;

          // 6 Tem 2026 (offline fix Adim 6): YANLIS KAPATMA GUARD. Bir masa offline acildi ama
          // create sync henuz BASARILI olmadiysa (transient hata -> server_id=NULL, sync_queue'da
          // pending create), server bu masayi HENUZ bos gorur. Burada koşulsuz kapatirsak: sonraki
          // poll create'i basarir -> server'da ticket olusur AMA local kapali = ORPHAN/DESYNC.
          // Cozum: bu ticket icin bekleyen sync (pending/in_progress) VARSA kapatma, atla.
          final pendingSync = await db.query(
            'sync_queue',
            where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
            whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%'],
          );
          if (pendingSync.isNotEmpty) {
            print('[LocalDb] Masa $tableId local ticket $localId sync bekliyor, kapatma ATLANDI');
            continue;
          }

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

    // Hatalı işlemler (6 Tem 2026: dead_letter de dahil — cleanupSyncedTickets artık
    // kalıcı başarısızları silmek yerine dead_letter'a arşivliyor; kullanıcı görüp retry edebilsin).
    final failed = await db.query(
      'sync_queue',
      where: "status IN ('failed', 'dead_letter') OR (status = 'pending' AND retry_count >= max_retries)",
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
    // 6 Tem 2026 DÜZELTME 6: dead_letter'i da sil. getOfflineDataSummary (failed listesi) dead_letter'i
    // gosteriyor ama eski clearFailedSyncItems onu haric tutuyordu -> "Tumunu Temizle" bozuk sanilyordu.
    await db.delete(
      'sync_queue',
      where: "status IN ('failed', 'dead_letter') OR (status = 'pending' AND retry_count >= max_retries)",
    );
    print('[LocalDb] Tüm hatalı işlemler temizlendi (dead_letter dahil)');
  }

  // Offline'da kapatılmış ama henüz sync olmamış masaların table_id'lerini getir
  // Bu methodla sunucudan gelen masa listesini güncelleyebiliriz
  Future<Set<int>> getOfflineClosedTableIds() async {
    final db = await database;

    // Closed veya voided olup, henüz sync olmamış ticketlar. LAN yansimalari (lan_origin='lan') HARIC.
    final results = await db.query(
      'local_tickets',
      columns: ['table_id'],
      where: "status IN ('closed', 'voided') AND server_id IS NULL AND COALESCE(lan_origin,'self') = 'self'",
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

  // ==================== LAN-SENKRON (Faz 2) ====================
  // 7 Tem 2026: LAN'dan yansiyan masalar. lan_origin='lan' -> UI'da DOLU gorunur (getOfflineOpenTableIds
  // server_id NULL filtreler, LAN masalari da dahil) AMA sync_queue'ya GIRMEZ -> backend'e GITMEZ
  // (masayi ACAN cihaz sync eder, Mustafa karari). Cift-kayit imkansiz.

  /// LAN'dan gelen bir masa ozetini lokale yansit (sync_queue'ya DOKUNMAZ). Idempotent (ticket_number key).
  Future<void> upsertLanTicket({
    required String ticketNumber,
    required int tableId,
    String? tableNumber,
    required String ownerDeviceId,
    String status = 'open',
    double total = 0,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('local_tickets',
        where: "ticket_number = ? AND lan_origin = 'lan'", whereArgs: [ticketNumber], limit: 1);
    final row = {
      'ticket_number': ticketNumber,
      'table_id': tableId,
      'table_number': tableNumber,
      'waiter_id': 0,
      'status': status,
      'total': total,
      'opened_at': now,
      'owner_device_id': ownerDeviceId,
      'lan_origin': 'lan',
      'synced': 1, // LAN masasi bu cihazin sync'ine ait DEGIL (sync_queue'ya girmez)
    };
    if (existing.isNotEmpty) {
      await db.update('local_tickets', row,
          where: 'local_id = ?', whereArgs: [existing.first['local_id']]);
    } else {
      row['created_at'] = now;
      await db.insert('local_tickets', row);
    }
  }

  /// Su an LAN'da acik olan ticket_number'lar disindaki tum LAN masalarini sil (kapananlar temizlenir).
  Future<void> pruneLanTickets(Set<String> activeTicketNumbers) async {
    final db = await database;
    final all = await db.query('local_tickets',
        columns: ['local_id', 'ticket_number'], where: "lan_origin = 'lan'");
    for (final t in all) {
      final tn = t['ticket_number']?.toString();
      if (tn == null || !activeTicketNumbers.contains(tn)) {
        await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [t['local_id']]);
      }
    }
  }

  /// Bu cihazin ACIK offline masalarinin ozeti (LAN yayini icin — lider yollar). Sadece lan_origin='self'.
  Future<List<Map<String, dynamic>>> getSelfOpenTicketsForLan() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT ticket_number, table_id, table_number, status, total
        FROM local_tickets
       WHERE status = 'open' AND COALESCE(lan_origin,'self') = 'self'
    ''');
  }

  /// 7 Tem 2026 (LAN Faz 2 — Fable K1): Bu masa SADECE LAN yansimasiyla mi dolu?
  /// (bu cihazin kendi acik self ticket'i YOK ama baska cihazdan yansiyan lan_origin='lan' VAR).
  /// true -> masa SALT-OKUNUR: garson uzerine YENI adisyon acmamali (cift kayit/ciro karismasi).
  /// Masayi ACAN cihaz backend'e sync eder; bu cihaz sadece gorur.
  Future<bool> hasLanOnlyOpenTicket(int tableId) async {
    final db = await database;
    final self = await db.query('local_tickets',
        columns: ['local_id'],
        where: "table_id = ? AND status = 'open' AND COALESCE(lan_origin,'self') = 'self'",
        whereArgs: [tableId], limit: 1);
    if (self.isNotEmpty) return false; // kendi acik ticket'i var -> normal akis
    final lan = await db.query('local_tickets',
        columns: ['local_id'],
        where: "table_id = ? AND status = 'open' AND lan_origin = 'lan'",
        whereArgs: [tableId], limit: 1);
    return lan.isNotEmpty;
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

      // 🟠 6 Tem 2026 DÜZELTME 2: AKTİF ADİSYON HER ZAMAN KAZANIR — open ÖNCE kontrol.
      // Senaryo: offline'da masa kapatildi (closed, server_id=NULL) SONRA ayni masa tekrar
      // offline acildi (yeni open, server_id=NULL). Masa HEM closed HEM open listesinde cikar.
      // Eski kod closed'i once kontrol edince masa BOS/yesil gorunuyordu, aktif adisyon gizleniyordu.
      // Simdi open once: masaya aktif offline adisyon varsa DOLU goster.
      if (openTableIds.contains(tableId)) {
        newTable['status'] = 'occupied';
        print('[LocalDb] Masa $tableId offline açık (aktif adisyon), occupied gösteriliyor');
      }
      // Offline'da kapatılan (ve tekrar acilmamis) masa: boş göster
      else if (closedTableIds.contains(tableId)) {
        newTable['status'] = 'empty';
        newTable['current_ticket_id'] = null;
        print('[LocalDb] Masa $tableId offline kapatıldı, empty gösteriliyor');
      }

      return newTable;
    }).toList();
  }

  // ==================== YAZICI KUYRUĞU İŞLEMLERİ ====================

  // Yazdırma işini kuyruğa ekle
  Future<int> addToPrintQueue({
    required String printType,
    required String printerIp,
    required int printerPort,
    String? printerName,
    required Map<String, dynamic> receiptData,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final id = await db.insert('print_queue', {
      'print_type': printType,
      'printer_ip': printerIp,
      'printer_port': printerPort,
      'printer_name': printerName,
      'receipt_data': jsonEncode(receiptData),
      'status': 'pending',
      'retry_count': 0,
      'max_retries': 5,
      'created_at': now,
      'last_attempt_at': now,
    });

    print('[LocalDb] Print job eklendi: $id (type: $printType, printer: $printerIp)');
    return id;
  }

  // Bekleyen yazdırma işlerini getir
  // 12 Haz 2026: completed temizliği buraya bağlandı — print_queue_service._processQueue()
  // kuyruk boşken early-return yaptığı için cleanupCompletedPrintJobs() hiç çalışmıyordu
  // (completed satırlar sürekli birikiyordu). Bu fonksiyon early-return'dan ÖNCE her
  // döngüde çağrıldığı için temizlik artık garantili; 10dk throttle gereksiz DELETE'i önler.
  Future<List<Map<String, dynamic>>> getPendingPrintJobs() async {
    final db = await database;
    final nowDt = DateTime.now();
    if (_lastPrintCleanupAt == null ||
        nowDt.difference(_lastPrintCleanupAt!) > const Duration(minutes: 10)) {
      _lastPrintCleanupAt = nowDt;
      try {
        await cleanupCompletedPrintJobs();
      } catch (e) {
        print('[LocalDb] completed print job temizlik hatası: $e');
      }
    }
    return await db.query(
      'print_queue',
      where: "status = 'pending' AND retry_count < max_retries",
      orderBy: 'created_at ASC',
    );
  }

  // Tek bir yazdırma işini getir
  Future<Map<String, dynamic>?> getPrintJob(int id) async {
    final db = await database;
    final results = await db.query(
      'print_queue',
      where: 'id = ?',
      whereArgs: [id],
    );
    return results.isNotEmpty ? results.first : null;
  }

  // Tüm yazdırma işlerini getir (modal için)
  Future<List<Map<String, dynamic>>> getAllPrintJobs() async {
    final db = await database;
    return await db.query(
      'print_queue',
      where: "status IN ('pending', 'failed')",
      orderBy: 'created_at DESC',
    );
  }

  /// 6 Tem 2026 (offline fix Adim 4b): Cikmamis mutfak fisi olan masalarin table_id'lerini doner.
  /// Amac: OFFLINE'da masa kartinda "FIS CIKMADI" badge'i gostermek (online'da bu getPendingOrders
  /// print_failed'den geliyordu; offline'da o endpoint calismaz -> lokal print_queue'dan besle).
  /// pending VEYA failed kitchen job'larin receipt_data.ticket.table_id'sini toplar.
  Future<Set<int>> getPrintFailedTableIds() async {
    final db = await database;
    final rows = await db.query(
      'print_queue',
      columns: ['receipt_data'],
      where: "print_type = 'kitchen' AND status IN ('pending', 'failed')",
    );
    final result = <int>{};
    for (final r in rows) {
      final raw = r['receipt_data'];
      if (raw is! String) continue;
      try {
        final decoded = jsonDecode(raw);
        final ticket = decoded is Map ? decoded['ticket'] : null;
        final tid = ticket is Map ? ticket['table_id'] : null;
        if (tid is int) {
          result.add(tid);
        } else if (tid != null) {
          final parsed = int.tryParse(tid.toString());
          if (parsed != null) result.add(parsed);
        }
      } catch (_) {
        // bozuk JSON -> atla
      }
    }
    return result;
  }

  // Yazdırma işini tamamlandı olarak işaretle
  Future<void> markPrintCompleted(int id) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.update(
      'print_queue',
      {
        'status': 'completed',
        'completed_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    print('[LocalDb] Print job tamamlandı: $id');
  }

  // Yazdırma işini başarısız olarak işaretle
  Future<void> markPrintFailed(int id, String? errorMessage) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // Önce mevcut retry_count'u al
    final job = await getPrintJob(id);
    if (job == null) return;

    final newRetryCount = (job['retry_count'] as int) + 1;
    final maxRetries = job['max_retries'] as int;

    await db.update(
      'print_queue',
      {
        'retry_count': newRetryCount,
        'error_message': errorMessage,
        'last_attempt_at': now,
        'status': newRetryCount >= maxRetries ? 'failed' : 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    print('[LocalDb] Print job başarısız: $id (retry: $newRetryCount/$maxRetries)');
  }

  // Yazdırma işini sıfırla (manuel retry için)
  Future<void> resetPrintJob(int id) async {
    final db = await database;

    await db.update(
      'print_queue',
      {
        'status': 'pending',
        'retry_count': 0,
        'error_message': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    print('[LocalDb] Print job sıfırlandı: $id');
  }

  // Yazdırma işini sil
  Future<void> deletePrintJob(int id) async {
    final db = await database;
    await db.delete('print_queue', where: 'id = ?', whereArgs: [id]);
    print('[LocalDb] Print job silindi: $id');
  }

  // Başarısız tüm işleri sil
  Future<void> clearFailedPrintJobs() async {
    final db = await database;
    final count = await db.delete('print_queue', where: "status = 'failed'");
    print('[LocalDb] $count başarısız print job silindi');
  }

  // Tamamlanmış eski işleri temizle (1 saatten eski)
  Future<void> cleanupCompletedPrintJobs() async {
    final db = await database;
    final oneHourAgo = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();

    final count = await db.delete(
      'print_queue',
      where: "status = 'completed' AND completed_at < ?",
      whereArgs: [oneHourAgo],
    );

    if (count > 0) {
      print('[LocalDb] $count eski print job temizlendi');
    }
  }

  // Yazdırma kuyruğu özeti
  Future<Map<String, int>> getPrintQueueSummary() async {
    final db = await database;

    final pending = await db.rawQuery(
      "SELECT COUNT(*) as count FROM print_queue WHERE status = 'pending'",
    );
    final failed = await db.rawQuery(
      "SELECT COUNT(*) as count FROM print_queue WHERE status = 'failed'",
    );
    final completed = await db.rawQuery(
      "SELECT COUNT(*) as count FROM print_queue WHERE status = 'completed'",
    );

    return {
      'pending_count': pending.first['count'] as int,
      'failed_count': failed.first['count'] as int,
      'completed_count': completed.first['count'] as int,
    };
  }

  // ───────────────────────────────────────────────────────────────────────
  // 1 Haz 2026 (v1.5.6) — SQLite şişme önleme (donma fix)
  // cleanupSyncedTickets DELETE yapıyor ama dosya küçülmüyordu
  // (auto_vacuum yok → silinen kayıtlar "boş alan" tutuyor).
  // ───────────────────────────────────────────────────────────────────────

  /// DB dosya boyutunu byte cinsinden döndür.
  /// 12 Haz 2026: getDatabasesPath() yerine sabitlenmiş yol (_resolveDbPath) —
  /// yoksa compactDatabase eski CWD-relatif konuma bakıp yanlış ölçerdi.
  Future<int> getDatabaseSizeBytes() async {
    try {
      final file = File(await _resolveDbPath());
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// Boot'ta çağrılır. DB > thresholdBytes ise VACUUM çalıştırır.
  /// VACUUM: tüm DB'yi yeniden yazar, silinen kayıtların yer kaybını geri kazanır.
  /// (Çok büyük DB'lerde yavaş — sadece şişmiş bayilerde tetiklenir.)
  Future<void> compactDatabase({int thresholdBytes = 50 * 1024 * 1024}) async {
    try {
      final beforeSize = await getDatabaseSizeBytes();
      if (beforeSize < thresholdBytes) {
        print('[LocalDb] compactDatabase atlandı: ${(beforeSize / (1024 * 1024)).toStringAsFixed(1)}MB < ${(thresholdBytes / (1024 * 1024)).toInt()}MB threshold');
        return;
      }
      final db = await database;
      print('[LocalDb] VACUUM başlıyor (DB ${(beforeSize / (1024 * 1024)).toStringAsFixed(1)}MB)...');
      final sw = Stopwatch()..start();
      await db.execute('VACUUM');
      sw.stop();
      final afterSize = await getDatabaseSizeBytes();
      final reclaimed = beforeSize - afterSize;
      print('[LocalDb] VACUUM tamamlandı ${sw.elapsedMilliseconds}ms: ${(beforeSize / (1024 * 1024)).toStringAsFixed(1)}MB → ${(afterSize / (1024 * 1024)).toStringAsFixed(1)}MB (${(reclaimed / (1024 * 1024)).toStringAsFixed(1)}MB geri kazanıldı)');
    } catch (e) {
      print('[LocalDb] compactDatabase hatası: $e');
    }
  }

  /// cleanupSyncedTickets gibi büyük DELETE'ler sonrası boş alanı geri kazan.
  /// (auto_vacuum=INCREMENTAL aktifse hızlı; değilse no-op.)
  Future<void> incrementalVacuum({int pages = 1000}) async {
    try {
      final db = await database;
      await db.execute('PRAGMA incremental_vacuum($pages)');
    } catch (e) {
      print('[LocalDb] incremental_vacuum hatası: $e');
    }
  }

  // Veritabanını kapat
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
