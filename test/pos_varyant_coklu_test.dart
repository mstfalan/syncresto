// 31 Tem 2026 — POS VARYANT ÇOKLU SEÇİM
// Web'in variants_allow_multiple ayarının POS karşılığı. Combo İLE İLGİSİ YOK:
// combo = paket/set mantığı (N kalem + indirim), bu = TEK kalemin üzerine birden
// fazla varyant farkının eklenmesi.
//
// Para kritik: fiyat = ana restoran fiyatı + Σ(seçilen varyant farkları).
// Ayrıca ÇEVRİMDIŞI cache bool'u 0/1 INTEGER döndürür — ayar sessizce kapanmamalı.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// --- add_item_modal.dart içindeki kurallarla AYNI ---
bool posCokluVaryant(Map<String, dynamic> p) {
  final v = p['variants_allow_multiple_pos'];
  return v == true || v == 1 || v == '1' || v == 'true';
}

bool posVaryantZorunlu(Map<String, dynamic> p) {
  final v = p['variants_required_pos'];
  return v == true || v == 1 || v == '1' || v == 'true';
}

double restoranBaz(Map<String, dynamic> p) {
  final rp = p['restaurant_price'];
  if (rp != null && (rp as num) != 0) return rp.toDouble();
  return (p['price'] as num?)?.toDouble() ?? 0;
}

double varyantFarki(Map<String, dynamic> v) {
  final rm = v['restaurant_modifier'];
  if (rm != null) return (rm as num).toDouble();
  return (v['price_modifier'] as num?)?.toDouble() ?? 0;
}

double toplamFiyat(Map<String, dynamic> p, List<Map<String, dynamic>> secili) =>
    restoranBaz(p) + secili.fold<double>(0, (t, v) => t + varyantFarki(v));

/// sync_service._decodeExtras ile aynı
List<dynamic> decodeExtras(dynamic raw) {
  if (raw is List) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is List) return d;
    } catch (_) {}
  }
  return const [];
}

