import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/combo_calculator.dart';

// Dart port'unun canli comboCalculator.js ile BIREBIR ayni sonucu verdigini dogrular.
// Beklenen degerler node combo_ref_gen.js ciktisindan (JS TEK DOGRU KAYNAK) alindi.
// JS guncellenirse: node ile referans yeniden uret + bu testleri guncelle.

void main() {
  group('calcComboForProduct — JS ile birebir', () {
    test('CASE1: 3 al 1 ode within, 3 adet -> 1 set, disc 500', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 3}]);
      expect(r.eligible, true);
      expect(r.sets, 1);
      expect(r.discountAmount, 500);
      expect(r.giftUnits, 1);
      expect(r.giftUnitPrice, 500);
      expect(r.mode, 'gift-within');
      expect(r.label, '3 al 2 öde');
    });
    test('CASE2: katlanma 6 adet -> 2 set, disc 1000', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 6}]);
      expect(r.sets, 2);
      expect(r.discountAmount, 1000);
      expect(r.giftUnits, 2);
    });
    test('CASE3: repeat false, 6 adet -> tek set, disc 500', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': false},
        [{'unit_price': 500, 'qty': 6}]);
      expect(r.sets, 1);
      expect(r.discountAmount, 500);
    });
    test('CASE4: en ucuz bedava (karisik fiyat), disc 300 (en ucuz)', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 1}, {'unit_price': 300, 'qty': 1}, {'unit_price': 700, 'qty': 1}]);
      expect(r.discountAmount, 300);
      expect(r.giftUnitPrice, 300);
    });
    test('CASE5: extra hediye 2 al 1, 4 adet -> 2 set, giftUnits 2, disc 0', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 2, 'combo_gift_qty': 1, 'combo_gift_mode': 'extra', 'combo_repeat': true},
        [{'unit_price': 400, 'qty': 4}]);
      expect(r.mode, 'gift-extra');
      expect(r.giftUnits, 2);
      expect(r.discountAmount, 0);
      expect(r.giftUnitPrice, 400);
      expect(r.label, '2 al 1 hediye');
    });
    test('CASE6: yuzde %20 N=3, disc 300', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 0, 'combo_discount_percent': 20, 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 3}]);
      expect(r.mode, 'percent');
      expect(r.discountAmount, 300);
      expect(r.label, '%20 indirim');
    });
    test('CASE7: sabit 100 N=2, 4 adet -> 2 set, disc 200', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 2, 'combo_gift_qty': 0, 'combo_discount_amount': 100, 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 4}]);
      expect(r.mode, 'amount');
      expect(r.discountAmount, 200);
      expect(r.label, '₺100 indirim');
    });
    test('CASE8: kural alti (2 adet, N=3) -> eligible false', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true},
        [{'unit_price': 500, 'qty': 2}]);
      expect(r.eligible, false);
    });
    test('CASE9: sabit set tutarini asar -> clamp (200)', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': true, 'combo_required_qty': 2, 'combo_gift_qty': 0, 'combo_discount_amount': 99999, 'combo_repeat': true},
        [{'unit_price': 100, 'qty': 2}]);
      expect(r.discountAmount, 200);
    });
    test('CASE10: combo_enabled false -> eligible false', () {
      final r = ComboCalculator.calcComboForProduct(
        {'name': 'X', 'combo_enabled': false, 'combo_required_qty': 2, 'combo_gift_qty': 1},
        [{'unit_price': 500, 'qty': 4}]);
      expect(r.eligible, false);
    });
  });

  group('calcCartCombos — JS ile birebir', () {
    test('CART: tek combo urun 3 al 1 ode -> total 500, breakdown+ids', () {
      final cc = ComboCalculator.calcCartCombos(
        [{'product_id': 100, 'unit_price': 500, 'quantity': 3}],
        {'100': {'name': 'Kahve', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true}});
      expect(cc.totalDiscount, 500);
      expect(cc.comboProductIds, [100]);
      expect(cc.breakdown.length, 1);
      expect(cc.breakdown.first.label, '3 al 2 öde');
      expect(cc.breakdown.first.amount, 500);
      expect(cc.giftLines.isEmpty, true);
    });
    test('CART: __combo_gift isaretli satir SAYILMAZ (tekrar hesap onle)', () {
      final cc = ComboCalculator.calcCartCombos(
        [{'product_id': 100, 'unit_price': 500, 'quantity': 3},
         {'product_id': 100, 'unit_price': 0, 'quantity': 1, '__combo_gift': true}],
        {'100': {'name': 'Kahve', 'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1, 'combo_gift_mode': 'within', 'combo_repeat': true}});
      expect(cc.totalDiscount, 500, reason: 'hediye satiri sayilmadi, 3 adet uzerinden');
    });
    test('CART: extra hediye -> giftLines (sepete eklenecek ₺0 satir)', () {
      final cc = ComboCalculator.calcCartCombos(
        [{'product_id': 50, 'unit_price': 400, 'quantity': 4}],
        {'50': {'name': 'Cay', 'combo_enabled': true, 'combo_required_qty': 2, 'combo_gift_qty': 1, 'combo_gift_mode': 'extra', 'combo_repeat': true}});
      expect(cc.totalDiscount, 0);
      expect(cc.giftLines.length, 1);
      expect(cc.giftLines.first.qty, 2);
      expect(cc.giftLines.first.name, 'Cay (HEDİYE)');
      expect(cc.comboProductIds, [50]);
    });
  });

  group('paidPicksAfterGift — combo secim ekrani extra hediye cikarma', () {
    test('giftCount=0 (within/percent/amount) -> hepsi odenen', () {
      final picks = [{'name': 'Buyuk', 'price': 200.0}, {'name': 'Orta', 'price': 150.0}];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 0);
      expect(paid.length, 2);
    });
    test('extra N=2 G=1: 3 secim -> en ucuz 1 hediye cikar, 2 odenen', () {
      final picks = [{'name': 'B', 'price': 200.0}, {'name': 'O', 'price': 150.0}, {'name': 'K', 'price': 100.0}];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 1);
      expect(paid.length, 2, reason: '3 sec - 1 hediye = 2 odenen');
      expect(paid.any((p) => p['price'] == 100.0), false, reason: 'en ucuz (100) hediye slotu, odenene girmez');
      expect(paid.map((p) => p['price']).toSet(), {200.0, 150.0});
    });
    test('extra 2 set (2 hediye): 6 secim -> en ucuz 2 hediye cikar, 4 odenen', () {
      final picks = [
        {'name': 'a', 'price': 300.0}, {'name': 'b', 'price': 250.0}, {'name': 'c', 'price': 200.0},
        {'name': 'd', 'price': 150.0}, {'name': 'e', 'price': 100.0}, {'name': 'f', 'price': 50.0},
      ];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 2);
      expect(paid.length, 4);
      expect(paid.any((p) => p['price'] == 50.0), false);
      expect(paid.any((p) => p['price'] == 100.0), false);
    });
    test('giftCount picks sayisini asarsa -> hepsi hediye, odenen bos (guard)', () {
      final picks = [{'name': 'x', 'price': 100.0}];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 5);
      expect(paid.isEmpty, true);
    });
    test('ayni fiyatli iki pick -> sadece giftCount kadar cikar (cift cikarma yok)', () {
      final picks = [{'name': 'A', 'price': 100.0}, {'name': 'B', 'price': 100.0}, {'name': 'C', 'price': 200.0}];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 1);
      expect(paid.length, 2, reason: 'sadece 1 hediye cikar');
    });
    test('B1 FIX: realValue (baz+mod) gercek fiyata gore en ucuz hediye (mod DEGIL)', () {
      // extra 2 al 1 hediye, baz 940: 1P(realValue 940) + 1P(940) + Buyuk(+100 realValue 1040)
      // GERCEK en ucuz = 1P (940 < 1040) -> hediye 1P; odenen [1P, Buyuk]. (Telefon ile birebir).
      final picks = [
        {'name': '1P', 'realValue': 940.0, 'mod': 0.0},
        {'name': '1P', 'realValue': 940.0, 'mod': 0.0},
        {'name': 'Buyuk', 'realValue': 1040.0, 'mod': 100.0},
      ];
      final paid = ComboCalculator.paidPicksAfterGift(picks, 1);
      expect(paid.length, 2);
      // en ucuz 1P (940) hediye cikti -> odenen: bir 1P + Buyuk
      expect(paid.any((p) => p['name'] == 'Buyuk'), true, reason: 'Buyuk (pahali) odenen kalir');
      expect(paid.where((p) => p['name'] == '1P').length, 1, reason: 'bir 1P hediye cikti');
    });
  });

  group('splitComboPackagePrice — combo paket fiyat bolme (baz + pozitif modifier / N)', () {
    test('N=2, ana 940, iki normal (mod 0) -> 470+470', () {
      final r = ComboCalculator.splitComboPackagePrice([0.0, 0.0], 940);
      expect(r, [470.0, 470.0]);
      expect(r.reduce((a, b) => a + b), 940.0);
    });
    test('N=2, ana 940, bir varyant +100 -> paket 1040 -> 520+520', () {
      final r = ComboCalculator.splitComboPackagePrice([100.0, 0.0], 940);
      expect(r.reduce((a, b) => a + b), 1040.0, reason: '940 + 100 pozitif modifier');
      expect(r, [520.0, 520.0]);
    });
    test('NEGATIF modifier (-940 baz-sifirla) toplama KATILMAZ', () {
      // iki varyant -940 (restoran modifier): paket = 940 + 0 (negatifler atlanir) = 940
      final r = ComboCalculator.splitComboPackagePrice([-940.0, -940.0], 940);
      expect(r.reduce((a, b) => a + b), 940.0, reason: 'negatif modifier sifir sayilir -> paket=ana fiyat');
      expect(r, [470.0, 470.0]);
    });
    test('karisik: bir +100 bir -940 -> paket 1040 (negatif atlanir)', () {
      final r = ComboCalculator.splitComboPackagePrice([100.0, -940.0], 940);
      expect(r.reduce((a, b) => a + b), 1040.0);
      expect(r, [520.0, 520.0]);
    });
    test('kurus kalani son kaleme (940/3)', () {
      final r = ComboCalculator.splitComboPackagePrice([0.0, 0.0, 0.0], 940);
      expect(r.reduce((a, b) => a + b), 940.0, reason: 'toplam tam');
      expect(r[0], 313.33);
      expect(r[2], closeTo(313.34, 0.001));
    });
    test('tek kalem, ana 940 +100 -> 1040', () {
      final r = ComboCalculator.splitComboPackagePrice([100.0], 940);
      expect(r, [1040.0]);
    });
    test('ana fiyat 0 + modifier 100 -> 100 (baz yok, modifier var)', () {
      final r = ComboCalculator.splitComboPackagePrice([100.0], 0);
      expect(r, [100.0]);
    });
  });
}
