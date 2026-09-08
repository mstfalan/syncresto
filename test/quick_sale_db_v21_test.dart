// 8 Eyl 2026 — HIZLI SATIS cevrimdisi katman testleri (gercek sqlite, ffi).
//
// Repo deseni (ikram_offline_db_test / sync_404_idempotent_test): LocalDbService dogrudan test
// edilemez (path_provider) -> v21 DDL'leri + SORGULAR BIREBIR kopyalanip gercek sqlite'ta
// dogrulanir; kural mantigi (QuickSaleRules) canli kodun kendisidir.
//
// Kapsam:
//   1) v20 -> v21 migration idempotent (iki kez calisinca patlamaz, mevcut satirlar korunur)
//   2) cacheSections/cacheTables yazim kurali: sunucu true/1/'1' -> 1, false/null -> 0;
//      getCachedSections/getCachedTables ile OFFLINE okunan satirlar QuickSaleRules'a uyar
//   3) hasPendingCloseForTable sorgusu (Fable E2): pending/in_progress close/void -> true;
//      completed -> false; baska masa -> false
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/quick_sale_rules.dart';

/// local_db_service.dart v20 _onCreate ile ayni (v21 kolonu YOK — migration testi icin)
const _semaSectionsV20 = '''
  CREATE TABLE cached_sections (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    color TEXT,
    table_count INTEGER DEFAULT 0,
    summary_printer_id INTEGER,
    cached_at TEXT NOT NULL
  )
''';
const _semaTablesV20 = '''
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
''';

/// local_db_service._onUpgrade v21 blogu ile BIREBIR DDL + try/catch idempotency
Future<void> _v21(Database db) async {
  for (final ddl in [
    'ALTER TABLE cached_sections ADD COLUMN is_quick_sale INTEGER DEFAULT 0',
    'ALTER TABLE cached_tables ADD COLUMN is_quick_sale INTEGER DEFAULT 0',
  ]) {
    try {
      await db.execute(ddl);
    } catch (_) {
      // zaten var
    }
  }
}

/// sync_queue + local_tickets (test icin sadeltilmis; kullanilan kolonlar birebir ayni adda)
const _semaSyncQueue = '''
  CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    local_id INTEGER,
    status TEXT DEFAULT 'pending'
  )
''';
const _semaLocalTickets = '''
  CREATE TABLE local_tickets (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    table_id INTEGER NOT NULL,
    status TEXT DEFAULT 'open'
  )
''';

