// 28 Eki 2026 — KALEM BOLME ("Bol") cevrimdisi katmani: v24 gecisi (uretim fonksiyonu, gercek
// sqlite) + KAYNAK KILITLERI (fiziksel okuyucular parca satirini suzer, ayna split_* yazar,
// fisler katlar/suzer). Repo deseni: ozet_fis_gizle_test / combo_group_migration_test.
//
// Kilitlenen kurallar:
//   1) v24: 3 kolon eklenir, SAHADAKI ACIK ADISYON KALEMLERI KAYBOLMAZ, varsayilan NULL
//      (= bolunmemis, bugunku davranis), idempotent, tablo yoksa FIRLATIR (surum 23 korunur).
//   2) Para okuyucu (SUM unit_price*quantity) parcayi DAHIL eder; fiziksel okuyucu
//      (split_parent_id IS NULL) yalniz ana satiri doner.
//   3) getUnprintedLocalItems (cevrimdisi mutfak fisi) ve getPendingOrdersOffline (masa takip)
//      sorgulari parca satirini suzer; upsertServerTicket split_* alanlarini yazar.
//   4) printer_service: kasa fisi parcalari ana satira KATLAR; mutfak + ozet fisi parcayi SUZER.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/local_db_service.dart';

void main() {
  group('v24 GEÇİŞİ — üretim kodu, gerçek sqlite', () {
    late Database db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    Future<void> v23Semasi() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE local_ticket_items (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          local_ticket_id INTEGER NOT NULL,
          product_id INTEGER NOT NULL,
          product_name TEXT NOT NULL,
          quantity INTEGER DEFAULT 1,
          unit_price REAL NOT NULL,
          status TEXT DEFAULT 'pending',
          created_at TEXT NOT NULL
        )
      ''');
      // Sahada acik masa: 200 TL Adana (goc sirasinda KAYBOLMAMALI)
      await db.insert('local_ticket_items', {
        'local_ticket_id': 1, 'product_id': 24, 'product_name': 'Adana', 'quantity': 1,
        'unit_price': 200, 'status': 'active', 'created_at': '2026-10-28T10:00:00',
      });
    }

    Future<Set<String>> kolonlar() async {
      final r = await db.rawQuery('PRAGMA table_info(local_ticket_items)');
      return r.map((k) => (k['name'] ?? '').toString()).toSet();
    }

    tearDown(() async => db.close());

    test('3 kolonu ekler, mevcut veriyi KORUR, varsayılan NULL (bölünmemiş)', () async {
      await v23Semasi();
      await LocalDbService.migrasyonV24(db);
      expect((await kolonlar()).containsAll(['split_parent_id', 'split_seq', 'split_parts']), isTrue);
      final r = await db.query('local_ticket_items');
      expect(r.length, 1);
      expect(r.first['product_name'], 'Adana');
      expect(r.first['unit_price'], 200.0);
      expect(r.first['split_parent_id'], isNull);
      expect(r.first['split_seq'], isNull);
      expect(r.first['split_parts'], isNull);
    });

    test('idempotent: iki kez çağrılabilir, veri yine durur', () async {
      await v23Semasi();
      await LocalDbService.migrasyonV24(db);
      await LocalDbService.migrasyonV24(db);
      expect((await kolonlar()).contains('split_seq'), isTrue);
      expect((await db.query('local_ticket_items')).length, 1);
    });

    test('tablo yoksa FIRLATIR — sürüm 23 korunur, sessiz geçmez', () async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      expect(() => LocalDbService.migrasyonV24(db), throwsA(isA<StateError>()));
    });

    test('ayna: parça satırı yazılır; fiziksel süzgeç yalnız ANA satırı döner, para toplamı DEĞİŞMEZ',
        () async {
      await v23Semasi();
      await LocalDbService.migrasyonV24(db);
      // Sunucu: ana satir ilk payi tutar (100, seq 1/2), parca satiri 100 (seq 2/2, parent=1).
      // upsertServerTicket ile AYNI alan donusumu (splitTamSayi) — sunucu int VEYA String gonderebilir.
      await db.update('local_ticket_items', {
        'unit_price': 100,
        'split_parent_id': LocalDbService.splitTamSayi(null),
        'split_seq': LocalDbService.splitTamSayi(1),
        'split_parts': LocalDbService.splitTamSayi('2'),
      }, where: 'local_id = 1');
      await db.insert('local_ticket_items', {
        'local_ticket_id': 1, 'product_id': 24, 'product_name': 'Adana', 'quantity': 1,
        'unit_price': 100, 'status': 'active', 'created_at': '2026-10-28T10:00:00',
        'split_parent_id': LocalDbService.splitTamSayi('1'),
        'split_seq': LocalDbService.splitTamSayi(2),
        'split_parts': LocalDbService.splitTamSayi(2),
      });
      final fiziksel = await db.rawQuery(
          "SELECT local_id FROM local_ticket_items WHERE status != 'cancelled' AND split_parent_id IS NULL");
      expect(fiziksel.map((r) => r['local_id']).toList(), [1]);
      final para = await db.rawQuery(
          "SELECT SUM(unit_price * quantity) AS t FROM local_ticket_items WHERE status != 'cancelled'");
      expect((para.first['t'] as num).toDouble(), 200.0);
    });

    test('splitTamSayi: int / num / String / boş / bozuk', () {
      expect(LocalDbService.splitTamSayi(5), 5);
      expect(LocalDbService.splitTamSayi(5.0), 5);
      expect(LocalDbService.splitTamSayi('187'), 187);
      expect(LocalDbService.splitTamSayi(null), isNull);
      expect(LocalDbService.splitTamSayi(''), isNull);
      expect(LocalDbService.splitTamSayi('abc'), isNull);
    });
  });

  group('KAYNAK KİLİTLERİ — fiziksel okuyucular parça satırını saymaz', () {
    final db = File('lib/services/local_db_service.dart').readAsStringSync();

    test('_onUpgrade v24 adımı + sürüm 24 + CREATE TABLE kolonları', () {
      expect(db.contains('if (oldVersion < 24) {\n      await migrasyonV24(db);'), isTrue);
      expect(db.contains('version: 24,'), isTrue);
      expect(
          db.contains('split_parent_id INTEGER,\n        split_seq INTEGER,\n        split_parts INTEGER,'),
          isTrue);
    });

    test('getUnprintedLocalItems (çevrimdışı mutfak fişi) parça satırını süzer', () {
      final p = db.substring(db.indexOf('getUnprintedLocalItems(int localTicketId)'));
      final sorgu = p.substring(0, p.indexOf('ORDER BY i.created_at'));
      expect(sorgu.contains('AND i.split_parent_id IS NULL'), isTrue);
    });

    test('getPendingOrdersOffline (masa takip) parça satırını süzer', () {
      final p = db.substring(db.indexOf('getPendingOrdersOffline()'));
      final sorgu = p.substring(0, p.indexOf('ORDER BY i.created_at'));
      expect(sorgu.contains('AND i.split_parent_id IS NULL'), isTrue);
    });

    test('upsertServerTicket aynası split_* alanlarını yazar', () {
      final p = db.substring(db.indexOf('Future<void> upsertServerTicket('));
      final govde = p.substring(0, p.indexOf("opName: 'upsertServerTicket'"));
      expect(govde.contains("'split_parent_id': splitTamSayi(it['split_parent_id'])"), isTrue);
      expect(govde.contains("'split_seq': splitTamSayi(it['split_seq'])"), isTrue);
      expect(govde.contains("'split_parts': splitTamSayi(it['split_parts'])"), isTrue);
    });

    test('printer_service: kasa fişi KATLAR, mutfak + özet fişi SÜZER', () {
      final ps = File('lib/services/printer_service.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final kasa = ps.substring(ps.indexOf('Future<List<int>> _generateTicketReceipt('),
          ps.indexOf('Future<List<int>> _generateOrderReceipt('));
      expect(kasa.contains('KalemBolme.parcalariAnaSatiraKatla(items)'), isTrue);
      final mutfak = ps.substring(ps.indexOf('Future<List<int>> _generateKitchenReceipt('),
          ps.indexOf('Future<bool> printClosingReceipt('));
      expect(mutfak.contains('KalemBolme.parcasiz(items)'), isTrue);
      expect(mutfak.contains("'Toplam \${_mKalemler.length} urun'"), isTrue);
      final ozet = ps.substring(ps.indexOf('Future<List<int>> _generateClosingReceipt('));
      expect(ozet.contains('KalemBolme.parcasiz(items)'), isTrue);
    });

    test('api_service.splitItem: çevrimdışında reddeder, kuyruğa ALMAZ', () {
      final api = File('lib/services/api_service.dart').readAsStringSync();
      final p = api.substring(api.indexOf('Future<Map<String, dynamic>> splitItem('));
      final govde = p.substring(0, p.indexOf('Future<Map<String, dynamic>> moveItem('));
      expect(govde.contains("'Bölme için internet gerekli'"), isTrue);
      expect(govde.contains('/split'), isTrue);
      expect(govde.contains('enqueueServerTicketAction'), isFalse);
      expect(govde.contains('addToSyncQueue'), isFalse);
    });

    test('ORTA-3: deleteTicketItem / moveItem 400-409 reddinde offline kuyruğa DÜŞMEZ, grup id\'lerini yerele yansıtır', () {
      final api = File('lib/services/api_service.dart').readAsStringSync();
      // yalnız 400/409 iş kuralı reddi; 404 / 5xx / ağ hatası eski offline yol
      final red = api.substring(api.indexOf('Map<String, dynamic>? _isKuraliReddi(DioException e)'));
      expect(red.substring(0, red.indexOf('Future<Map<String, dynamic>> deleteTicketItem(')).contains('if (sc != 400 && sc != 409) return null;'), isTrue);
      final del = api.substring(api.indexOf('Future<Map<String, dynamic>> deleteTicketItem('),
          api.indexOf('_resolveLocalTicketAndItem(int ticketId, int itemId) async'));
      expect(del.contains('final red = _isKuraliReddi(e);'), isTrue);
      expect(del.indexOf('return red;'), lessThan(del.indexOf('enqueueServerTicketAction')));
      expect(del.contains("cancelled_item_ids"), isTrue);
      expect(del.contains('cancelLocalItemsByServerIds('), isTrue);
      final mv = api.substring(api.indexOf('Future<Map<String, dynamic>> moveItem('),
          api.indexOf('Future<Map<String, dynamic>> transferTable('));
      expect(mv.contains('final red = _isKuraliReddi(e);'), isTrue);
      expect(mv.indexOf('return red;'), lessThan(mv.indexOf('addToSyncQueue')));
      expect(mv.contains("moved_item_ids"), isTrue);
      // çağıranlar success:false'ı başarı saymaz
      final modal = File('lib/widgets/add_item_modal.dart').readAsStringSync();
      final iptal = modal.substring(modal.indexOf('Future<void> _cancelSelectedItem()'),
          modal.indexOf('Future<void> _sendToKitchen()'));
      expect(iptal.contains("if (cancelResponse['success'] == false) {"), isTrue);
      final tm = File('lib/widgets/ticket_modal.dart').readAsStringSync().replaceAll('\r\n', '\n');
      expect(tm.contains("if (silme['success'] == false) {"), isTrue);
    });
  });
}
