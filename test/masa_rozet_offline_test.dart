// 19 Eyl 2026 — "MUTFAGA GITMEDI" sahte rozeti (cevrimdisi).
//
// Kok sebep: masa takip ekraninin CEVRIMDISI kaynagi (getPendingOrdersOffline) skip_pos_print
// kolonunu HIC secmiyordu; ekran `r['skip_pos_print'] == true` diye bakiyordu. Icecek/su gibi
// mutfak yazicisina zaten gitmeyen urunler "basilmadi" sayilip masa karti kirmizi rozet aliyordu.
//
// Iki kural bu testte kilitlenir:
//   1) Sorgu skip_pos_print'i URUNDEN (v22 cached_products) dondurur.
//   2) Ekran karari SQLite'in 0/1 int bicimini de kabul eder (== true tek basina YETMEZ).
//
// Asagidaki SQL, lib/services/local_db_service.dart -> getPendingOrdersOffline icindeki sorgunun
// BIREBIR kopyasidir. Canli sorgu degisirse bu test once kirilmali.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/local_db_service.dart';

const String _sorgu = '''
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
        i.extras AS extras,
        i.delivered_at AS delivered_at,
        COALESCE(wd.name, i.delivered_by_name) AS delivered_by_name,
        COALESCE(wa.name, i.added_by_name) AS added_by_name,
        i.created_at AS item_created_at,
        COALESCE(cp.skip_pos_print, i.skip_pos_print, 0) AS skip_pos_print,
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
''';

/// tables_screen.dart `_refreshPendingCount` icindeki karar — birebir ayni ifade.
bool mutfagaGitmediMi(Map<String, Object?> r) {
  final isPrinted = r['printed'] == 1 || r['printed'] == true;
  final skipRaw = r['skip_pos_print'];
  final isSkip = skipRaw == true || skipRaw == 1 || skipRaw == '1' || skipRaw == 'true' || skipRaw == 't';
  return !isPrinted && !isSkip;
}

/// Canli sorguyu kaynaktan cikarir (yorumlar ve bosluklar normalize edilir).
String _canliSorguNormal() {
  final kaynak = File('lib/services/local_db_service.dart').readAsStringSync();
  final basla = kaynak.indexOf('getPendingOrdersOffline()');
  if (basla < 0) throw StateError('getPendingOrdersOffline bulunamadi');
  final acik = kaynak.indexOf("rawQuery('''", basla);
  final kapa = kaynak.indexOf("''')", acik);
  if (acik < 0 || kapa < 0) throw StateError('sorgu sinirlari bulunamadi');
  return _normalize(kaynak.substring(acik + "rawQuery('''".length, kapa));
}