/// local_db_service.hasPendingCloseForTable ile AYNI sorgu
Future<bool> _hasPendingClose(Database db, int tableId) async {
  final r = await db.rawQuery('''
      SELECT sq.id FROM sync_queue sq
        JOIN local_tickets lt ON lt.local_id = sq.local_id
       WHERE sq.action IN ('close','void') AND sq.status IN ('pending','in_progress')
         AND lt.table_id = ?
       LIMIT 1
    ''', [tableId]);
  return r.isNotEmpty;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('v21 migration', () {
    test('v20 sema + v21 ALTER idempotent, mevcut satirlar korunur ve 0 okunur', () async {
      final db = await openDatabase(inMemoryDatabasePath);
      await db.execute(_semaSectionsV20);
      await db.execute(_semaTablesV20);
      await db.insert('cached_sections', {'id': 1, 'name': 'Salon', 'cached_at': 'x'});
      await db.insert('cached_tables', {'id': 10, 'section_id': 1, 'table_number': '1', 'cached_at': 'x'});
      await _v21(db);
      await _v21(db); // ikinci kez -> try/catch yutar, patlamaz
      final s = await db.query('cached_sections');
      final t = await db.query('cached_tables');
      expect(s.first['is_quick_sale'], 0);
      expect(t.first['is_quick_sale'], 0);
      expect(QuickSaleRules.salonHizli(s.first), isFalse);
      expect(QuickSaleRules.masaGizli(t.first), isFalse);
      await db.close();
    });
  });

  group('cache yazim + offline okuma', () {
    test('sunucu true/1/"1" -> 1, false/null -> 0; okunan satir QuickSaleRules ile dogru', () async {
      final db = await openDatabase(inMemoryDatabasePath);
      await db.execute(_semaSectionsV20);
      await db.execute(_semaTablesV20);
      await _v21(db);
      // local_db_service.cacheSections/cacheTables ile AYNI yazim kurali
      int yaz(dynamic v) => QuickSaleRules.bayrak(v) ? 1 : 0;
      final gelenSalonlar = [
        {'id': 1, 'name': 'Salon', 'is_quick_sale': false},
        {'id': 2, 'name': 'Hızlı Satış', 'is_quick_sale': true},
        {'id': 3, 'name': 'Bahçe'},
        {'id': 4, 'name': 'Hızlı Kasa 2', 'is_quick_sale': 1},
      ];
      for (final s in gelenSalonlar) {
        await db.insert('cached_sections', {'id': s['id'], 'name': s['name'], 'is_quick_sale': yaz(s['is_quick_sale']), 'cached_at': 'x'});
      }
      final gelenMasalar = [
        {'id': 10, 'section_id': 1, 'table_number': '1', 'is_quick_sale': 0},
        {'id': 11, 'section_id': 2, 'table_number': 'Hızlı Satış', 'is_quick_sale': '1'},
        {'id': 12, 'section_id': 4, 'table_number': 'Hızlı Kasa 2', 'is_quick_sale': true},
      ];
      for (final t in gelenMasalar) {
        await db.insert('cached_tables', {'id': t['id'], 'section_id': t['section_id'], 'table_number': t['table_number'], 'is_quick_sale': yaz(t['is_quick_sale']), 'cached_at': 'x'});
      }
      final sections = await db.query('cached_sections');
      final tables = await db.query('cached_tables');
      expect(QuickSaleRules.hizliSalonlar(sections).map((s) => s['id']), [2, 4]);
      expect(QuickSaleRules.normalSalonlar(sections).map((s) => s['id']), [1, 3]);
      expect(QuickSaleRules.gorunurMasalar(tables).map((t) => t['id']), [10]);
      expect(QuickSaleRules.gizliMasa(tables, 2)?['id'], 11);
      expect(QuickSaleRules.gizliMasa(tables, 4)?['id'], 12);
      await db.close();
    });
  });

  group('hasPendingCloseForTable (Fable E2)', () {
    test('pending close -> true; completed -> false; baska masa -> false; void in_progress -> true', () async {
      final db = await openDatabase(inMemoryDatabasePath);
      await db.execute(_semaSyncQueue);
      await db.execute(_semaLocalTickets);
      final t1 = await db.insert('local_tickets', {'table_id': 11, 'status': 'closed'});
      final t2 = await db.insert('local_tickets', {'table_id': 12, 'status': 'closed'});
      final t3 = await db.insert('local_tickets', {'table_id': 13, 'status': 'voided'});
      await db.insert('sync_queue', {'action': 'close', 'entity_type': 'ticket', 'local_id': t1, 'status': 'pending'});
      await db.insert('sync_queue', {'action': 'close', 'entity_type': 'ticket', 'local_id': t2, 'status': 'completed'});
      await db.insert('sync_queue', {'action': 'void', 'entity_type': 'ticket', 'local_id': t3, 'status': 'in_progress'});
      expect(await _hasPendingClose(db, 11), isTrue);
      expect(await _hasPendingClose(db, 12), isFalse);
      expect(await _hasPendingClose(db, 13), isTrue);
      expect(await _hasPendingClose(db, 99), isFalse);
      // create pending (close degil) -> false
      final t4 = await db.insert('local_tickets', {'table_id': 14, 'status': 'open'});
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': t4, 'status': 'pending'});
      expect(await _hasPendingClose(db, 14), isFalse);
      await db.close();
    });
  });
}
