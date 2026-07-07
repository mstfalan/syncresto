// LAN-senkron salt-okunur masa yansiması — Fable Faz 2 KRİTİK düzeltmelerinin canlı testi.
// 7 Tem 2026. Bu testler in-memory SQLite üzerinde local_tickets şemasını kurar ve
// düzeltilen SORGULARIN BİREBİR AYNISINI çalıştırarak LAN satırlarının (lan_origin='lan')
// self akışlardan dışlandığını, self satırların (lan_origin='self'/NULL) korunduğunu kanıtlar.
//
// Kapsanan Fable bulguları:
//   K1  — hasLanOnlyOpenTicket: LAN-only masa salt-okunur tespiti
//   K2/K3 — pruneLanTickets: yalnızca lan_origin='lan' satırları silinir, self korunur
//   O1  — moveLocalItem hedef sorgusu: LAN masası hedef olamaz
//   D1  — getLocalTicketWithSection: LAN satırı print akışına girmez
//   Filtre — getTableTicket / getOfflineClosedTableIds / syncOpenTicketsFromServer local sorgusu
//   D3  — NULL lan_origin (eski satır) COALESCE ile 'self' sayılır

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Üretim şemasıyla uyumlu minimal local_tickets tablosu (LAN kolonları dahil).
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
  return db;
}

/// hasLanOnlyOpenTicket'ın birebir mantığı (local_db_service.dart).
Future<bool> _hasLanOnlyOpenTicket(Database db, int tableId) async {
  final self = await db.query('local_tickets',
      columns: ['local_id'],
      where: "table_id = ? AND status = 'open' AND COALESCE(lan_origin,'self') = 'self'",
      whereArgs: [tableId], limit: 1);
  if (self.isNotEmpty) return false;
  final lan = await db.query('local_tickets',
      columns: ['local_id'],
      where: "table_id = ? AND status = 'open' AND lan_origin = 'lan'",
      whereArgs: [tableId], limit: 1);
  return lan.isNotEmpty;
}

