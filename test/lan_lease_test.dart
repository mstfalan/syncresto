import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 1),
  );
  await db.execute('''
    CREATE TABLE local_tickets (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      server_id INTEGER,
      ticket_number TEXT,
      table_id INTEGER,
      table_number TEXT,
      waiter_id INTEGER,
      status TEXT,
      total REAL DEFAULT 0,
      synced INTEGER DEFAULT 0,
      opened_at TEXT,
      created_at TEXT,
      owner_device_id TEXT,
      lan_lease_until TEXT,
      lan_origin TEXT DEFAULT 'self'
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_queue (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      local_id INTEGER,
      payload TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      created_at TEXT NOT NULL
    )
  ''');
  return db;
}

Future<bool> canWriteTable(Database db, int tableId, String deviceId, {required bool lanEnabled}) async {
  if (!lanEnabled) return true;
  final rows = await db.query('local_tickets',
      columns: ['owner_device_id', 'lan_lease_until', 'lan_origin', 'status'],
      where: "table_id = ? AND status IN ('open','lease_hold')", whereArgs: [tableId]);
  if (rows.isEmpty) return true;
  final now = DateTime.now();
  for (final r in rows) {
    final owner = r['owner_device_id']?.toString();
    final leaseStr = r['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    if (owner != null && owner != deviceId && leaseUntil != null && leaseUntil.isAfter(now)) {
      return false;
    }
  }
  for (final r in rows) {
    final origin = (r['lan_origin'] ?? 'self').toString();
    final owner = r['owner_device_id']?.toString();
    final leaseStr = r['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    if (origin == 'lan') continue;
    if (origin == 'self' && owner == null) return true;
    if (owner == deviceId && leaseUntil != null && leaseUntil.isAfter(now)) return true;
    if (owner == deviceId && leaseUntil == null) return true;
  }
  return false;
}

Future<Map<String, dynamic>> tryGrantLease(Database db,
    {required int tableId, required String claimant, required Duration leaseTtl, bool isRenew = false}) async {
  return await db.transaction((txn) async {
    final now = DateTime.now();
    final until = now.add(leaseTtl).toIso8601String();
    final rows = await txn.query('local_tickets',
        columns: ['local_id', 'owner_device_id', 'lan_lease_until', 'lan_origin', 'status', 'ticket_number'],
        where: "table_id = ? AND status IN ('open','lease_hold')", whereArgs: [tableId]);
    if (rows.isEmpty) {
      if (isRenew) return {'granted': false, 'reason': 'no_ticket'};
      final nowIso = now.toIso8601String();
      await txn.insert('local_tickets', {
        'ticket_number': 'LEASE-$tableId-$claimant', 'table_id': tableId, 'waiter_id': 0,
        'status': 'lease_hold', 'total': 0, 'opened_at': nowIso, 'created_at': nowIso,
        'owner_device_id': claimant, 'lan_lease_until': until, 'lan_origin': 'lease', 'synced': 1,
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

Future<void> demoteSelfAfterLeaseLost(Database db, int tableId) async {
  await db.transaction((txn) async {
    final rows = await txn.query('local_tickets',
        columns: ['local_id'], where: "table_id = ? AND COALESCE(lan_origin,'self')='self' AND status='open'",
        whereArgs: [tableId]);
    for (final row in rows) {
      final localId = row['local_id'];
      await txn.update('sync_queue', {'status': 'held'},
          where: "local_id = ? AND status = 'pending' AND action IN ('create_ticket','add_item','update_item','delete_item','close_ticket','void_ticket')",
          whereArgs: [localId]);
      await txn.update('local_tickets',
          {'lan_origin': 'lan', 'owner_device_id': null, 'lan_lease_until': null},
          where: 'local_id = ?', whereArgs: [localId]);
    }
  });
}

Future<List<Map<String, dynamic>>> getLanLedgerForBroadcast(Database db) async {
  final rows = await db.rawQuery("""
    SELECT ticket_number, table_id, owner_device_id, lan_lease_until
      FROM local_tickets
     WHERE owner_device_id IS NOT NULL
       AND COALESCE(lan_origin,'self') IN ('self','lease')
       AND status IN ('open','lease_hold')
  """);
  final now = DateTime.now();
  return rows.map((r) {
    final leaseStr = r['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    final remainingMs = (leaseUntil != null) ? leaseUntil.difference(now).inMilliseconds : 0;
    return {'table_id': r['table_id'], 'owner_device_id': r['owner_device_id'], 'lease_ms': remainingMs > 0 ? remainingMs : 0};
  }).toList();
}

void main() {
  late Database db;
  setUp(() async { db = await _openTestDb(); });
  tearDown(() async { await db.close(); });

  String future(int s) => DateTime.now().add(Duration(seconds: s)).toIso8601String();
  String past(int s) => DateTime.now().subtract(Duration(seconds: s)).toIso8601String();

  group('canWriteTable', () {
    test('flag OFF -> daima true', () async {
      await db.insert('local_tickets', {'table_id': 5, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B'});
      expect(await canWriteTable(db, 5, 'A', lanEnabled: false), true);
    });
    test('bos masa -> true', () async {
      expect(await canWriteTable(db, 9, 'A', lanEnabled: true), true);
    });
    test('kendi damgasiz self masa -> true', () async {
      await db.insert('local_tickets', {'table_id': 5, 'status': 'open', 'lan_origin': 'self'});
      expect(await canWriteTable(db, 5, 'A', lanEnabled: true), true);
    });
    test('canli self-lease bu cihazin -> true', () async {
      await db.insert('local_tickets', {'table_id': 5, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      expect(await canWriteTable(db, 5, 'A', lanEnabled: true), true);
    });
    test('baska owner LAN yansimasi -> false', () async {
      await db.insert('local_tickets', {'table_id': 5, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      expect(await canWriteTable(db, 5, 'A', lanEnabled: true), false);
    });
    test('K4a: baskasinin canli lease_hold placeholder masasi -> false (bos sanma)', () async {
      await db.insert('local_tickets', {'table_id': 7, 'status': 'lease_hold', 'lan_origin': 'lease', 'owner_device_id': 'B', 'lan_lease_until': future(45)});
      expect(await canWriteTable(db, 7, 'A', lanEnabled: true), false);
    });
    test('demote-sonrasi durum (origin=lan, owner NULL) -> canWriteTable false', () async {
      await db.insert('local_tickets', {'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': null});
      expect(await canWriteTable(db, 7, 'A', lanEnabled: true), false);
    });
  });

  group('tryGrantLease', () {
    test('G1: iki cihaz bos masaya -> tek grant, digeri deny', () async {
      final g1 = await tryGrantLease(db, tableId: 7, claimant: 'A', leaseTtl: const Duration(seconds: 45));
      final g2 = await tryGrantLease(db, tableId: 7, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      expect(g1['granted'], true);
      expect(g2['granted'], false);
      expect(g2['owner'], 'A');
      expect((await db.query('local_tickets', where: 'table_id = 7')).length, 1);
    });
    test('K1: damgasiz DOLU self masaya claim -> deny (unleased_open, takeover YOK)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-5-X', 'table_id': 5, 'status': 'open', 'lan_origin': 'self'});
      final r = await tryGrantLease(db, tableId: 5, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      expect(r['granted'], false);
      expect(r['reason'], 'unleased_open');
      final t = await db.query('local_tickets', where: 'table_id=5');
      expect(t.first['owner_device_id'], null);
    });
    test('owner tazeler (isRenew) -> grant', () async {
      await tryGrantLease(db, tableId: 7, claimant: 'A', leaseTtl: const Duration(seconds: 45));
      final r = await tryGrantLease(db, tableId: 7, claimant: 'A', leaseTtl: const Duration(seconds: 45), isRenew: true);
      expect(r['granted'], true);
    });
    test('damgali+expired lease -> baska cihaz devralir', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'A', 'lan_lease_until': past(10)});
      final r = await tryGrantLease(db, tableId: 7, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      expect(r['granted'], true);
      expect(r['takeover'], true);
    });
    test('K1 FIX: owner-damgali kendi masasina renew -> granted (unleased_open DEGIL)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-5-X', 'table_id': 5, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final r = await tryGrantLease(db, tableId: 5, claimant: 'A', leaseTtl: const Duration(seconds: 60), isRenew: true);
      expect(r['granted'], true);
      expect(r['takeover'], false);
    });
    test('canli lease baska owner -> deny', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final r = await tryGrantLease(db, tableId: 7, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      expect(r['granted'], false);
      expect(r['owner'], 'A');
    });
  });

  group('G4 demote (K3 tasarimina ertelendi — demote MUHURLU)', () {
    // demote gövdesi K3'te dogru action-isimleri/payload-esleme/un-hold ile yeniden yazilacak
    test('self->lan + pending sync IPTAL (in_progress korunur) + damga temizlenir', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create_ticket', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('sync_queue', {'action': 'add_item', 'entity_type': 'item', 'local_id': tid, 'payload': '{}', 'status': 'in_progress', 'created_at': DateTime.now().toIso8601String()});
      await demoteSelfAfterLeaseLost(db, 7);
      expect((await db.query('sync_queue', where: "local_id=$tid AND status='pending'")).isEmpty, true);
      expect((await db.query('sync_queue', where: "local_id=$tid AND status='held'")).length, 1);
      expect((await db.query('sync_queue', where: "local_id=$tid AND status='in_progress'")).length, 1);
      final t = (await db.query('local_tickets', where: 'table_id=7')).first;
      expect(t['lan_origin'], 'lan');
      expect(t['owner_device_id'], null);
      expect(t['lan_lease_until'], null);
    });
    test('K4b: ayni masada 2 self ticket -> IKISI de demote', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-A', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A'});
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-B', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A'});
      await demoteSelfAfterLeaseLost(db, 7);
      final selfLeft = await db.query('local_tickets', where: "table_id=7 AND COALESCE(lan_origin,'self')='self'");
      expect(selfLeft.isEmpty, true);
    });
  });

  group('getLanLedgerForBroadcast (defter yayini)', () {
    test('owner-damgali self + lease_hold yayinlanir, damgasiz self YAYINLANMAZ', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-5-A', 'table_id': 5, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      await db.insert('local_tickets', {'ticket_number': 'LEASE-7-A', 'table_id': 7, 'status': 'lease_hold', 'lan_origin': 'lease', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      await db.insert('local_tickets', {'ticket_number': 'MIRROR-9', 'table_id': 9, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': null});
      final led = await getLanLedgerForBroadcast(db);
      expect(led.length, 2);
      expect(led.any((x) => x['table_id'] == 9), false);
      expect(led.firstWhere((x) => x['table_id'] == 5)['lease_ms'] > 0, true);
    });
    test('expired lease -> lease_ms 0', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-5-A', 'table_id': 5, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': past(10)});
      final led = await getLanLedgerForBroadcast(db);
      expect(led.first['lease_ms'], 0);
    });
  });
}