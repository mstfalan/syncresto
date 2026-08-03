// 3 Agu 2026 — IKRAM kurallari testleri.
//
// Uretim kodu (add_item_modal / api_service / local_db_service) AYNI IkramRules
// fonksiyonlarini cagirir — burada dogrulanan kod birebir canli koddur (kopya degil).
//
// Kapsam (Mustafa'nin zorunlu kildigi davranislar):
//   1) YETKI KATI: veri yoksa/bozuksa ikram YAPILAMAZ
//   2) ikram_reason_required: '1' engel / '0' gecer / BILINMIYORSA ZORUNLU
//   3) SQLite 0/1 bayrak tuzagi: Dart'ta `0 == false` FALSE — esnek guard sart
//   4) Ikram tutari tahsilattan dusuyor (iptal/miktar/string fiyat dahil)
//   5) Sebep listesi: pasifler elenir, sort_order'a gore siralanir

import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/ikram_rules.dart';

void main() {
  group('IkramRules.yetkiVarMi — KATI yetki (veri yoksa RED)', () {
    test('permissions null -> RED', () {
      expect(IkramRules.yetkiVarMi(null), isFalse);
    });
    test('permissions List (offline cache bozuk sekli) -> RED', () {
      expect(IkramRules.yetkiVarMi([]), isFalse);
    });
    test('permissions bos Map -> RED', () {
      expect(IkramRules.yetkiVarMi(<String, dynamic>{}), isFalse);
    });
    test('ikram: false -> RED', () {
      expect(IkramRules.yetkiVarMi({'ikram': false}), isFalse);
    });
    test('ikram: 1 (int) -> RED (sadece bool true kabul — backend bool gonderir)', () {
      expect(IkramRules.yetkiVarMi({'ikram': 1}), isFalse);
    });
    test("ikram: 'true' (string) -> RED", () {
      expect(IkramRules.yetkiVarMi({'ikram': 'true'}), isFalse);
    });
    test('ikram: true -> IZIN', () {
      expect(IkramRules.yetkiVarMi({'ikram': true, 'add_item': true}), isTrue);
    });
    test('baska yetkiler acik ama ikram alani YOK -> RED', () {
      expect(IkramRules.yetkiVarMi({'add_item': true, 'close_ticket': true}), isFalse);
    });
  });

  group('IkramRules.sebepZorunluMu — ikram_reason_required ayari', () {
    test('BILINMIYOR (null) -> ZORUNLU (guvenli taraf)', () {
      expect(IkramRules.sebepZorunluMu(null), isTrue);
    });
    test('bos string -> ZORUNLU', () {
      expect(IkramRules.sebepZorunluMu(''), isTrue);
      expect(IkramRules.sebepZorunluMu('   '), isTrue);
    });
    test("'1' / 'true' / true / 1 -> ZORUNLU", () {
      expect(IkramRules.sebepZorunluMu('1'), isTrue);
      expect(IkramRules.sebepZorunluMu('true'), isTrue);
      expect(IkramRules.sebepZorunluMu(true), isTrue);
      expect(IkramRules.sebepZorunluMu(1), isTrue);
    });
    test("'0' / 'false' / false / 0 -> OPSIYONEL", () {
      expect(IkramRules.sebepZorunluMu('0'), isFalse);
      expect(IkramRules.sebepZorunluMu('false'), isFalse);
      expect(IkramRules.sebepZorunluMu(false), isFalse);
      expect(IkramRules.sebepZorunluMu(0), isFalse);
    });
    test('cop deger -> ZORUNLU (bilinmeyen = guvenli taraf)', () {
      expect(IkramRules.sebepZorunluMu('belki'), isTrue);
    });
    test('cached_settings TEXT sakladigi icin bool -> toString yolu da dogru', () {
      // cacheSettings value.toString() yazar: true -> 'true', false -> 'false'
      expect(IkramRules.sebepZorunluMu(true.toString()), isTrue);
      expect(IkramRules.sebepZorunluMu(false.toString()), isFalse);
    });
  });

  group('IkramRules.onaylanabilirMi — sebep onay butonu', () {
    test("zorunlu + sebepsiz -> ENGELLENIR (ayar '1')", () {
      expect(IkramRules.onaylanabilirMi(girilen: '', zorunlu: true), isFalse);
      expect(IkramRules.onaylanabilirMi(girilen: '   ', zorunlu: true), isFalse);
    });
    test('zorunlu + sebepli -> gecer', () {
      expect(IkramRules.onaylanabilirMi(girilen: 'Dogum gunu', zorunlu: true), isTrue);
    });
    test("opsiyonel + sebepsiz -> gecer (ayar '0')", () {
      expect(IkramRules.onaylanabilirMi(girilen: '', zorunlu: false), isTrue);
    });
    test('opsiyonel + sebepli -> gecer (sebep yine kaydedilir)', () {
      expect(IkramRules.onaylanabilirMi(girilen: 'VIP', zorunlu: false), isTrue);
    });
    test('AYAR BILINMIYORKEN zorunlu davranir (sebepZorunluMu(null)=true zinciri)', () {
      final zorunlu = IkramRules.sebepZorunluMu(null);
      expect(IkramRules.onaylanabilirMi(girilen: '', zorunlu: zorunlu), isFalse);
    });
  });

  group('IkramRules.bayrak/kalemIkramMi — SQLite 0/1 tuzagi', () {
    test('SQLite int 1 -> ikram (0 == false tuzagina dusmez)', () {
      expect(IkramRules.kalemIkramMi({'is_ikram': 1}), isTrue);
      expect(IkramRules.kalemIkramMi({'is_ikram': 0}), isFalse);
    });
    test("string '1'/'true'/'t' -> ikram; '0' -> degil", () {
      expect(IkramRules.kalemIkramMi({'is_ikram': '1'}), isTrue);
      expect(IkramRules.kalemIkramMi({'is_ikram': 'true'}), isTrue);
      expect(IkramRules.kalemIkramMi({'is_ikram': 't'}), isTrue);
      expect(IkramRules.kalemIkramMi({'is_ikram': '0'}), isFalse);
    });
    test('bool true/false', () {
      expect(IkramRules.kalemIkramMi({'is_ikram': true}), isTrue);
      expect(IkramRules.kalemIkramMi({'is_ikram': false}), isFalse);
    });
    test('alan yok / null / item Map degil -> ikram DEGIL (eski kayitlar guvenli)', () {
      expect(IkramRules.kalemIkramMi({'product_name': 'Çay'}), isFalse);
      expect(IkramRules.kalemIkramMi({'is_ikram': null}), isFalse);
      expect(IkramRules.kalemIkramMi(null), isFalse);
      expect(IkramRules.kalemIkramMi('x'), isFalse);
    });
  });

  group('IkramRules.ikramToplami — tahsilattan dusulecek tutar', () {
    test('karisik sepet: sadece aktif ikram kalemler toplanir', () {
      final items = [
        {'is_ikram': 1, 'unit_price': 100.0, 'quantity': 2},              // 200 ikram
        {'is_ikram': 0, 'unit_price': 50.0, 'quantity': 1},               // normal
        {'is_ikram': 1, 'unit_price': 30.0, 'quantity': 1, 'status': 'cancelled'}, // iptal — sayilmaz
        {'unit_price': 80.0, 'quantity': 3},                              // alan yok — normal
      ];
      expect(IkramRules.ikramToplami(items), 200.0);
    });
    test('backend String fiyat/miktar gonderirse de dogru', () {
      final items = [
        {'is_ikram': true, 'unit_price': '75.50', 'quantity': '2'},
      ];
      expect(IkramRules.ikramToplami(items), 151.0);
    });
    test('quantity yoksa 1 kabul', () {
      expect(IkramRules.ikramToplami([{'is_ikram': 1, 'unit_price': 40.0}]), 40.0);
    });
    test('ikram yoksa 0 (mevcut davranis birebir korunur)', () {
      final items = [
        {'unit_price': 100.0, 'quantity': 2},
        {'is_ikram': 0, 'unit_price': 50.0, 'quantity': 1},
      ];
      expect(IkramRules.ikramToplami(items), 0.0);
    });
    test('geri alma sonrasi (is_ikram tekrar 0) tutar geri gelir', () {
      final once = [{'is_ikram': 1, 'unit_price': 60.0, 'quantity': 1}];
      final sonra = [{'is_ikram': 0, 'unit_price': 60.0, 'quantity': 1}];
      expect(IkramRules.ikramToplami(once), 60.0);
      expect(IkramRules.ikramToplami(sonra), 0.0);
    });
  });

  group('IkramRules.aktifSebepler — filtre + siralama', () {
    test('pasifler elenir (0/false/"0"), sort_order sirali', () {
      final rows = [
        {'id': 1, 'reason': 'VIP müşteri', 'sort_order': 2, 'is_active': 1},
        {'id': 2, 'reason': 'Pasif sebep', 'sort_order': 0, 'is_active': 0},
        {'id': 3, 'reason': 'Doğum günü', 'sort_order': 1, 'is_active': true},
        {'id': 4, 'reason': 'String pasif', 'sort_order': 0, 'is_active': '0'},
      ];
      final out = IkramRules.aktifSebepler(rows);
      expect(out.map((r) => r['reason']).toList(), ['Doğum günü', 'VIP müşteri']);
    });
    test('is_active alani HIC yoksa aktif kabul (server filtreli gonderebilir)', () {
      final out = IkramRules.aktifSebepler([
        {'id': 1, 'reason': 'Şikayet telafisi'},
      ]);
      expect(out.length, 1);
    });
    test('bos reason elenir, Map olmayan satir elenir', () {
      final out = IkramRules.aktifSebepler([
        {'id': 1, 'reason': '  '},
        'cop',
        {'id': 2, 'reason': 'Geçerli'},
      ]);
      expect(out.length, 1);
      expect(out.first['reason'], 'Geçerli');
    });
    test('turkce karakterler bozulmadan doner', () {
      final out = IkramRules.aktifSebepler([
        {'id': 1, 'reason': 'İçecek ikramı — müşteri şikâyeti', 'is_active': 1},
      ]);
      expect(out.first['reason'], 'İçecek ikramı — müşteri şikâyeti');
    });
  });
}
