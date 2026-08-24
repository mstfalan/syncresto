import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'ikram_rules.dart';
import 'log_service.dart';

/// 20 Ağu 2026 — SELF-HEAL sinyali: DB açıldı ama PRAGMA quick_check 'ok' dönmedi
/// (sessiz sayfa-bozulması). `openDatabase` bir istisna atmadığı için recovery
/// akışına düşürmek üzere bu özel sinyal fırlatılır. `_isCorruptionError` bunu
/// ayrıca tanır (bkz. `_initDatabase` catch bloğu).
class _CorruptSignal implements Exception {
  final String reason;
  _CorruptSignal(this.reason);
  @override
  String toString() => '_CorruptSignal($reason)';
}

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
  // Fable B1: ONLINE teslim mirror'a yazilinca (sync_queue izi yok) bayat backend snapshot'i
  // upsertServerTicket'te delivered_*'i geri EZMESIN diye kisa omurlu koruma. local_item_id -> zaman.
  static final Map<int, DateTime> _deliveryTouchedAt = {};
  static const Duration _kDeliveryTouchTtl = Duration(seconds: 15);
  // v20 IKRAM (3 Agu 2026): ayni desen — online ikram isareti mirror'a yazilinca
  // (sync_queue izi yok) bayat backend snapshot'i is_ikram'i geri EZMESIN. local_item_id -> zaman.
  static final Map<int, DateTime> _ikramTouchedAt = {};
  static final LocalDbService _instance = LocalDbService._internal();

  factory LocalDbService() => _instance;
  LocalDbService._internal();

  // 20 Ağu 2026 [B] — single-flight: eşzamanlı ilk erişimlerde (sync_service +
  // print_queue_service + tables_screen aynı anda) _initDatabase yalnız BİR kez
  // koşsun. Aksi halde recovery/rename yarışır, çift açılış olur.
  static Future<Database>? _initFuture;
  Future<Database> get database async {
    final ex = _database;
    if (ex != null) return ex;
    // F5: bu erişimin beklediği future'ı yerelde tut.
    final f = _initFuture ??= _initDatabase();
    try {
      final db = await f;
      _database = db;
      return db;
    } catch (e) {
      // Başarısızsa future'ı sıfırla → sonraki erişim yeniden denesin
      // (main.dart "Tekrar Dene" akışı bunu tetikler). F5: yalnız HÂLÂ aynı
      // future ise sıfırla — araya yeni bir init başlamışsa onu ezme.
      if (identical(_initFuture, f)) _initFuture = null;
      rethrow;
    }
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

    // ───────────────────────────────────────────────────────────────────────
    // 20 Ağu 2026 [C] — ELEKTRİK KESİNTİSİ SELF-HEAL (Fable-rafine)
    // Bozuk DB'de openDatabase patlayınca _initDatabase throw ediyor, init bitmiyor,
    // runApp çağrılmıyor → BEYAZ EKRAN. Artık:
    //   1) aç + PRAGMA quick_check → 'ok' ise DÖNDÜR (sağlam)
    //   2) quick_check 'ok' değilse (sessiz sayfa-bozulması) kapat + _CorruptSignal
    //   3) SADECE corruption (SQLITE_CORRUPT/NOTADB veya quick_check fail) → recovery:
    //      bozuk dosya SİLİNMEZ, yeniden ADLANDIRILIR + taze DB (onCreate) → boş
    //      sync_queue → sunucudan re-sync (MÜKERRER push YOK).
    //   4) lock/izin/disk-dolu/migration hataları → RETHROW (main.dart yakalar,
    //      InitialSyncScreen "Tekrar Dene" ekranı gösterir, beyaz ekran DEĞİL).
    //
    // Kapsam sabiti (yanlış-pozitif wipe önlemi): _isCorruptionError SADECE bu
    // bloktaki _openDb istisnalarına ve _CorruptSignal'a uygulanır. CRUD/sync
    // katmanının ürettiği 'malformed' benzeri string'ler buraya ULAŞMAZ → kullanıcı
    // verisi asla yanlışlıkla wipe TETIKLEYEMEZ.
    // ───────────────────────────────────────────────────────────────────────
    try {
      final db = await _openDb(path);
      if (await _quickCheckOk(db)) return db; // Q2: sağlam
      try {
        await db.close();
      } catch (_) {}
      throw _CorruptSignal('quick_check != ok');
    } catch (e) {
      if (!(e is _CorruptSignal || _isCorruptionError(e))) {
        rethrow; // K4: lock/izin/disk-dolu/migration → main yakalar
      }
      return await _recreateAfterCorruption(path, e);
    }
  }

  /// 20 Ağu 2026 [C] — asıl openDatabase çağrısı (version/onCreate/onUpgrade/
  /// onConfigure AYNEN korunmuştur; recovery hem ilk açılışta hem taze DB'de
  /// bunu kullanır).
  Future<Database> _openDb(String path) async {
    return await openDatabase(
      path,
      version: 20, // v20 (3 Agu 2026): IKRAM — cached_cancel_reasons + cached_ikram_reasons + local_ticket_items.is_ikram/ikram_reason
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
  // 20 Ağu 2026 [C/E] — CORRUPTION RECOVERY + YARDIMCILAR (additive, elektrik
  // kesintisi self-heal). Var olan CRUD/sync/onUpgrade mantığına dokunmaz.
  // ───────────────────────────────────────────────────────────────────────

  /// K1: boot başına TEK wipe. İkinci corruption'da yedeği ASLA ezme.
  static bool _recreateAttemptedThisBoot = false;

  /// Bozuk DB'yi güvenle yedekle (SİLME → yeniden ADLANDIR) ve taze DB oluştur.
  Future<Database> _recreateAfterCorruption(String path, Object cause) async {
    // K1: boot başına tek deneme — ikinci corruption'da mevcut yedeği ezme, hatayı
    // yükselt (main.dart hata ekranı gösterir; forensics yedeği korunur).
    if (_recreateAttemptedThisBoot) throw cause;
    _recreateAttemptedThisBoot = true;

    final ts =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');

    // K2: SİLME — yeniden ADLANDIR (forensics + `sqlite3 .recover` ile kurtarma şansı).
    final corruptMain = '$path.corrupt-$ts';
    await _renameQuietly(path, corruptMain);
    await _renameQuietly('$path-wal', '$path.corrupt-$ts-wal');
    await _renameQuietly('$path-shm', '$path.corrupt-$ts-shm');

    // F3 (K2 ihlali önlemi): yedek GERÇEKTEN oluştu mu? rename+copy İKİSİ de
    // başarısızsa (ör. Windows sharing violation + disk dolu) bozuk .db hâlâ
    // path'te durur. Koşulsuz deleteDatabase onu İMHA EDER = tek kopya yok olur.
    // Yedek doğrulanamadıysa: prune + deleteDatabase ATLA, cause'u RETHROW et →
    // main.dart "Tekrar Dene" ekranı (bozuk da olsa tek kopya korunur).
    if (!await File(corruptMain).exists()) {
      try {
        LogService().error(
          LogType.error,
          'DB bozuk ama yedeklenemedi (rename+copy basarisiz) — wipe IPTAL, hata ekrani',
          details: {
            'db_path': path,
            'event': 'db_corruption_backup_failed',
          },
          error: cause,
        );
      } catch (_) {}
      throw cause;
    }

    // K1+F2: en yeni 3 corrupt set'i tut, eskiyi sil (disk şişmesin). exclude ile
    // AZ ÖNCE oluşturulan yedeği prune'dan MUAF tut: elektrik kesintisi RTC'yi
    // sıfırlarsa ($ts '2000-...' olur) ve diskte 2026-adlı 3 yedek varsa, yeni
    // yedek leksikografik "en eski" sayılıp SİLİNİRDİ → forensik kopya yok olurdu.
    await _pruneCorruptBackups(path, keep: 3, exclude: corruptMain);

    // Q4: rename sonrası orijinal yolda kalan -journal/-wal/-shm kalıntılarını
    // güvenle süpür (açık handle yok — _openDb henüz başarılı olmadı). Yalnız
    // yedek DOĞRULANDIKTAN sonra çalışır (F3).
    try {
      await databaseFactory.deleteDatabase(path);
    } catch (_) {}

    // Q8: sonraki başarılı boot'ta sunucuya raporlanabilsin diye iz bırak.
    await _writeRecoveryMarker(path, cause);

    // KANIT: uzaktan #poslogs'ta görülür (online olunca gönderilir).
    // (Layer note: normalde local_db LogService'e bağlanmaz; bu TEK-SEFERLİK
    //  felaket-kurtarma olayı için spec gereği doğrudan loglanır, try/catch ile
    //  sarılı — loglama patlarsa recovery bloklanmaz.)
    try {
      LogService().error(
        LogType.error,
        'DB bozulmus, yedeklenip sifirdan olusturuldu (elektrik kesintisi kurtarma)',
        details: {
          'db_path': path,
          'corrupt_backup': '$path.corrupt-$ts',
          'event': 'db_corruption_recovery',
        },
        error: cause,
      );
    } catch (_) {}

    // Taze DB (onCreate) → boş sync_queue → sunucudan re-sync, MÜKERRER push YOK.
    return await _openDb(path);
  }

  /// PRAGMA quick_check(1): sessiz sayfa-bozulmasını yakala.
  /// quick_check integrity_check'ten hafiftir (index-sırası doğrulaması yapmaz)
  /// ama yine de tüm sayfaları tarar — boot başına 1 kez.
  ///
  /// F1 (KRİTİK): catch-all ARTIK YOK. Eskiden `catch (_) => false` busy/locked/
  /// disk-I/O gibi GEÇİCİ hatalarda bile SAĞLAM DB'yi corruption sanıp wipe
  /// ettiriyordu (çift-başlatma quick_check'i busy_timeout'u aşabilir; elektrik
  /// sonrası titrek disk "disk I/O error" verir). Artık:
  ///   - GERÇEK corruption (SQLITE_CORRUPT/NOTADB / 'malformed' ...) → false
  ///     (recovery yolu, wipe).
  ///   - busy/locked/ioerr → db'yi kapat + RETHROW → _initDatabase corruption
  ///     saymaz, rethrow eder → main.dart "Tekrar Dene" ekranı (WIPE YOK).
  Future<bool> _quickCheckOk(Database db) async {
    try {
      final r = await db.rawQuery('PRAGMA quick_check(1)');
      return r.isNotEmpty &&
          (r.first.values.first?.toString().toLowerCase() == 'ok');
    } catch (e) {
      if (_isCorruptionError(e)) return false; // gerçek corruption → recovery
      try {
        await db.close();
      } catch (_) {}
      rethrow; // busy/locked/ioerr → K4 yolu, wipe YOK
    }
  }

  /// SADECE corruption'ı tanı. lock/busy/izin/disk-dolu/disk-i/o ASLA true dönmez
  /// (bunlar geçici → wipe YAPILMAZ, rethrow edilir). Yalnız _openDb istisnalarına
  /// uygulanır (kapsam sabiti — bkz. _initDatabase).
  bool _isCorruptionError(Object e) {
    if (e is DatabaseException) {
      final rc = e.getResultCode();
      if (rc == 11 || rc == 26) return true; // SQLITE_CORRUPT / SQLITE_NOTADB
    }
    final s = e.toString().toLowerCase();
    const needles = <String>[
      'malformed',
      'file is not a database',
      'not a database',
      'disk image is malformed',
      'sqlite_corrupt',
      'sqlite_notadb',
    ];
    // KASITLI DIŞARIDA: 'locked', 'busy', 'unable to open', 'disk i/o',
    // 'disk is full' — bunlar corruption DEĞİL, wipe TETIKLEMEZ.
    for (final n in needles) {
      if (s.contains(n)) return true;
    }
    return false;
  }

  /// Dosyayı sessizce taşı: rename dener, Windows "in use"/sharing-violation'da
  /// copy+delete fallback. Asla throw etmez (recovery bloklanmasın).
  Future<void> _renameQuietly(String from, String to) async {
    try {
      final f = File(from);
      if (!await f.exists()) return;
      try {
        await f.rename(to);
      } catch (_) {
        try {
          await f.copy(to);
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// En yeni `keep` corrupt set'i (ana + -wal + -shm) TOPLAM tut, eskilerini sil.
  /// İsimdeki ISO timestamp leksikografik olarak kronolojik → sıralama güvenli.
  ///
  /// F2: `exclude` verilirse o set (az önce oluşturulan yedek) HİÇBİR koşulda
  /// silinmez ve toplam kotaya dahil sayılır — RTC sıfırlanıp yeni yedek
  /// leksikografik "en eski" görünse bile korunur.
  Future<void> _pruneCorruptBackups(String path,
      {required int keep, String? exclude}) async {
    try {
      final dir = Directory(dirname(path));
      if (!await dir.exists()) return;
      final prefix = '${basename(path)}.corrupt-';
      final excludeBase = exclude == null ? null : basename(exclude);
      final mains = <String>[];
      var excludedCount = 0;
      await for (final e in dir.list(followLinks: false)) {
        final name = basename(e.path);
        // Ana corrupt kayıtları: prefix ile başlar, -wal/-shm ile BİTMEZ.
        if (name.startsWith(prefix) &&
            !name.endsWith('-wal') &&
            !name.endsWith('-shm')) {
          if (excludeBase != null && name == excludeBase) {
            excludedCount++; // korunan yeni yedek — kotadan sayılır ama silinmez
            continue;
          }
          mains.add(e.path);
        }
      }
      // Korunan yedek toplam kotaya dahil → eskilerden yalnız (keep-excluded) kalır.
      var allowOld = keep - excludedCount;
      if (allowOld < 0) allowOld = 0;
      if (mains.length <= allowOld) return;
      mains.sort((a, b) => basename(a).compareTo(basename(b))); // eski → yeni
      final toDelete = mains.sublist(0, mains.length - allowOld);
      for (final mainPath in toDelete) {
        for (final p in [mainPath, '$mainPath-wal', '$mainPath-shm']) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Q8: DB klasörüne recovery iz dosyası yaz. Sonraki başarılı boot'ta sunucuya
  /// raporlanıp silinebilir — bu turda SADECE yazılır (raporlama opsiyonel/eklenmedi).
  Future<void> _writeRecoveryMarker(String path, Object cause) async {
    try {
      final markerPath = join(dirname(path), 'db_recovery_marker.json');
      final causeShort = cause.toString();
      final marker = <String, dynamic>{
        'at': DateTime.now().toIso8601String(),
        'step': 'recreate_after_corruption',
        'cause_kisa':
            causeShort.length > 300 ? causeShort.substring(0, 300) : causeShort,
      };
      await File(markerPath).writeAsString(jsonEncode(marker));
      // TODO(opsiyonel): sonraki başarılı boot'ta bu marker'ı sunucuya raporla + sil.
    } catch (_) {}
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
    // 20 Ağu 2026 [D/K3] — TEK SEFER: recovery sonrası antik CWD-relatif DB
    // hortlamasın. SharedPreferences bayrağı set ise HEMEN çık. İlk kontrolden
    // sonra (kopyalasa da kopyalamasa da) bayrak true yazılır (finally).
    const migCheckedKey = 'legacy_db_migration_checked';
    SharedPreferences? migPrefs;
    try {
      migPrefs = await SharedPreferences.getInstance();
      if (migPrefs.getBool(migCheckedKey) == true) return;
    } catch (_) {
      migPrefs = null; // prefs erişilemezse guard'sız eski davranışa düş
    }
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
    } finally {
      // K3: ilk kontrolden sonra bayrağı işaretle (return'lerde de finally çalışır).
      try {
        await migPrefs?.setBool(migCheckedKey, true);
      } catch (_) {}
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
        combo_enabled INTEGER DEFAULT 0,
        combo_required_qty INTEGER,
        combo_gift_qty INTEGER,
        combo_gift_mode TEXT,
        combo_discount_percent REAL,
        combo_discount_amount REAL,
        combo_repeat INTEGER DEFAULT 1,
        combo_pos_selection_required INTEGER DEFAULT 1,
        combo_pos_unlimited INTEGER DEFAULT 0,
        variants_allow_multiple_pos INTEGER DEFAULT 0,
        variants_required_pos INTEGER DEFAULT 0,
        ingredients TEXT,
        hide_from_tracking INTEGER DEFAULT 0,
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
        current_total REAL,
        ticket_opened_at TEXT,
        opened_by_device TEXT,
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

    // Ödeme yöntemleri cache (v13) — offline'da dinamik ödeme butonları görünsün
    await db.execute('''
      CREATE TABLE cached_payment_methods (
        code TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        icon TEXT,
        is_builtin INTEGER DEFAULT 0,
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
        lan_origin TEXT DEFAULT 'self',
        waiter_name TEXT,
        section_name TEXT,
        opened_by_device TEXT
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
        added_by INTEGER,
        added_by_name TEXT,
        delivered_at TEXT,
        delivered_by INTEGER,
        delivered_by_name TEXT,
        portion TEXT,
        payment_status TEXT,
        payment_method TEXT,
        skip_pos_print INTEGER DEFAULT 0,
        combo_group_id TEXT,
        combo_group_name TEXT,
        combo_pick_name TEXT,
        is_ikram INTEGER DEFAULT 0,
        ikram_reason TEXT,
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

    // v20: Iptal + ikram sebepleri AYRI tablolarda (offline sebep listesi garantisi).
    // cached_lookups('cancel_reasons') KORUNUR (legacy okuma fallback'i) — cift kaynak degil,
    // dedicated tablo bos ise (ilk migration, henuz sync olmadi) legacy'den okunur.
    await db.execute('''
      CREATE TABLE cached_cancel_reasons (
        id INTEGER PRIMARY KEY,
        reason TEXT NOT NULL,
        sort_order INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        cached_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE cached_ikram_reasons (
        id INTEGER PRIMARY KEY,
        reason TEXT NOT NULL,
        sort_order INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
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

    // v10 (7 Tem 2026): cached_tables'a current_total + ticket_opened_at. Online sync'te backend'in
    // gonderdigi masa tutari cache'lenir -> offline'a gecince masa tutarlari KAYBOLMAZ (eskiden
    // sadece canli server cevabinda vardi, cache'te YOKTU).
    if (oldVersion < 10) {
      for (final col in [
        'ALTER TABLE cached_tables ADD COLUMN current_total REAL',
        'ALTER TABLE cached_tables ADD COLUMN ticket_opened_at TEXT',
      ]) {
        try {
          await db.execute(col);
        } catch (e) {
          print('[LocalDb] v10 kolon zaten var: $e');
        }
      }
      print('[LocalDb] v10 cached_tables tutar kolonlari eklendi (current_total/ticket_opened_at)');
    }

    // v14 (17 Tem 2026): opened_by_device — masayı hangi kasa açtı. cached_tables (online sync'ten)
    // + local_tickets (offline açılışta kendi kasa adı). owner_device_id (LAN lease hash'i) ile
    // KARIŞTIRMA: bu kolon kullanıcıya gösterilen okunabilir ad ('Kasa 1'), lease mantığı bozulmaz.
    if (oldVersion < 14) {
      for (final col in [
        'ALTER TABLE cached_tables ADD COLUMN opened_by_device TEXT',
        'ALTER TABLE local_tickets ADD COLUMN opened_by_device TEXT',
      ]) {
        try {
          await db.execute(col);
        } catch (e) {
          print('[LocalDb] v14 kolon zaten var: $e');
        }
      }
      print('[LocalDb] v14 opened_by_device kolonlari eklendi');
    }

    // v15 (21 Tem 2026): hide_from_tracking — "Masa Takip Ekranında Gösterme" ürün bazlı gizleme
    // (offline). Backend dondurmese NULL/0 -> gorunur (mevcut davranis, guvenli). Additive.
    if (oldVersion < 15) {
      try {
        await db.execute('ALTER TABLE cached_products ADD COLUMN hide_from_tracking INTEGER DEFAULT 0');
        print('[LocalDb] v15 hide_from_tracking kolonu eklendi');
      } catch (e) {
        print('[LocalDb] v15 kolon zaten var: $e');
      }
    }

    // v16 (31 Tem 2026): combo paket kimligi — ayni combo seciminden gelen kalemler ayni
    // combo_group_id'yi tasir; fis/mutfak/adisyon ANA URUN altinda gruplar. Backend
    // panel_pos_ticket_items ile AYNI isimler. NULL = combo disi kalem (mevcut davranis). Additive.
    if (oldVersion < 16) {
      for (final k in ['combo_group_id', 'combo_group_name', 'combo_pick_name']) {
        try {
          await db.execute('ALTER TABLE local_ticket_items ADD COLUMN $k TEXT');
          print('[LocalDb] v16 $k kolonu eklendi');
        } catch (e) {
          print('[LocalDb] v16 $k zaten var: $e');
        }
      }
    }

    // v17 (31 Tem 2026): combo POS ayarlari CEVRIMDISI da gecerli olsun. Bu iki alan
    // cache'lenmedigi surece internet gidince ayar YOK sayiliyordu (eski davranisa dusuyordu):
    // "limitsiz secim" kapali gibi, "zorunlu secim" acik gibi. Varsayilanlar ESKI DAVRANIS
    // (secim zorunlu=1, limitsiz=0) — backend dondurmezse hicbir sey degismez. Additive.
    if (oldVersion < 17) {
      for (final col in [
        'ALTER TABLE cached_products ADD COLUMN combo_pos_selection_required INTEGER DEFAULT 1',
        'ALTER TABLE cached_products ADD COLUMN combo_pos_unlimited INTEGER DEFAULT 0',
      ]) {
        try {
          await db.execute(col);
          print('[LocalDb] v17 kolon eklendi: $col');
        } catch (e) {
          print('[LocalDb] v17 kolon zaten var: $e');
        }
      }
    }

    // v18 (31 Tem 2026): POS varyant coklu secim ayarlari CEVRIMDISI da gecerli olsun.
    // Varsayilanlar ESKI DAVRANIS (coklu kapali=0, zorunlu kapali=0) — backend dondurmezse
    // hicbir sey degismez, tekli varyant akisi aynen calisir. Additive.
    if (oldVersion < 18) {
      for (final col in [
        'ALTER TABLE cached_products ADD COLUMN variants_allow_multiple_pos INTEGER DEFAULT 0',
        'ALTER TABLE cached_products ADD COLUMN variants_required_pos INTEGER DEFAULT 0',
      ]) {
        try {
          await db.execute(col);
          print('[LocalDb] v18 kolon eklendi: $col');
        } catch (e) {
          print('[LocalDb] v18 kolon zaten var: $e');
        }
      }
    }

    // v19 (1 Agu 2026): URUN ICERIKLERI cevrimdisi (Mustafa: "webde gosteriyoruz ama POS'ta
    // gostermiyoruz"). JSON metin olarak saklanir (variants/extras ile ayni desen).
    // Kolon bos/NULL ise Flutter icerik bolumunu HIC cizmez -> eski gorunum BIREBIR ayni.
    // ⚠️ Varyant SECIM GRUPLARI icin goc GEREKMEZ: variants zaten JSON saklaniyor,
    //    group_name/group_required/group_multi otomatik tasinir.
    if (oldVersion < 19) {
      try {
        await db.execute('ALTER TABLE cached_products ADD COLUMN ingredients TEXT');
        print('[LocalDb] v19 ingredients kolonu eklendi');
      } catch (e) {
        print('[LocalDb] v19 ingredients zaten var: $e');
      }
    }

    // v20 (3 Agu 2026): IKRAM (Mustafa: her POS ozelligi cache+offline).
    // (a) cached_cancel_reasons — iptal sebepleri AYRI tabloda (cached_lookups legacy'si
    //     KORUNUR, okuma once dedicated'a bakar, bossa legacy'e duser — veri kaybi yok).
    // (b) cached_ikram_reasons — ikram sebepleri offline'da da secilebilsin.
    // (c) local_ticket_items.is_ikram/ikram_reason — mirror'lanan adisyonlarda ikram
    //     isareti offline'a tasinir; cevrimdisi kapanis ikram tutarini dusebilir.
    // TAMAMEN EKLEMELI: hicbir mevcut kolon/veri degismez; backend alan gondermezse
    // is_ikram NULL/0 -> ikram YOK (mevcut davranis birebir korunur).
    if (oldVersion < 20) {
      for (final ddl in [
        '''CREATE TABLE IF NOT EXISTS cached_cancel_reasons (
             id INTEGER PRIMARY KEY,
             reason TEXT NOT NULL,
             sort_order INTEGER DEFAULT 0,
             is_active INTEGER DEFAULT 1,
             cached_at TEXT NOT NULL
           )''',
        '''CREATE TABLE IF NOT EXISTS cached_ikram_reasons (
             id INTEGER PRIMARY KEY,
             reason TEXT NOT NULL,
             sort_order INTEGER DEFAULT 0,
             is_active INTEGER DEFAULT 1,
             cached_at TEXT NOT NULL
           )''',
        'ALTER TABLE local_ticket_items ADD COLUMN is_ikram INTEGER DEFAULT 0',
        'ALTER TABLE local_ticket_items ADD COLUMN ikram_reason TEXT',
      ]) {
        try {
          await db.execute(ddl);
        } catch (e) {
          print('[LocalDb] v20 adim zaten var: $e');
        }
      }
      print('[LocalDb] v20 IKRAM tablolari/kolonlari eklendi');
    }

    // v11 (7 Tem 2026): offline-parity — masa detayi + masa takip ekrani canliyla birebir olsun.
    // local_tickets: garson/salon adi. local_ticket_items: ekleyen/teslim eden garson, porsiyon,
    // odeme durumu, mutfak-gizle. Hepsi nullable/DEFAULT'lu additive -> sync_queue/FIFO etkilenmez.
    if (oldVersion < 11) {
      for (final col in [
        'ALTER TABLE local_tickets ADD COLUMN waiter_name TEXT',
        'ALTER TABLE local_tickets ADD COLUMN section_name TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN added_by INTEGER',
        'ALTER TABLE local_ticket_items ADD COLUMN added_by_name TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN delivered_at TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN delivered_by INTEGER',
        'ALTER TABLE local_ticket_items ADD COLUMN delivered_by_name TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN portion TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN payment_status TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN payment_method TEXT',
        'ALTER TABLE local_ticket_items ADD COLUMN skip_pos_print INTEGER DEFAULT 0',
      ]) {
        try {
          await db.execute(col);
        } catch (e) {
          print('[LocalDb] v11 kolon zaten var: $e');
        }
      }
      print('[LocalDb] v11 offline-parity kolonlari eklendi');
    }

    // v12 (8 Tem 2026): COMBO FAZ4 — cached_products combo_* kolonlari. Backend /api/pos/products
    // combo alanlarini dondurunce POS offline combo hesabi (comboCalculator.dart) calisir. Backend
    // dondurmese kolonlar NULL/0 -> combo_enabled=0 -> combo KAPALI (mevcut davranis, guvenli).
    if (oldVersion < 12) {
      for (final col in [
        'ALTER TABLE cached_products ADD COLUMN combo_enabled INTEGER DEFAULT 0',
        'ALTER TABLE cached_products ADD COLUMN combo_required_qty INTEGER',
        'ALTER TABLE cached_products ADD COLUMN combo_gift_qty INTEGER',
        'ALTER TABLE cached_products ADD COLUMN combo_gift_mode TEXT',
        'ALTER TABLE cached_products ADD COLUMN combo_discount_percent REAL',
        'ALTER TABLE cached_products ADD COLUMN combo_discount_amount REAL',
        'ALTER TABLE cached_products ADD COLUMN combo_repeat INTEGER DEFAULT 1',
      ]) {
        try {
          await db.execute(col);
        } catch (e) {
          print('[LocalDb] v12 kolon zaten var: $e');
        }
      }
      print('[LocalDb] v12 COMBO kolonlari eklendi (cached_products combo_*)');
    }

    // v13: cached_payment_methods — offline'da dinamik ödeme yöntemleri.
    // Tablo yoksa Flutter built-in nakit/kart ile çalışır (geriye uyum), sadece dinamikler offline kaybolur.
    if (oldVersion < 13) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cached_payment_methods (
            code TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            icon TEXT,
            is_builtin INTEGER DEFAULT 0,
            cached_at TEXT NOT NULL
          )
        ''');
        print('[LocalDb] v13 cached_payment_methods eklendi');
      } catch (e) {
        print('[LocalDb] v13 cached_payment_methods zaten var: $e');
      }
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
          // 🔴 Fable: eski kod List.toString() -> gecersiz JSON ([{id: 199, name: ...}] tirnaksiz) ->
          // offline parse EDILEMEZ -> varyant popup acilmaz + product_detail crash. jsonEncode dogru JSON yazar.
          'extras': prod['extras'] is String ? prod['extras'] : (prod['extras'] != null ? jsonEncode(prod['extras']) : null),
          'show_variants_pos': prod['show_variants_pos'] ?? 0,
          'variants': prod['variants'] is String ? prod['variants'] : (prod['variants'] != null ? jsonEncode(prod['variants']) : null),
          // v19: icerikler (variants ile ayni desen — JSON metin)
          'ingredients': prod['ingredients'] is String
              ? prod['ingredients']
              : (prod['ingredients'] != null ? jsonEncode(prod['ingredients']) : null),
          'printer_id': prod['printer_id'], // v8: offline mutfak fisi icin
          // v12 COMBO: backend combo_* dondurunce offline hesap icin sakla. Bool->0/1, sayilar oldugu gibi.
          // Backend dondurmese hepsi NULL -> combo_enabled 0 -> combo KAPALI (guvenli).
          'combo_enabled': (prod['combo_enabled'] == true || prod['combo_enabled'] == 1) ? 1 : 0,
          'combo_required_qty': prod['combo_required_qty'],
          'combo_gift_qty': prod['combo_gift_qty'],
          'combo_gift_mode': prod['combo_gift_mode'],
          'combo_discount_percent': prod['combo_discount_percent'],
          'combo_discount_amount': prod['combo_discount_amount'],
          'combo_repeat': (prod['combo_repeat'] == false || prod['combo_repeat'] == 0) ? 0 : 1,
          // v17: combo POS ayarlari. Backend alani hic gondermezse (eski surum) ESKI DAVRANIS
          // korunur: secim zorunlu (1), limitsiz kapali (0).
          'combo_pos_selection_required':
              (prod['combo_pos_selection_required'] == false || prod['combo_pos_selection_required'] == 0) ? 0 : 1,
          'combo_pos_unlimited':
              (prod['combo_pos_unlimited'] == true || prod['combo_pos_unlimited'] == 1) ? 1 : 0,
          // v18: POS varyant coklu secim. Backend gondermezse ESKI DAVRANIS (0/0).
          'variants_allow_multiple_pos':
              (prod['variants_allow_multiple_pos'] == true || prod['variants_allow_multiple_pos'] == 1) ? 1 : 0,
          'variants_required_pos':
              (prod['variants_required_pos'] == true || prod['variants_required_pos'] == 1) ? 1 : 0,
          // 21 Tem 2026: Masa Takipte gizle (offline). Backend dondurmese 0 -> gorunur (guvenli).
          'hide_from_tracking': (prod['hide_from_tracking'] == true || prod['hide_from_tracking'] == 1) ? 1 : 0,
          'cached_at': now,
        });
      }
    }), opName: 'cacheProducts');
  }

  // Ürünleri getir
  Future<List<Map<String, dynamic>>> getCachedProducts() async {
    final db = await database;
    final rows = await db.query('cached_products', where: 'is_active = 1');
    // 🔴 Fable: variants/extras TEXT olarak saklanir; tuketiciler (pos_screen, add_item_modal,
    // product_detail_modal) List bekler. Decode et (offline varyant popup + crash fix).
    // sqflite row READ-ONLY -> once kopyala, sonra mutasyon.
    return rows.map((row) {
      final m = Map<String, dynamic>.from(row);
      m['variants'] = _decodeJsonList(m['variants']);
      m['extras'] = _decodeJsonList(m['extras']);
      // v19: icerikler de List olarak tuketiliyor (bozuk/eksik kayitta bos liste)
      m['ingredients'] = _decodeJsonList(m['ingredients']);
      return m;
    }).toList();
  }

  // TEXT (JSON) -> List; parse edilemeyen eski bozuk kayit -> []. num/bool gibi degilse guvenli.
  List<dynamic> _decodeJsonList(dynamic v) {
    if (v is List) return v;
    if (v is String && v.isNotEmpty) {
      try {
        final d = jsonDecode(v);
        return d is List ? d : [];
      } catch (_) {
        return [];
      }
    }
    return [];
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
          // v10: masa tutari + acilis (online sync'te sakla -> offline'a gecince kaybolmaz).
          // Backend current_total'i String ('580.00') VEYA num donebilir -> guvenli parse.
          'current_total': _parseMoney(table['current_total']),
          'ticket_opened_at': table['ticket_opened_at']?.toString(),
          'opened_by_device': table['opened_by_device']?.toString(), // v14: masayı açan kasa
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

  /// Ödeme yöntemlerini cache'le (online sync sonrası) — offline'da dinamik butonlar görünsün
  Future<void> cachePaymentMethods(List<Map<String, dynamic>> methods) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete('cached_payment_methods');
      for (final m in methods) {
        final code = (m['code'] ?? '').toString();
        if (code.isEmpty) continue;
        await txn.insert('cached_payment_methods', {
          'code': code,
          'display_name': m['display_name'] ?? code,
          'icon': m['icon'],
          'is_builtin': m['is_builtin'] == true ? 1 : 0,
          'cached_at': now,
        });
      }
    }), opName: 'cachePaymentMethods');
    print('[LocalDb] cached_payment_methods: ${methods.length} kayit');
  }

  Future<List<Map<String, dynamic>>> getCachedPaymentMethods() async {
    final db = await database;
    try {
      return await db.query('cached_payment_methods');
    } catch (e) {
      // Tablo yoksa (eski DB, migration çalışmadıysa) boş dön -> built-in nakit/kart devam eder
      print('[LocalDb] getCachedPaymentMethods: tablo yok, boş dönülüyor: $e');
      return [];
    }
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
    // 9 Agu 2026 (Fable): mutfak fisi kalem garson+saati icin created_at + added_by_name de cek
    // (getByTable ile ayni desen: COALESCE(cached_waiters, mirror-kolon)). Yoksa offline mutfak
    // fisinde saat cikmaz, garson gonderi garsonuna duserdi.
    final r = await db.rawQuery('''
      SELECT i.local_id, i.server_id, i.product_id, i.product_name, i.quantity,
             i.unit_price, i.notes, i.portion, i.created_at,
             COALESCE(wa.name, i.added_by_name) AS added_by_name,
             p.printer_id
        FROM local_ticket_items i
   LEFT JOIN cached_products p ON p.id = i.product_id
   LEFT JOIN cached_waiters wa ON wa.id = i.added_by
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
    // v11: COALESCE(JOIN, mirror-kolon) — JOIN offline-açılan ticket'i cached_waiters'tan çözer;
    // mirror kolonu (t.waiter_name) cache'te olmayan/silinmiş garsonu kurtarır. JOIN öncelik = print davranışı aynı.
    final r = await db.rawQuery('''
      SELECT t.*, COALESCE(s.name, t.section_name) as section_name, s.summary_printer_id,
             COALESCE(w.name, t.waiter_name) as waiter_name
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

  // ==================== SEBEP CACHE (v20 — IKRAM + IPTAL) ====================
  // cached_cancel_reasons / cached_ikram_reasons — {id, reason, sort_order, is_active}.
  // Yazma: kategori/urun deseniyle ayni (delete + insert, retry'li transaction).
  // ⚠️ SQLite BOOLEAN yok: is_active esnek guard ile 0/1'e cevrilir (IkramRules.bayrak
  //    ile ayni mantik — bool/int/string hepsi guvenli).

  Future<void> _cacheReasonTable(String table, List<Map<String, dynamic>> rows) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await _runWithRetry(() => db.transaction((txn) async {
      await txn.delete(table);
      for (final r in rows) {
        final reason = (r['reason'] ?? '').toString().trim();
        if (reason.isEmpty) continue;
        final act = r['is_active'];
        await txn.insert(table, {
          'id': r['id'] is num ? (r['id'] as num).toInt() : int.tryParse('${r['id'] ?? ''}'),
          'reason': reason,
          'sort_order': r['sort_order'] is num
              ? (r['sort_order'] as num).toInt()
              : int.tryParse('${r['sort_order'] ?? 0}') ?? 0,
          // Alan HIC gelmezse aktif kabul (server zaten filtrelemis olabilir); gelirse
          // esnek guard (IkramRules.bayrak — bool/int/string, testli TEK KAYNAK).
          'is_active': (act == null || IkramRules.bayrak(act)) ? 1 : 0,
          'cached_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }), opName: 'cacheReasons[$table]');
    print('[LocalDb] $table: ${rows.length} kayit');
  }

  Future<List<Map<String, dynamic>>> _getReasonTable(String table) async {
    final db = await database;
    try {
      final rows = await db.query(table,
          where: 'is_active = 1', orderBy: 'sort_order ASC, id ASC');
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      // Tablo yoksa (eski DB, migration calismadiysa) bos don — cagiran fallback'ine duser.
      print('[LocalDb] _getReasonTable($table): tablo yok, bos donuluyor: $e');
      return [];
    }
  }

  Future<void> cacheCancelReasons(List<Map<String, dynamic>> rows) =>
      _cacheReasonTable('cached_cancel_reasons', rows);

  /// Iptal sebepleri — once dedicated tablo; BOSSA legacy cached_lookups('cancel_reasons').
  /// (Migration sonrasi ilk online sync'e kadar eski cache kaybolmasin.)
  Future<List<Map<String, dynamic>>> getCachedCancelReasons() async {
    final rows = await _getReasonTable('cached_cancel_reasons');
    if (rows.isNotEmpty) return rows;
    try {
      return await getCachedLookups(lookupType: 'cancel_reasons');
    } catch (_) {
      return [];
    }
  }

  Future<void> cacheIkramReasons(List<Map<String, dynamic>> rows) =>
      _cacheReasonTable('cached_ikram_reasons', rows);

  Future<List<Map<String, dynamic>>> getCachedIkramReasons() =>
      _getReasonTable('cached_ikram_reasons');

  /// IKRAM MIRROR (v20): online ikram isaretleme basarili olunca lokal mirror item'a
  /// is_ikram/ikram_reason yaz — sync_queue'ya KAYIT BIRAKMADAN (backend zaten guncel;
  /// kuyruk kaydi cift PUT atardi). Boylece internet hemen ardindan koparsa offline
  /// kapanis ikram tutarini dusebilir. serverItemId veya localItemId'den biri yeter.
  Future<void> markItemIkramMirror({
    int? serverItemId,
    int? localItemId,
    required bool isIkram,
    String? reason,
  }) async {
    if (serverItemId == null && localItemId == null) return;
    final db = await database;
    try {
      final data = <String, dynamic>{
        'is_ikram': isIkram ? 1 : 0,
        'ikram_reason': isIkram ? reason : null,
      };
      int updated = 0;
      if (localItemId != null) {
        updated = await db.update('local_ticket_items', data,
            where: 'local_id = ?', whereArgs: [localItemId]);
      }
      if (updated == 0 && serverItemId != null) {
        updated = await db.update('local_ticket_items', data,
            where: 'server_id = ?', whereArgs: [serverItemId]);
      }
      if (updated > 0) {
        // Ticket toplamini tazele (ikram dusumu lokal subtotal'a yansisin)
        final r = await db.query('local_ticket_items', columns: ['local_id', 'local_ticket_id'],
            where: localItemId != null ? 'local_id = ?' : 'server_id = ?',
            whereArgs: [localItemId ?? serverItemId], limit: 1);
        if (r.isNotEmpty) {
          // Bayat mirror snapshot'i bu isareti geri ezmesin (delivered_* deseniyle ayni TTL).
          final lid = r.first['local_id'] as int?;
          if (lid != null) _ikramTouchedAt[lid] = DateTime.now();
          final tid = r.first['local_ticket_id'] as int?;
          if (tid != null) await recalcTicketTotals(tid);
        }
      }
      print('[LocalDb] markItemIkramMirror: server=$serverItemId local=$localItemId ikram=$isIkram (updated=$updated)');
    } catch (e) {
      // Mirror best-effort — online islem ZATEN basarili, lokal yansima hatasi akisi kesmesin.
      print('[LocalDb] markItemIkramMirror hatasi (yoksayildi): $e');
    }
  }

  // ==================== YEREL ADİSYON İŞLEMLERİ ====================

  // Yerel adisyon aç
  Future<int> createLocalTicket({
    required int tableId,
    required int waiterId,
    required String tableNumber,
    int customerCount = 1,
    String? ownerDeviceId,
    int? leaseTtlMs,
    String? openedByDevice, // 17 Tem 2026: bu kasanın görünen adı (offline "hangi kasa açtı")
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

    final row = <String, dynamic>{
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
    };
    if (openedByDevice != null && openedByDevice.isNotEmpty) {
      row['opened_by_device'] = openedByDevice;
    }
    if (ownerDeviceId != null) {
      row['owner_device_id'] = ownerDeviceId;
      row['lan_lease_until'] =
          DateTime.now().add(Duration(milliseconds: leaseTtlMs ?? 60000)).toIso8601String();
    }
    final localId = await db.insert('local_tickets', row);

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

    // 🔴 Fable: taşımadan ÖNCE kaynak ticket'ı oku (taşındıktan sonra kaybolur — recalc için gerekli).
    final srcRow = await db.query('local_ticket_items', columns: ['local_ticket_id'],
        where: 'local_id = ? OR server_id = ?', whereArgs: [itemId, itemId], limit: 1);
    final sourceLocalTicketId = srcRow.isNotEmpty ? srcRow.first['local_ticket_id'] as int? : null;

    // Item'i hedef adisyona taşı (local_ticket_items üzerinden)
    await db.update(
      'local_ticket_items',
      {'local_ticket_id': resolvedTargetLocalId ?? resolvedTargetTicketId},
      where: 'local_id = ? OR server_id = ?',
      whereArgs: [itemId, itemId],
    );

    // Kaynak + hedef ticket total'larını güncelle (taşınan item her ikisinin tutarını değiştirir).
    if (sourceLocalTicketId != null) await recalcTicketTotals(sourceLocalTicketId);
    final tgt = resolvedTargetLocalId ?? resolvedTargetTicketId;
    if (tgt != null) await recalcTicketTotals(tgt);

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
    // v11: COALESCE(JOIN, mirror-kolon) — offline-açılan ticket'ta bile garson/salon adı cached'ten çözülür.
    final results = await db.rawQuery('''
      SELECT t.*, COALESCE(w.name, t.waiter_name) AS waiter_name,
             COALESCE(s.name, t.section_name) AS section_name
        FROM local_tickets t
   LEFT JOIN cached_waiters w ON w.id = t.waiter_id
   LEFT JOIN cached_tables tb ON tb.id = t.table_id
   LEFT JOIN cached_sections s ON s.id = tb.section_id
       WHERE t.local_id = ?
       LIMIT 1
    ''', [localId]);

    if (results.isEmpty) return null;

    final ticket = Map<String, dynamic>.from(results.first);

    // local_id'yi id olarak da ekle (uyumluluk için)
    ticket['id'] = ticket['local_id'];

    // Kalemleri de getir — v11: added_by/delivered_by garson adlarını cached_waiters'tan çöz.
    final items = await db.rawQuery('''
      SELECT i.*, COALESCE(wa.name, i.added_by_name) AS added_by_name,
             COALESCE(wd.name, i.delivered_by_name) AS delivered_by_name
        FROM local_ticket_items i
   LEFT JOIN cached_waiters wa ON wa.id = i.added_by
   LEFT JOIN cached_waiters wd ON wd.id = i.delivered_by
       WHERE i.local_ticket_id = ?
    ''', [localId]);

    // Item'lara da id alanı ekle
    final processedItems = items.map((item) {
      final newItem = Map<String, dynamic>.from(item);
      newItem['id'] = newItem['local_id'];
      return newItem;
    }).toList();

    ticket['items'] = processedItems;

    // Subtotal hesapla
    // v20 IKRAM: is_ikram=1 kalemler TAHSIL EDILMEZ -> subtotal'a girmez (backend close()
    // ayni dusumu authoritative yapar; offline kapanis da ayni kurali uygular).
    // Esnek guard sart: SQLite int 0/1 doner, Dart'ta 0 == false FALSE'tur.
    double subtotal = 0;
    for (final item in items) {
      final ik = item['is_ikram'];
      final ikramMi = ik == true || ik == 1 || ik == '1';
      if (item['status'] != 'cancelled' && !ikramMi) {
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
    String? portion,
    String? comboGroupId,
    String? comboGroupName,
    String? comboPickName,
    String? extras,
  }) async {
    final localId = await addTicketItem(
      localTicketId: localTicketId,
      productId: productId,
      productName: productName,
      unitPrice: unitPrice,
      quantity: quantity,
      notes: notes,
      waiterId: waiterId, // v11: ekleyen garson (rapor için) — önceden iletilmiyordu
      portion: portion,
      comboGroupId: comboGroupId,
      comboGroupName: comboGroupName,
      comboPickName: comboPickName,
      extras: extras,
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
    int? waiterId,
    String? portion,
    String? comboGroupId,
    String? comboGroupName,
    String? comboPickName,
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
      'added_by': waiterId, // v11: ekleyen garson (garson performans raporu)
      'portion': portion,
      'combo_group_id': comboGroupId,
      'combo_group_name': comboGroupName,
      'combo_pick_name': comboPickName,
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
        if (waiterId != null) 'waiter_id': waiterId, // v11: backend key adı waiter_id
        if (portion != null) 'portion': portion,
        if (comboGroupId != null) 'combo_group_id': comboGroupId,
        if (comboGroupName != null) 'combo_group_name': comboGroupName,
        if (comboPickName != null) 'combo_pick_name': comboPickName,
        // 31 Tem 2026: coklu varyant secimleri cevrimdisi eklemede de korunsun; internet
        // gelince sync ayni yapiyi backend'e gonderir (yoksa alt satirlar kaybolurdu).
        if (extras != null && extras.isNotEmpty) 'extras': extras,
      },
      description: 'Masa $tableNumber: $productName x$quantity eklendi',
      dependsOnSyncId: dependsOn,
    );

    // 🔴 Fable: offline ürün eklenince ticket total GÜNCELLENMİYORDU (0 kalıyordu) -> masa tutarı
    // görünmüyordu. Recalc: total item'lardan hesaplansın (masa kartında + merge'de doğru tutar).
    await recalcTicketTotals(localTicketId);

    return localItemId;
  }

  /// v11 Fable: offline ürün güncellemesini LOKAL item'a yansıt (fiş/tutar uyuşmazlığı önle).
  /// Sadece gelen (non-null) alanları günceller. Sonra ticket total'ını recalc eder.
  Future<void> updateLocalItemFields({
    required int localItemId,
    int? localTicketId,
    double? unitPrice,
    int? quantity,
    String? notes,
    String? extras, // 9 Agu 2026 (Fable Bulgu 2): offline secim degisikligi JSON metin olarak
  }) async {
    final db = await database;
    final fields = <String, dynamic>{};
    if (unitPrice != null) fields['unit_price'] = unitPrice;
    if (quantity != null) fields['quantity'] = quantity;
    if (notes != null) fields['notes'] = notes;
    if (extras != null) fields['extras'] = extras; // '[]' ise secimler temizlenir (bilincli)
    if (fields.isNotEmpty) {
      await db.update('local_ticket_items', fields, where: 'local_id = ?', whereArgs: [localItemId]);
    }
    // Ticket'ı çöz (verilmemişse item'dan) ve recalc.
    int? tid = localTicketId;
    if (tid == null) {
      final r = await db.query('local_ticket_items', columns: ['local_ticket_id'],
          where: 'local_id = ?', whereArgs: [localItemId], limit: 1);
      if (r.isNotEmpty) tid = r.first['local_ticket_id'] as int?;
    }
    if (tid != null) await recalcTicketTotals(tid);
  }

  /// v11 Fable: offline ürün iptalini LOKAL item'a yansıt (status='cancelled') + recalc.
  Future<void> cancelLocalItemOffline(int localItemId, {int? localTicketId}) async {
    final db = await database;
    await db.update('local_ticket_items', {'status': 'cancelled'},
        where: 'local_id = ?', whereArgs: [localItemId]);
    int? tid = localTicketId;
    if (tid == null) {
      final r = await db.query('local_ticket_items', columns: ['local_ticket_id'],
          where: 'local_id = ?', whereArgs: [localItemId], limit: 1);
      if (r.isNotEmpty) tid = r.first['local_ticket_id'] as int?;
    }
    if (tid != null) await recalcTicketTotals(tid);
  }

  /// Bir local ticket'ın subtotal/total'ını item'larından yeniden hesapla (offline tutar).
  /// Formül getLocalTicket + closeLocalTicket ile BİREBİR aynı (tutarlılık).
  /// v20 IKRAM: is_ikram=1 kalemler tahsil edilmez -> toplama girmez (COALESCE guard:
  /// eski satirlarda kolon NULL olabilir, NULL = ikram degil).
  Future<void> recalcTicketTotals(int localTicketId) async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT COALESCE(SUM(unit_price * quantity), 0) AS sub
        FROM local_ticket_items
       WHERE local_ticket_id = ? AND status != 'cancelled'
         AND COALESCE(is_ikram, 0) != 1
    ''', [localTicketId]);
    final subtotal = (r.first['sub'] as num?)?.toDouble() ?? 0.0;
    final tk = await db.query('local_tickets', columns: ['discount_amount'],
        where: 'local_id = ?', whereArgs: [localTicketId], limit: 1);
    final discount = tk.isNotEmpty ? ((tk.first['discount_amount'] as num?)?.toDouble() ?? 0.0) : 0.0;
    await db.update('local_tickets',
        {'subtotal': subtotal, 'total': subtotal - discount},
        where: 'local_id = ?', whereArgs: [localTicketId]);
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

  /// 🟡 6 Tem 2026 FINAL-FIX D: Bu ticket'a ait SON bekleyen item-değiştiren sync kaydinin id'si.
  /// close/void bu id'ye bagimli yapilir -> close, kendi item islemlerinden SONRA backend'e gider.
  /// Aksi halde close (prio 1) item'lardan ONCE gidiyordu -> backend final_total'i eksik kilitliyordu.
  /// 🔴 7 Tem (Fable K1): SADECE add_item degil, update_item + delete_item de kapsanmali. Aksi halde
  /// "ekle -> miktar degistir -> kapat" akisinda close, update_item'i beklemeden gider -> backend
  /// final_total ESKI miktar/fiyat uzerinden kilitlenir -> musteri farkli oder, rapor farkli gosterir.
  Future<int?> _lastPendingItemSyncId(int localTicketId) async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT id FROM sync_queue
       WHERE action IN ('add_item','update_item','delete_item')
         AND status IN ('pending','in_progress')
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
      {'status': 'empty', 'current_ticket_id': null, 'current_total': null},
      where: 'id = ?',
      whereArgs: [ticket['table_id']],
    );
    print('[LocalDb] Masa boşaltıldı (close): ${ticket['table_id']}');
    // Masa kapandı -> "FİŞ ÇIKMADI" göstergesi kalmasın. try/catch: bu HİÇBİR koşulda close sync'ini
    // kesmesin (Fable — best-effort, aksi halde DB hatası ciro sapmasına yol açabilir).
    final closeTid = ticket['table_id'] is int ? ticket['table_id'] as int : int.tryParse('${ticket['table_id']}');
    if (closeTid != null) { try { await clearPrintQueueForTable(closeTid); } catch (_) {} }

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
      {'status': 'empty', 'current_ticket_id': null, 'current_total': null},
      where: 'id = ?',
      whereArgs: [ticket['table_id']],
    );
    print('[LocalDb] Masa boşaltıldı (void): ${ticket['table_id']}');
    // Masa iptal edildi -> "FİŞ ÇIKMADI" göstergesi kalmasın (best-effort, sync'i kesmesin).
    final voidTid = ticket['table_id'] is int ? ticket['table_id'] as int : int.tryParse('${ticket['table_id']}');
    if (voidTid != null) { try { await clearPrintQueueForTable(voidTid); } catch (_) {} }

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
    int? dependsOnSyncId,          // 🔴 Fable O1: _failIfParentDead guard'ının çalışması için
  }) async {
    final db = await database;
    // Duplicate guard
    final existing = await db.query('sync_queue',
        where: "action = ? AND entity_type = ? AND server_id = ? AND status IN ('pending', 'in_progress')",
        whereArgs: [action, entityType, serverId]);
    if (existing.isNotEmpty) {
      final existId = existing.first['id'] as int?;
      // 🔴 Fable: update_item için payload MERGE (son-yazan-kazanır). Eski kod ikinci çağrıyı YUTUYORDU
      // -> ardışık iki değişiklikte (varyant sonra not) ikincisi KALICI kaybolur (para/veri kaybı).
      // close/void/delete için merge YOK (idempotent — aynı işlem iki kez yapılmamalı).
      if (action == 'update_item' && existId != null) {
        try {
          final merged = Map<String, dynamic>.from(jsonDecode(existing.first['payload'] as String? ?? '{}'));
          // 9 Agu 2026 (Fable Bulgu 2): 'extras' de merge listesinde OLMALI — yoksa ardisik
          // iki offline guncellemede (once secim, sonra not) ikincisi extras'i DUSURUR.
          for (final k in ['quantity', 'notes', 'unit_price', 'extras_amount', 'waiter_id', 'extras']) {
            if (payload[k] != null) merged[k] = payload[k];
          }
          await db.update('sync_queue', {'payload': jsonEncode(merged)}, where: 'id = ?', whereArgs: [existId]);
          print('[LocalDb] enqueueServerTicketAction: update_item payload MERGE — #$serverId');
        } catch (_) {}
      } else {
        print('[LocalDb] enqueueServerTicketAction: zaten kuyrukta — $action #$serverId');
      }
      return existId;
    }
    return await addToSyncQueueWithReturn(
      action: action,
      entityType: entityType,
      serverId: serverId,
      payload: payload,
      priority: 1,
      description: description ?? 'Server $entityType #$serverId offline $action',
      dependsOnSyncId: dependsOnSyncId,
    );
  }

  /// Bir item'ın bekleyen add_item sync id'sini bul (update/delete_item depends_on için — Fable O1).
  Future<int?> pendingAddItemSyncId(int itemLocalId) async {
    final db = await database;
    final r = await db.query('sync_queue',
        columns: ['id'],
        where: "action = 'add_item' AND status IN ('pending','in_progress') AND local_id = ?",
        whereArgs: [itemLocalId], limit: 1);
    return r.isNotEmpty ? r.first['id'] as int? : null;
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

  /// Faz 2 (22 Tem 2026): Lokal yazici kuyrugu basarili basinca sunucu raporu
  /// (mark-items-printed job_ids) OFFLINE/HATA durumunda kaybolmasin diye sync_queue'ya
  /// kuyruklar. SADECE TELEMETRI — basim kararini etkilemez, fis TEKRAR BASILMAZ.
  /// Ayni server_job_id icin bekleyen kayit varsa yenisi ACILMAZ (dup-guard, idempotent).
  /// SQLite SEMASI DEGISMEZ — mevcut generic sync_queue tablosu, payload JSON.
  Future<int?> enqueueMarkJobPrinted({
    required int serverTicketId,
    required int serverJobId,
  }) async {
    final db = await database;
    // Dup-guard: bekleyen mark_job_printed kayitlarini tara (sayilari her zaman kucuktur)
    final existing = await db.query('sync_queue',
        where: "action = 'mark_job_printed' AND status IN ('pending', 'in_progress')");
    for (final row in existing) {
      try {
        final raw = row['payload'];
        if (raw is String && raw.isNotEmpty) {
          final p = jsonDecode(raw);
          if (p is Map && (p['server_job_id'] as num?)?.toInt() == serverJobId) {
            print('[LocalDb] mark_job_printed zaten kuyrukta (job=$serverJobId)');
            return row['id'] as int?;
          }
        }
      } catch (_) {}
    }
    return await addToSyncQueueWithReturn(
      action: 'mark_job_printed',
      entityType: 'ticket',
      localId: null, // lokal ticket bagimliligi YOK — server id'ler payload'da hazir
      serverId: serverTicketId,
      payload: {
        'server_ticket_id': serverTicketId,
        'server_job_id': serverJobId,
      },
      priority: 0,
      description: 'Kuyruk fisi basildi raporu (job#$serverJobId, ticket#$serverTicketId)',
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
      // v11: backend guest_count doner (customer_count yanit'ta YOK) — eski kod hep 1 yaziyordu.
      final gc = serverTicket['guest_count'] ?? serverTicket['customer_count'];
      final ticketRow = <String, dynamic>{
        'server_id': serverId,
        'ticket_number': serverTicket['ticket_number']?.toString() ?? 'SRV-$serverId',
        'table_id': serverTicket['table_id'],
        'table_number': serverTicket['table_number']?.toString(),
        'waiter_id': serverTicket['waiter_id'] ?? 0,
        'waiter_name': serverTicket['waiter_name']?.toString(),
        'section_name': serverTicket['section_name']?.toString(),
        'opened_by_device': serverTicket['opened_by_device']?.toString(), // 17 Tem 2026: mirror'da da taşı
        'customer_count': gc is num ? gc.toInt() : int.tryParse('${gc ?? 1}') ?? 1,
        'status': serverTicket['status']?.toString() ?? 'open',
        // 🟡 6 Tem 2026 DÜZELTME 3 (ORTA-PRINT): backend fiyat alanini num VEYA String donebilir.
        // Eski kod `(x as num?)?.toDouble()` String'de 0'a dusuruyordu; total'da operator onceligi
        // hatasi (as num? sadece 2. operanda) + kontrolsuz .toDouble() -> String gelirse EXCEPTION
        // -> upsertServerTicket TAMAMEN atlanir -> o masaya offline fis kaynagi OLUSMAZ. Guvenli parse:
        'subtotal': _parseMoney(serverTicket['subtotal']),
        'discount_amount': _parseMoney(serverTicket['discount_amount']),
        'discount_type': serverTicket['discount_type']?.toString(),
        'total': _parseMoney(serverTicket['total_amount'] ?? serverTicket['total']),
        'opened_at': serverTicket['opened_at']?.toString() ??
            serverTicket['created_at']?.toString() ?? now,
        'synced': 1,
        'synced_at': now,
      };

      int localTicketId;
      if (existing.isNotEmpty) {
        localTicketId = existing.first['local_id'] as int;
        final localStatus = existing.first['status'] as String?;
        // 🔴 7 Tem (Fable bulk-mirror bulgusu): masa OFFLINE kapatildi (yerel status=closed/voided)
        // ama close-sync HENUZ pending. Backend fake-online'da hala 'open' donerse mirror KOSULSUZ
        // status='open' yazip kapatmayi GERI ALIYORDU (masa ~10sn tekrar dolu + cift-close riski).
        // Yerel kapali + pending close/void varsa status/synced'i EZME (offline kapatma sonucu korunur).
        bool preserveClose = false;
        if (localStatus == 'closed' || localStatus == 'voided') {
          final pc = await txn.rawQuery('''
            SELECT sq.id FROM sync_queue sq
             WHERE sq.action IN ('close','void') AND sq.status IN ('pending','in_progress')
               AND sq.local_id = ? LIMIT 1
          ''', [localTicketId]);
          preserveClose = pc.isNotEmpty;
        }
        if (preserveClose) {
          final safeRow = Map<String, dynamic>.from(ticketRow)
            ..remove('status')..remove('synced')..remove('synced_at');
          await txn.update('local_tickets', safeRow,
              where: 'local_id = ?', whereArgs: [localTicketId]);
        } else {
          // GUVENLIK: offline-olusturulan (server_id NULL iken sync bekleyen) kayit BURAYA DUSMEZ
          // cunku where server_id=? ile ariyoruz; mirror sadece zaten server_id'li kaydi gunceller.
          await txn.update('local_tickets', ticketRow,
              where: 'local_id = ?', whereArgs: [localTicketId]);
        }
      } else {
        ticketRow['created_at'] = serverTicket['created_at']?.toString() ?? now;
        localTicketId = await txn.insert('local_tickets', ticketRow);
      }

      // ITEM MIRROR: server item'larini server_id ile eslestir, printed durumunu KORU.
      final items = serverTicket['items'];
      final serverItemIds = <int>{}; // v11: hayalet-iptal temizligi icin gelen item id'leri
      bool itemIdParseSafe = true; // 🔴 Fable D1: bir item id parse edilemezse hayalet-iptal ATLA (yikim onle)
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final it = Map<String, dynamic>.from(raw);
          // id int VEYA String ('187123') gelebilir (tenant backend sürümüne göre) — güvenli parse.
          final rawId = it['id'];
          final itemServerId = rawId is int ? rawId : int.tryParse('${rawId ?? ''}');
          if (itemServerId == null) { itemIdParseSafe = false; continue; }
          serverItemIds.add(itemServerId);

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
            // 🔴 Fable O2: backend fiyat String ('230.00') VEYA num donebilir; eski cast String'de 0
            // yaziyordu -> recalcTicketTotals bu 0'i toplayip masa/kapama tutarini COKERTIRDI. Guvenli parse.
            'unit_price': _parseMoney(it['unit_price'] ?? it['price']),
            'custom_price': it['custom_price'] != null ? _parseMoney(it['custom_price']) : null,
            'notes': it['notes']?.toString(),
            'extras': it['extras'] is String ? it['extras'] : (it['extras'] != null ? jsonEncode(it['extras']) : null),
            'status': it['status']?.toString() ?? 'pending',
            // v11 offline-parity: ekleyen/teslim eden garson, porsiyon, odeme durumu, mutfak-gizle.
            'portion': it['portion']?.toString(),
            'payment_status': it['payment_status']?.toString(),
            'payment_method': it['payment_method']?.toString(),
            'delivered_at': it['delivered_at']?.toString(),
            'delivered_by': (it['delivered_by'] as num?)?.toInt(),
            'delivered_by_name': it['delivered_by_name']?.toString(),
            'added_by': (it['waiter_id'] as num?)?.toInt(), // backend item alan adi waiter_id
            'added_by_name': it['added_by_name']?.toString(),
            'skip_pos_print': (it['skip_pos_print'] == true || it['skip_pos_print'] == 1) ? 1 : 0,
            // v20 IKRAM: backend is_ikram/ikram_reason dondurunce mirror'a tasi -> internet
            // koparsa offline gorunum + kapanis tutari dogru kalir. Esnek guard (bool/int/str).
            'is_ikram': (it['is_ikram'] == true || it['is_ikram'] == 1 || it['is_ikram'] == '1') ? 1 : 0,
            'ikram_reason': it['ikram_reason']?.toString(),
            'printed': existingPrinted, // KORUNUR
            'synced': 1,
            'synced_at': now,
          };

          if (existItem.isNotEmpty) {
            final exLocalId = existItem.first['local_id'] as int;
            // v11 mark_served PRESERVE: bu item icin bekleyen teslim-toggle varsa mirror delivered_*'i
            // EZMESIN (offline toggle sonucu korunur, backend henuz gormemis olabilir).
            final pendingServed = await txn.query('sync_queue',
                where: "action = 'mark_served' AND status IN ('pending','in_progress') AND local_id = ?"
                       " AND (payload LIKE ? OR payload LIKE ?)",
                whereArgs: [localTicketId, '%"item_local_id":$exLocalId,%', '%"item_local_id":$exLocalId}%'],
                limit: 1);
            // B1: online mirror yazimi (sync_queue izi yok) son 15sn icinde ise bayat snapshot delivered_*'i ezmesin.
            final touched = _deliveryTouchedAt[exLocalId];
            final freshTouch = touched != null && DateTime.now().difference(touched) < _kDeliveryTouchTtl;
            if (pendingServed.isNotEmpty || freshTouch) {
              itemRow.remove('delivered_at');
              itemRow.remove('delivered_by');
              itemRow.remove('delivered_by_name');
            }
            // v20 IKRAM PRESERVE: az once online ikram isaretlendi/geri alindi (mirror'a
            // yazildi, sync_queue izi yok) — bayat snapshot is_ikram'i geri EZMESIN.
            final ikramTouch = _ikramTouchedAt[exLocalId];
            if (ikramTouch != null &&
                DateTime.now().difference(ikramTouch) < _kDeliveryTouchTtl) {
              itemRow.remove('is_ikram');
              itemRow.remove('ikram_reason');
            }
            await txn.update('local_ticket_items', itemRow,
                where: 'local_id = ?', whereArgs: [exLocalId]);
          } else {
            itemRow['created_at'] = it['created_at']?.toString() ?? now; // gerçek eklenme anı (bekleme süresi)
            await txn.insert('local_ticket_items', itemRow);
          }
        }
        // v11 HAYALET-IPTAL: backend 'cancelled' item'i HIC dondurmez -> gelen listede OLMAYAN
        // mirror item (server_id'li, sync olmus) online iptal edilmis demektir -> offline'da da iptal
        // isaretle (yoksa detayda geri gelir + total sisirir). server_id NULL (offline-eklenen) satira DOKUNMA.
        // 🔴 Fable O2: az-once add_item sync'i tamamlanmis item BAYAT mirror cevabinda olmayabilir ->
        // pending/in_progress add_item olan item'lari HARIC tut (yanlislikla iptal edilmesin, yaris fix).
        final pendingAdds = await txn.rawQuery('''
          SELECT local_id FROM sync_queue
           WHERE action = 'add_item' AND status IN ('pending','in_progress')
        ''');
        final protectItemIds = pendingAdds.map((r) => r['local_id']).whereType<int>().toList();
        final protectClause = protectItemIds.isEmpty ? '' : ' AND local_id NOT IN (${protectItemIds.join(",")})';
        final keepIds = serverItemIds.isEmpty ? '(-1)' : '(${serverItemIds.join(",")})';
        // Fable D1: bir item id parse edilemediyse (beklenmedik format) hayalet-iptal ATLA — yoksa
        // eksik keepIds ile aktif item'lar yanlislikla iptal edilir (yikici).
        if (itemIdParseSafe) {
          await txn.rawUpdate('''
            UPDATE local_ticket_items SET status = 'cancelled'
             WHERE local_ticket_id = ? AND server_id IS NOT NULL AND synced = 1
               AND status != 'cancelled' AND server_id NOT IN $keepIds$protectClause
          ''', [localTicketId]);
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

  /// Bu local ticket için sync_queue'da bekleyen (pending/in_progress) işlem var mı?
  /// 404-yanlış-kapatma guard'ı için (create henüz push edilmemiş masayı kapatma).
  Future<bool> hasPendingSyncForTicket(int localTicketId) async {
    final db = await database;
    final r = await db.query('sync_queue',
        where: "status IN ('pending', 'in_progress') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
        whereArgs: [localTicketId, '%"local_ticket_id":$localTicketId,%', '%"local_ticket_id":$localTicketId}%'],
        limit: 1);
    return r.isNotEmpty;
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
    // Bu masadaki server_id'li (mirror) ticket'lari bul. KRITIK-YENI-1 (Fable 3. tur): 'demoted'
    // ticket'lar HARIC — held sync tasiyabilirler; mirror-temizlik onlari silerse held YETIM kalir
    // (reconcile sadece demoted satirlari iter -> satir silindi -> ebedi ciro kaybi). demoted'in
    // yasam dongusu SADECE quarantinePrune/reconcile'da (held/pending/failed cozulunce siler).
    final mirrored = await db.query('local_tickets',
        columns: ['local_id'],
        where: "table_id = ? AND server_id IS NOT NULL AND COALESCE(lan_origin,'self') != 'demoted'",
        whereArgs: [tableId]);

    for (final t in mirrored) {
      final localId = t['local_id'] as int;
      // Guvenlik: bu ticket icin bekleyen sync var mi? 'held' de dahil (KRITIK-YENI-1) — devredilmis
      // ama teslim edilmemis satis silinmesin.
      final pending = await db.query('sync_queue',
          where: "status IN ('pending', 'in_progress', 'held') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
          whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%']);
      if (pending.isNotEmpty) continue; // sync bekliyor -> dokunma

      await db.delete('local_ticket_items', where: 'local_ticket_id = ?', whereArgs: [localId]);
      await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [localId]);
    }
  }

  /// 7 Tem 2026: Bulk-mirror temizligi. Su an backend'de ACIK olan masalar DISINDAKI tum
  /// mirror'lanmis (server_id'li, sync BEKLEMEYEN) ticket'lari sil -> kapanan masa iceriği
  /// lokalden temizlenir, DB ŞİŞMEZ. Offline-olusturulan/pending kayitlara DOKUNMAZ.
  Future<void> pruneMirroredTicketsExcept(Set<int> openTableIds) async {
    final db = await database;
    // KRITIK-YENI-1 (Fable 3. tur): 'demoted' HARIC — held sync tasiyabilir, silinirse yetim held.
    final mirrored = await db.query('local_tickets',
        columns: ['local_id', 'table_id'],
        where: "server_id IS NOT NULL AND COALESCE(lan_origin,'self') != 'demoted'");
    for (final t in mirrored) {
      final tableId = t['table_id'] as int?;
      if (tableId != null && openTableIds.contains(tableId)) continue; // hala acik -> koru
      final localId = t['local_id'] as int;
      // 'held' de guard'a dahil (devredilmis satis teslim beklerken silinmesin).
      final pending = await db.query('sync_queue',
          where: "status IN ('pending', 'in_progress', 'held') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
          whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%'], limit: 1);
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
      try { await txn.delete('cached_settings'); } catch (_) {} // tenant tema/marka ayari
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
      final srvId = ticket['server_id'] as int?;

      // Bu ticket için pending sync işlemi var mı kontrol et. 🔴 Fable Fix 3: update_item/delete_item
      // payload'i 'ticket_id'(server) VEYA 'local_ticket_id'/'ticket_local_id' kullanabilir; hepsini
      // kapsa yoksa esleme verisi pending kayit dururken silinir (eski id=17 gibi zombi'nin koku).
      final pendingSync = await db.query(
        'sync_queue',
        where: "status IN ('pending', 'in_progress') AND ("
               "local_id = ? OR payload LIKE ? OR payload LIKE ? OR payload LIKE ? OR payload LIKE ?"
               "${srvId != null ? " OR payload LIKE ? OR payload LIKE ?" : ""})",
        whereArgs: [
          localId,
          '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%',
          '%"ticket_local_id":$localId,%', '%"ticket_local_id":$localId}%',
          if (srvId != null) ...['%"ticket_id":$srvId,%', '%"ticket_id":$srvId}%'],
        ],
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
  /// Bir sync kaydına bağımlı işlem var mı? (manuel silme uyarısı — Fable Fix 4).
  /// deleteSyncItem cascade ile aynı status seti (pending/in_progress/failed) — UI sayısı gerçekle örtüşsün.
  Future<List<Map<String, dynamic>>> getDependentSyncItems(int syncId) async {
    final db = await database;
    return await db.query('sync_queue',
        columns: ['id', 'action', 'description'],
        where: "depends_on_sync_id = ? AND status IN ('pending','in_progress','failed')",
        whereArgs: [syncId]);
  }

  /// Sync kaydını sil. 🔴 Fable Fix 4: pending-sil butonu artık bağımlı işlemleri de ele almalı —
  /// aksi halde silinen create'e bağımlı add_item/close YETİM kalır (satış verisi sessiz kaybolur).
  /// cascade=true ise bağımlıları da siler; false ise bağımlıları 'failed' işaretler (kullanıcı görsün).
  /// 31 Tem 2026 — ONLINE ISLEM ZATEN BASARILI OLDU, kuyruktaki ESI GEREKSIZ.
  /// closeLocalTicket/voidLocalTicket lokal cache'i guncellerken KOSULSUZ sync kaydi birakir.
  /// Online yol basardiginda bu kayit ikinci bir POST'a yol acar; adisyon o an silinmis/
  /// yetim ise 404 -> 3 retry -> dead_letter -> kasada kalici kirmizi uyari.
  /// Burada SADECE o adisyonun BEKLEYEN (pending/in_progress) kaydi 'completed' yapilir.
  /// SILMEZ (iz kalsin), failed/dead_letter'a DOKUNMAZ (gercek hatalar gorunur kalsin).
  Future<int> completeRedundantSync(String action, int localTicketId) async {
    final db = await database;
    final n = await db.update(
      'sync_queue',
      {'status': 'completed', 'processed_at': DateTime.now().toIso8601String()},
      where: "action = ? AND entity_type = 'ticket' AND local_id = ? AND status IN ('pending','in_progress')",
      whereArgs: [action, localTicketId],
    );
    if (n > 0) print('[LocalDb] Gereksiz $action kaydi tamamlandi (online zaten basardi): $n adet');
    return n;
  }

  Future<void> deleteSyncItem(int syncId, {bool cascade = true}) async {
    final db = await database;
    // Bu kayda bağımlı olan tüm alt işlemleri bul (zincir — recursive değil ama tek seviye yeterli
    // çünkü add_item -> create'e, close -> create'e bağımlı; hepsi doğrudan bu syncId'ye bakar).
    final deps = await db.query('sync_queue',
        columns: ['id'],
        where: "depends_on_sync_id = ? AND status IN ('pending','in_progress','failed')",
        whereArgs: [syncId]);
    if (deps.isNotEmpty) {
      final depIds = deps.map((r) => r['id'] as int).toList();
      if (cascade) {
        // Bağımlıları da sil (kullanıcı "bu işlemi ve bağlılarını iptal et" dedi).
        for (final id in depIds) {
          await deleteSyncItem(id, cascade: true); // rekürsif zincir temizliği
        }
      } else {
        // Bağımlıları failed işaretle (yetim kalmasın, kullanıcı görsün).
        for (final id in depIds) {
          await db.update('sync_queue',
              {'status': 'failed', 'error_message': 'Bağımlı olduğu işlem manuel silindi'},
              where: 'id = ?', whereArgs: [id]);
        }
      }
    }
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [syncId]);
    print('[LocalDb] Sync item silindi: $syncId (bağımlı: ${deps.length}, cascade: $cascade)');
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

    // Open olup, henüz sunucuya sync olmamış ticketlar. KRITIK-1/2 (Fable 2. tur): 'demoted'
    // (bu cihazin kaybettigi masa — foreign 'lan' satiri zaten dolu gosterir) + owner-null zombi
    // 'lease' satirlari hayalet DOLU gostermesin. 'lan'/canli 'lease' foreign masalar DAHIL (Faz 2:
    // baska kasadaki masa dolu gorunur), 'self' DAHIL. Owner-null 'lease' zombi HARIC.
    final results = await db.query(
      'local_tickets',
      columns: ['table_id'],
      where: "status = 'open' AND server_id IS NULL "
          "AND COALESCE(lan_origin,'self') != 'demoted' "
          "AND NOT (lan_origin = 'lease' AND owner_device_id IS NULL)",
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
    int? leaseMs,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('local_tickets',
        where: "ticket_number = ? AND lan_origin = 'lan'", whereArgs: [ticketNumber], limit: 1);
    final row = <String, dynamic>{
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
    if (leaseMs != null && leaseMs > 0) {
      row['lan_lease_until'] = DateTime.now().add(Duration(milliseconds: leaseMs)).toIso8601String();
    }
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

  /// LAN kapanis temizligi (dispose): TUM 'lan' + 'lease' yansima/placeholder satirlarini sil.
  /// DUSUK-5 (Fable 3. tur): failover-cevrilmis owner-dolu 'lease'(status=open) da dahil (LAN yok artik).
  /// 'demoted' ve 'self' DOKUNULMAZ — held sync tasiyabilir/gercek adisyon (veri kaybi yasak); onlar
  /// reconcile/quarantine ile yonetilir.
  Future<void> clearAllLanReflections() async {
    final db = await database;
    await db.delete('local_tickets', where: "lan_origin IN ('lan','lease')");
  }

  /// K-1 FAILOVER: lider dalinda pruneLanTickets(const{}) yerine cagirilir. lan yansimalarindan
  /// CANLI foreign lease tasiyanlari (owner + lease_until>now) 'lease' placeholder'a DONUSTURUR —
  /// bunlar devralinan lease defteri kopyasi; yeni lider oldu(k)gumuzda bu masalarin korumasini
  /// surdurmeliyiz (yoksa cift adisyon: eski lider oldu, biz defteri sildik, cihaz C bos gorup ikinci
  /// adisyon acar). 'lease'e cevirmek: (1) getLanLedgerForBroadcast bunu yayar -> diger istemciler de
  /// gorur; (2) tryGrantLease/canWriteTable/hasLiveForeignLease 'lease'i canli lease sayar. Gercek
  /// sahibi renew gonderince lider myRow bulup yeniler. SADECE lease'siz yansimalar (kapanmis/damgasiz
  /// mirror) SILINIR.
  Future<void> pruneLanReflectionsKeepLeases() async {
    final db = await database;
    final now = DateTime.now();
    final all = await db.query('local_tickets',
        columns: ['local_id', 'owner_device_id', 'lan_lease_until', 'status'],
        where: "lan_origin = 'lan'");
    for (final t in all) {
      final owner = t['owner_device_id']?.toString();
      final leaseStr = t['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      final liveLease = owner != null && owner.isNotEmpty && leaseUntil != null && leaseUntil.isAfter(now);
      if (liveLease) {
        // Devralinan defter kopyasi — 'lease' placeholder'a cevir (yayilir + lease sayilir).
        // status='open' kalir (gercek dolu masa); ledger 'open'+'lease_hold' ikisini de yayar.
        await db.update('local_tickets', {'lan_origin': 'lease'},
            where: 'local_id = ?', whereArgs: [t['local_id']]);
        continue;
      }
      await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [t['local_id']]);
    }
  }

  /// demoted masalari temizle: teslim edilecek sync KALMADI (reconcile pending'e aldi + backend'e gitti,
  /// veya un-hold oldu). Item de silinir (yetim birakma — Fable M4). Engel: held/pending/in_progress
  /// (O-2) VE failed/dead_letter (YENI-2 Fable 3. tur: kalici backend hatasinda dead_letter kurtarma
  /// penceresi 30 gun korunmali; silinirse retry create'i offline_ticket_number=null gonderir = kayip).
  /// dead_letter 30 gunde ayri temizlenince (dead_letter cleanup) bu demoted da prune'lanir.
  /// Ticket-scope: local_id=ticket VEYA payload local_ticket_id VEYA item JOIN. prune'dan AYRI.
  Future<void> quarantinePrune() async {
    final db = await database;
    final demoted = await db.query('local_tickets',
        columns: ['local_id'], where: "lan_origin = 'demoted'");
    for (final t in demoted) {
      final localId = t['local_id'] as int;
      final pending = await db.query('sync_queue',
          where: "status IN ('held','pending','in_progress','failed','dead_letter') "
              "AND (local_id = ? OR CAST(json_extract(payload, '\$.local_ticket_id') AS INTEGER) = ? "
              "OR local_id IN (SELECT local_id FROM local_ticket_items WHERE local_ticket_id = ?))",
          whereArgs: [localId, localId, localId], limit: 1);
      if (pending.isNotEmpty) continue;
      await db.delete('local_ticket_items', where: 'local_ticket_id = ?', whereArgs: [localId]);
      await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [localId]);
    }
  }

  /// Bu cihazin ACIK offline masalarinin ozeti (LAN yayini icin — lider yollar). Sadece lan_origin='self'.
  /// Faz 3 (8 Tem, Fable ORTA-5 fix): owner_device_id/lan_lease_until SELECT'te (Adim 2 yayin icin) ama
  /// filtre 'self'te KALDI — 'lease' placeholder status='lease_hold' oldugundan zaten yakalanmazdi (olu kod).
  Future<List<Map<String, dynamic>>> getSelfOpenTicketsForLan() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT ticket_number, table_id, table_number, status, total, owner_device_id, lan_lease_until
        FROM local_tickets
       WHERE status = 'open' AND COALESCE(lan_origin,'self') = 'self'
    ''');
  }

  /// Liderin peer'lere yayinladigi lease defteri: owner-damgali acik masalar + lease_hold placeholder.
  /// lease_ms = kalan sure (wall-clock DEGIL — alici now'una ekler, saat kaymasi bagimsiz). owner damgasiz
  /// (Faz 2 mirror) satirlar defter DISI (lease bilgisi yok, yayilmaz).
  Future<List<Map<String, dynamic>>> getLanLedgerForBroadcast() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT ticket_number, table_id, table_number, status, total, owner_device_id, lan_lease_until
        FROM local_tickets
       WHERE owner_device_id IS NOT NULL
         AND COALESCE(lan_origin,'self') IN ('self','lease')
         AND status IN ('open','lease_hold')
    ''');
    final now = DateTime.now();
    return rows.map((r) {
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      final remainingMs = (leaseUntil != null) ? leaseUntil.difference(now).inMilliseconds : 0;
      return {
        'ticket_number': r['ticket_number'],
        'table_id': r['table_id'],
        'table_number': r['table_number'],
        'status': r['status'],
        'total': r['total'],
        'owner_device_id': r['owner_device_id'],
        'lease_ms': remainingMs > 0 ? remainingMs : 0,
      };
    }).toList();
  }

  // FAZ 3 (Faz 2 uzeri): masa kilidi/lease. Flag OFF -> lease NULL -> daima yazilabilir (Faz 2 aynen).
  // TASARIM NOTU (Fable NOT-2): Bu fonksiyon BILINCLI olarak lib/ akisindan cagrilmiyor. Yazma kilidi
  // OTURUM ACILISINDA aliniyor (claimTable -> openTicket:420); ayni oturumun add_item/close/void'i
  // acilista alinan lease'e guveniyor (lease renew ile 45sn'de bir tazelenir). canWriteTable per-yazma
  // kapi mantigini test/dokumantasyon icin tutuyor; ileride per-islem kilit gerekirse buradan baglanir.
  Future<bool> canWriteTable(int tableId, String deviceId, {required bool lanEnabled}) async {
    if (!lanEnabled) return true; // GRAFT: flag OFF -> byte-identical Faz 2
    final db = await database;
    final rows = await db.query('local_tickets',
        columns: ['owner_device_id', 'lan_lease_until', 'lan_origin', 'status'],
        where: "table_id = ? AND status IN ('open','lease_hold')", whereArgs: [tableId]);
    if (rows.isEmpty) return true; // gercekten bos masa — claim acilista yapilir
    final now = DateTime.now();
    // ONCE engelleyici kontrol: baska cihazin CANLI lease/placeholder'i varsa yazamayiz (K4a)
    for (final r in rows) {
      final owner = r['owner_device_id']?.toString();
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      if (owner != null && owner != deviceId && leaseUntil != null && leaseUntil.isAfter(now)) {
        return false;
      }
    }
    // Izin verici kontrol: kendi yazma hakkimiz var mi
    for (final r in rows) {
      final origin = (r['lan_origin'] ?? 'self').toString();
      final owner = r['owner_device_id']?.toString();
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      if (origin == 'lan' || origin == 'demoted') continue;
      if (origin == 'self' && owner == null) return true;
      if (owner == deviceId && leaseUntil != null && leaseUntil.isAfter(now)) return true;
      if (owner == deviceId && leaseUntil == null) return true;
    }
    return false;
  }

  /// Liderde cagirilir. Masaya lease ver/yenile/devral. Damgasiz dolu masa devredilmez.
  Future<Map<String, dynamic>> tryGrantLease({
    required int tableId,
    required String claimant,
    required Duration leaseTtl,
    bool isRenew = false,
  }) async {
    final db = await database;
    return await db.transaction((txn) async {
      final now = DateTime.now();
      final until = now.add(leaseTtl).toIso8601String();
      // KRITIK-2 (Fable 2. tur): 'demoted' satirlar HARIC — bunlar bu cihazin kaybettigi (devredilmis)
      // masalar, owner-null olduklarindan 'unleased_open' deny beslerlerdi -> masa herkese kilitlenir.
      final rows = await txn.query('local_tickets',
          columns: ['local_id', 'owner_device_id', 'lan_lease_until', 'lan_origin', 'status', 'ticket_number'],
          where: "table_id = ? AND status IN ('open','lease_hold') AND COALESCE(lan_origin,'self') != 'demoted'",
          whereArgs: [tableId]);
      if (rows.isEmpty) {
        if (isRenew) return {'granted': false, 'reason': 'no_ticket'};

        final nowIso = now.toIso8601String();
        await txn.insert('local_tickets', {
          'ticket_number': 'LEASE-$tableId-$claimant',
          'table_id': tableId, 'waiter_id': 0, 'status': 'lease_hold', 'total': 0,
          'opened_at': nowIso, 'created_at': nowIso,
          'owner_device_id': claimant, 'lan_lease_until': until, 'lan_origin': 'lease',
          'synced': 1,
        });
        return {'granted': true, 'owner': claimant, 'until': until};
      }
      Map<String, dynamic>? myRow;
      Map<String, dynamic>? staleRow;
      for (final r in rows) {
        final curOwner = r['owner_device_id']?.toString();
        final leaseStr = r['lan_lease_until']?.toString();
        final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
        if (curOwner == claimant) { myRow = r; continue; }
        if (curOwner == null && leaseUntil == null) {
          return {'granted': false, 'reason': 'unleased_open', 'owner': curOwner};
        }
        if (leaseUntil != null && leaseUntil.isAfter(now)) {
          return {'granted': false, 'owner': curOwner, 'reason': 'held', 'until': leaseStr};
        }
        if (leaseUntil != null && leaseUntil.isBefore(now)) staleRow = r;
      }
      if (myRow != null) {
        await txn.update('local_tickets', {'owner_device_id': claimant, 'lan_lease_until': until},
            where: 'local_id = ?', whereArgs: [myRow['local_id']]);
        return {'granted': true, 'owner': claimant, 'until': until, 'takeover': false};
      }
      if (!isRenew && staleRow != null) {
        await txn.update('local_tickets', {'owner_device_id': claimant, 'lan_lease_until': until},
            where: 'local_id = ?', whereArgs: [staleRow['local_id']]);
        return {'granted': true, 'owner': claimant, 'until': until, 'takeover': true};
      }
      if (isRenew) return {'granted': false, 'reason': 'no_ticket'};
      return {'granted': false, 'reason': 'unleased_open'};
    });
  }

  /// PUSH-ON-CLAIM: lider, istemcinin lease_claim/renew ile tasidigi GERCEK ticket icerigini
  /// (ticket_number/total/table_number) mevcut 'lease' placeholder satirina yansitir. Boylece
  /// getLanLedgerForBroadcast masayi total=0 + 'LEASE-x' yerine GERCEK icerikle yayar -> ucuncu
  /// istemci gorur. WHERE lan_origin='lease' + owner=claimant: self/demoted/lan satirlarina ASLA yazmaz.
  /// status='open' YAPAR (Fable KRITIK-1): ucuncu istemcinin dolu-masa tespiti getOfflineOpenTableIds
  /// SADECE status='open' sayar; lease_hold biraksak masa BOS gorunurdu (ozellik no-op). 'lease' origin
  /// backend'e SIZMAZ (getSelfOpenTicketsForLan/getUnsyncedClosedTickets 'self' filtreli) -> open guvenli.
  /// tryGrantLease/canWriteTable/clearLease/pruneLeaseZombies status'a bagli DEGIL -> lease mantigi bozulmaz.
  /// release'te ASLA cagrilmaz (ticketNumber null -> total=0 ile ezme yok).
  Future<void> enrichLeaseReflection({
    required int tableId,
    required String claimant,
    required String ticketNumber,
    double? total,
    String? tableNumber,
  }) async {
    final db = await database;
    final row = <String, dynamic>{'ticket_number': ticketNumber, 'status': 'open'};
    if (total != null) row['total'] = total;
    if (tableNumber != null) row['table_number'] = tableNumber;
    await db.update('local_tickets', row,
        where: "table_id = ? AND owner_device_id = ? AND lan_origin = 'lease'",
        whereArgs: [tableId, claimant]);
  }

  /// Lease serbest birak (masa kapaninca). KRITIK-1 (Fable 2. tur): DELETE artik status KOSULSUZ
  /// 'lease' origin'i siler — failover'da pruneLanReflectionsKeepLeases satiri 'lease'+status='open'e
  /// cevirdiginden eski 'lease_hold' kosulu zombi birakiyordu (unleased_open ile masa restoran capinda
  /// kalici kilit). 'lease' origin HER ZAMAN defter kopyasi/placeholder (gercek veri degil) -> guvenle
  /// silinir. UPDATE owner-null'lama SADECE 'self' ticket'a (gercek adisyon) uygulanir — 'lease'/'lan'/
  /// 'demoted' satirlar owner damgasini korur/ilgisiz.
  Future<void> clearLease(int tableId, String owner) async {
    final db = await database;
    await db.delete('local_tickets',
        where: "table_id = ? AND owner_device_id = ? AND lan_origin = 'lease'",
        whereArgs: [tableId, owner]);
    await db.update('local_tickets', {'owner_device_id': null, 'lan_lease_until': null},
        where: "table_id = ? AND owner_device_id = ? AND status = 'open' AND COALESCE(lan_origin,'self') = 'self'",
        whereArgs: [tableId, owner]);
  }

  /// KRITIK-1 SUPURUCU (lider dalinda cagirilir): owner-null VEYA lease-expired 'lease' zombilerini sil.
  /// pruneLanReflectionsKeepLeases 'lan'->'lease' cevirir; sahibi renew etmezse (oldu) veya masa kapanip
  /// clearLease disinda bir yolla owner-null kalirsa bu satirlar unleased_open deny kaynagi olur. Temizle.
  Future<void> pruneLeaseZombies() async {
    final db = await database;
    final now = DateTime.now();
    final rows = await db.query('local_tickets',
        columns: ['local_id', 'owner_device_id', 'lan_lease_until'],
        where: "lan_origin = 'lease'");
    for (final r in rows) {
      final owner = r['owner_device_id']?.toString();
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      final dead = owner == null || owner.isEmpty || leaseUntil == null || !leaseUntil.isAfter(now);
      if (dead) {
        await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [r['local_id']]);
      }
    }
  }

  /// TAKEOVER — Adim 2'ye kadar MUHURLU (item transfer + sync_queue create + backend idempotency gerek).
  Future<bool> promoteLanTicketToSelf({
    required int tableId,
    required String ticketNumber,
    required String deviceId,
    required Duration leaseTtl,
  }) async {
    throw UnsupportedError('promoteLanTicketToSelf Adim 2 tasarimina kadar muhurlu.');
  }

  /// Lease kaybedilince tum self masalari 'lan'a dusur + pending sync iptal + damga temizle.
  /// Bu masanin acik self ticket'larini 'demoted'a dusur + pending sync'lerini 'held'e al
  /// (SILME YOK -> un-hold ile geri donusumlu, veri kaybi yasak). Ticket-scope held: masa'nin
  /// tum ticket local_id'leri bulunur; her action turu dogru anahtar ile eslenir (ticket action
  /// localId IN; add_item payload local_ticket_id; cancel_item items JOIN). lan_origin='demoted'
  /// prune'dan ayirir (quarantinePrune held cozulunce siler).
  Future<void> demoteSelfAfterLeaseLost(int tableId) async {
    final db = await database;
    await db.transaction((txn) async {
      final tickets = await txn.query('local_tickets',
          columns: ['local_id'],
          where: "table_id = ? AND COALESCE(lan_origin,'self')='self' AND status='open'",
          whereArgs: [tableId]);
      if (tickets.isEmpty) return;
      final ticketIds = tickets.map((t) => t['local_id'] as int).toList();
      final inClause = ticketIds.join(',');

      await txn.rawUpdate(
          "UPDATE sync_queue SET status = 'held' WHERE status = 'pending' AND ${_ticketScopeSyncClause(inClause)}");

      for (final tid in ticketIds) {
        await txn.update('local_tickets',
            {'lan_origin': 'demoted', 'owner_device_id': null, 'lan_lease_until': null},
            where: 'local_id = ?', whereArgs: [tid]);
      }
    });
  }

  /// Ticket-scope sync eslesmesi (demote/un-hold ortak). Ticket action'lari local_id=ticket;
  /// item action'lari (add/update/delete_item) payload'da local_ticket_id tasir (Fable O-1).
  /// ORTA-2 (Fable 2. tur): _resolveLocalTicketAndItem basarisizsa payload'da local_ticket_id OLMAYABILIR
  /// (kosullu yazim) -> o zaman item_local_id uzerinden local_ticket_items JOIN ile masaya baglanir
  /// (ikinci yol). cancel_item olu ama JOIN ile kapali. $inClause = virgullu ticket local_id listesi.
  String _ticketScopeSyncClause(String inClause) => """
    (
      (action IN ('create','close','void','mark_printed','mark_served') AND local_id IN ($inClause))
      OR (action IN ('add_item','update_item','delete_item')
            AND CAST(json_extract(payload, '\$.local_ticket_id') AS INTEGER) IN ($inClause))
      OR (action IN ('update_item','delete_item')
            AND CAST(json_extract(payload, '\$.item_local_id') AS INTEGER) IN (
              SELECT local_id FROM local_ticket_items WHERE local_ticket_id IN ($inClause)))
      OR (action = 'cancel_item' AND local_id IN (
            SELECT local_id FROM local_ticket_items WHERE local_ticket_id IN ($inClause)))
    )
  """;

  /// K-3 RECONCILIATION: teslim edilmemis held sync'leri backend'e KURTAR. openTicket un-hold
  /// yapmadigindan (K-2), demote edilmis masalar bu supurucu ile teslim edilir. Kosul: masada artik
  /// BASKA cihazin CANLI foreign lease'i YOK (garson devretmedi/geri aldi) -> held->pending.
  /// KRITIK-2 (Fable 2. tur): ticket 'demoted' KALIR (self'e FLIP ETME). Flip edilseydi getTableTicket
  /// (self+open filtresi) eski ticket'i DIRILTIR -> yeni musteriye eski kalemler karisir -> para hatasi.
  /// 'demoted' kalinca: getTableTicket gormez (self degil), tryGrantLease/getOfflineOpenTableIds
  /// dislar, quarantinePrune sync'ler completed olunca ticket+item'i siler (janitor bedava). Held->pending
  /// yapilan sync'ler backend'e gider (create+add_item), backend masa-bazli merge dogru ayirir.
  /// flag-OFF'ta da cagirilabilir (foreign lease yoksa teslim eder = kill-switch guvenli).
  /// Donen: teslime alinan (pending'e donen) sync sayisi (0 = is yok).
  Future<int> reconcileHeldSyncs(String myDeviceId) async {
    final db = await database;
    final demoted = await db.query('local_tickets',
        columns: ['local_id', 'table_id'], where: "lan_origin = 'demoted'");
    int released = 0;
    for (final t in demoted) {
      final localId = t['local_id'] as int;
      final tableId = t['table_id'] as int?;
      // Masada canli foreign lease hala varsa DOKUNMA (garson karsi kasada aktif calisiyor).
      if (tableId != null && await hasLiveForeignLease(tableId, myDeviceId)) continue;
      final inClause = '$localId';
      final n = await db.rawUpdate(
          "UPDATE sync_queue SET status = 'pending' WHERE status = 'held' AND ${_ticketScopeSyncClause(inClause)}");
      // NOT: lan_origin='demoted' KALIR (KRITIK-2). Ticket dirilmez; quarantinePrune sync bitince siler.
      released += n;
    }
    if (released > 0) {
      print('[LanSync] reconcileHeldSyncs: $released held sync backend teslimine alindi');
    }
    return released;
  }

  /// Bu masada BASKA cihazin CANLI lease'i (lan yansimasi, lease_until>now) var mi.
  /// Korumali demote karari icin (Fable S8 veri kaybi yasak — teyit yoksa demote edilmez).
  /// K3 ile calisir: ledger yayini lan satirlarina gercek owner+lease tasir.
  Future<bool> hasLiveForeignLease(int tableId, String myDeviceId) async {
    final db = await database;
    final rows = await db.query('local_tickets',
        columns: ['owner_device_id', 'lan_lease_until'],
        where: "table_id = ? AND lan_origin IN ('lan','lease')", whereArgs: [tableId]);
    final now = DateTime.now();
    for (final r in rows) {
      final owner = r['owner_device_id']?.toString();
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      if (owner != null && owner != myDeviceId && leaseUntil != null && leaseUntil.isAfter(now)) {
        return true;
      }
    }
    return false;
  }

  /// LAN ayar ekrani icin lease durum ozeti (saf okuma, UI gostergesi). owner_device_id NULL ise
  /// (Faz 2 mirror / demoted) durum bilgisi tasimaz — atlanir.
  /// Doner: {'mine': [bu cihazin canli lease masalari], 'foreign': [baska cihazin canli lease masalari],
  ///         'heldCount': kurtarma bekleyen (held+demoted) sync sayisi}
  Future<Map<String, dynamic>> getLanLeaseStatus(String myDeviceId) async {
    final db = await database;
    final now = DateTime.now();
    final rows = await db.query('local_tickets',
        columns: ['table_id', 'table_number', 'owner_device_id', 'lan_lease_until', 'lan_origin'],
        where: "owner_device_id IS NOT NULL AND status IN ('open','lease_hold') "
            "AND lan_lease_until IS NOT NULL");
    final mine = <Map<String, dynamic>>[];
    final foreign = <Map<String, dynamic>>[];
    for (final r in rows) {
      final owner = r['owner_device_id']?.toString();
      final leaseStr = r['lan_lease_until']?.toString();
      final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
      if (owner == null || leaseUntil == null || !leaseUntil.isAfter(now)) continue;
      final entry = {
        'table_id': r['table_id'],
        'table_number': r['table_number'],
        'owner': owner,
        'remaining_s': leaseUntil.difference(now).inSeconds,
      };
      (owner == myDeviceId ? mine : foreign).add(entry);
    }
    // Kurtarma bekleyen: demoted masalarin held sync'leri (reconcile teslim edecek).
    final held = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM sync_queue WHERE status = 'held'");
    final heldCount = (held.first['n'] as int?) ?? 0;
    return {'mine': mine, 'foreign': foreign, 'heldCount': heldCount};
  }

  /// v11 (7 Tem 2026): Masa takip ekrani offline kaynagi. Acik masalarin (mirror + offline-acilan)
  /// iptal EDILMEMIS item'larini backend pending-orders sekline map'ler. Garson adlari cached_waiters
  /// JOIN ile cozulur. Ekran kendi siralama/filtresini yapar. LAN yansimalari (lan_origin='lan') HARIC.
  Future<List<Map<String, dynamic>>> getPendingOrdersOffline() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT
        t.table_id AS table_id,
        COALESCE(t.table_number, 'M' || t.table_id) AS table_number,
        COALESCE(s.name, t.section_name) AS section_name,
        COALESCE(t.server_id, t.local_id) AS ticket_id,
        t.ticket_number AS ticket_number,
        t.local_id AS _local_ticket_id,
        COALESCE(i.server_id, i.local_id) AS item_id,
        i.local_id AS _local_item_id,
        i.product_name AS product_name,
        i.quantity AS quantity,
        i.notes AS notes,
        -- 6 Agu 2026: masa takipte varyant/coklu secim/eklenen-cikarilan icerik.
        -- Online sorguya eslenik — AMA SART: panel-direct/tickets.js getPendingOrders
        -- SELECT'ine `i.extras` 6 Agu 2026 sunucu guncellemesiyle eklendi. O guncelleme
        -- geri alinirsa online tarafta detay KAYBOLUR, burasi calismaya devam eder
        -- (tarihsiz "eslenik" iddiasina guvenme, sunucuyu dogrula).
        -- Katı kural: her POS ozelligi CEVRIMDISI da calisir [[feedback_pos_cache_offline_zorunlu]].
        -- Burada JSON METIN doner (SQLite), online tarafta jsonb dizi gelir —
        -- takipDetayParcalari() iki bicimi de kabul eder.
        i.extras AS extras,
        i.delivered_at AS delivered_at,
        COALESCE(wd.name, i.delivered_by_name) AS delivered_by_name,
        COALESCE(wa.name, i.added_by_name) AS added_by_name,
        i.created_at AS item_created_at,
        i.printed AS printed
      FROM local_tickets t
      JOIN local_ticket_items i ON i.local_ticket_id = t.local_id
 LEFT JOIN cached_tables tb ON tb.id = t.table_id
 LEFT JOIN cached_sections s ON s.id = tb.section_id
 LEFT JOIN cached_waiters wa ON wa.id = i.added_by
 LEFT JOIN cached_waiters wd ON wd.id = i.delivered_by
 LEFT JOIN cached_products cp ON cp.id = i.product_id
     WHERE t.status = 'open' AND COALESCE(t.lan_origin,'self') = 'self'
       AND i.status != 'cancelled'
       AND COALESCE(cp.hide_from_tracking, 0) = 0
     ORDER BY i.created_at
    ''');
  }

  /// v11: Masa takip ekrani offline teslim toggle. itemId/ticketId = server_id VEYA local_id (ekran
  /// COALESCE gonderir). item'i lokalde delivered_at null<->now yapar + mark_served sync_queue'ya ekler.
  /// 🔴 Fable O1: item aramasi TICKET'a daraltilir (id-cakismasi -> yanlis urun toggle onlenir).
  Future<Map<String, dynamic>> markItemServedOffline(int itemId, {int? ticketId, int? waiterId}) async {
    final db = await database;
    // Once ticket'i coz (server_id VEYA local_id) -> item aramasini o ticket'a daralt.
    int? scopeLocalTicketId;
    if (ticketId != null) {
      final tk = await db.query('local_tickets', columns: ['local_id'],
          where: 'local_id = ? OR server_id = ?', whereArgs: [ticketId, ticketId], limit: 1);
      if (tk.isNotEmpty) scopeLocalTicketId = tk.first['local_id'] as int?;
    }
    final scope = scopeLocalTicketId != null ? ' AND local_ticket_id = $scopeLocalTicketId' : '';
    // itemId'yi cöz: once server_id, sonra local_id — ama TICKET kapsaminda.
    var rows = await db.query('local_ticket_items',
        where: 'server_id = ?$scope', whereArgs: [itemId], limit: 1);
    if (rows.isEmpty) {
      rows = await db.query('local_ticket_items',
          where: 'local_id = ?$scope', whereArgs: [itemId], limit: 1);
    }
    if (rows.isEmpty) return {'success': false, 'error': 'Item bulunamadi'};
    final item = rows.first;
    final localItemId = item['local_id'] as int;
    final localTicketId = item['local_ticket_id'] as int;
    final itemServerId = item['server_id'] as int?;
    final currentlyDelivered = item['delivered_at'] != null;
    final now = DateTime.now().toIso8601String();

    // Toggle: teslim edildi <-> geri al
    final newDeliveredAt = currentlyDelivered ? null : now;
    String? deliveredByName;
    if (!currentlyDelivered && waiterId != null) {
      final w = await db.query('cached_waiters', columns: ['name'], where: 'id = ?', whereArgs: [waiterId], limit: 1);
      if (w.isNotEmpty) deliveredByName = w.first['name'] as String?;
    }
    await db.update('local_ticket_items', {
      'delivered_at': newDeliveredAt,
      'delivered_by': currentlyDelivered ? null : waiterId,
      'delivered_by_name': currentlyDelivered ? null : deliveredByName,
    }, where: 'local_id = ?', whereArgs: [localItemId]);

    // 🔴 Fable K1: Ayni item icin ONCEKI pending mark_served'i sil (in_progress'e dokunma — ucusta).
    // Backend endpoint KOSULSUZ TOGGLE (delivered_at NULL<->NOW) -> ardisik iki toggle net-sifir OLMALI.
    // Silinen pending VARSA yeni kayit EKLEME: iki flip birbirini goturur, tek POST kalirsa backend'i
    // yanlis yone cevirir (cift-tik sapmasi). Silinen yoksa (ilk toggle) normal enqueue.
    final deleted = await db.delete('sync_queue',
        where: "action = 'mark_served' AND status = 'pending' AND local_id = ?"
               " AND (payload LIKE ? OR payload LIKE ?)",
        whereArgs: [localTicketId, '%"item_local_id":$localItemId,%', '%"item_local_id":$localItemId}%']);

    // Uçuşta (in_progress) mark_served var mı? Varsa yeni pending gerekli (uçuştaki flip'i dengeler).
    final inFlight = await db.query('sync_queue',
        columns: ['id'],
        where: "action = 'mark_served' AND status = 'in_progress' AND local_id = ?"
               " AND (payload LIKE ? OR payload LIKE ?)",
        whereArgs: [localTicketId, '%"item_local_id":$localItemId,%', '%"item_local_id":$localItemId}%'],
        limit: 1);

    // Silinen pending VAR ve uçuşta olan YOK -> net-sifir, enqueue etme.
    if (deleted > 0 && inFlight.isEmpty) {
      return {'success': true, 'action': newDeliveredAt != null ? 'delivered' : 'undelivered', 'offline': true};
    }

    // dependsOn: item'in add_item'i (ITEM bazli — _lastPendingItemSyncId TICKET bazli, yanlis).
    final addSync = await db.query('sync_queue',
        columns: ['id'],
        where: "action = 'add_item' AND status IN ('pending','in_progress') AND local_id = ?",
        whereArgs: [localItemId], limit: 1);
    final dependsOn = addSync.isNotEmpty ? addSync.first['id'] as int? : null;

    await addToSyncQueue(
      action: 'mark_served',
      entityType: 'ticket_item',
      localId: localTicketId, // ticket local_id (mirror-prune guard'lari bunu gorur — E2)
      payload: {
        'item_local_id': localItemId,
        if (itemServerId != null) 'item_server_id': itemServerId,
        'ticket_local_id': localTicketId,
        if (waiterId != null) 'waiter_id': waiterId,
        'delivered': newDeliveredAt != null,
      },
      description: 'Kalem teslim toggle (offline)',
      dependsOnSyncId: dependsOn,
    );

    return {'success': true, 'action': newDeliveredAt != null ? 'delivered' : 'undelivered', 'offline': true};
  }

  // Fable K1: ONLINE teslim basarisini mirror'a yansit (sync_queue'ya EKLEMEDEN). Mirror-fallback
  // poll'lari da teslimi gorsun -> overlay TTL'de dusup teslim "geri gelmesin". delivered = backend action.
  Future<void> markItemDeliveryMirror(int itemId, {required int ticketId, required bool delivered, int? waiterId}) async {
    try {
      final db = await database;
      // B2: ONCELIKLI cozum (server_id ONCE) — onceliksiz OR + limit yanlis ticket/kalem esleyebilir.
      // Online akista ticketId/itemId HER ZAMAN server id'dir; oncelik dogru olani secer.
      int? scopeLocalTicketId;
      var tk = await db.query('local_tickets', columns: ['local_id'],
          where: 'server_id = ?', whereArgs: [ticketId], limit: 1);
      if (tk.isEmpty) {
        tk = await db.query('local_tickets', columns: ['local_id'],
            where: 'local_id = ?', whereArgs: [ticketId], limit: 1);
      }
      if (tk.isEmpty) return; // masa mirror'da yok — yapacak sey yok
      scopeLocalTicketId = tk.first['local_id'] as int?;
      final scope = ' AND local_ticket_id = $scopeLocalTicketId';
      var rows = await db.query('local_ticket_items', columns: ['local_id'],
          where: 'server_id = ?$scope', whereArgs: [itemId], limit: 1);
      if (rows.isEmpty) {
        rows = await db.query('local_ticket_items', columns: ['local_id'],
            where: 'local_id = ?$scope', whereArgs: [itemId], limit: 1);
      }
      if (rows.isEmpty) return;
      String? deliveredByName;
      if (delivered && waiterId != null) {
        final w = await db.query('cached_waiters', columns: ['name'], where: 'id = ?', whereArgs: [waiterId], limit: 1);
        if (w.isNotEmpty) deliveredByName = w.first['name'] as String?;
      }
      final localItemId = rows.first['local_id'] as int;
      await db.update('local_ticket_items', {
        'delivered_at': delivered ? DateTime.now().toIso8601String() : null,
        'delivered_by': delivered ? waiterId : null,
        'delivered_by_name': delivered ? deliveredByName : null,
      }, where: 'local_id = ?', whereArgs: [localItemId]);
      final nowTs = DateTime.now();
      _deliveryTouchedAt[localItemId] = nowTs; // B1: bayat snapshot bunu ~15sn ezemesin
      _deliveryTouchedAt.removeWhere((_, t) => nowTs.difference(t) > _kDeliveryTouchTtl); // sisme onle
    } catch (_) {} // mirror best-effort — online zaten backend authoritative
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

  /// 17 Tem 2026 (filo #26): Başka kasada açık LAN masasının SALT-OKUMA özeti. Hiçbir yazma yok
  /// (INSERT/UPDATE/sync_queue dokunmaz) → K1 kuralı korunur. Offline'da masaya tıklanınca uyarı
  /// yerine bu özet gösterilir (tutar + adisyon no + hangi kasa). opened_at LAN'da yerel alım
  /// zamanıdır (gerçek açılış değil, #28) — diyalogda süre/açılış GÖSTERİLMEZ.
  Future<Map<String, dynamic>?> getLanTicketSummary(int tableId) async {
    final db = await database;
    final rows = await db.query('local_tickets',
        columns: ['ticket_number', 'total', 'table_number', 'owner_device_id',
          'opened_by_device', 'lan_lease_until'],
        where: "table_id = ? AND status = 'open' AND lan_origin = 'lan'",
        whereArgs: [tableId],
        orderBy: 'total DESC', limit: 1);
    return rows.isNotEmpty ? rows.first : null;
  }

  // Sunucu tablosunu offline değişikliklerle birleştir
  Future<List<Map<String, dynamic>>> mergeTablesWithOfflineChanges(
    List<Map<String, dynamic>> serverTables,
  ) async {
    final closedTableIds = await getOfflineClosedTableIds();
    final openTableIds = await getOfflineOpenTableIds();

    // Açık masaların tutarını local_tickets.total'dan al (backend current_total offline/fake-online'da gelmez).
    // Hem offline-oluşturulan (server_id NULL) hem mirror'lanmış (server_id VAR) açık ticket'lar dahil.
    final db = await database;
    final totalsByTable = <int, double>{};
    // 🔴 Fable: eff_total = total>0 ise total, yoksa subtotal>0 ise subtotal, yoksa item'lardan hesapla.
    // Eski `total ?? subtotal` calismiyordu cunku SQLite DEFAULT'u 0.0 (NULL degil) -> ?? atlamiyordu.
    final openRows = await db.rawQuery('''
      SELECT t.table_id AS table_id, t.opened_by_device AS opened_by_device,
             COALESCE(NULLIF(t.total,0), NULLIF(t.subtotal,0),
               (SELECT SUM(i.unit_price * i.quantity) FROM local_ticket_items i
                 WHERE i.local_ticket_id = t.local_id AND i.status != 'cancelled'), 0) AS eff_total
        FROM local_tickets t
       WHERE t.status = 'open' AND COALESCE(t.lan_origin,'self') = 'self'
    ''');

    // 17 Tem 2026 (filo bulgusu #24): LAN yansıması masaları için AYRI tutar sorgusu. Şikayet:
    // offline'da başka kasanın açtığı masa görünüyor ama tutar '0 TL'. LAN satırının total'ı
    // lokalde MEVCUT ama üstteki self-filtreli sorgu onu dışlıyordu. Bu map'i self toplamıyla
    // TOPLAMA — self öncelikli, yoksa lan fallback (aynı ticket iki kez sayılmasın).
    final lanRows = await db.rawQuery('''
      SELECT table_id, MAX(total) AS lan_total, MAX(opened_by_device) AS opened_by_device
        FROM local_tickets
       WHERE status = 'open' AND lan_origin = 'lan'
       GROUP BY table_id
    ''');
    final lanTotalsByTable = <int, double>{};
    final lanDeviceByTable = <int, String>{};
    for (final r in lanRows) {
      final tid = r['table_id'] as int?;
      if (tid == null) continue;
      final lt = (r['lan_total'] as num?)?.toDouble() ?? 0.0;
      if (lt > 0) lanTotalsByTable[tid] = lt;
      final dev = r['opened_by_device']?.toString();
      if (dev != null && dev.isNotEmpty) lanDeviceByTable[tid] = dev;
    }
    final selfDeviceByTable = <int, String>{};
    for (final r in openRows) {
      final tid = r['table_id'] as int?;
      final dev = r['opened_by_device']?.toString();
      if (tid != null && dev != null && dev.isNotEmpty) selfDeviceByTable[tid] = dev;
    }

    if (closedTableIds.isEmpty && openTableIds.isEmpty && openRows.isEmpty) {
      return serverTables;
    }

    print('[LocalDb] Offline değişiklikler birleştiriliyor - kapalı: $closedTableIds, açık: $openTableIds');

    for (final r in openRows) {
      final tid = r['table_id'] as int?;
      if (tid == null) continue;
      final t = (r['eff_total'] as num?)?.toDouble() ?? 0.0;
      // Ayni masada birden cok acik self ticket (mirror + offline-yeni) -> TOPLA (uzerine yazma).
      if (t > 0) totalsByTable[tid] = (totalsByTable[tid] ?? 0) + t;
    }

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
        newTable['current_total'] = null;
        print('[LocalDb] Masa $tableId offline kapatıldı, empty gösteriliyor');
      }

      // Tutar: backend current_total boş/0 ise local ticket total'ından doldur (offline/fake-online).
      final serverTotal = _parseMoney(newTable['current_total']); // String veya num güvenli
      final localTotal = totalsByTable[tableId];
      if (serverTotal <= 0 && localTotal != null && localTotal > 0 &&
          newTable['status'] != 'empty') {
        newTable['current_total'] = localTotal;
      }
      // 17 Tem 2026 (#24): hâlâ 0 ise LAN yansıması tutarıyla doldur — "başka kasanın masası 0 TL"
      // şikayetinin çözümü. LAN satırı occupied işaretini zaten getiriyor (getOfflineOpenTableIds).
      final effServerTotal = _parseMoney(newTable['current_total']);
      final lanTotal = lanTotalsByTable[tableId];
      if (effServerTotal <= 0 && lanTotal != null && lanTotal > 0 &&
          newTable['status'] != 'empty') {
        newTable['current_total'] = lanTotal;
      }
      // opened_by_device'ı offline dalda doldur (self > lan). Online masalarda backend zaten verir.
      final devName = selfDeviceByTable[tableId] ?? lanDeviceByTable[tableId];
      if (devName != null &&
          (newTable['opened_by_device'] == null ||
              newTable['opened_by_device'].toString().isEmpty)) {
        newTable['opened_by_device'] = devName;
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
      where: "print_type IN ('kitchen','kitchen_order') AND status IN ('pending', 'failed')",
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

  /// 24 Tem 2026: RETRY TÜKENMİŞ (5/5 denendi, çıkmadı) mutfak fişleri — POS sağ-üst
  /// "çıkmayan fiş" bildirimi için. status='failed' + kitchen + SON 12 SAAT (24 Agu: 18h→12h).
  /// 🔴 Fable H2: takvim-günü (startsWith today) DEĞİL rolling 12h window — yoksa 23:58'de
  /// çıkmayan fiş 00:01'de takvim değişince SESSİZCE kaybolurdu (restoran gece yarısını geçer).
  /// 24 Agu (Mustafa): 12h — şişme/eski-kayıt olmasın. cleanupCompletedPrintJobs 12h'te fiziksel siler.
  /// Her satır: id (failed job id, sil/retry için), masa, ürünler, yazıcı, saat, server_job_id.
  Future<List<Map<String, dynamic>>> getFailedKitchenPrints() async {
    final db = await database;
    final rows = await db.query(
      'print_queue',
      columns: ['id', 'printer_name', 'printer_ip', 'printer_port', 'error_message',
                'created_at', 'last_attempt_at', 'receipt_data'],
      where: "print_type IN ('kitchen','kitchen_order') AND status = 'failed'",
      orderBy: 'last_attempt_at DESC',
    );
    final cutoff = DateTime.now().subtract(const Duration(hours: 12)); // 24 Agu: 18h -> 12h (Mustafa: sisme/eski-kayit olmasin)
    final result = <Map<String, dynamic>>[];
    for (final r in rows) {
      final ts = (r['last_attempt_at'] ?? r['created_at'] ?? '').toString();
      final dt = DateTime.tryParse(ts);
      if (dt == null || dt.isBefore(cutoff)) continue; // rolling 18h window (Fable H2)
      String tableLabel = '-';
      final items = <String>[];
      dynamic serverJobId;
      dynamic serverTicketId;
      final raw = r['receipt_data'];
      if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            serverJobId = decoded['server_job_id'];
            serverTicketId = decoded['server_ticket_id'];
            // 'kitchen' → receipt.ticket + items; 'kitchen_order' → receipt.order + items (order-formatı)
            final ticket = decoded['ticket'];
            final order = decoded['order'];
            final src = (ticket is Map) ? ticket : (order is Map ? order : null);
            if (src != null) {
              tableLabel = (src['table_number'] ?? src['table_name'] ?? src['table_id'] ?? src['order_number'] ?? '-').toString();
            }
            // items: ticket-formatında kökte, order-formatında order.items ya da kökte
            final its = decoded['items'] ?? (order is Map ? order['items'] : null);
            if (its is List) {
              for (final it in its) {
                if (it is Map) {
                  final name = (it['product_name'] ?? it['name'] ?? '').toString();
                  final qty = it['quantity'] ?? it['qty'] ?? 1;
                  if (name.isNotEmpty) items.add('${qty}x $name');
                }
              }
            }
          }
        } catch (_) {/* bozuk JSON atla */}
      }
      result.add({
        'id': r['id'],
        'table': tableLabel,
        'printer_name': (r['printer_name'] ?? '-').toString(),
        'printer_ip': r['printer_ip'],
        'printer_port': r['printer_port'],
        'items': items,
        'item_count': items.length,
        'at': ts.length >= 16 ? ts.substring(11, 16) : ts, // HH:MM
        'error': (r['error_message'] ?? '').toString(),
        'server_job_id': serverJobId,
        'server_ticket_id': serverTicketId,
        'receipt_data': raw, // manuel Tekrar Yazdır için (items+ticket yeniden gerekir)
      });
    }
    return result;
  }

  /// 24 Tem 2026: Çıkmayan-fiş bildirimini garson silince o failed job'u kuyruktan çıkar.
  Future<void> deleteFailedKitchenPrint(int id) async {
    final db = await database;
    await db.delete('print_queue', where: "id = ? AND status = 'failed'", whereArgs: [id]);
    print('[LocalDb] Cikmayan-fis bildirimi silindi: $id');
  }

  /// 24 Tem 2026 (Fable C2): manuel Tekrar Yazdır BAŞARILI olunca o failed row'u
  /// completed'a çevir (badge'den düşsün). deleteFailedKitchenPrint yerine bunu kullan
  /// ki iz kalsın (completed 1h sonra cleanupCompletedPrintJobs ile temizlenir).
  Future<void> markFailedKitchenPrintResolved(int id) async {
    final db = await database;
    await db.update('print_queue',
      {'status': 'completed', 'completed_at': DateTime.now().toIso8601String()},
      where: "id = ? AND status = 'failed'", whereArgs: [id]);
    print('[LocalDb] Cikmayan-fis manuel cozuldu (completed): $id');
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

  // Yazdırma işini başarısız olarak işaretle.
  // 24 Tem 2026: retry TÜKENDİĞİNDE (newRetryCount>=maxRetries) `true` döner → çağıran
  // (printer_service) bunu görüp "çıkmayan fiş" bildirimini + sunucu logunu tetikler.
  // Katman ayrımı: local_db LogService'e bağlanmaz, sadece durumu raporlar.
  Future<bool> markPrintFailed(int id, String? errorMessage) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // Önce mevcut retry_count'u al
    final job = await getPrintJob(id);
    if (job == null) return false;

    final newRetryCount = (job['retry_count'] as int) + 1;
    final maxRetries = job['max_retries'] as int;
    final didExhaust = newRetryCount >= maxRetries;

    await db.update(
      'print_queue',
      {
        'retry_count': newRetryCount,
        'error_message': errorMessage,
        'last_attempt_at': now,
        'status': didExhaust ? 'failed' : 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    print('[LocalDb] Print job başarısız: $id (retry: $newRetryCount/$maxRetries)${didExhaust ? ' — RETRY TUKENDI' : ''}');
    return didExhaust;
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

  /// 🔴 7 Tem 2026: Bir masa kapatılınca o masanın bekleyen/başarısız kitchen fişlerini temizle.
  /// Aksi halde masa boşalsa bile "FİŞ ÇIKMADI" göstergesi (getPrintFailedTableIds) kalıyordu.
  /// print_queue'da table_id kolonu yok -> receipt_data JSON'ından çöz (getPrintFailedTableIds mantığı).
  /// SADECE verilen masanın kitchen kaydı silinir; başka masaların/tamamlanmışların fişine DOKUNMAZ.
  Future<void> clearPrintQueueForTable(int tableId) async {
    final db = await database;
    final rows = await db.query('print_queue',
        columns: ['id', 'receipt_data'],
        where: "print_type IN ('kitchen','kitchen_order') AND status IN ('pending', 'failed')");
    final idsToDelete = <int>[];
    for (final r in rows) {
      final raw = r['receipt_data'];
      if (raw is! String) continue;
      try {
        final decoded = jsonDecode(raw);
        // 'kitchen' → ticket.table_id; 'kitchen_order' → order.table_id (order-formatı)
        final ticket = decoded is Map ? decoded['ticket'] : null;
        final order = decoded is Map ? decoded['order'] : null;
        final src = (ticket is Map) ? ticket : (order is Map ? order : null);
        final tid = src != null ? src['table_id'] : null;
        final parsed = tid is int ? tid : int.tryParse('${tid ?? ''}');
        if (parsed == tableId) idsToDelete.add(r['id'] as int);
      } catch (_) {}
    }
    for (final id in idsToDelete) {
      await db.delete('print_queue', where: 'id = ?', whereArgs: [id]);
    }
    if (idsToDelete.isNotEmpty) {
      print('[LocalDb] Masa $tableId kapatıldı, ${idsToDelete.length} bekleyen fiş kaydı temizlendi');
    }
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

    // 24 Tem 2026 (Fable H3): failed row'lar HİÇ purge edilmiyordu → SQLite şişme.
    // 24 Agu 2026 (Mustafa): 48h → 12h. Çıkmayan-fiş bildirim penceresi de 12h; eşit tutuldu
    // → 12 saatten eski failed kayıt hem sağ-üst listede görünmez hem DB'den SİLİNİR (şişme yok).
    final twelveHoursAgo = DateTime.now().subtract(const Duration(hours: 12)).toIso8601String();
    final failedCount = await db.delete(
      'print_queue',
      where: "status = 'failed' AND COALESCE(last_attempt_at, created_at) < ?",
      whereArgs: [twelveHoursAgo],
    );
    if (failedCount > 0) {
      print('[LocalDb] $failedCount eski failed print job temizlendi (12h+)');
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
    // 20 Ağu 2026 [B] — single-flight future'ı da sıfırla; yoksa sonraki
    // `database` erişimi tamamlanmış-ama-kapalı db'yi döndürür.
    _initFuture = null;
  }
}
