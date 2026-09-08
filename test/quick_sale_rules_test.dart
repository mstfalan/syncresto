// 8 Eyl 2026 — HIZLI SATIS saf kural testleri (QuickSaleRules canli kodun kendisi).
//
// Kapsam: bayrak paritesi (sunucu bool / SQLite 0-1 / string), salon ayrimi, gizli masa filtresi,
// gizli masa bulma, dolu-masa tanimi, baska-kasa guard'i (Fable Y1), rozet ozeti,
// offline ticket_number kirpma (Fable E1: sunucu varchar(30)).
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/quick_sale_rules.dart';

void main() {
  group('QuickSaleRules.bayrak — online/offline paritesi', () {
    test('true / 1 / "1" / "true" -> true', () {
      for (final v in [true, 1, '1', 'true']) {
        expect(QuickSaleRules.bayrak(v), isTrue, reason: 'v=$v');
      }
    });
    test('false / 0 / "0" / null / "false" / bos -> false', () {
      for (final v in [false, 0, '0', null, 'false', '', 'evet']) {
        expect(QuickSaleRules.bayrak(v), isFalse, reason: 'v=$v');
      }
    });
  });

  group('salon ayrimi', () {
    final sections = [
      {'id': 1, 'name': 'Salon', 'is_quick_sale': false},
      {'id': 2, 'name': 'Hızlı Satış', 'is_quick_sale': true},
      {'id': 3, 'name': 'Bahçe'}, // alan hic yok (eski sunucu / eski cache)
      {'id': 4, 'name': 'Hızlı Kasa 2', 'is_quick_sale': 1}, // SQLite 0/1
    ];
    test('hizliSalonlar sadece isaretli (bool VE int)', () {
      final h = QuickSaleRules.hizliSalonlar(sections);
      expect(h.map((s) => s['id']), [2, 4]);
    });
    test('normalSalonlar hizli olanlari eler, alan yoksa normal sayar', () {
      final n = QuickSaleRules.normalSalonlar(sections);
      expect(n.map((s) => s['id']), [1, 3]);
    });
    test('bos liste guvenli', () {
      expect(QuickSaleRules.hizliSalonlar([]), isEmpty);
      expect(QuickSaleRules.normalSalonlar([]), isEmpty);
    });
  });

  group('gizli masa', () {
    final tables = [
      {'id': 10, 'section_id': 1, 'table_number': '1', 'status': 'empty'},
      {'id': 11, 'section_id': 2, 'table_number': 'Hızlı Satış', 'is_quick_sale': 1, 'status': 'empty'},
      {'id': 12, 'section_id': 4, 'table_number': 'Hızlı Kasa 2', 'is_quick_sale': true, 'status': 'occupied', 'current_ticket_id': 900, 'current_total': '250.50'},
      {'id': 13, 'section_id': 1, 'table_number': '2', 'is_quick_sale': 0},
    ];
    test('gorunurMasalar gizlileri eler (0 ve alan-yok normal kalir)', () {
      expect(QuickSaleRules.gorunurMasalar(tables).map((t) => t['id']), [10, 13]);
    });
    test('gizliMasa salon id ile bulur; yoksa null', () {
      expect(QuickSaleRules.gizliMasa(tables, 2)?['id'], 11);
      expect(QuickSaleRules.gizliMasa(tables, 4)?['id'], 12);
      expect(QuickSaleRules.gizliMasa(tables, 1), isNull); // normal salonun gizli masasi yok
      expect(QuickSaleRules.gizliMasa(tables, 99), isNull);
    });
    test('section_id String gelse de eslesir', () {
      final t = [{'id': 5, 'section_id': '7', 'is_quick_sale': '1'}];
      expect(QuickSaleRules.gizliMasa(t, 7)?['id'], 5);
    });
    test('masaDolu tables_screen ile ayni tanim', () {
      expect(QuickSaleRules.masaDolu({'status': 'occupied'}), isTrue);
      expect(QuickSaleRules.masaDolu({'status': 'empty', 'current_ticket_id': 5}), isTrue);
      expect(QuickSaleRules.masaDolu({'status': 'empty', 'active_ticket_id': 5}), isTrue);
      expect(QuickSaleRules.masaDolu({'status': 'empty'}), isFalse);
      expect(QuickSaleRules.masaDolu({'status': 'available', 'current_ticket_id': null}), isFalse);
    });
    test('acikOzet: sadece hizli salonlarin DOLU gizli masalari', () {
      final o = QuickSaleRules.acikOzet(tables, [2, 4]);
      expect(o.adet, 1);
      expect(o.tutar, closeTo(250.5, 0.001));
      final o2 = QuickSaleRules.acikOzet(tables, [2]);
      expect(o2.adet, 0);
      expect(o2.tutar, 0);
    });
  });

  group('baskaKasadaAcik (Fable Y1)', () {
    test('farkli kasa -> true', () {
      expect(QuickSaleRules.baskaKasadaAcik(openedByDevice: 'Kasa 1', buKasa: 'Kasa 2'), isTrue);
    });
    test('ayni kasa (buyuk/kucuk harf, bosluk) -> false', () {
      expect(QuickSaleRules.baskaKasadaAcik(openedByDevice: ' kasa 1 ', buKasa: 'KASA 1'), isFalse);
    });
    test('eski veri (null/bos) -> devam edilebilir (false)', () {
      expect(QuickSaleRules.baskaKasadaAcik(openedByDevice: null, buKasa: 'Kasa 1'), isFalse);
      expect(QuickSaleRules.baskaKasadaAcik(openedByDevice: 'Kasa 1', buKasa: null), isFalse);
      expect(QuickSaleRules.baskaKasadaAcik(openedByDevice: '', buKasa: ''), isFalse);
    });
  });

  group('offlineMasaAnahtari (Fable E1: ticket_number varchar(30))', () {
    test('Turkce + bosluk + uzun -> ASCII alnum, en fazla 13', () {
      expect(QuickSaleRules.offlineMasaAnahtari('Hızlı Satış Kasa 2'), 'HizliSatisKas');
      expect(QuickSaleRules.offlineMasaAnahtari('Hızlı Satış'), 'HizliSatis');
    });
    test('kisa masa adlari BIREBIR (regresyon yok)', () {
      expect(QuickSaleRules.offlineMasaAnahtari('5'), '5');
      expect(QuickSaleRules.offlineMasaAnahtari('12'), '12');
      expect(QuickSaleRules.offlineMasaAnahtari('AG 1'), 'AG1');
    });
    test('bos/null -> MASA', () {
      expect(QuickSaleRules.offlineMasaAnahtari(''), 'MASA');
      expect(QuickSaleRules.offlineMasaAnahtari(null), 'MASA');
      expect(QuickSaleRules.offlineMasaAnahtari('★★★'), 'MASA');
    });
    test('tam ticket_number her girdide <= 30', () {
      for (final ad in ['Hızlı Satış Kasa 2 Üst Kat', 'ÇĞİÖŞÜçğıöşü' * 3, 'Masa 1', '']) {
        final tn = 'OFFLINE-${QuickSaleRules.offlineMasaAnahtari(ad)}-A1B2C3D4';
        expect(tn.length, lessThanOrEqualTo(30), reason: ad);
        expect(RegExp(r'^OFFLINE-[A-Za-z0-9]{1,13}-[A-Z0-9]{8}$').hasMatch(tn), isTrue, reason: tn);
      }
    });
  });
}
