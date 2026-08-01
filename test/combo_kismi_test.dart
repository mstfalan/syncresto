// COMBO kısmi set (POS "limitsiz seçim") — Dart hesabı backend JS ile BİREBİR mi?
// Beklenen değerler syncresto-api routes/pos/panel-direct/comboCalculator.js üzerinde
// çalıştırılan 16 senaryonun ÇIKTISIDIR (31 Tem 2026, hepsi geçti).
// Bu ikisi ayrışırsa kasada görünen indirim ile kapanışta yazılan indirim TUTMAZ.
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/combo_calculator.dart';

List<Map<String, dynamic>> L(int adet, double fiyat) => [
      {'unit_price': fiyat, 'qty': adet}
    ];

void main() {
  offlineFormatTestleri();
  group('Limitsiz KAPALI — mevcut davranış korunmalı', () {
    test('N=10, 2 seçildi, %20 → indirim YOK', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_percent': 20, 'combo_pos_unlimited': false,
      }, L(2, 100));
      expect(r.eligible, false);
      expect(r.discountAmount, 0);
    });

    test('N=10, 2 seçildi, sabit 500 → indirim YOK', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_amount': 500, 'combo_pos_unlimited': false,
      }, L(2, 100));
      expect(r.discountAmount, 0);
    });

    test('N=3, 3 seçildi, %10 → tam indirim 30', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 3,
        'combo_discount_percent': 10, 'combo_pos_unlimited': false,
      }, L(3, 100));
      expect(r.discountAmount, 30);
    });
  });

  group('Limitsiz AÇIK — kısmi set (Mustafa örneği: 10 gereken, 2 seçildi)', () {
    test('%20 → 200*0.20 = 40 (doğal oranlı)', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_percent': 20, 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.eligible, true);
      expect(r.discountAmount, 40);
    });

    test('sabit 500 → 500*(2/10) = 100', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_amount': 500, 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.discountAmount, 100);
    });

    test('hediye within G=2 → ort100*2*(2/10) = 40, fiziksel hediye YOK', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10, 'combo_gift_qty': 2,
        'combo_gift_mode': 'within', 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.discountAmount, 40);
      expect(r.giftUnits, 0);
    });

    test('hediye EXTRA G=2 → hiçbir şey (ciro koruması)', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10, 'combo_gift_qty': 2,
        'combo_gift_mode': 'extra', 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.eligible, false);
      expect(r.discountAmount, 0);
      expect(r.giftUnits, 0);
    });
  });

  group('Limitsiz AÇIK ama tam/fazla set — eski davranış değişmemeli', () {
    test('N=3, 3x100, %10 → 30', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 3,
        'combo_discount_percent': 10, 'combo_pos_unlimited': true,
      }, L(3, 100));
      expect(r.discountAmount, 30);
    });

    test('N=3, 6x100, %10 katlanır → 60', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 3, 'combo_discount_percent': 10,
        'combo_repeat': true, 'combo_pos_unlimited': true,
      }, L(6, 100));
      expect(r.discountAmount, 60);
    });

    test('N=3, 3x100, hediye within G=1 → 100, 1 fiziksel hediye', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 3, 'combo_gift_qty': 1,
        'combo_gift_mode': 'within', 'combo_pos_unlimited': true,
      }, L(3, 100));
      expect(r.discountAmount, 100);
      expect(r.giftUnits, 1);
    });

    test('N=2, 2x100, hediye EXTRA G=1 → 1 fiziksel hediye, indirim 0', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 2, 'combo_gift_qty': 1,
        'combo_gift_mode': 'extra', 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.giftUnits, 1);
      expect(r.discountAmount, 0);
    });
  });

  group('Sınır durumları', () {
    test('N=10, 1 seçildi, sabit 500 → 50', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_amount': 500, 'combo_pos_unlimited': true,
      }, L(1, 100));
      expect(r.discountAmount, 50);
    });

    test('aşırı sabit indirim seçilen tutarı AŞAMAZ', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_amount': 5000, 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.discountAmount, 200);
    });

    test('0 seçim → hiçbir şey', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10,
        'combo_discount_percent': 20, 'combo_pos_unlimited': true,
      }, <Map<String, dynamic>>[]);
      expect(r.eligible, false);
    });

    test('combo KAPALI ürün, limitsiz açık → etkisiz', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': false, 'combo_required_qty': 10,
        'combo_discount_percent': 20, 'combo_pos_unlimited': true,
      }, L(2, 100));
      expect(r.eligible, false);
    });

    test('farklı fiyatlı 2 birim (100+300), hediye within G=5 → ort200*5*(2/10)=200', () {
      final r = ComboCalculator.calcComboForProduct({
        'combo_enabled': true, 'combo_required_qty': 10, 'combo_gift_qty': 5,
        'combo_gift_mode': 'within', 'combo_pos_unlimited': true,
      }, [
        {'unit_price': 100.0, 'qty': 1},
        {'unit_price': 300.0, 'qty': 1},
      ]);
      expect(r.discountAmount, 200);
    });
  });
}

// 31 Tem 2026 EK: ÇEVRİMDIŞI cache bool'u 0/1 INTEGER döndürür. Sadece `== true`
// bakılsaydı internet gidince "limitsiz seçim" sessizce kapanır, kasa 2 seçimde
// ürün ekleyemezdi. _truthy hem bool hem 1/'1'/'true' kabul etmeli.
void offlineFormatTestleri() {
  group('Çevrimdışı cache formatı (SQLite 0/1) — ayar sessizce kapanmamalı', () {
    for (final v in [true, 1, '1', 'true']) {
      test('limitsiz=$v (${v.runtimeType}) → kısmi set çalışır (40)', () {
        final r = ComboCalculator.calcComboForProduct({
          'combo_enabled': 1, 'combo_required_qty': 10,
          'combo_discount_percent': 20, 'combo_pos_unlimited': v,
        }, L(2, 100));
        expect(r.eligible, true);
        expect(r.discountAmount, 40);
      });
    }
    for (final v in [false, 0, '0', null]) {
      test('limitsiz=$v → ESKİ davranış (indirim yok)', () {
        final r = ComboCalculator.calcComboForProduct({
          'combo_enabled': 1, 'combo_required_qty': 10,
          'combo_discount_percent': 20, 'combo_pos_unlimited': v,
        }, L(2, 100));
        expect(r.discountAmount, 0);
      });
    }
  });
}
