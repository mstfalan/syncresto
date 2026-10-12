// 12 Eki 2026 — SALON OZET FISI: kategori "Salon Ozet Fisinde Gosterme" (v23) + tutarsiz fis.
//
// Kilitlenen kurallar:
//   1) v23 gecisi (uretim fonksiyonu, gercek sqlite): kolonu ekler, veriyi korur, varsayilan 0,
//      idempotent, tablo yoksa FIRLATIR (surum 22 korunur).
//   2) Kaynak kodda ozet fisinde HICBIR TUTAR basilmaz; birlestirme ve gizleme filtresi baglidir.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncresto_pos/services/local_db_service.dart';

void main() {
  group('v23 GEÇİŞİ — üretim kodu, gerçek sqlite', () {
    late Database db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    Future<void> v22Semasi() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE cached_products (id INTEGER PRIMARY KEY, name TEXT,
          skip_pos_print INTEGER DEFAULT 0)
      ''');
      await db.insert('cached_products', {'id': 7, 'name': 'Ayran', 'skip_pos_print': 1});
    }

    Future<List<String>> kolonlar() async {
      final r = await db.rawQuery('PRAGMA table_info(cached_products)');
      return r.map((k) => (k['name'] ?? '').toString()).toList();
    }

    tearDown(() async => db.close());

    test('kolonu ekler, mevcut veriyi KORUR, varsayılan 0 (hiçbir ürün gizlenmez)', () async {
      await v22Semasi();
      await LocalDbService.migrasyonV23(db);
      expect(await kolonlar(), contains('hide_on_summary_receipt'));
      final u = await db.query('cached_products');
      expect(u.first['name'], 'Ayran');
      expect(u.first['skip_pos_print'], 1);
      expect(u.first['hide_on_summary_receipt'], 0);
    });

    test('iki kez çalıştırmak güvenli (idempotent)', () async {
      await v22Semasi();
      await LocalDbService.migrasyonV23(db);
      await LocalDbService.migrasyonV23(db);
      expect(await kolonlar(), contains('hide_on_summary_receipt'));
    });

    test('tablo yoksa FIRLATIR — sürüm 22 korunur', () async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      expect(() => LocalDbService.migrasyonV23(db), throwsA(isA<StateError>()));
    });
  });

  group('ÖZET FİŞİ kaynak kuralları', () {
    final kaynak = File('lib/services/printer_service.dart').readAsStringSync();
    final bas = kaynak.indexOf('Future<List<int>> _generateClosingReceipt(');
    final son = kaynak.indexOf('// ==================== YAZICI KUYRUĞU', bas);
    // Yorum satirlari haric (aciklamada "Ara Toplam kaldirildi" gecebilir) — yalniz KOD denetlenir.
    final govde = kaynak
        .substring(bas, son)
        .split(RegExp(r'\r?\n'))
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('özet fişinde HİÇBİR TUTAR basılmaz', () {
      for (final yasak in ['Ara Toplam', 'TOPLAM:', 'Indirim:', "toStringAsFixed(2)} TL", 'unit_price']) {
        expect(govde.contains(yasak), false, reason: 'özet fişinde "$yasak" kaldı');
      }
      expect(govde.contains("'Odeme: \$paymentText'"), true); // ödeme yöntemi KALIR
    });

    test('aynı kalemler birleştirilir (try/catch içinde)', () {
      expect(govde.contains('ayniKalemleriBirlestir('), true);
      expect(govde.contains('_ozetBirlesmeAnahtari('), true);
    });

    test('gizli kategori filtresi printClosingReceipt içinde ve kuyruğa filtreli yazılır', () {
      final p = kaynak.substring(kaynak.indexOf('Future<bool> printClosingReceipt('),
          kaynak.indexOf('Future<List<int>> _generateClosingReceipt('));
      final filtre = p.indexOf('ozetFisindeGizliUrunIdleri()');
      expect(filtre, greaterThan(0));
      expect(filtre, lessThan(p.indexOf('_generateClosingReceipt(')));
      expect(filtre, lessThan(p.indexOf('addToPrintQueue(')));
    });

    test('_onUpgrade v23 adımında migrasyonV23 çağrılıyor ve sürüm 23', () {
      final db = File('lib/services/local_db_service.dart').readAsStringSync();
      expect(db.contains('if (oldVersion < 23) {\n      await migrasyonV23(db);'), true);
      expect(db.contains('version: 23,'), true);
      expect(db.contains('hide_on_summary_receipt INTEGER DEFAULT 0,\n        cached_at TEXT NOT NULL'), true);
    });
  });
}
