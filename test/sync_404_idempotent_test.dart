// 31 Tem 2026 — "senkronize olmuyor" YALANCI UYARISI düzeltmelerinin testleri.
//
// Yaşanmış vaka (Dora, 22:39): kiracı değişiminden kalma yetim adisyonun iptali
// 3 kez 404 alıp dead_letter'a düştü → kasada KALICI kırmızı uyarı, oysa hiçbir
// şey kayıp değildi. İki katman düzeltildi:
//   1) sync_service: close/void'de 404 = "zaten tamam" (idempotent)
//   2) api_service: online başarıdan sonra kuyruktaki gereksiz eş kapatılır
//
// Bu dosya 2. katmanın DB mantığını (completeRedundantSync) ve rozetin beslendiği
// sayımı gerçek sqlite üzerinde doğrular.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _semaSyncQueue = '''
  CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    local_id INTEGER,
    server_id INTEGER,
    payload TEXT,
    status TEXT DEFAULT 'pending',
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    created_at TEXT,
    processed_at TEXT,
    description TEXT,
    error_message TEXT,
    depends_on_sync_id INTEGER,
    priority INTEGER DEFAULT 0
  )
''';

/// local_db_service.dart completeRedundantSync ile AYNI sorgu
Future<int> _completeRedundantSync(Database db, String action, int localTicketId) {
  return db.update(
    'sync_queue',
    {'status': 'completed', 'processed_at': '2026-07-31T23:00:00'},
    where: "action = ? AND entity_type = 'ticket' AND local_id = ? AND status IN ('pending','in_progress')",
    whereArgs: [action, localTicketId],
  );
}

/// tables_screen kırmızı rozetinin beslendiği sayım (local_db_service:2633)
Future<int> _hataliSayisi(Database db) async {
  final r = await db.rawQuery(
    "SELECT count(*) c FROM sync_queue WHERE status IN ('failed','dead_letter') "
    "OR (status = 'pending' AND retry_count >= max_retries)",
  );
  return r.first['c'] as int;
}

Future<void> _ekle(Database db, String action, int localId, String status,
    {String entity = 'ticket', int retry = 0}) async {
  await db.insert('sync_queue', {
    'action': action, 'entity_type': entity, 'local_id': localId,
    'status': status, 'retry_count': retry, 'max_retries': 3,
    'created_at': '2026-07-31T22:39:00',
  });
}

Future<String> _durum(Database db, int id) async {
  final r = await db.query('sync_queue', where: 'id = ?', whereArgs: [id]);
  return r.first['status'] as String;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute(_semaSyncQueue);
  });
  tearDown(() async => db.close());

  group('completeRedundantSync — online başardıysa kuyruktaki eşi kapat', () {
    test('bekleyen void kaydı tamamlanır (ikinci POST hiç atılmaz)', () async {
      await _ekle(db, 'void', 233, 'pending');
      final n = await _completeRedundantSync(db, 'void', 233);
      expect(n, 1);
      expect(await _durum(db, 1), 'completed');
    });

    test('in_progress olan da kapatılır', () async {
      await _ekle(db, 'close', 300, 'in_progress');
      expect(await _completeRedundantSync(db, 'close', 300), 1);
    });

    test('BAŞKA adisyonun kaydına DOKUNMAZ', () async {
      await _ekle(db, 'void', 233, 'pending');
      await _ekle(db, 'void', 999, 'pending'); // baska masa, hala bekliyor
      await _completeRedundantSync(db, 'void', 233);
      expect(await _durum(db, 2), 'pending');
    });

    test('BAŞKA eylemin kaydına DOKUNMAZ (void kapatınca close bekler)', () async {
      await _ekle(db, 'close', 233, 'pending');
      await _completeRedundantSync(db, 'void', 233);
      expect(await _durum(db, 1), 'pending');
    });

    test('GERÇEK hatalar görünür kalır — failed/dead_letter EZİLMEZ', () async {
      await _ekle(db, 'void', 233, 'failed', retry: 3);
      await _ekle(db, 'close', 233, 'dead_letter', retry: 3);
      expect(await _completeRedundantSync(db, 'void', 233), 0);
      expect(await _completeRedundantSync(db, 'close', 233), 0);
      expect(await _durum(db, 1), 'failed');
      expect(await _durum(db, 2), 'dead_letter');
    });

    test('ürün kalemi (ticket_item) kaydına DOKUNMAZ — sadece adisyon', () async {
      await _ekle(db, 'void', 233, 'pending', entity: 'ticket_item');
      expect(await _completeRedundantSync(db, 'void', 233), 0);
    });

    test('kayıt yoksa 0 döner, patlamaz (saf offline yol)', () async {
      expect(await _completeRedundantSync(db, 'void', 12345), 0);
    });
  });

  group('Kırmızı rozet sayımı — yalancı uyarı gerçekten biter mi', () {
    test('ÖNCE: 404 dead_letter rozeti kırmızı yakıyordu', () async {
      await _ekle(db, 'void', 233, 'dead_letter', retry: 3);
      expect(await _hataliSayisi(db), 1); // kasada kirmizi "1"
    });

    test('SONRA: 404 tamam sayılınca (completed) rozet söner', () async {
      await _ekle(db, 'void', 233, 'pending');
      await db.update('sync_queue', {'status': 'completed'}, where: 'id = 1'); // 404 -> markSyncComplete
      expect(await _hataliSayisi(db), 0);
    });

    test('gerçek bir hata varsa rozet HÂLÂ yanar (uyarı körelmedi)', () async {
      await _ekle(db, 'void', 233, 'pending');
      await db.update('sync_queue', {'status': 'completed'}, where: 'id = 1');
      await _ekle(db, 'add_item', 400, 'dead_letter', entity: 'ticket_item', retry: 3);
      expect(await _hataliSayisi(db), 1);
    });

    test('tükenmiş retry (pending ama retry>=max) da hata sayılır', () async {
      await _ekle(db, 'close', 501, 'pending', retry: 3);
      expect(await _hataliSayisi(db), 1);
    });
  });
}
