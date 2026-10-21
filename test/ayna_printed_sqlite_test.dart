// 21 Eki 2026 — cevrimdisi mutfak fisi cift basim.
// local_db_service.dart'taki ayna printed birlestirme, markItemsPrintedByServerIds,
// updateItemServerId yaris korumasi ve getPendingMarkPrintedForServerTicket sorgularinin
// AYNI SQL'ini gercek sqlite uzerinde dogrular (LocalDbService singleton dogrudan test edilemiyor;
// repo deseni: sync_404_idempotent_test.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/ayna_printed.dart';

const _semaTickets = '''
  CREATE TABLE local_tickets (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER,
    status TEXT DEFAULT 'open'
  )
''';

const _semaItems = '''
  CREATE TABLE local_ticket_items (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER,
    local_ticket_id INTEGER NOT NULL,
    product_name TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    synced INTEGER DEFAULT 0,
    synced_at TEXT,
    printed INTEGER DEFAULT 0
  )
''';

const _semaSyncQueue = '''
  CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    local_id INTEGER,
    server_id INTEGER,
    payload TEXT NOT NULL,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    status TEXT DEFAULT 'pending',
    created_at TEXT NOT NULL
  )
''';

/// upsertServerTicket item aynasinin printed kismi (local_db_service.dart) ile AYNI mantik.
Future<void> _ayna(Database db, int localTicketId, int serverItemId, String ad, Object? sunucuPrinted) async {
  final exist = await db.query('local_ticket_items',
      columns: ['local_id', 'printed'], where: 'server_id = ?', whereArgs: [serverItemId], limit: 1);
  final printed = printedBirlestir(
    lokal: exist.isNotEmpty ? (exist.first['printed'] as int? ?? 0) : null,
    sunucu: sunucuPrinted,
  );
  final row = {
    'server_id': serverItemId,
    'local_ticket_id': localTicketId,
    'product_name': ad,
    'status': 'active',
    'synced': 1,
    'printed': printed,
  };
  if (exist.isNotEmpty) {
    await db.update('local_ticket_items', row, where: 'local_id = ?', whereArgs: [exist.first['local_id']]);
  } else {
    await db.insert('local_ticket_items', row);
  }
}

/// getUnprintedLocalItems filtresi (cevrimdisi mutfak fisine girecek kalemler)
Future<List<String>> _basilacaklar(Database db, int localTicketId) async {
  final r = await db.rawQuery('''
    SELECT product_name FROM local_ticket_items
     WHERE local_ticket_id = ? AND printed = 0 AND (status IS NULL OR status != 'cancelled')
     ORDER BY local_id
  ''', [localTicketId]);
  return r.map((e) => e['product_name'] as String).toList();
}

/// local_db_service.markItemsPrintedByServerIds ile AYNI sorgu
Future<int> _markByServerIds(Database db, List<int> ids) {
  final ph = List.filled(ids.length, '?').join(',');
  return db.rawUpdate(
      'UPDATE local_ticket_items SET printed = 1 WHERE server_id IN ($ph) AND printed = 0', ids);
}

/// local_db_service.updateItemServerId (yaris korumasi) ile AYNI mantik
Future<void> _updateItemServerId(Database db, int localId, int serverId) async {
  await db.transaction((txn) async {
    final kopyalar = await txn.query('local_ticket_items',
        columns: ['local_id', 'printed'],
        where: 'server_id = ? AND local_id != ?', whereArgs: [serverId, localId]);
    var tasinan = 0;
    for (final k in kopyalar) {
      final kopyaId = k['local_id'] as int;
      if ((k['printed'] as int? ?? 0) == 1) tasinan = 1;
      final sq = await txn.query('sync_queue',
          columns: ['id', 'payload'],
          where: "status IN ('pending','in_progress') AND payload LIKE ?",
          whereArgs: ['%$kopyaId%']);
      for (final row in sq) {
        final pl = Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
        var degisti = false;
        if (pl['item_local_id'] == kopyaId) {
          pl['item_local_id'] = localId;
          degisti = true;
        }
        final ids = pl['item_local_ids'];
        if (ids is List && ids.contains(kopyaId)) {
          pl['item_local_ids'] = {...ids.whereType<int>().map((x) => x == kopyaId ? localId : x)}.toList();
          degisti = true;
        }
        if (degisti) {
          await txn.update('sync_queue', {'payload': jsonEncode(pl)}, where: 'id = ?', whereArgs: [row['id']]);
        }
      }
      await txn.delete('local_ticket_items', where: 'local_id = ?', whereArgs: [kopyaId]);
    }
    await txn.update('local_ticket_items', {
      'server_id': serverId,
      'synced': 1,
      'synced_at': '2026-10-21T10:00:00',
      if (tasinan == 1) 'printed': 1,
    }, where: 'local_id = ?', whereArgs: [localId]);
  });
}

