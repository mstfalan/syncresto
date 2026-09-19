// 19 Eyl 2026 — ÇEVRİMDIŞI FİŞTE SEÇİM (extras) KAYBI — regresyon testleri.
//
// Olay: Green Chef masa 33, adisyon 260919-7263. POS o an çevrimdışıydı; mutfak fişinde
// "Yanına Yandan Ürün Var" notu çıktı ama "Ürün Seçimi: SYC (+10)" ÇIKMADI.
// Kök neden: offline kalem sorgusu (getUnprintedLocalItems) `extras` kolonunu hiç
// okumuyordu; fiş üreticisi de yalnız `extras is List` ise seçim satırı basıyordu.
//
// 🔴 Bu testin ASIL amacı GERİ UYUMLULUK: seçimi olmayan kalemlerde fiş satırları
// BİREBİR eskisi gibi kalmalı (fiş akışı bozulamaz kuralı).
//
// Repo deseni (ikram_offline_db_test.dart): LocalDbService doğrudan test edilemez
// (path_provider platform kanalı ister) → şeması + SORGUSU BİREBİR kopyalanıp gerçek
// sqlite (ffi) üzerinde doğrulanır. Saf mantık (extras biçim kabulü) ise canlı koddaki
// _extrasListesi / _decodeJsonList ile AYNI kural.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// printer_service.dart:_extrasListesi ile AYNI kural.
List<dynamic> extrasListesi(dynamic v) {
  if (v is List) return v;
  if (v is String && v.trim().isNotEmpty) {
    try {
      final d = jsonDecode(v);
      return d is List ? d : const [];
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

/// local_db_service.dart:_decodeJsonList ile AYNI kural.
List<dynamic> decodeJsonList(dynamic v) {
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

/// _generateKitchenReceipt'in SEÇİM bloğunun metin karşılığı (bayt yerine satır dizisi;
/// ESC/POS baytları aynı satırlardan üretildiği için satır eşitliği = çıktı eşitliği).
/// Kural: grup adı varsa başlık + girintili "+ ad"; grupsuz/çıkarılan → düz satır.
List<String> mutfakSecimSatirlari(dynamic extrasRaw, {bool grupBasliklari = true}) {
  final out = <String>[];
  final ex = extrasListesi(extrasRaw);
  if (ex.isEmpty) return out;
  String sonGrup = '';
  for (final e in ex) {
    var ad = (e is Map)
        ? (e['name'] ?? e['label'] ?? e['title'] ?? '').toString().trim()
        : (e?.toString() ?? '');
    final grp = (e is Map) ? (e['group'] ?? '').toString().trim() : '';
    final cikar = ad.startsWith('-');
    if (cikar) ad = ad.substring(1).trim();
    if (ad.isEmpty) continue;
    if (grupBasliklari && grp.isNotEmpty && !cikar) {
      if (grp != sonGrup) {
        out.add('   $grp:');
        sonGrup = grp;
      }
      out.add('      + $ad');
    } else {
      sonGrup = '';
      out.add(cikar ? '   CIKAR: $ad' : '   + $ad');
    }
  }
  return out;
}

/// local_db_service.dart v22 — cevrimdisi mutfak fisi kalem sorgusu (BİREBİR kopya).
const _sorgu = '''
      SELECT i.local_id, i.server_id, i.product_id, i.product_name, i.quantity,
             i.unit_price, i.notes, i.portion, i.created_at,
             i.extras,
             COALESCE(p.skip_pos_print, i.skip_pos_print, 0) AS skip_pos_print,
             i.combo_group_id, i.combo_group_name, i.combo_pick_name,
             COALESCE(wa.name, i.added_by_name) AS added_by_name,
             p.printer_id,
             p.id AS cached_product_id
        FROM local_ticket_items i
   LEFT JOIN cached_products p ON p.id = i.product_id
   LEFT JOIN cached_waiters wa ON wa.id = i.added_by
       WHERE i.local_ticket_id = ?
         AND i.printed = 0
         AND (i.status IS NULL OR i.status != 'cancelled')
       ORDER BY i.created_at
''';

void main() {
  group('FİŞ ÇIKTISI DEĞİŞMEMELİ — seçimsiz kalem', () {
    test('extras null ile extras [] AYNI çıktıyı verir (satır yok)', () {
      expect(mutfakSecimSatirlari(null), mutfakSecimSatirlari(<dynamic>[]));
      expect(mutfakSecimSatirlari(null), isEmpty);
    });

    test('boş JSON metni "[]" de satır üretmez', () {
      expect(mutfakSecimSatirlari('[]'), isEmpty);
    });

    test('bozuk JSON metni fişi düşürmez, satır da üretmez', () {
      expect(mutfakSecimSatirlari('xx{bozuk'), isEmpty);
      expect(mutfakSecimSatirlari('{"name":"SYC"}'), isEmpty); // liste değil → yok say
    });
  });

  group('SEÇİM BASILIR — liste ve JSON metin AYNI sonucu verir', () {
    final secim = [
      {'name': 'SYC', 'group': 'Ürün Seçimi', 'price': 10},
    ];

    test('olaydaki kalem: grup başlığı + seçim satırı', () {
      expect(mutfakSecimSatirlari(secim), ['   Ürün Seçimi:', '      + SYC']);
    });

    test('JSON METİN (çevrimdışı SQLite biçimi) liste ile birebir aynı', () {
      expect(mutfakSecimSatirlari(jsonEncode(secim)), mutfakSecimSatirlari(secim));
    });

    test('grupsuz eski veri düz satır olarak basılır (geri uyumluluk)', () {
      expect(mutfakSecimSatirlari([
        {'name': 'Ekstra Peynir'}
      ]), ['   + Ekstra Peynir']);
    });

    test('çıkarılan malzeme CIKAR: olarak basılır, grup başlığı almaz', () {
      expect(mutfakSecimSatirlari([
        {'name': '-Sogan', 'group': 'Ürün Seçimi'}
      ]), ['   CIKAR: Sogan']);
    });
  });

  group('MIGRATION v21 → v22 (gerçek sqlite)', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    test('ALTER mevcut satırları korur, yeni kolon 0 olur; ikinci kez çalışması zararsız', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // v21 hâli: skip_pos_print kolonu YOK
      await db.execute('''
        CREATE TABLE cached_products (
          id INTEGER PRIMARY KEY, name TEXT, printer_id INTEGER,
          hide_from_tracking INTEGER DEFAULT 0, cached_at TEXT NOT NULL
        )
      ''');
      await db.insert('cached_products',
          {'id': 24, 'name': 'Dağ Kekikli Tavuk', 'printer_id': 3, 'cached_at': 'x'});

      await db.execute('ALTER TABLE cached_products ADD COLUMN skip_pos_print INTEGER DEFAULT 0');

      final kolonlar = await db.rawQuery('PRAGMA table_info(cached_products)');
      expect(kolonlar.any((k) => k['name'] == 'skip_pos_print'), isTrue);

      final satir = (await db.query('cached_products')).first;
      expect(satir['name'], 'Dağ Kekikli Tavuk'); // eski veri korundu
      expect(satir['skip_pos_print'], 0); // DEFAULT geriye dönük uygulanır

      // aynı ALTER ikinci kez: hata verir ama yakalanır, kolon doğrulaması yine geçer
      await expectLater(
        db.execute('ALTER TABLE cached_products ADD COLUMN skip_pos_print INTEGER DEFAULT 0'),
        throwsA(isA<DatabaseException>()),
      );
      final k2 = await db.rawQuery('PRAGMA table_info(cached_products)');
      expect(k2.where((k) => k['name'] == 'skip_pos_print').length, 1);
      await db.close();
    });
  });

  group('ÇEVRİMDIŞI SORGU (gerçek sqlite) — v22', () {
    late Database db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE local_ticket_items (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          server_id INTEGER, local_ticket_id INTEGER, product_id INTEGER,
          product_name TEXT, quantity INTEGER, unit_price REAL, notes TEXT,
          extras TEXT, portion TEXT, printed INTEGER DEFAULT 0, status TEXT,
          added_by INTEGER, added_by_name TEXT, created_at TEXT,
          skip_pos_print INTEGER DEFAULT 0,
          combo_group_id TEXT, combo_group_name TEXT, combo_pick_name TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE cached_products (
          id INTEGER PRIMARY KEY, name TEXT, printer_id INTEGER,
          skip_pos_print INTEGER DEFAULT 0, cached_at TEXT
        )
      ''');
      await db.execute('CREATE TABLE cached_waiters (id INTEGER PRIMARY KEY, name TEXT)');

      await db.insert('cached_products',
          {'id': 24, 'name': 'Dağ Kekikli Tavuk', 'printer_id': 3, 'skip_pos_print': 0, 'cached_at': 'x'});
      await db.insert('cached_products',
          {'id': 161, 'name': 'Didi', 'printer_id': 7, 'skip_pos_print': 1, 'cached_at': 'x'});
      await db.insert('cached_waiters', {'id': 11, 'name': 'Zafer'});
    });

    tearDown(() async => db.close());

    Future<void> kalemEkle(Map<String, Object?> v) => db.insert('local_ticket_items', {
          'local_ticket_id': 9070,
          'quantity': 1,
          'printed': 0,
          'status': 'active',
          'added_by': 11,
          'created_at': '2026-09-19T20:20:08',
          ...v,
        });

    test('extras JSON metni sorgudan gelir ve listeye çevrilir', () async {
      await kalemEkle({
        'product_id': 24,
        'product_name': 'Dağ Kekikli Tavuk',
        'extras': jsonEncode([
          {'name': 'SYC', 'group': 'Ürün Seçimi', 'price': 10}
        ]),
        'notes': 'Yanına Yandan Ürün Var',
      });

      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r.length, 1);
      // sqflite satırı SALT OKUNUR → kopyala (canlı koddaki desen)
      final m = Map<String, dynamic>.from(r.first);
      m['extras'] = decodeJsonList(m['extras']);

      expect(m['extras'], isA<List>());
      expect((m['extras'] as List).first['name'], 'SYC');
      expect(m['notes'], 'Yanına Yandan Ürün Var');
      expect(m['printer_id'], 3);
      expect(mutfakSecimSatirlari(m['extras']), ['   Ürün Seçimi:', '      + SYC']);
    });

    test('kopyalamadan yazmak HATA verir (fişi düşüren tuzak)', () async {
      await kalemEkle({'product_id': 24, 'product_name': 'Dağ Kekikli Tavuk', 'extras': '[]'});
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(() => r.first['extras'] = const [], throwsUnsupportedError);
    });

    test('skip_pos_print ÜRÜNDEN gelir (çevrimdışı eklenen kalemde 0 olsa bile)', () async {
      await kalemEkle({'product_id': 161, 'product_name': 'Didi', 'skip_pos_print': 0});
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r.first['skip_pos_print'], 1); // ürün bayrağı kazanır → mutfağa basılmaz
    });

    test('ürün önbellekte yoksa kalem bayrağına düşer, yoksa 0', () async {
      await kalemEkle({'product_id': 999, 'product_name': 'Bilinmeyen', 'skip_pos_print': 1});
      await kalemEkle({'product_id': 998, 'product_name': 'Bilinmeyen2'});
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r[0]['skip_pos_print'], 1);
      expect(r[1]['skip_pos_print'], 0);
    });

    test('combo kolonları artık sorguda (offline gruplama çalışsın)', () async {
      await kalemEkle({
        'product_id': 24,
        'product_name': 'Dağ Kekikli Tavuk',
        'combo_group_id': 'cg1',
        'combo_group_name': 'Menü',
        'combo_pick_name': 'Ayran',
      });
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r.first['combo_group_id'], 'cg1');
      expect(r.first['combo_group_name'], 'Menü');
      expect(r.first['combo_pick_name'], 'Ayran');
    });

    test('ürün önbellekte yoksa cached_product_id NULL gelir (varsayılan yazıcı dalı)', () async {
      await kalemEkle({'product_id': 555, 'product_name': 'Pasif Urun'});
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r.first['cached_product_id'], isNull);
      expect(r.first['printer_id'], isNull); // ikisi birlikte = "urun cache'te yok"
    });

    test('iptal ve basılmış kalemler yine dışarıda (davranış değişmedi)', () async {
      await kalemEkle({'product_id': 24, 'product_name': 'A', 'status': 'cancelled'});
      await kalemEkle({'product_id': 24, 'product_name': 'B', 'printed': 1});
      await kalemEkle({'product_id': 24, 'product_name': 'C'});
      final r = await db.rawQuery(_sorgu, [9070]);
      expect(r.map((e) => e['product_name']).toList(), ['C']);
    });
  });
}