String _normalize(String sql) => sql
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('--'))
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('SORGU KOPYASI CANLI KODLA AYNI KALSIN', () {
    test('testteki SQL, getPendingOrdersOffline ile birebir (yorumlar haric)', () {
      // Kopya test, canli sorgu degisince sessizce ayrisirdi; bu kontrol onu kirar.
      expect(_normalize(_sorgu), _canliSorguNormal());
    });

    test('urun bayragi > kalem bayragi onceligi canli kodda duruyor', () {
      expect(_canliSorguNormal(), contains('COALESCE(cp.skip_pos_print, i.skip_pos_print, 0)'));
    });

    test('_onUpgrade v22 adiminda migrasyonV22 CAGIRILIYOR', () {
      // Gecisin kendisi asagida gercek sqlite ile kosuluyor; burada yalnizca yukseltme
      // zincirine bagli oldugu dogrulanir (cagri dusarse eski kasalar kolonsuz kalir).
      final kaynak = File('lib/services/local_db_service.dart').readAsStringSync();
      final basla = kaynak.indexOf('if (oldVersion < 22)');
      expect(basla, greaterThan(0), reason: 'v22 adimi bulunamadi');
      expect(kaynak.substring(basla, basla + 120), contains('migrasyonV22(db)'));
    });

    test('addTicketItem kaleme skip_pos_print YAZMAYA devam ediyor (Fable B5)', () {
      // Bu satir silinirse cevrimdisi eklenen icecek, urun onbellekten dusunce sahte rozet alir.
      final kaynak = File('lib/services/local_db_service.dart').readAsStringSync();
      final basla = kaynak.indexOf('Future<int> addTicketItem');
      expect(basla, greaterThan(0), reason: 'addTicketItem bulunamadi');
      final govde = kaynak.substring(basla, basla + 3000);
      expect(govde, contains("'skip_pos_print': kalemSkipPosPrint"));
      expect(govde, contains("columns: ['skip_pos_print']"));
      expect(govde, contains('LocalDbService.skipBayragi('));
    });

    test('skipBayragi GERCEK kodu: tum bicimler tek kurala iner', () {
      // Metin taramasi degil — uretim fonksiyonu dogrudan cagriliyor.
      expect(LocalDbService.skipBayragi(1), 1);
      expect(LocalDbService.skipBayragi(true), 1);
      expect(LocalDbService.skipBayragi('1'), 1);
      expect(LocalDbService.skipBayragi('true'), 1);
      expect(LocalDbService.skipBayragi('t'), 1);
      expect(LocalDbService.skipBayragi(0), 0);
      expect(LocalDbService.skipBayragi(false), 0);
      expect(LocalDbService.skipBayragi('0'), 0);
      expect(LocalDbService.skipBayragi('f'), 0);
      expect(LocalDbService.skipBayragi(null), 0);
      expect(LocalDbService.skipBayragi('evet'), 0); // bilinmeyen deger = ATLAMA YOK (guvenli yon)
    });
  });

  v22GecisTestleri();

  group('EKRAN KARARI — skip_pos_print bicimleri', () {
    test('SQLite int 1 de atlanmis sayilir (sahte rozetin kok sebebi)', () {
      expect(mutfagaGitmediMi({'printed': 0, 'skip_pos_print': 1}), isFalse);
    });

    test('backend true, metin "1"/"true"/"t" ayni sonucu verir', () {
      for (final v in [true, 1, '1', 'true', 't']) {
        expect(mutfagaGitmediMi({'printed': 0, 'skip_pos_print': v}), isFalse, reason: 'deger: $v');
      }
    });

    test('gercek basilmamis urun HALA rozet alir (davranis korunur)', () {
      expect(mutfagaGitmediMi({'printed': 0, 'skip_pos_print': 0}), isTrue);
      expect(mutfagaGitmediMi({'printed': 0, 'skip_pos_print': null}), isTrue);
      expect(mutfagaGitmediMi({'printed': 0}), isTrue);
    });

    test('ESKI IFADE neden yetmiyordu: Dart\'ta 1 == true FALSE\'dir', () {
      const Object skipRaw = 1;                 // SQLite'in dondurdugu bicim
      expect(skipRaw == true, isFalse);         // eski kod: atlanmis urunu goremiyordu
      expect(mutfagaGitmediMi({'printed': 0, 'skip_pos_print': skipRaw}), isFalse); // yeni kod
    });

    test('basilmis urun hicbir bicimde rozet almaz', () {
      expect(mutfagaGitmediMi({'printed': 1, 'skip_pos_print': 0}), isFalse);
      expect(mutfagaGitmediMi({'printed': true, 'skip_pos_print': 0}), isFalse);
    });
  });

  group('ÇEVRİMDIŞI MASA TAKİP SORGUSU (gerçek sqlite)', () {
    late Database db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE local_tickets (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT, server_id INTEGER,
          table_id INTEGER, table_number TEXT, section_name TEXT,
          ticket_number TEXT, status TEXT, lan_origin TEXT,
          waiter_id INTEGER, waiter_name TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE local_ticket_items (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT, server_id INTEGER,
          local_ticket_id INTEGER, product_id INTEGER, product_name TEXT,
          quantity INTEGER, notes TEXT, extras TEXT, printed INTEGER DEFAULT 0,
          status TEXT, added_by INTEGER, added_by_name TEXT,
          delivered_at TEXT, delivered_by INTEGER, delivered_by_name TEXT,
          created_at TEXT, skip_pos_print INTEGER DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE cached_products (
          id INTEGER PRIMARY KEY, name TEXT, printer_id INTEGER,
          skip_pos_print INTEGER DEFAULT 0, hide_from_tracking INTEGER DEFAULT 0
        )
      ''');
      await db.execute('CREATE TABLE cached_tables (id INTEGER PRIMARY KEY, section_id INTEGER)');
      await db.execute('CREATE TABLE cached_sections (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('CREATE TABLE cached_waiters (id INTEGER PRIMARY KEY, name TEXT)');

      await db.insert('cached_sections', {'id': 2, 'name': 'ALT KAT'});
      await db.insert('cached_tables', {'id': 5, 'section_id': 2});
      await db.insert('cached_waiters', {'id': 11, 'name': 'Zafer'});
      await db.insert('cached_products',
          {'id': 24, 'name': 'Dağ Kekikli Tavuk', 'printer_id': 3, 'skip_pos_print': 0});
      await db.insert('cached_products',
          {'id': 161, 'name': 'Didi', 'printer_id': null, 'skip_pos_print': 1});
      await db.insert('local_tickets', {
        'local_id': 9070, 'table_id': 5, 'ticket_number': 'OFFLINE-5-A7F3B2C1',
        'status': 'open', 'lan_origin': 'self',
      });
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

    test('içecek (ürün skip_pos_print=1) sahte rozet ÜRETMEZ', () async {
      await kalemEkle({'product_id': 161, 'product_name': 'Didi'});
      final r = await db.rawQuery(_sorgu);
      expect(r.length, 1);
      expect(r.first['skip_pos_print'], 1);
      expect(mutfagaGitmediMi(r.first), isFalse); // düzeltme öncesi: true → kırmızı rozet
    });

    test('kalem bayrağı 0 olsa bile ÜRÜN bayrağı kazanır', () async {
      await kalemEkle({'product_id': 161, 'product_name': 'Didi', 'skip_pos_print': 0});
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 1);
    });

    test('mutfağa gidecek ürün basılmadıysa rozet ALIR (davranış korunur)', () async {
      await kalemEkle({'product_id': 24, 'product_name': 'Dağ Kekikli Tavuk'});
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 0);
      expect(mutfagaGitmediMi(r.first), isTrue);
    });

    test('ürün önbellekten DÜŞSE bile kalem bayrağı içeceği korur (Fable F1)', () async {
      // Gerçek senaryo: içecek akşam stok dışı kaldı → /products onu döndürmüyor →
      // cacheProducts tam-değiştirme yaptığı için cached_products satırı yok. Kalemdeki
      // ayna bayrak olmasaydı masa sahte kırmızı rozet alırdı.
      await kalemEkle({'product_id': 161, 'product_name': 'Didi', 'skip_pos_print': 1});
      await db.delete('cached_products', where: 'id = ?', whereArgs: [161]);
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 1);
      expect(mutfagaGitmediMi(r.first), isFalse);
    });

    test('çevrimdışı EKLENEN kalem ürün bayrağını taşır (Fable B5)', () async {
      // addTicketItem'ın yaptığı iş: ekleme anında cached_products'tan bayrağı kopyala.
      final u = await db.query('cached_products',
          columns: ['skip_pos_print'], where: 'id = ?', whereArgs: [161], limit: 1);
      final kopya = (u.first['skip_pos_print'] == 1) ? 1 : 0;
      await kalemEkle({'product_id': 161, 'product_name': 'Didi', 'skip_pos_print': kopya});

      // Ürün stok dışı kalıp önbellekten düştü; ayna (upsertServerTicket) henüz gelmedi.
      await db.delete('cached_products', where: 'id = ?', whereArgs: [161]);
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 1);
      expect(mutfagaGitmediMi(r.first), isFalse);
    });

    test('ürün de kalem de bayrak taşımıyorsa 0 (eski davranış, rozet çıkar)', () async {
      await kalemEkle({'product_id': 999, 'product_name': 'Pasif Ürün'});
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 0);
      expect(mutfagaGitmediMi(r.first), isTrue);
    });

    test('öncelik sırası kardeş sorguyla aynı: ÜRÜN > kalem > 0', () async {
      // Ürün bayrağı 0, kalem bayrağı 1 → ürün kazanır (panelde ayar geri alınmışsa
      // masa takip de ANINDA onu yansıtır, bayat kalem bayrağına takılmaz).
      await kalemEkle({'product_id': 24, 'product_name': 'Dağ Kekikli Tavuk', 'skip_pos_print': 1});
      final r = await db.rawQuery(_sorgu);
      expect(r.first['skip_pos_print'], 0);
      expect(mutfagaGitmediMi(r.first), isTrue);
    });

    test('diğer alanlar bozulmadı: extras metni, garson, salon, masa', () async {
      await kalemEkle({
        'product_id': 24,
        'product_name': 'Dağ Kekikli Tavuk',
        'extras': jsonEncode([
          {'name': 'SYC', 'group': 'Ürün Seçimi'}
        ]),
      });
      final r = await db.rawQuery(_sorgu);
      final m = r.first;
      expect(jsonDecode(m['extras'] as String)[0]['name'], 'SYC');
      expect(m['added_by_name'], 'Zafer');
      expect(m['section_name'], 'ALT KAT');
      expect(m['table_number'], 'M5');
      expect(m['ticket_number'], 'OFFLINE-5-A7F3B2C1');
      expect(m['printed'], 0);
    });

    test('iptal kalem ve LAN yansıması yine dışarıda', () async {
      await kalemEkle({'product_id': 24, 'product_name': 'A', 'status': 'cancelled'});
      await db.insert('local_tickets', {
        'local_id': 9071, 'table_id': 5, 'status': 'open', 'lan_origin': 'lan',
      });
      await db.insert('local_ticket_items', {
        'local_ticket_id': 9071, 'product_id': 24, 'product_name': 'LAN',
        'quantity': 1, 'printed': 0, 'status': 'active', 'created_at': '2026-09-19T20:21:00',
      });
      await kalemEkle({'product_id': 24, 'product_name': 'C'});
      final r = await db.rawQuery(_sorgu);
      expect(r.map((e) => e['product_name']).toList(), ['C']);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 19 Eyl 2026 — v22 GEÇİŞİNİN KENDİSİ (kopya değil, üretim fonksiyonu) gerçek sqlite'ta.
// Fable son kapı notu: blok yalnız metin olarak doğrulanıyordu; burada ÇALIŞTIRILIYOR.
// ─────────────────────────────────────────────────────────────────────────────
void v22GecisTestleri() {
  group('v22 GEÇİŞİ — üretim kodu, gerçek sqlite', () {
    late Database db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    Future<void> v21Semasi({required bool kalemKolonuVar}) async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // v21'deki hâl: cached_products'ta skip_pos_print YOK.
      await db.execute('''
        CREATE TABLE cached_products (id INTEGER PRIMARY KEY, name TEXT, printer_id INTEGER)
      ''');
      await db.execute('''
        CREATE TABLE local_ticket_items (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT, local_ticket_id INTEGER,
          product_id INTEGER, product_name TEXT, quantity INTEGER
          ${kalemKolonuVar ? ', skip_pos_print INTEGER DEFAULT 0' : ''}
        )
      ''');
      await db.insert('cached_products', {'id': 24, 'name': 'Dağ Kekikli Tavuk', 'printer_id': 3});
      await db.insert('local_ticket_items',
          {'local_ticket_id': 1, 'product_id': 24, 'product_name': 'Dağ Kekikli Tavuk', 'quantity': 2});
    }

    Future<List<String>> kolonlar(String tablo) async {
      final r = await db.rawQuery('PRAGMA table_info($tablo)');
      return r.map((k) => (k['name'] ?? '').toString()).toList();
    }

    tearDown(() async => db.close());

    test('ürün kolonunu ekler, mevcut veriyi KORUR, varsayılan 0', () async {
      await v21Semasi(kalemKolonuVar: true);
      await LocalDbService.migrasyonV22(db);

      expect(await kolonlar('cached_products'), contains('skip_pos_print'));
      final urun = await db.query('cached_products');
      expect(urun.length, 1);
      expect(urun.first['name'], 'Dağ Kekikli Tavuk'); // veri kaybı yok
      expect(urun.first['skip_pos_print'], 0);         // eski davranış (atlama yok)
      final kalem = await db.query('local_ticket_items');
      expect(kalem.first['quantity'], 2);
    });

    test('v11 sessizce atlanmışsa KALEM kolonunu onarır (B6)', () async {
      await v21Semasi(kalemKolonuVar: false);
      expect(await kolonlar('local_ticket_items'), isNot(contains('skip_pos_print')));

      await LocalDbService.migrasyonV22(db);

      expect(await kolonlar('local_ticket_items'), contains('skip_pos_print'));
      final kalem = await db.query('local_ticket_items');
      expect(kalem.first['skip_pos_print'], 0);
      expect(kalem.first['product_name'], 'Dağ Kekikli Tavuk');
    });

    test('iki kez çalıştırmak güvenli (idempotent)', () async {
      await v21Semasi(kalemKolonuVar: false);
      await LocalDbService.migrasyonV22(db);
      await LocalDbService.migrasyonV22(db); // yükseltme yarıda kalıp tekrar denenirse
      expect(await kolonlar('cached_products'), contains('skip_pos_print'));
      expect(await kolonlar('local_ticket_items'), contains('skip_pos_print'));
    });

    test('tablo yoksa FIRLATIR — sürüm 21 korunur, sessiz geçmez', () async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('CREATE TABLE local_ticket_items (local_id INTEGER PRIMARY KEY)');
      // cached_products YOK: ALTER yutulur ama PRAGMA doğrulaması fırlatmalı.
      expect(() => LocalDbService.migrasyonV22(db), throwsA(isA<StateError>()));
    });
  });
}