/// local_db_service.getPendingMarkPrintedForServerTicket ile AYNI sorgu
Future<List<Map<String, Object?>>> _bekleyenMarkPrinted(Database db, int serverTicketId) {
  return db.rawQuery('''
    SELECT sq.* FROM sync_queue sq
     WHERE sq.action = 'mark_printed' AND sq.status = 'pending' AND sq.retry_count < sq.max_retries
       AND (sq.server_id = ? OR sq.local_id IN (SELECT local_id FROM local_tickets WHERE server_id = ?))
     ORDER BY sq.created_at ASC
  ''', [serverTicketId, serverTicketId]);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute(_semaTickets);
    await db.execute(_semaItems);
    await db.execute(_semaSyncQueue);
    await db.insert('local_tickets', {'local_id': 1, 'server_id': 172163});
  });
  tearDown(() async => db.close());

  group('ayna printed — basimdan once aynalanan kalem', () {
    test('basimdan ONCE aynalanan 6 kalem, sonraki aynada sunucu 1 ile 1 olur; cevrimdisi fis yalniz 2 yeni', () async {
      const eski = ['Pideli Kofte', 'Cocuk Burger', 'Izgara Somon', 'Uludag Gazoz', 'Uludag Gazoz', 'Ayran'];
      // 19:46 ayna: henuz basilmamis (sunucu 0)
      for (var i = 0; i < eski.length; i++) {
        await _ayna(db, 1, 479870 + i, eski[i], 0);
      }
      // 19:47 WebPOS basti -> sonraki ayna sunucu 1 getirir
      for (var i = 0; i < eski.length; i++) {
        await _ayna(db, 1, 479870 + i, eski[i], 1);
      }
      // 20:17 cevrimdisi 2 IKRAM CAY (server_id yok)
      await db.insert('local_ticket_items', {'local_ticket_id': 1, 'product_name': 'IKRAM CAY', 'status': 'pending'});
      await db.insert('local_ticket_items', {'local_ticket_id': 1, 'product_name': 'IKRAM CAY', 'status': 'pending'});
      expect(await _basilacaklar(db, 1), ['IKRAM CAY', 'IKRAM CAY']);
    });

    test('lokal 1 (cevrimdisi basildi) + sunucu henuz 0 -> ayna 1 korur, tekrar basilmaz', () async {
      await _ayna(db, 1, 9001, 'Ayran', 0);
      await db.update('local_ticket_items', {'printed': 1}, where: 'server_id = ?', whereArgs: [9001]);
      await _ayna(db, 1, 9001, 'Ayran', 0);
      expect(await _basilacaklar(db, 1), isEmpty);
    });

    test('mesru ilk basim: sunucu 0 + lokal 0 -> fise girer', () async {
      await _ayna(db, 1, 9002, 'Kola', 0);
      expect(await _basilacaklar(db, 1), ['Kola']);
    });

    test('yeni satir sunucu 1 -> fise girmez', () async {
      await _ayna(db, 1, 9003, 'Su', 1);
      expect(await _basilacaklar(db, 1), isEmpty);
    });
  });

  group('markItemsPrintedByServerIds (online basim / WebPOS claim)', () {
    test('yalniz verilen server_id ve printed=0 satirlar guncellenir', () async {
      await _ayna(db, 1, 1, 'A', 0);
      await _ayna(db, 1, 2, 'B', 0);
      await _ayna(db, 1, 3, 'C', 1);
      await db.insert('local_ticket_items', {'local_ticket_id': 1, 'product_name': 'Lokal', 'status': 'pending'});
      final n = await _markByServerIds(db, [1, 3, 777]);
      expect(n, 1); // 3 zaten 1, 777 yok
      expect(await _basilacaklar(db, 1), ['B', 'Lokal']); // server_id NULL satir dokunulmaz
    });
  });

  group('uctan uca: online basim (D) -> kesinti -> cevrimdisi fis', () {
    test('online basilan kalemler cevrimdisi fise GIRMEZ, yalniz yeni eklenen girer', () async {
      await _ayna(db, 1, 701, 'Kofte', 0);
      await _ayna(db, 1, 702, 'Ayran', 0);
      await _markByServerIds(db, [701, 702]); // printKitchen yaniti
      await db.insert('local_ticket_items', {'local_ticket_id': 1, 'product_name': 'Cay', 'status': 'pending'});
      expect(await _basilacaklar(db, 1), ['Cay']);
    });
  });

  group('updateItemServerId yaris korumasi', () {
    test('ayna kopyasi silinir, printed asil satira tasinir, tek satir kalir', () async {
      final asil = await db.insert('local_ticket_items',
          {'local_ticket_id': 1, 'product_name': 'Ayran', 'status': 'pending', 'printed': 0});
      // POST yaniti ile updateItemServerId arasinda ayna ayni kalemi ikinci satir olarak acti
      await _ayna(db, 1, 5555, 'Ayran', 1);
      await _updateItemServerId(db, asil, 5555);
      final r = await db.query('local_ticket_items', where: 'server_id = ?', whereArgs: [5555]);
      expect(r.length, 1);
      expect(r.first['local_id'], asil);
      expect(r.first['printed'], 1);
      expect(await _basilacaklar(db, 1), isEmpty);
    });

    test('kopyaya bagli bekleyen mark_printed / mark_served ASIL satira yonlenir', () async {
      final asil = await db.insert('local_ticket_items',
          {'local_ticket_id': 1, 'product_name': 'Ayran', 'status': 'pending', 'printed': 0});
      await _ayna(db, 1, 5555, 'Ayran', 0);
      final kopya = (await db.query('local_ticket_items', where: 'server_id = ?', whereArgs: [5555])).first['local_id'] as int;
      // kopya o arada cevrimdisi basilip kuyruga girdi
      final mp = await db.insert('sync_queue', {
        'action': 'mark_printed', 'entity_type': 'ticket', 'local_id': 1,
        'payload': jsonEncode({'item_local_ids': [kopya, 99]}), 'created_at': '2026-10-21T10:00:00'});
      final ms = await db.insert('sync_queue', {
        'action': 'mark_served', 'entity_type': 'ticket', 'local_id': 1,
        'payload': jsonEncode({'item_local_id': kopya}), 'created_at': '2026-10-21T10:00:01'});
      await _updateItemServerId(db, asil, 5555);
      Future<Map> pl(int id) async =>
          jsonDecode((await db.query('sync_queue', where: 'id = ?', whereArgs: [id])).first['payload'] as String) as Map;
      expect((await pl(mp))['item_local_ids'], [asil, 99]);
      expect((await pl(ms))['item_local_id'], asil);
      // cozumleme: yonlenen local_id gercekten var ve server_id'li
      final r = await db.query('local_ticket_items', where: 'local_id = ?', whereArgs: [asil]);
      expect(r.first['server_id'], 5555);
    });

    test('kopya yoksa davranis eskisiyle ayni (printed degismez)', () async {
      final asil = await db.insert('local_ticket_items',
          {'local_ticket_id': 1, 'product_name': 'Kola', 'status': 'pending', 'printed': 0});
      await _updateItemServerId(db, asil, 6000);
      final r = await db.query('local_ticket_items', where: 'local_id = ?', whereArgs: [asil]);
      expect(r.first['server_id'], 6000);
      expect(r.first['synced'], 1);
      expect(r.first['printed'], 0);
    });
  });

  group('getPendingMarkPrintedForServerTicket', () {
    Future<void> ekle(int? localId, int? serverId, String status, {int retry = 0, String action = 'mark_printed'}) =>
        db.insert('sync_queue', {
          'action': action, 'entity_type': 'ticket', 'local_id': localId, 'server_id': serverId,
          'payload': '{}', 'status': status, 'retry_count': retry, 'max_retries': 3,
          'created_at': '2026-10-21T10:00:00',
        });

    test('server_id ile veya local_id->local_tickets.server_id ile bulunur', () async {
      await ekle(null, 172163, 'pending');
      await ekle(1, null, 'pending');
      expect((await _bekleyenMarkPrinted(db, 172163)).length, 2);
    });

    test('tamamlanmis, retry tukenmis, baska eylem ve baska adisyon bulunmaz', () async {
      await ekle(1, null, 'completed');
      await ekle(1, null, 'pending', retry: 3);
      await ekle(1, null, 'pending', action: 'add_item');
      await ekle(null, 999, 'pending');
      expect(await _bekleyenMarkPrinted(db, 172163), isEmpty);
    });
  });
}