void main() {
  late Database db;

  setUp(() async {
    db = await _openTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('K1 — hasLanOnlyOpenTicket (UI salt-okunur guard)', () {
    test('SADECE LAN yansıması olan masa -> true (salt-okunur, adisyon açtırma)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'OFFLINE-5-AAA', 'table_id': 5, 'status': 'open',
        'lan_origin': 'lan', 'owner_device_id': 'device-A', 'synced': 1,
      });
      expect(await _hasLanOnlyOpenTicket(db, 5), isTrue);
    });

    test('Kendi self açık ticketı olan masa -> false (normal akış, LAN de olsa)', () async {
      // Aynı masada hem self hem LAN yansıması varsa: self KAZANIR (normal akış).
      await db.insert('local_tickets', {
        'ticket_number': 'OFFLINE-5-SELF', 'table_id': 5, 'status': 'open',
        'lan_origin': 'self', 'synced': 0,
      });
      await db.insert('local_tickets', {
        'ticket_number': 'OFFLINE-5-LAN', 'table_id': 5, 'status': 'open',
        'lan_origin': 'lan', 'owner_device_id': 'device-A', 'synced': 1,
      });
      expect(await _hasLanOnlyOpenTicket(db, 5), isFalse);
    });

    test('Boş masa -> false', () async {
      expect(await _hasLanOnlyOpenTicket(db, 99), isFalse);
    });

    test('Eski self satır (lan_origin NULL) -> false (COALESCE self sayar)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'OLD-7', 'table_id': 7, 'status': 'open', 'lan_origin': null,
      });
      expect(await _hasLanOnlyOpenTicket(db, 7), isFalse);
    });
  });

  group('getTableTicket sorgusu — LAN satırı iş akışına girmez', () {
    // getTableTicket birebir where + orderBy
    Future<List<Map<String, dynamic>>> tableTicketQuery(int tableId) {
      return db.query('local_tickets',
          where: "table_id = ? AND status = ? AND COALESCE(lan_origin,'self') = 'self'",
          whereArgs: [tableId, 'open'],
          orderBy: '(server_id IS NULL) DESC, local_id DESC');
    }

    test('Sadece LAN masası -> sorgu BOŞ döner (garson iş açamaz)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'LAN-3', 'table_id': 3, 'status': 'open',
        'lan_origin': 'lan', 'owner_device_id': 'device-B', 'synced': 1,
      });
      expect(await tableTicketQuery(3), isEmpty);
    });

    test('Self masa -> sorgu döner (normal)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'SELF-3', 'table_id': 3, 'status': 'open', 'lan_origin': 'self',
      });
      expect((await tableTicketQuery(3)).length, 1);
    });

    test('Eski self (NULL) masa -> sorgu döner (COALESCE)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'OLD-3', 'table_id': 3, 'status': 'open', 'lan_origin': null,
      });
      expect((await tableTicketQuery(3)).length, 1);
    });
  });

  group('O1 — moveLocalItem hedef sorgusu: LAN masası hedef olamaz', () {
    Future<List<Map<String, dynamic>>> moveTargetQuery(int targetTableId) {
      return db.query('local_tickets',
          where: "table_id = ? AND status = ? AND COALESCE(lan_origin,'self') = 'self'",
          whereArgs: [targetTableId, 'open'], limit: 1);
    }

    test('Hedef masa LAN ise -> boş döner (self item LAN satırına bağlanmaz)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'LAN-9', 'table_id': 9, 'status': 'open',
        'lan_origin': 'lan', 'owner_device_id': 'device-C', 'synced': 1,
      });
      expect(await moveTargetQuery(9), isEmpty);
    });
  });

  group('D1 — getLocalTicketWithSection (PRINT KALBI): LAN satırı girmez', () {
    Future<List<Map<String, dynamic>>> printQuery(int ticketId) {
      return db.rawQuery('''
        SELECT * FROM local_tickets t
         WHERE (t.local_id = ? OR t.server_id = ?) AND COALESCE(t.lan_origin,'self') = 'self'
      ORDER BY (t.server_id = ?) DESC, t.local_id ASC LIMIT 1
      ''', [ticketId, ticketId, ticketId]);
    }

    test('LAN satırının local_id ile print sorgusu -> BOŞ (yanlış fiş çıkmaz)', () async {
      final lanId = await db.insert('local_tickets', {
        'ticket_number': 'LAN-P', 'table_id': 11, 'status': 'open',
        'lan_origin': 'lan', 'owner_device_id': 'device-D', 'synced': 1,
      });
      expect(await printQuery(lanId), isEmpty);
    });

    test('Self satırının local_id ile print sorgusu -> döner (fiş çıkar)', () async {
      final selfId = await db.insert('local_tickets', {
        'ticket_number': 'SELF-P', 'table_id': 11, 'status': 'open', 'lan_origin': 'self',
      });
      expect((await printQuery(selfId)).length, 1);
    });
  });

  group('K2/K3 — pruneLanTickets: yalnızca lan_origin=lan silinir, self korunur', () {
    Future<void> pruneLanTickets(Set<String> active) async {
      final all = await db.query('local_tickets',
          columns: ['local_id', 'ticket_number'], where: "lan_origin = 'lan'");
      for (final t in all) {
        final tn = t['ticket_number']?.toString();
        if (tn == null || !active.contains(tn)) {
          await db.delete('local_tickets', where: 'local_id = ?', whereArgs: [t['local_id']]);
        }
      }
    }

    test('prune(const {}) -> TÜM LAN satırları silinir, self+NULL korunur', () async {
      await db.insert('local_tickets', {'ticket_number': 'LAN-1', 'table_id': 1, 'status': 'open', 'lan_origin': 'lan'});
      await db.insert('local_tickets', {'ticket_number': 'LAN-2', 'table_id': 2, 'status': 'open', 'lan_origin': 'lan'});
      await db.insert('local_tickets', {'ticket_number': 'SELF-1', 'table_id': 3, 'status': 'open', 'lan_origin': 'self'});
      await db.insert('local_tickets', {'ticket_number': 'OLD-1', 'table_id': 4, 'status': 'open', 'lan_origin': null});

      await pruneLanTickets(const {});

      final remaining = await db.query('local_tickets', columns: ['ticket_number', 'lan_origin']);
      final numbers = remaining.map((r) => r['ticket_number']).toSet();
      expect(numbers, {'SELF-1', 'OLD-1'}); // sadece LAN'lar gitti
      expect(numbers.contains('LAN-1'), isFalse);
      expect(numbers.contains('LAN-2'), isFalse);
    });

    test('prune(active) -> aktif olmayan LAN silinir, aktif LAN kalır', () async {
      await db.insert('local_tickets', {'ticket_number': 'LAN-KEEP', 'table_id': 1, 'status': 'open', 'lan_origin': 'lan'});
      await db.insert('local_tickets', {'ticket_number': 'LAN-DROP', 'table_id': 2, 'status': 'open', 'lan_origin': 'lan'});

      await pruneLanTickets({'LAN-KEEP'});

      final numbers = (await db.query('local_tickets', columns: ['ticket_number']))
          .map((r) => r['ticket_number']).toSet();
      expect(numbers, {'LAN-KEEP'});
    });
  });

  group('getOfflineClosedTableIds — LAN kapalı satır self akışa girmez', () {
    Future<Set<int>> closedTableIds() async {
      final results = await db.query('local_tickets',
          columns: ['table_id'],
          where: "status IN ('closed', 'voided') AND server_id IS NULL AND COALESCE(lan_origin,'self') = 'self'");
      return results.map((r) => r['table_id'] as int).toSet();
    }

    test('LAN kapalı satır -> closed set DIŞINDA', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'LAN-CL', 'table_id': 20, 'status': 'closed',
        'lan_origin': 'lan', 'server_id': null,
      });
      await db.insert('local_tickets', {
        'ticket_number': 'SELF-CL', 'table_id': 21, 'status': 'closed',
        'lan_origin': 'self', 'server_id': null,
      });
      expect(await closedTableIds(), {21}); // sadece self
    });
  });

  group('getOfflineOpenTableIds — LAN masa UI DOLU gösterimi (İSTENEN)', () {
    // Bu sorgu BİLEREK LAN satırlarını dahil eder (server_id NULL) -> masa dolu görünür.
    Future<Set<int>> openTableIds() async {
      final results = await db.query('local_tickets',
          columns: ['table_id'], where: "status = 'open' AND server_id IS NULL");
      return results.map((r) => r['table_id'] as int).toSet();
    }

    test('LAN açık masa -> open set İÇİNDE (UI dolu görünür, doğru)', () async {
      await db.insert('local_tickets', {
        'ticket_number': 'LAN-OP', 'table_id': 30, 'status': 'open',
        'lan_origin': 'lan', 'server_id': null,
      });
      expect((await openTableIds()).contains(30), isTrue);
    });
  });

  group('getSelfOpenTicketsForLan — sadece kendi masalarını yayınlar', () {
    Future<List<Map<String, dynamic>>> selfForLan() {
      return db.rawQuery('''
        SELECT ticket_number, table_id, table_number, status, total
          FROM local_tickets
         WHERE status = 'open' AND COALESCE(lan_origin,'self') = 'self'
      ''');
    }

    test('LAN yansıması yayınlanmaz (yankı önlenir), self+NULL yayınlanır', () async {
      await db.insert('local_tickets', {'ticket_number': 'SELF-Y', 'table_id': 1, 'status': 'open', 'lan_origin': 'self'});
      await db.insert('local_tickets', {'ticket_number': 'OLD-Y', 'table_id': 2, 'status': 'open', 'lan_origin': null});
      await db.insert('local_tickets', {'ticket_number': 'LAN-Y', 'table_id': 3, 'status': 'open', 'lan_origin': 'lan'});

      final published = (await selfForLan()).map((r) => r['ticket_number']).toSet();
      expect(published, {'SELF-Y', 'OLD-Y'});
      expect(published.contains('LAN-Y'), isFalse); // yankı YOK
    });
  });
}
