// 3 Agu 2026 — IKRAM cevrimdisi katman testleri (gercek sqlite, ffi).
//
// Repo deseni (bkz. sync_404_idempotent_test.dart): LocalDbService dogrudan test
// edilemez (path_provider platform kanali ister) -> semasi + SORGULARI BIREBIR
// kopyalanip gercek sqlite uzerinde dogrulanir. Guard/kural mantigi ise kopya DEGIL:
// IkramRules canli kodun kendisidir.
//
// Kapsam:
//   1) v20 cached_ikram_reasons / cached_cancel_reasons: yazma guard'i (is_active
//      esnek 0/1) + okuma sirasi — OFFLINE SEBEP LISTESI OKUNABILIYOR kaniti
//   2) recalcTicketTotals v20 sorgusu: ikram kalem TAHSILATTAN DUSUYOR; iptal harici;
//      eski satirlarda is_ikram NULL -> COALESCE guard'i normal sayar
//   3) closeLocalTicket formulu: total = subtotal(ikramsiz) - discount
//   4) geri alma: is_ikram tekrar 0 -> tutar geri gelir

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/ikram_rules.dart';

/// local_db_service.dart v20 _onCreate/_onUpgrade ile AYNI sema
const _semaSebep = '''
  CREATE TABLE cached_ikram_reasons (
    id INTEGER PRIMARY KEY,
    reason TEXT NOT NULL,
    sort_order INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1,
    cached_at TEXT NOT NULL
  )
''';

/// local_db_service.dart local_ticket_items v20 kolonlariyla (test icin sadeltilmis —
/// kullanilan kolonlar birebir ayni adda)
const _semaItems = '''
  CREATE TABLE local_ticket_items (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    local_ticket_id INTEGER NOT NULL,
    product_name TEXT NOT NULL,
    quantity INTEGER DEFAULT 1,
    unit_price REAL NOT NULL,
    status TEXT DEFAULT 'pending',
    is_ikram INTEGER DEFAULT 0,
    ikram_reason TEXT
  )
''';

