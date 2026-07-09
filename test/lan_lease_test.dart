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
    CREATE TABLE local_ticket_items (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_ticket_id INTEGER
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
    if (origin == 'lan' || origin == 'demoted') continue;
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
        where: "table_id = ? AND status IN ('open','lease_hold') AND COALESCE(lan_origin,'self') != 'demoted'",
        whereArgs: [tableId]);
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

// PUSH-ON-CLAIM enrichLeaseReflection (uretim local_db_service.dart ile BIREBIR).
Future<void> enrichLeaseReflection(Database db,
    {required int tableId, required String claimant, required String ticketNumber,
    double? total, String? tableNumber}) async {
  final row = <String, dynamic>{'ticket_number': ticketNumber, 'status': 'open'};
  if (total != null) row['total'] = total;
  if (tableNumber != null) row['table_number'] = tableNumber;
  await db.update('local_tickets', row,
      where: "table_id = ? AND owner_device_id = ? AND lan_origin = 'lease'",
      whereArgs: [tableId, claimant]);
}

// Ortak ticket-scope clause (uretimdeki _ticketScopeSyncClause ile BIREBIR).
String ticketScopeSyncClause(String inClause) => """
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

Future<void> demoteSelfAfterLeaseLost(Database db, int tableId) async {
  await db.transaction((txn) async {
    final tickets = await txn.query('local_tickets',
        columns: ['local_id'], where: "table_id = ? AND COALESCE(lan_origin,'self')='self' AND status='open'",
        whereArgs: [tableId]);
    if (tickets.isEmpty) return;
    final ticketIds = tickets.map((t) => t['local_id'] as int).toList();
    final inClause = ticketIds.join(',');
    await txn.rawUpdate(
        "UPDATE sync_queue SET status = 'held' WHERE status = 'pending' AND ${ticketScopeSyncClause(inClause)}");
    for (final tid in ticketIds) {
      await txn.update('local_tickets',
          {'lan_origin': 'demoted', 'owner_device_id': null, 'lan_lease_until': null},
          where: 'local_id = ?', whereArgs: [tid]);
    }
  });
}

// K-3: teslim edilmemis held sync'leri backend'e kurtar (masada canli foreign lease YOKSA).
// KRITIK-2 (Fable 2. tur): ticket 'demoted' KALIR (self'e FLIP ETME) — flip eski ticket'i diriltirdi.
Future<int> reconcileHeldSyncs(Database db, String myDeviceId) async {
  final demoted = await db.query('local_tickets',
      columns: ['local_id', 'table_id'], where: "lan_origin = 'demoted'");
  int released = 0;
  for (final t in demoted) {
    final localId = t['local_id'] as int;
    final tableId = t['table_id'] as int?;
    if (tableId != null && await hasLiveForeignLease(db, tableId, myDeviceId)) continue;
    final inClause = '$localId';
    final n = await db.rawUpdate(
        "UPDATE sync_queue SET status = 'pending' WHERE status = 'held' AND ${ticketScopeSyncClause(inClause)}");
    // NOT: lan_origin='demoted' KALIR (dirilme yok); quarantinePrune sync bitince siler.
    released += n;
  }
  return released;
}

// KRITIK-1: lease serbest birak. DELETE status KOSULSUZ 'lease'; UPDATE sadece 'self'.
Future<void> clearLease(Database db, int tableId, String owner) async {
  await db.delete('local_tickets',
      where: "table_id = ? AND owner_device_id = ? AND lan_origin = 'lease'", whereArgs: [tableId, owner]);
  await db.update('local_tickets', {'owner_device_id': null, 'lan_lease_until': null},
      where: "table_id = ? AND owner_device_id = ? AND status = 'open' AND COALESCE(lan_origin,'self') = 'self'",
      whereArgs: [tableId, owner]);
}

// KRITIK-1: owner-null / expired 'lease' zombilerini sil.
Future<void> pruneLeaseZombies(Database db) async {
  final now = DateTime.now();
  final rows = await db.query('local_tickets',
      columns: ['local_id', 'owner_device_id', 'lan_lease_until'], where: "lan_origin = 'lease'");
  for (final r in rows) {
    final owner = r['owner_device_id']?.toString();
    final leaseStr = r['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    final dead = owner == null || owner.isEmpty || leaseUntil == null || !leaseUntil.isAfter(now);
    if (dead) await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [r['local_id']]);
  }
}

// KRITIK-2: hayalet dolu masa dislama (demoted + owner-null lease zombi).
Future<Set<int>> getOfflineOpenTableIds(Database db) async {
  final results = await db.query('local_tickets', columns: ['table_id'],
      where: "status = 'open' AND server_id IS NULL "
          "AND COALESCE(lan_origin,'self') != 'demoted' "
          "AND NOT (lan_origin = 'lease' AND owner_device_id IS NULL)");
  return results.map((r) => r['table_id'] as int).toSet();
}

// hasLiveForeignLease (uretimle birebir).
Future<bool> hasLiveForeignLease(Database db, int tableId, String myDeviceId) async {
  final rows = await db.query('local_tickets',
      columns: ['owner_device_id', 'lan_lease_until'],
      where: "table_id = ? AND lan_origin IN ('lan','lease')", whereArgs: [tableId]);
  final now = DateTime.now();
  for (final r in rows) {
    final owner = r['owner_device_id']?.toString();
    final leaseStr = r['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    if (owner != null && owner != myDeviceId && leaseUntil != null && leaseUntil.isAfter(now)) return true;
  }
  return false;
}

// K-1: lider dalinda lease tasiyan lan yansimalarini 'lease'e cevirir, lease'siz olanlari siler.
Future<void> pruneLanReflectionsKeepLeases(Database db) async {
  final now = DateTime.now();
  final all = await db.query('local_tickets',
      columns: ['local_id', 'owner_device_id', 'lan_lease_until', 'status'], where: "lan_origin = 'lan'");
  for (final t in all) {
    final owner = t['owner_device_id']?.toString();
    final leaseStr = t['lan_lease_until']?.toString();
    final leaseUntil = (leaseStr != null && leaseStr.isNotEmpty) ? DateTime.tryParse(leaseStr) : null;
    final liveLease = owner != null && owner.isNotEmpty && leaseUntil != null && leaseUntil.isAfter(now);
    if (liveLease) {
      await db.update('local_tickets', {'lan_origin': 'lease'}, where: 'local_id = ?', whereArgs: [t['local_id']]);
      continue;
    }
    await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [t['local_id']]);
  }
}

Future<void> quarantinePrune(Database db) async {
  final demoted = await db.query('local_tickets', columns: ['local_id'], where: "lan_origin = 'demoted'");
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

// YENI-1: mirror-temizlik guard'lari 'demoted' + 'held'i tanir (uretimle birebir).
Future<void> pruneMirroredTicketsExcept(Database db, Set<int> openTableIds) async {
  final mirrored = await db.query('local_tickets',
      columns: ['local_id', 'table_id'],
      where: "server_id IS NOT NULL AND COALESCE(lan_origin,'self') != 'demoted'");
  for (final t in mirrored) {
    final tableId = t['table_id'] as int?;
    if (tableId != null && openTableIds.contains(tableId)) continue;
    final localId = t['local_id'] as int;
    final pending = await db.query('sync_queue',
        where: "status IN ('pending', 'in_progress', 'held') AND (local_id = ? OR payload LIKE ? OR payload LIKE ?)",
        whereArgs: [localId, '%"local_ticket_id":$localId,%', '%"local_ticket_id":$localId}%'], limit: 1);
    if (pending.isNotEmpty) continue;
    await db.delete('local_ticket_items', where: 'local_ticket_id = ?', whereArgs: [localId]);
    await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [localId]);
  }
}

// DUSUK-5: LAN kapanis temizligi (dispose) — lan+lease sil, demoted+self KORU.
Future<void> clearAllLanReflections(Database db) async {
  await db.delete('local_tickets', where: "lan_origin IN ('lan','lease')");
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

  group('demote + held (K3, dogru action-esleme)', () {
    test('create/add_item/cancel_item held\'e alinir (SILINMEZ), ticket demoted', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('local_ticket_items', {'local_ticket_id': tid});
      final itemId = (await db.query('local_ticket_items')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('sync_queue', {'action': 'add_item', 'entity_type': 'ticket_item', 'local_id': itemId, 'payload': '{"local_ticket_id":$tid}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('sync_queue', {'action': 'cancel_item', 'entity_type': 'ticket_item', 'local_id': itemId, 'payload': '{"local_item_id":$itemId}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await demoteSelfAfterLeaseLost(db, 7);
      expect((await db.query('sync_queue', where: "status='pending'")).isEmpty, true, reason: 'hepsi held olmali (cancel_item kacagi yok)');
      expect((await db.query('sync_queue', where: "status='held'")).length, 3);
      final t = (await db.query('local_tickets', where: 'table_id=7')).first;
      expect(t['lan_origin'], 'demoted');
      expect(t['owner_device_id'], null);
    });
    test('in_progress KORUNUR (yarida kesilmez)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A'});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'close', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'in_progress', 'created_at': DateTime.now().toIso8601String()});
      await demoteSelfAfterLeaseLost(db, 7);
      expect((await db.query('sync_queue', where: "status='in_progress'")).length, 1);
    });
    test('O-1: delete_item/update_item de held\'e alinir (canli iptal/guncelleme kacagi yok)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'update_item', 'entity_type': 'ticket_item', 'local_id': 999, 'payload': '{"local_ticket_id":$tid}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('sync_queue', {'action': 'delete_item', 'entity_type': 'ticket_item', 'local_id': 998, 'payload': '{"local_ticket_id":$tid}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await demoteSelfAfterLeaseLost(db, 7);
      expect((await db.query('sync_queue', where: "status='pending'")).isEmpty, true, reason: 'update_item+delete_item held olmali (O-1)');
      expect((await db.query('sync_queue', where: "status='held'")).length, 2);
    });
    test('K4b: ayni masada 2 self ticket -> IKISI de demoted', () async {
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

  group('quarantinePrune (failover temizlik)', () {
    test('held VARKEN demoted masa SILINMEZ (veri korunur)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'held', 'created_at': DateTime.now().toIso8601String()});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true);
    });
    test('held YOKSA demoted masa + item silinir (yetim yok)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('local_ticket_items', {'local_ticket_id': tid});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isEmpty, true);
      expect((await db.query('local_ticket_items', where: 'local_ticket_id=$tid')).isEmpty, true);
    });
    test('O-2: PENDING delete_item varken demoted masa SILINMEZ (teslim bekliyor)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFFLINE-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      // reconcile held->pending yapti; henuz backend'e gitmedi. quarantine SILMEMELI.
      await db.insert('sync_queue', {'action': 'delete_item', 'entity_type': 'ticket_item', 'local_id': 5, 'payload': '{"local_ticket_id":$tid}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true, reason: 'pending sync teslim bekliyor, silinmemeli');
    });
  });

  group('K-1 failover: pruneLanReflectionsKeepLeases', () {
    test('CANLI foreign lease tasiyan lan yansimasi -> lease e cevrilir (SILINMEZ)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-B', 'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      await pruneLanReflectionsKeepLeases(db);
      final t = (await db.query('local_tickets', where: 'table_id=7')).first;
      expect(t['lan_origin'], 'lease', reason: 'devralinan defter kopyasi korunur+yayilir');
      expect(t['owner_device_id'], 'B');
    });
    test('lease SIZ lan yansimasi (kapanmis mirror) -> SILINIR', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-9', 'table_id': 9, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': null});
      await pruneLanReflectionsKeepLeases(db);
      expect((await db.query('local_tickets', where: 'table_id=9')).isEmpty, true);
    });
    test('EXPIRED lease lan yansimasi -> SILINIR (canli degil)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-8', 'table_id': 8, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': past(10)});
      await pruneLanReflectionsKeepLeases(db);
      expect((await db.query('local_tickets', where: 'table_id=8')).isEmpty, true);
    });
    test('devralinan lease sonra ledger e yayilir (getLanLedgerForBroadcast gorur)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-B', 'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      await pruneLanReflectionsKeepLeases(db);
      final led = await getLanLedgerForBroadcast(db);
      expect(led.any((x) => x['table_id'] == 7 && x['owner_device_id'] == 'B'), true, reason: 'yeni lider devralinan lease i yayar -> cihaz C bos gormez, cift adisyon YOK');
    });
  });

  group('K-3 reconcile: held->pending teslim (ebedi held yok)', () {
    test('foreign lease YOKSA held->pending, ticket DEMOTED KALIR (KRITIK-2: dirilme yok)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'held', 'created_at': DateTime.now().toIso8601String()});
      final n = await reconcileHeldSyncs(db, 'A');
      expect(n, 1);
      expect((await db.query('sync_queue', where: "status='pending'")).length, 1, reason: 'held->pending teslime alindi');
      expect((await db.query('local_tickets', where: 'table_id=7')).first['lan_origin'], 'demoted',
          reason: 'KRITIK-2: self flip YOK -> getTableTicket eski ticket i diriltmez');
    });
    test('CANLI foreign lease VARSA DOKUNMA (garson karsi kasada aktif)', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      await db.insert('local_tickets', {'ticket_number': 'LAN-7-B', 'table_id': 7, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      final tid = (await db.query('local_tickets', where: "table_id=7 AND lan_origin='demoted'")).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'held', 'created_at': DateTime.now().toIso8601String()});
      final n = await reconcileHeldSyncs(db, 'A');
      expect(n, 0);
      expect((await db.query('sync_queue', where: "status='held'")).length, 1, reason: 'foreign lease canli -> held korunur');
    });
    test('reconcile sonrasi sync tamamlanip quarantine: demoted masa+item SILINIR', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('local_ticket_items', {'local_ticket_id': tid});
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'held', 'created_at': DateTime.now().toIso8601String()});
      await reconcileHeldSyncs(db, 'A'); // held->pending (demoted KALIR)
      // backend teslim etti -> sync completed
      await db.update('sync_queue', {'status': 'completed'}, where: "action='create'");
      await quarantinePrune(db); // artik pending yok -> demoted masa+item silinir
      expect((await db.query('local_tickets', where: 'table_id=7')).isEmpty, true, reason: 'janitor bedava geldi');
      expect((await db.query('local_ticket_items', where: 'local_ticket_id=$tid')).isEmpty, true);
    });
  });

  group('KRITIK-1: clearLease + lease zombi (failover kilit)', () {
    test('failover-cevrilen lease (status=open) clearLease ile SILINIR (zombi yok)', () async {
      // pruneLanReflectionsKeepLeases lan->lease cevirdi, status='open' kaldi. A doner, kapatir.
      await db.insert('local_tickets', {'ticket_number': 'LAN-5-A', 'table_id': 5, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      await clearLease(db, 5, 'A');
      expect((await db.query('local_tickets', where: 'table_id=5')).isEmpty, true,
          reason: 'status kosulsuz lease DELETE -> unleased_open zombi kalmaz');
    });
    test('clearLease self ticket i owner-null yapar ama lease origin i BOZMAZ', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-5-A', 'table_id': 5, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      await clearLease(db, 5, 'A');
      final t = (await db.query('local_tickets', where: 'table_id=5')).first;
      expect(t['owner_device_id'], null);
      expect(t['lan_lease_until'], null);
      expect(t['lan_origin'], 'self');
    });
    test('pruneLeaseZombies: owner-null lease -> SILINIR, canli lease -> KALIR', () async {
      await db.insert('local_tickets', {'ticket_number': 'Z1', 'table_id': 1, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': null});
      await db.insert('local_tickets', {'ticket_number': 'Z2', 'table_id': 2, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': 'B', 'lan_lease_until': past(10)});
      await db.insert('local_tickets', {'ticket_number': 'Z3', 'table_id': 3, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      await pruneLeaseZombies(db);
      expect((await db.query('local_tickets', where: 'table_id=1')).isEmpty, true, reason: 'owner-null zombi');
      expect((await db.query('local_tickets', where: 'table_id=2')).isEmpty, true, reason: 'expired zombi');
      expect((await db.query('local_tickets', where: 'table_id=3')).isNotEmpty, true, reason: 'canli lease korunur');
    });
    test('failover-cevrilen lease zombisi tryGrantLease i KILITLEMEZ (temizlik sonrasi)', () async {
      // zombi: lease+open+owner-null (clearLease disi bir yolla olustu)
      await db.insert('local_tickets', {'ticket_number': 'Z', 'table_id': 5, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': null});
      await pruneLeaseZombies(db); // temizle
      final r = await tryGrantLease(db, tableId: 5, claimant: 'C', leaseTtl: const Duration(seconds: 45));
      expect(r['granted'], true, reason: 'zombi temizlendi -> masa yeniden aciilabilir');
    });
  });

  group('KRITIK-2: demoted masa hayalet/dirilme dislama', () {
    test('getOfflineOpenTableIds: demoted masa DOLU GORUNMEZ (foreign lan satiri gosterir)', () async {
      await db.insert('local_tickets', {'ticket_number': 'D', 'table_id': 7, 'status': 'open', 'server_id': null, 'lan_origin': 'demoted', 'owner_device_id': null});
      final ids = await getOfflineOpenTableIds(db);
      expect(ids.contains(7), false, reason: 'demoted kendi basina dolu gostermez');
    });
    test('getOfflineOpenTableIds: owner-null lease zombi DOLU GORUNMEZ', () async {
      await db.insert('local_tickets', {'ticket_number': 'Z', 'table_id': 8, 'status': 'open', 'server_id': null, 'lan_origin': 'lease', 'owner_device_id': null});
      final ids = await getOfflineOpenTableIds(db);
      expect(ids.contains(8), false);
    });
    test('getOfflineOpenTableIds: self + canli lan foreign masa DOLU GORUNUR', () async {
      await db.insert('local_tickets', {'ticket_number': 'S', 'table_id': 9, 'status': 'open', 'server_id': null, 'lan_origin': 'self', 'owner_device_id': 'A'});
      await db.insert('local_tickets', {'ticket_number': 'F', 'table_id': 10, 'status': 'open', 'server_id': null, 'lan_origin': 'lan', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      final ids = await getOfflineOpenTableIds(db);
      expect(ids.contains(9), true);
      expect(ids.contains(10), true, reason: 'Faz 2: baska kasadaki masa dolu gorunur');
    });
    test('tryGrantLease: demoted satir unleased_open DENY BESLEMEZ (masa acilabilir)', () async {
      await db.insert('local_tickets', {'ticket_number': 'D', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final r = await tryGrantLease(db, tableId: 7, claimant: 'C', leaseTtl: const Duration(seconds: 45));
      expect(r['granted'], true, reason: 'demoted dislaninca masa bos gorunur -> grant');
    });
  });

  group('ORTA-2: item_local_id ile masaya baglanma (local_ticket_id payload da yoksa)', () {
    test('delete_item local_ticket_id SIZ ama item_local_id ile held e alinir', () async {
      await db.insert('local_tickets', {'ticket_number': 'OFF-7-X', 'table_id': 7, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A', 'lan_lease_until': future(30)});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('local_ticket_items', {'local_ticket_id': tid});
      final itemId = (await db.query('local_ticket_items')).first['local_id'] as int;
      // resolve basarisiz -> local_ticket_id YOK, sadece item_local_id var
      await db.insert('sync_queue', {'action': 'delete_item', 'entity_type': 'ticket_item', 'local_id': 500, 'payload': '{"item_local_id":$itemId}', 'status': 'pending', 'created_at': DateTime.now().toIso8601String()});
      await demoteSelfAfterLeaseLost(db, 7);
      expect((await db.query('sync_queue', where: "status='held'")).length, 1, reason: 'item_local_id JOIN ile held e alindi (O-1 kacagi kapandi)');
    });
  });

  group('KRITIK-YENI-1: mirror-temizlik guard held/demoted tanir', () {
    test('pruneMirroredTicketsExcept: HELD sync tasiyan demoted ticket SILINMEZ', () async {
      // demoted + server_id DOLU + held add_item -> mirror-prune silmemeli (yoksa yetim held)
      await db.insert('local_tickets', {'ticket_number': 'M-7', 'table_id': 7, 'server_id': 900, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'add_item', 'entity_type': 'ticket_item', 'local_id': 5, 'payload': '{"local_ticket_id":$tid}', 'status': 'held', 'created_at': DateTime.now().toIso8601String()});
      await pruneMirroredTicketsExcept(db, const {}); // masa backend'de kapali (openTableIds bos)
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true, reason: 'demoted+held korunur');
      expect((await db.query('sync_queue', where: "status='held'")).length, 1, reason: 'held yetim kalmadi');
    });
    test('pruneMirroredTicketsExcept: demoted ama SYNC YOK -> yine korunur (demoted dislama)', () async {
      // demoted origin tek basina mirror-prune disinda (yasam dongusu quarantine da)
      await db.insert('local_tickets', {'ticket_number': 'M-7', 'table_id': 7, 'server_id': 900, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      await pruneMirroredTicketsExcept(db, const {});
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true);
    });
    test('pruneMirroredTicketsExcept: normal mirror (self, sync yok, kapali) SILINIR (regresyon yok)', () async {
      await db.insert('local_tickets', {'ticket_number': 'M-9', 'table_id': 9, 'server_id': 901, 'status': 'open', 'lan_origin': 'self'});
      await pruneMirroredTicketsExcept(db, const {});
      expect((await db.query('local_tickets', where: 'table_id=9')).isEmpty, true, reason: 'temiz mirror hala temizlenir');
    });
  });

  group('KRITIK-YENI-2: quarantine failed/dead_letter korur (kurtarma penceresi)', () {
    test('FAILED sync varken demoted masa SILINMEZ (dead_letter retry penceresi korunur)', () async {
      await db.insert('local_tickets', {'ticket_number': 'D-7', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'failed', 'created_at': DateTime.now().toIso8601String()});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true, reason: 'failed retry edilebilir, silinmemeli');
    });
    test('DEAD_LETTER sync varken de demoted masa SILINMEZ', () async {
      await db.insert('local_tickets', {'ticket_number': 'D-7', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'dead_letter', 'created_at': DateTime.now().toIso8601String()});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isNotEmpty, true);
    });
    test('completed sync -> masa temizlenir (dead_letter 30 gunde silinince prune devreye)', () async {
      await db.insert('local_tickets', {'ticket_number': 'D-7', 'table_id': 7, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      final tid = (await db.query('local_tickets', where: 'table_id=7')).first['local_id'] as int;
      await db.insert('sync_queue', {'action': 'create', 'entity_type': 'ticket', 'local_id': tid, 'payload': '{}', 'status': 'completed', 'created_at': DateTime.now().toIso8601String()});
      await quarantinePrune(db);
      expect((await db.query('local_tickets', where: 'table_id=7')).isEmpty, true);
    });
  });

  group('DUSUK-5: dispose LAN kapanis temizligi', () {
    test('clearAllLanReflections: lan+lease sil, demoted+self KORU (veri kaybi yasak)', () async {
      await db.insert('local_tickets', {'ticket_number': 'L1', 'table_id': 1, 'status': 'open', 'lan_origin': 'lan', 'owner_device_id': 'B'});
      await db.insert('local_tickets', {'ticket_number': 'L2', 'table_id': 2, 'status': 'open', 'lan_origin': 'lease', 'owner_device_id': 'B', 'lan_lease_until': future(30)});
      await db.insert('local_tickets', {'ticket_number': 'D3', 'table_id': 3, 'status': 'open', 'lan_origin': 'demoted', 'owner_device_id': null});
      await db.insert('local_tickets', {'ticket_number': 'S4', 'table_id': 4, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'A'});
      await clearAllLanReflections(db);
      expect((await db.query('local_tickets', where: 'table_id=1')).isEmpty, true, reason: 'lan silindi');
      expect((await db.query('local_tickets', where: 'table_id=2')).isEmpty, true, reason: 'lease silindi (failover kalintisi dahil)');
      expect((await db.query('local_tickets', where: 'table_id=3')).isNotEmpty, true, reason: 'demoted KORUNUR (held olabilir)');
      expect((await db.query('local_tickets', where: 'table_id=4')).isNotEmpty, true, reason: 'self KORUNUR (gercek adisyon)');
    });
  });

  group('PUSH-ON-CLAIM: enrichLeaseReflection (istemci masasi ucuncu kasada gorunsun)', () {
    test('enrich lease satirini GERCEK icerikle gunceller (LEASE-x total=0 -> gercek)', () async {
      // Lider tryGrantLease ile placeholder yaratir (istemci B masa 5 acti)
      await tryGrantLease(db, tableId: 5, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      final before = (await db.query('local_tickets', where: 'table_id=5')).first;
      expect(before['ticket_number'], 'LEASE-5-B');
      expect(before['total'], 0);
      // Istemci B gercek masa icerigini push eder
      await enrichLeaseReflection(db, tableId: 5, claimant: 'B',
          ticketNumber: 'OFFLINE-5-ABCD', total: 256.0, tableNumber: 'Fıçı 2');
      final after = (await db.query('local_tickets', where: 'table_id=5')).first;
      expect(after['ticket_number'], 'OFFLINE-5-ABCD');
      expect(after['total'], 256.0);
      expect(after['table_number'], 'Fıçı 2');
      expect(after['lan_origin'], 'lease', reason: 'KISIT-1: lease KALIR, self OLMAZ (backend sync YOK)');
    });

    test('Fable KRITIK-1: enrich status=open YAPAR (ucuncu istemci dolu-masa tespiti open sayar)', () async {
      await tryGrantLease(db, tableId: 6, claimant: 'B', leaseTtl: const Duration(seconds: 45));
      final before = (await db.query('local_tickets', where: 'table_id=6')).first;
      expect(before['status'], 'lease_hold', reason: 'placeholder lease_hold ile baslar');
      await enrichLeaseReflection(db, tableId: 6, claimant: 'B', ticketNumber: 'OFFLINE-6-X', total: 100.0);
      final after = (await db.query('local_tickets', where: 'table_id=6')).first;
      expect(after['status'], 'open', reason: 'enrich open yapar -> getOfflineOpenTableIds sayar (masa BOS gorunmez)');
      expect(after['lan_origin'], 'lease', reason: 'origin lease KALIR (backend sizmaz)');
    });

    test('enrich SADECE lease satirina yazar (self/demoted/lan DOKUNULMAZ)', () async {
      // Ayni masada hem self (bu cihazin gercek masasi) hem baska cihazin lease i olamaz normalde,
      // ama guard testi: farkli origin ler ayni owner+table ile -> sadece lease guncellenir.
      await db.insert('local_tickets', {'ticket_number': 'SELF-9', 'table_id': 9, 'status': 'open', 'lan_origin': 'self', 'owner_device_id': 'B', 'total': 500});
      await db.insert('local_tickets', {'ticket_number': 'LEASE-9-B', 'table_id': 9, 'status': 'lease_hold', 'lan_origin': 'lease', 'owner_device_id': 'B', 'total': 0});
      await enrichLeaseReflection(db, tableId: 9, claimant: 'B', ticketNumber: 'OFFLINE-9-Y', total: 300.0);
      final self = (await db.query('local_tickets', where: "table_id=9 AND lan_origin='self'")).first;
      final lease = (await db.query('local_tickets', where: "table_id=9 AND lan_origin='lease'")).first;
      expect(self['ticket_number'], 'SELF-9', reason: 'self DOKUNULMADI');
      expect(self['total'], 500, reason: 'self total korundu');
      expect(lease['ticket_number'], 'OFFLINE-9-Y', reason: 'sadece lease guncellendi');
      expect(lease['total'], 300.0);
    });

    test('enrich baska cihazin lease ine yazmaz (owner=claimant filtresi)', () async {
      await db.insert('local_tickets', {'ticket_number': 'LEASE-8-C', 'table_id': 8, 'status': 'lease_hold', 'lan_origin': 'lease', 'owner_device_id': 'C', 'total': 0});
      // B claimant ile enrich -> C nin lease ine DOKUNMAZ
      await enrichLeaseReflection(db, tableId: 8, claimant: 'B', ticketNumber: 'OFFLINE-8-Z', total: 99.0);
      final row = (await db.query('local_tickets', where: 'table_id=8')).first;
      expect(row['ticket_number'], 'LEASE-8-C', reason: 'C nin lease i DOKUNULMADI (owner=B eslesmedi)');
      expect(row['total'], 0, reason: 'total degismedi');
    });

    test('Fable KRITIK-1 REGRESYON: enrich sonrasi masa getOfflineOpenTableIds te DOLU gorunur', () async {
      // Ucuncu istemci C nin gozunden: liderden gelen enrich li lease satirini upsertLanTicket 'lan' yazar.
      // enrich ONCESI (lease_hold placeholder) masa BOS gorunurdu; enrich SONRASI (open) DOLU gorunmeli.
      await db.insert('local_tickets', {'ticket_number': 'LEASE-11-B', 'table_id': 11, 'status': 'lease_hold', 'lan_origin': 'lease', 'owner_device_id': 'B', 'total': 0, 'lan_lease_until': future(30)});
      var ids = await getOfflineOpenTableIds(db);
      expect(ids.contains(11), false, reason: 'lease_hold placeholder DOLU GORUNMEZ (dogru — henuz icerik yok)');
      // enrich -> status open
      await enrichLeaseReflection(db, tableId: 11, claimant: 'B', ticketNumber: 'OFFLINE-11-Q', total: 256.0, tableNumber: 'Fıçı 3');
      ids = await getOfflineOpenTableIds(db);
      expect(ids.contains(11), true, reason: 'enrich sonrasi masa DOLU GORUNUR (ozellik amacina ulasti)');
    });
  });
}