void main() {
  cakismaTestleri();
  // Dora "Afrodit Waffle Cup": ana 300₺, 4 dondurma varyantı ×+50₺ (canlı doğrulandı)
  final afrodit = <String, dynamic>{
    'name': 'Afrodit Waffle Cup',
    'price': 300, 'restaurant_price': 300,
    'variants_allow_multiple_pos': true, 'variants_required_pos': true,
  };
  final d1 = {'id': 1, 'name': 'Frutti Dondurma', 'price_modifier': 50};
  final d2 = {'id': 2, 'name': 'Sade Dondurma', 'price_modifier': 50};
  final d3 = {'id': 3, 'name': 'Frambuazlı Dondurma', 'price_modifier': 50};

  group('Fiyat = ana + Σ(farklar) — web ile birebir', () {
    test('hiç seçim yok → sadece ana fiyat', () {
      expect(toplamFiyat(afrodit, []), 300);
    });
    test('1 seçim → 350', () {
      expect(toplamFiyat(afrodit, [d1]), 350);
    });
    test('2 seçim → 400', () {
      expect(toplamFiyat(afrodit, [d1, d2]), 400);
    });
    test('3 seçim → 450 (üst sınır YOK, combo değil)', () {
      expect(toplamFiyat(afrodit, [d1, d2, d3]), 450);
    });
    test('restaurant_modifier price_modifier\'ı EZER (POS kanal fiyatı)', () {
      final v = {'name': 'X', 'price_modifier': 50, 'restaurant_modifier': 20};
      expect(toplamFiyat(afrodit, [v]), 320);
    });
    test('negatif fark düşürür (baz-sıfırla deseni)', () {
      final v = {'name': 'Sade', 'price_modifier': -100};
      expect(toplamFiyat(afrodit, [v]), 200);
    });
    test('restaurant_price yoksa ana price kullanılır', () {
      final p = {'price': 120, 'restaurant_price': null};
      expect(toplamFiyat(p, [d1]), 170);
    });
  });

  group('Ayar okuma — çevrimdışı cache 0/1 sessizce kapatmamalı', () {
    for (final v in [true, 1, '1', 'true']) {
      test('çoklu=$v (${v.runtimeType}) → AÇIK', () {
        expect(posCokluVaryant({'variants_allow_multiple_pos': v}), true);
      });
    }
    for (final v in [false, 0, '0', null]) {
      test('çoklu=$v → KAPALI (eski tekli akış)', () {
        expect(posCokluVaryant({'variants_allow_multiple_pos': v}), false);
      });
    }
    test('alan HİÇ yoksa kapalı — eski ürünlerde regresyon yok', () {
      expect(posCokluVaryant({'name': 'Eski Ürün'}), false);
      expect(posVaryantZorunlu({'name': 'Eski Ürün'}), false);
    });
  });

  group('Zorunlu seçim kuralı', () {
    bool eklenebilir(Map<String, dynamic> p, int secim) =>
        posVaryantZorunlu(p) ? secim > 0 : true;
    test('zorunlu AÇIK + 0 seçim → eklenemez', () {
      expect(eklenebilir(afrodit, 0), false);
    });
    test('zorunlu AÇIK + 1 seçim → eklenebilir', () {
      expect(eklenebilir(afrodit, 1), true);
    });
    test('zorunlu KAPALI + 0 seçim → eklenebilir', () {
      expect(eklenebilir({'variants_required_pos': false}, 0), true);
    });
  });

  group('extras taşınması (çevrimdışı → sync → backend)', () {
    test('liste aynen geçer', () {
      final e = [
        {'name': 'Frutti', 'price': 50.0}
      ];
      expect(decodeExtras(e), e);
    });
    test('JSON metin çözülür (kuyrukta metin saklanır)', () {
      final r = decodeExtras('[{"name":"Sade","price":50}]');
      expect(r.length, 1);
      expect(r.first['name'], 'Sade');
    });
    test('bozuk JSON → boş liste, kalem yine de eklenir (veri kaybı yok)', () {
      expect(decodeExtras('{bozuk'), isEmpty);
    });
    test('null/boş → boş liste', () {
      expect(decodeExtras(null), isEmpty);
      expect(decodeExtras(''), isEmpty);
    });
  });

  group('SQLite v17→v18 göçü — açık adisyon kalemleri kaybolmamalı', () {
    late Database db;
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE cached_products (
          id INTEGER PRIMARY KEY, name TEXT, price REAL,
          combo_pos_selection_required INTEGER DEFAULT 1,
          combo_pos_unlimited INTEGER DEFAULT 0
        )
      ''');
      await db.insert('cached_products', {'id': 1, 'name': 'Afrodit', 'price': 300.0});
    });
    tearDown(() async => db.close());

    Future<void> v18(Database d) async {
      for (final c in [
        'ALTER TABLE cached_products ADD COLUMN variants_allow_multiple_pos INTEGER DEFAULT 0',
        'ALTER TABLE cached_products ADD COLUMN variants_required_pos INTEGER DEFAULT 0',
      ]) {
        try {
          await d.execute(c);
        } catch (_) {}
      }
    }

    test('göç sonrası ürün durur, yeni kolonlar 0 (eski davranış)', () async {
      await v18(db);
      final r = await db.query('cached_products');
      expect(r.length, 1);
      expect(r.first['name'], 'Afrodit');
      expect(r.first['variants_allow_multiple_pos'], 0);
      expect(r.first['variants_required_pos'], 0);
    });

    test('göç iki kez çalışsa da patlamaz (idempotent)', () async {
      await v18(db);
      await v18(db);
      expect((await db.query('cached_products')).length, 1);
    });

    test('ayar yazılıp okunabiliyor', () async {
      await v18(db);
      await db.update('cached_products',
          {'variants_allow_multiple_pos': 1, 'variants_required_pos': 1},
          where: 'id = 1');
      final r = await db.query('cached_products', where: 'id = 1');
      expect(posCokluVaryant(Map<String, dynamic>.from(r.first)), true);
      expect(posVaryantZorunlu(Map<String, dynamic>.from(r.first)), true);
    });
  });
}

// 31 Tem 2026 — COMBO ↔ VARYANT ÇAKIŞMASI (Mustafa: "birbirlerini eziyorlar")
// Eskiden combo KOŞULSUZ kazanıyordu; ikisi de açıkken varyant yoluna hiç gelinmiyordu.
// Yeni kural: SADECE ikisi de aktifken seçim ekranı çıkar. Tek özellik açıksa
// ESKİ AKIŞ AYNEN korunmalı — yoksa bugün çalışan her combo ürününe ekstra tık binerdi.
enum Akis { comboEkrani, varyantEkrani, secimEkrani, dogrudanEkle }

Akis kararVer(Map<String, dynamic> p, {required bool variantOnTap}) {
  final comboAktif = p['combo_enabled'] == true || p['combo_enabled'] == 1;
  final varyantlar = (p['variants'] as List?) ?? const [];
  final coklu = posCokluVaryant(p) && varyantlar.isNotEmpty;
  // 1 Ağu: "SORAYIM MI" (zorunlu || global toggle) ile "NASIL" (çoklu/tekli) AYRI
  if (comboAktif) {
    final selReq = p['combo_pos_selection_required'];
    final comboZorunlu = !(selReq == false || selReq == 0 || selReq == '0');
    if (!comboZorunlu && !variantOnTap) return Akis.dogrudanEkle;
    if (coklu) return Akis.secimEkrani;
    return Akis.comboEkrani;
  }
  if (varyantlar.isNotEmpty) {
    final sorulacak = posVaryantZorunlu(p) || variantOnTap;
    if (sorulacak) return coklu ? Akis.varyantEkrani : Akis.varyantEkrani;
  }
  return Akis.dogrudanEkle;
}

void cakismaTestleri() {
  final v = [
    {'id': 1, 'name': 'Frutti', 'price_modifier': 50}
  ];
  group('Combo ↔ Varyant önceliği', () {
    test('İKİSİ DE açık → seçim ekranı (asıl düzeltme)', () {
      expect(
          kararVer({'combo_enabled': true, 'variants_allow_multiple_pos': true, 'variants': v},
              variantOnTap: true),
          Akis.secimEkrani);
    });

    test('sadece combo → combo ekranı (eski akış, ekstra tık YOK)', () {
      expect(
          kararVer({'combo_enabled': true, 'variants': v}, variantOnTap: true),
          Akis.comboEkrani);
    });

    test('combo + çoklu açık ama ürünün VARYANTI YOK → combo ekranı', () {
      expect(
          kararVer({'combo_enabled': true, 'variants_allow_multiple_pos': true, 'variants': []},
              variantOnTap: true),
          Akis.comboEkrani);
    });

    test('sadece çoklu varyant → varyant ekranı', () {
      expect(
          kararVer({'variants_allow_multiple_pos': true, 'variants': v}, variantOnTap: true),
          Akis.varyantEkrani);
    });

    test('combo + seçim zorunlu DEĞİL + global AÇIK → sorar (toggle geçerli)', () {
      expect(
          kararVer({'combo_enabled': true, 'combo_pos_selection_required': false, 'variants': v},
              variantOnTap: true),
          Akis.comboEkrani);
    });

    test('combo + zorunlu değil + çoklu açık + global AÇIK → seçim ekranı', () {
      expect(
          kararVer({
            'combo_enabled': true,
            'combo_pos_selection_required': false,
            'variants_allow_multiple_pos': true,
            'variants': v
          }, variantOnTap: true),
          Akis.secimEkrani);
    });

    test('hiçbiri yok → doğrudan ekle', () {
      expect(kararVer({'name': 'Çay', 'variants': []}, variantOnTap: true), Akis.dogrudanEkle);
    });

    test('sadece ZORUNLU açık (çoklu kapalı) + global kapalı → yine ekran açılır', () {
      expect(
          kararVer({'variants_required_pos': true, 'variants': v}, variantOnTap: false),
          Akis.varyantEkrani);
    });

    test('hiç POS ayarı yok + global KAPALI → doğrudan ekle (eski davranış korunur)', () {
      expect(kararVer({'variants': v}, variantOnTap: false), Akis.dogrudanEkle);
    });

    test('hiç POS ayarı yok + global AÇIK → varyant ekranı (eski davranış korunur)', () {
      expect(kararVer({'variants': v}, variantOnTap: true), Akis.varyantEkrani);
    });

    test('🔴 ÇOKLU açık AMA zorunlu değil + global KAPALI → DOĞRUDAN EKLE', () {
      // Mustafa 1 Ağu: "toggle'ı açıp kapamak bir şeyi değiştirmiyor" — çoklu seçim
      // ekranı ZORLA açıyordu. Çoklu bir BİÇİM ayarı, "sor" emri değil.
      expect(
          kararVer({'variants_allow_multiple_pos': true, 'variants': v}, variantOnTap: false),
          Akis.dogrudanEkle);
    });

    test('çoklu açık + global AÇIK → varyant ekranı', () {
      expect(
          kararVer({'variants_allow_multiple_pos': true, 'variants': v}, variantOnTap: true),
          Akis.varyantEkrani);
    });

    test('ZORUNLU açık + global kapalı → yine sorar (zorunluluk toggle\'ı ezer)', () {
      expect(
          kararVer({'variants_required_pos': true, 'variants': v}, variantOnTap: false),
          Akis.varyantEkrani);
    });

    test('combo + global KAPALI ama combo zorunlu VARSAYILAN (true) → combo ekranı', () {
      // Regresyon: bugüne kadarki combo davranışı AYNEN korunmalı
      expect(kararVer({'combo_enabled': true, 'variants': v}, variantOnTap: false),
          Akis.comboEkrani);
    });

    test('combo + zorunlu KAPATILMIŞ + global kapalı → doğrudan ekle', () {
      expect(
          kararVer({'combo_enabled': true, 'combo_pos_selection_required': false, 'variants': v},
              variantOnTap: false),
          Akis.dogrudanEkle);
    });

    test('combo + zorunlu kapalı AMA global AÇIK → yine sorar', () {
      expect(
          kararVer({'combo_enabled': true, 'combo_pos_selection_required': false, 'variants': v},
              variantOnTap: true),
          Akis.comboEkrani);
    });

    test('çevrimdışı 0/1 formatı da aynı kararı verir', () {
      expect(
          kararVer({'combo_enabled': 1, 'variants_allow_multiple_pos': 1, 'variants': v},
              variantOnTap: true),
          Akis.secimEkrani);
    });
  });
}