/// local_db_service._cacheReasonTable ile AYNI yazma mantigi (guard IkramRules.bayrak
/// uzerinden — canli kodla ayni cagri).
Future<void> _sebepYaz(Database db, List<Map<String, dynamic>> rows) async {
  await db.delete('cached_ikram_reasons');
  for (final r in rows) {
    final reason = (r['reason'] ?? '').toString().trim();
    if (reason.isEmpty) continue;
    final act = r['is_active'];
    await db.insert('cached_ikram_reasons', {
      'id': r['id'],
      'reason': reason,
      'sort_order': r['sort_order'] ?? 0,
      'is_active': (act == null || IkramRules.bayrak(act)) ? 1 : 0,
      'cached_at': '2026-08-03T10:00:00',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// local_db_service._getReasonTable ile AYNI okuma sorgusu
Future<List<Map<String, Object?>>> _sebepOku(Database db) =>
    db.query('cached_ikram_reasons', where: 'is_active = 1', orderBy: 'sort_order ASC, id ASC');

/// local_db_service.recalcTicketTotals v20 ile AYNI SUM sorgusu
Future<double> _subtotal(Database db, int ticketId) async {
  final r = await db.rawQuery('''
      SELECT COALESCE(SUM(unit_price * quantity), 0) AS sub
        FROM local_ticket_items
       WHERE local_ticket_id = ? AND status != 'cancelled'
         AND COALESCE(is_ikram, 0) != 1
    ''', [ticketId]);
  return (r.first['sub'] as num).toDouble();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute(_semaSebep);
    await db.execute(_semaItems);
  });
  tearDown(() async => db.close());

  group('cached_ikram_reasons — offline sebep listesi', () {
    test('yaz + oku: sadece aktifler, sort_order sirali (OFFLINE OKUMA KANITI)', () async {
      await _sebepYaz(db, [
        {'id': 1, 'reason': 'VIP müşteri', 'sort_order': 2, 'is_active': 1},
        {'id': 2, 'reason': 'Pasif', 'sort_order': 0, 'is_active': 0},
        {'id': 3, 'reason': 'Doğum günü', 'sort_order': 1, 'is_active': true},
      ]);
      final rows = await _sebepOku(db);
      expect(rows.map((r) => r['reason']).toList(), ['Doğum günü', 'VIP müşteri']);
    });

    test("SQLite BOOLEAN tuzagi: is_active '1'/'true'/'t' string gelse de 0/1 yazilir", () async {
      await _sebepYaz(db, [
        {'id': 1, 'reason': 'A', 'is_active': '1'},
        {'id': 2, 'reason': 'B', 'is_active': 'true'},
        {'id': 3, 'reason': 'C', 'is_active': 't'},
        {'id': 4, 'reason': 'D', 'is_active': 'false'},
      ]);
      final tum = await db.query('cached_ikram_reasons');
      // Yazilan degerler HER ZAMAN int 0/1 (esnek okuma guard'ina bile gerek kalmaz)
      for (final r in tum) {
        expect(r['is_active'], anyOf(0, 1));
      }
      final aktif = await _sebepOku(db);
      expect(aktif.map((r) => r['reason']).toList(), ['A', 'B', 'C']);
    });

    test('is_active alani gelmezse aktif kabul; bos reason yazilmaz', () async {
      await _sebepYaz(db, [
        {'id': 1, 'reason': 'Şikayet telafisi'},
        {'id': 2, 'reason': '   '},
      ]);
      final rows = await _sebepOku(db);
      expect(rows.length, 1);
      expect(rows.first['reason'], 'Şikayet telafisi');
    });

    test('yeniden yazim eskiyi temizler (delete+insert deseni — bayat kayit kalmaz)', () async {
      await _sebepYaz(db, [{'id': 1, 'reason': 'Eski', 'is_active': 1}]);
      await _sebepYaz(db, [{'id': 2, 'reason': 'Yeni', 'is_active': 1}]);
      final rows = await _sebepOku(db);
      expect(rows.length, 1);
      expect(rows.first['reason'], 'Yeni');
    });
  });

  group('recalcTicketTotals v20 — ikram tutari tahsilattan DUSUYOR', () {
    Future<void> kalem(int tid, String ad, double fiyat, int adet,
        {int? ikram, String status = 'active'}) async {
      await db.insert('local_ticket_items', {
        'local_ticket_id': tid,
        'product_name': ad,
        'quantity': adet,
        'unit_price': fiyat,
        'status': status,
        'is_ikram': ikram, // null birakilabilir (eski satir simulasyonu)
      });
    }

    test('ikram kalem subtotala girmez, normal + iptal kurallari korunur', () async {
      await kalem(1, 'Çay', 40, 2);                      // 80 tahsil
      await kalem(1, 'Künefe', 150, 1, ikram: 1);        // IKRAM — dusulur
      await kalem(1, 'Kola', 60, 1, status: 'cancelled'); // iptal — zaten haric
      await kalem(1, 'Su', 20, 1, ikram: 0);             // normal
      expect(await _subtotal(db, 1), 100.0); // 80 + 20
    });

    test('ESKI satirlarda is_ikram NULL -> COALESCE guard normal sayar (regresyon yok)', () async {
      await kalem(1, 'Pide', 200, 1); // is_ikram NULL
      expect(await _subtotal(db, 1), 200.0);
    });

    test('tum kalemler ikram -> tahsil edilecek 0', () async {
      await kalem(1, 'Baklava', 120, 1, ikram: 1);
      await kalem(1, 'Çay', 40, 2, ikram: 1);
      expect(await _subtotal(db, 1), 0.0);
    });

    test('GERI ALMA: is_ikram tekrar 0 -> tutar geri gelir', () async {
      await kalem(1, 'Künefe', 150, 1, ikram: 1);
      expect(await _subtotal(db, 1), 0.0);
      await db.update('local_ticket_items', {'is_ikram': 0, 'ikram_reason': null},
          where: 'local_ticket_id = 1');
      expect(await _subtotal(db, 1), 150.0);
    });

    test('closeLocalTicket formulu: total = subtotal(ikramsiz) - discount', () async {
      await kalem(1, 'Adana', 300, 2);              // 600
      await kalem(1, 'Ayran', 50, 2, ikram: 1);     // ikram 100 — dusulur
      final subtotal = await _subtotal(db, 1);
      const discount = 50.0;
      final total = subtotal - discount; // closeLocalTicket ile AYNI formul
      expect(subtotal, 600.0);
      expect(total, 550.0);
    });

    test('baska ticketin ikrami bu ticketi etkilemez (multi-ticket izolasyon)', () async {
      await kalem(1, 'Çay', 40, 1);
      await kalem(2, 'Künefe', 150, 1, ikram: 1);
      expect(await _subtotal(db, 1), 40.0);
      expect(await _subtotal(db, 2), 0.0);
    });
  });
}
