// 28 Eki 2026 — KALEM BOLME ("Bol") saf kural testleri (lib/services/kalem_bolme.dart).
//
// Kilitlenen kurallar:
//   1) Esit bolme kurus duzeyinde; artik SON parcaya (sunucuyla ayni) — toplam DEGISMEZ.
//   2) "Tutar yaz": son parca KALAN (en cok 10); 0 / tam tutar / fazla / 2+ ondalik -> gecersiz.
//   3) bolunebilirMi: odenmis, ikram, combo, parca, zaten bolunmus, adet!=1, PAVO -> buton YOK.
//   4) parcasiz: parca yoksa AYNI liste nesnesi (fis sozlesmesi: 0 regresyon).
//   5) parcalariAnaSatiraKatla: kasa fisinde parcalar ANA satira katlanir, tutar toplami korunur,
//      parca yoksa AYNI nesneler/AYNI sira, ana satir yoksa parca kendi satirinda kalir.
//   6) Masa Takip / Tumunu Gor sayimi: parca satiri 0 adet (etiket "2/2").
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/kalem_bolme.dart';

Map<String, dynamic> k(int id, String ad, double fiyat,
        {int adet = 1,
        int? parent,
        int? seq,
        int? parts,
        String? odeme,
        bool ikram = false,
        String? combo,
        String status = 'active',
        dynamic pavo}) =>
    {
      'id': id,
      'product_name': ad,
      'unit_price': fiyat,
      'quantity': adet,
      'status': status,
      'split_parent_id': parent,
      'split_seq': seq,
      'split_parts': parts,
      if (odeme != null) 'payment_status': odeme,
      'is_ikram': ikram,
      if (combo != null) 'combo_group_id': combo,
      if (pavo != null) 'pavo_tx_id': pavo,
    };

double satirToplami(List<dynamic> l) => l.fold(0.0, (a, i) {
      final m = i as Map;
      return a + KalemBolme.ondalik(m['unit_price']) * (KalemBolme.tamSayi(m['quantity']) ?? 1);
    });

void main() {
  group('esitBol — kurus duzeyi, artik SON parcaya', () {
    test('200 / 2 -> 100 + 100', () {
      expect(KalemBolme.esitBol(200, 2), [100.0, 100.0]);
    });
    test('100 / 3 -> 33.33 + 33.33 + 33.34 (artik sonda, toplam 100.00)', () {
      final p = KalemBolme.esitBol(100, 3)!;
      expect(p, [33.33, 33.33, 33.34]);
      expect(KalemBolme.toplamTutuyorMu(100, p), isTrue);
    });
    test('0.05 / 4 -> 0.01 + 0.01 + 0.01 + 0.02', () {
      expect(KalemBolme.esitBolKurus(5, 4), [1, 1, 1, 2]);
    });
    test('199.99 / 2 -> 99.99 + 100.00', () {
      expect(KalemBolme.esitBol(199.99, 2), [99.99, 100.0]);
    });
    test('her parcaya 1 kurus dusmuyorsa null; 1 parca ve 11 parca null', () {
      expect(KalemBolme.esitBolKurus(1, 2), isNull);
      expect(KalemBolme.esitBol(200, 1), isNull);
      expect(KalemBolme.esitBol(200, 11), isNull);
    });
    test('2..10 araligi tamam, toplam her zaman korunur', () {
      for (var n = 2; n <= 10; n++) {
        final p = KalemBolme.esitBol(123.45, n)!;
        expect(p.length, n);
        expect(KalemBolme.toplamTutuyorMu(123.45, p), isTrue, reason: 'n=$n');
      }
    });
  });

  group('tutarlaBol — ikinci parca KALAN, fallback YOK', () {
    test('200, ilk 120 -> [120, 80]', () {
      expect(KalemBolme.tutarlaBol(200, 120), [120.0, 80.0]);
    });
    test('kurus: 200, ilk 0.01 -> [0.01, 199.99]', () {
      expect(KalemBolme.tutarlaBol(200, 0.01), [0.01, 199.99]);
    });
    test('ilk == satir tutari -> gecersiz (kalan 0 olurdu)', () {
      expect(KalemBolme.tutarlaBol(200, 200), isNull);
    });
    test('ilk > satir tutari -> gecersiz', () {
      expect(KalemBolme.tutarlaBol(200, 200.01), isNull);
    });
    test('ilk 0 / negatif -> gecersiz', () {
      expect(KalemBolme.tutarlaBol(200, 0), isNull);
      expect(KalemBolme.tutarlaBol(200, -5), isNull);
    });
    test('0.1+0.2 tuzagi yok: 0.30, ilk 0.10 -> [0.10, 0.20] ve toplam tutar', () {
      final p = KalemBolme.tutarlaBol(0.30, 0.10)!;
      expect(p, [0.10, 0.20]);
      expect(KalemBolme.toplamTutuyorMu(0.30, p), isTrue);
    });
  });

  group('toplamTutuyorMu', () {
    test('kurus farki varsa tutmaz (sunucu 400 derdi)', () {
      expect(KalemBolme.toplamTutuyorMu(200, [100, 99.99]), isFalse);
      expect(KalemBolme.toplamTutuyorMu(200, [100, 100.01]), isFalse);
    });
    test('0 parca / bos liste tutmaz', () {
      expect(KalemBolme.toplamTutuyorMu(200, [200, 0]), isFalse);
      expect(KalemBolme.toplamTutuyorMu(200, []), isFalse);
    });
  });

  group('tutarAyristir — dokunmatik giris', () {
    test('virgul ve nokta ikisi de', () {
      expect(KalemBolme.tutarAyristir('120'), 120);
      expect(KalemBolme.tutarAyristir('120,50'), 120.5);
      expect(KalemBolme.tutarAyristir('120.5'), 120.5);
      expect(KalemBolme.tutarAyristir(' 99 '), 99);
    });
    test('bos / bozuk / sifir / cift ayrac -> null', () {
      expect(KalemBolme.tutarAyristir(''), isNull);
      expect(KalemBolme.tutarAyristir('abc'), isNull);
      expect(KalemBolme.tutarAyristir('0'), isNull);
      expect(KalemBolme.tutarAyristir('1.250,75'), isNull);
    });
    test('2 ondalik ustu RED (Web POS ile ayni; sessiz yuvarlama yok)', () {
      expect(KalemBolme.tutarAyristir('120.555'), isNull);
      expect(KalemBolme.tutarAyristir('120,555'), isNull);
      expect(KalemBolme.tutarAyristir('-5'), isNull);
      expect(KalemBolme.tutarAyristir('120,05'), 120.05);
    });
  });

  group('tutarlarlaBol — cok parca, son parca KALAN (Web POS ile ayni)', () {
    test('200: [100, 50] -> [100, 50, 50]', () {
      expect(KalemBolme.tutarlarlaBol(200, [100, 50]), [100.0, 50.0, 50.0]);
    });
    test('tek yazilan = eski iki parcali davranis', () {
      expect(KalemBolme.tutarlarlaBol(200, [120]), [120.0, 80.0]);
    });
    test('kalan 0 / eksi / sifir parca -> null', () {
      expect(KalemBolme.tutarlarlaBol(200, [100, 100]), isNull);
      expect(KalemBolme.tutarlarlaBol(200, [150, 60]), isNull);
      expect(KalemBolme.tutarlarlaBol(200, [0, 50]), isNull);
      expect(KalemBolme.tutarlarlaBol(200, []), isNull);
    });
    test('en cok 10 parca: 9 yazilan + kalan olur, 10 yazilan olmaz', () {
      expect(KalemBolme.tutarlarlaBol(200, List.filled(9, 10.0))!.length, 10);
      expect(KalemBolme.tutarlarlaBol(200, List.filled(10, 10.0)), isNull);
    });
    test('kurus toplami korunur', () {
      final p = KalemBolme.tutarlarlaBol(100, [33.33, 33.33])!;
      expect(p, [33.33, 33.33, 33.34]);
      expect(KalemBolme.toplamTutuyorMu(100, p), isTrue);
    });
  });

  group('bolunebilirMi — Bol dugmesi kurallari', () {
    test('duz, odenmemis, 1 adet, tutar>0 -> bolunebilir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200)), isTrue);
    });
    test('backend String fiyat / String adet de kabul', () {
      expect(KalemBolme.bolunebilirMi({'id': '5', 'unit_price': '200.00', 'quantity': '1'}), isTrue);
    });
    test('odenmis -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200, odeme: 'paid')), isFalse);
    });
    test('ikram (bool/int/str) -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200, ikram: true)), isFalse);
      expect(KalemBolme.bolunebilirMi({'id': 1, 'unit_price': 200, 'quantity': 1, 'is_ikram': 1}), isFalse);
      expect(KalemBolme.bolunebilirMi({'id': 1, 'unit_price': 200, 'quantity': 1, 'is_ikram': '1'}), isFalse);
    });
    test('combo uyesi -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Menu', 200, combo: 'abc')), isFalse);
    });
    test('PAVO fisi kesilmis -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200, pavo: 'tx-1')), isFalse);
    });
    test('adet != 1 -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200, adet: 2)), isFalse);
    });
    test('zaten bolunmus ana satir -> hayir; parca satiri -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 100, seq: 1, parts: 2)), isFalse);
      expect(KalemBolme.bolunebilirMi(k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2)), isFalse);
    });
    test('tutar 0 / iptal -> hayir', () {
      expect(KalemBolme.bolunebilirMi(k(1, 'Su', 0)), isFalse);
      expect(KalemBolme.bolunebilirMi(k(1, 'Adana', 200, status: 'cancelled')), isFalse);
    });
    test('Map degil -> hayir', () {
      expect(KalemBolme.bolunebilirMi(null), isFalse);
      expect(KalemBolme.bolunebilirMi('x'), isFalse);
    });
  });

  group('parca etiketi / grup', () {
    test('ana 1/2, parca 2/2; duz kalemde null', () {
      expect(KalemBolme.parcaEtiketi(k(1, 'Adana', 100, seq: 1, parts: 2)), '1/2');
      expect(KalemBolme.parcaEtiketi(k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2)), '2/2');
      expect(KalemBolme.parcaEtiketi(k(3, 'Ayran', 30)), isNull);
    });
    test('grupKalemleri: parcadan ana+kardesler, anadan parcalar; duz kalem yalniz kendisi', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 3),
        k(2, 'Adana', 50, parent: 1, seq: 2, parts: 3),
        k(3, 'Adana', 50, parent: 1, seq: 3, parts: 3),
        k(4, 'Ayran', 30),
      ];
      expect(KalemBolme.grupKalemleri(l[1], l).map((e) => e['id']).toList(), [1, 2, 3]);
      expect(KalemBolme.grupKalemleri(l[0], l).map((e) => e['id']).toList(), [1, 2, 3]);
      expect(KalemBolme.grupKalemleri(l[3], l).map((e) => e['id']).toList(), [4]);
    });
    test('gruptaOdenmisVarMi', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 2, odeme: 'paid'),
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2),
      ];
      expect(KalemBolme.gruptaOdenmisVarMi(l[1], l), isTrue);
      expect(KalemBolme.gruptaOdenmisVarMi(k(9, 'Ayran', 30), l), isFalse);
    });
  });

  group('parcasiz — fiziksel liste', () {
    test('parca yoksa AYNI liste nesnesi (0 regresyon)', () {
      final l = [k(1, 'Adana', 200), k(2, 'Ayran', 30)];
      expect(identical(KalemBolme.parcasiz(l), l), isTrue);
    });
    test('parca satirlari duser, ana satir kalir', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 2),
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2),
        k(3, 'Ayran', 30),
      ];
      expect(KalemBolme.parcasiz(l).map((e) => e['id']).toList(), [1, 3]);
    });
    test('Masa Takip / Tumunu Gor adedi: parca 0, ana 1 -> grup toplami 1 urun', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 2),
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2),
      ];
      final adet = l.fold<int>(
          0, (t, i) => t + (KalemBolme.parcaSatiriMi(i) ? 0 : (KalemBolme.tamSayi(i['quantity']) ?? 1)));
      expect(adet, 1);
      expect(satirToplami(l), 200); // para okuyucu: tutar DEGISMEZ
    });
  });

  group('parcalariAnaSatiraKatla — kasa/hesap fisi', () {
    test('🔴 REGRESYON — parca yoksa AYNI nesneler, AYNI sira', () {
      final l = [k(1, 'Adana', 200), k(2, 'Ayran', 30, adet: 3)];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(identical(s, l), isTrue);
      expect(identical(s[0], l[0]) && identical(s[1], l[1]), isTrue);
    });
    test('2 parca -> tek satir, tutar grup toplami, adet 1; diger satirlar AYNI nesne', () {
      final ayran = k(3, 'Ayran', 30);
      final l = [
        k(1, 'Adana', 120, seq: 1, parts: 2),
        ayran,
        k(2, 'Adana', 80, parent: 1, seq: 2, parts: 2),
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 2);
      expect((s[0] as Map)['id'], 1);
      expect((s[0] as Map)['unit_price'], 200.0);
      expect((s[0] as Map)['quantity'], 1);
      expect(identical(s[1], ayran), isTrue);
      expect(satirToplami(s), satirToplami(l)); // para korunur
    });
    test('3 parca kurus artikli: 33.33+33.33+33.34 -> 100.00', () {
      final l = [
        k(1, 'Kunefe', 33.33, seq: 1, parts: 3),
        k(2, 'Kunefe', 33.33, parent: 1, seq: 2, parts: 3),
        k(3, 'Kunefe', 33.34, parent: 1, seq: 3, parts: 3),
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 1);
      expect((s[0] as Map)['unit_price'], 100.0);
    });
    test('backend String fiyat ("80.00") de katlanir', () {
      final l = [
        {'id': 1, 'product_name': 'Adana', 'unit_price': '120.00', 'quantity': 1, 'split_seq': 1, 'split_parts': 2},
        {'id': 2, 'product_name': 'Adana', 'unit_price': '80.00', 'quantity': '1', 'split_parent_id': '1', 'split_seq': 2, 'split_parts': 2},
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 1);
      expect((s[0] as Map)['unit_price'], 200.0);
    });
    test('ana satir listede YOKSA parca kendi satirinda kalir (tutar kaybolmaz)', () {
      final l = [k(2, 'Adana', 80, parent: 1, seq: 2, parts: 2), k(3, 'Ayran', 30)];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 2);
      expect(satirToplami(s), 110);
    });
    test('kaynak liste DEGISMEZ (ana satir kopyalanir)', () {
      final ana = k(1, 'Adana', 120, seq: 1, parts: 2);
      final l = [ana, k(2, 'Adana', 80, parent: 1, seq: 2, parts: 2)];
      KalemBolme.parcalariAnaSatiraKatla(l);
      expect(ana['unit_price'], 120.0);
      expect(l.length, 2);
    });
    test('parcalar FARKLI yontemle odendiyse katlanan satir tek yontem tasimaz (PARÇALI)', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 2, odeme: 'paid')..['payment_method'] = 'cash',
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2, odeme: 'paid')..['payment_method'] = 'card',
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 1);
      expect((s[0] as Map)['payment_status'], KalemBolme.karisikOdemeDurumu);
      expect((s[0] as Map)['payment_method'], KalemBolme.karisikOdemeYontemi);
      expect((s[0] as Map)['unit_price'], 200.0);
    });
    test('biri odenmis biri odenmemis -> yine PARÇALI; ikisi de ayni yontemle odenmisse ana yontem kalir', () {
      final karisik = [
        k(1, 'Adana', 100, seq: 1, parts: 2, odeme: 'paid')..['payment_method'] = 'cash',
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2),
      ];
      expect((KalemBolme.parcalariAnaSatiraKatla(karisik)[0] as Map)['payment_status'],
          KalemBolme.karisikOdemeDurumu);
      final ayni = [
        k(1, 'Adana', 100, seq: 1, parts: 2, odeme: 'paid')..['payment_method'] = 'cash',
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2, odeme: 'paid')..['payment_method'] = 'cash',
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(ayni);
      expect((s[0] as Map)['payment_status'], 'paid');
      expect((s[0] as Map)['payment_method'], 'cash');
    });
    test('kasa birlestirme anahtariyla uyum: katlanan satir duz 200 TL Adana ile ayni fiyatta', () {
      final l = [
        k(1, 'Adana', 100, seq: 1, parts: 2),
        k(2, 'Adana', 100, parent: 1, seq: 2, parts: 2),
        k(3, 'Adana', 200),
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 2);
      expect(KalemBolme.ondalik((s[0] as Map)['unit_price']).toStringAsFixed(4),
          KalemBolme.ondalik((s[1] as Map)['unit_price']).toStringAsFixed(4));
    });
  });
  // 30 Eki 2026 Fable ORTA-1: cevrimdisi yerel aynada id = YEREL local_id, sunucu id'si
  // server_id'de; parcanin split_parent_id'si SUNUCU id. Katlama/grup server_id ile eslesmeli.
  group('cevrimdisi bicim (id=yerel, server_id=sunucu)', () {
    Map<String, dynamic> yerel(int yerelId, int? sunucuId, double fiyat,
            {int? parent, int? seq, int? parts}) =>
        {
          'id': yerelId,
          'local_id': yerelId,
          'server_id': sunucuId,
          'product_name': 'Dag Kekikli Tavuk',
          'unit_price': fiyat,
          'quantity': 1,
          'status': 'active',
          'split_parent_id': parent,
          'split_seq': seq,
          'split_parts': parts,
        };
    final l = [
      yerel(41, 509158, 120, seq: 1, parts: 2),
      yerel(42, 509191, 60, parent: 509158, seq: 2, parts: 2),
      yerel(43, null, 30),
    ];
    test('kasa fisi: parca ana satira katlanir (tek satir, grup toplami)', () {
      final s = KalemBolme.parcalariAnaSatiraKatla(l);
      expect(s.length, 2);
      expect((s[0] as Map)['local_id'], 41);
      expect(KalemBolme.ondalik((s[0] as Map)['unit_price']), 180.0);
      expect((s[0] as Map)['quantity'], 1);
      expect(identical(s[1], l[2]), isTrue);
    });
    test('grupKalemleri: parcadan ve anadan 2 uye; sunucu id\'siz satir yalniz kendisi', () {
      expect(KalemBolme.grupKalemleri(l[1], l).map((e) => e['local_id']).toList(), [41, 42]);
      expect(KalemBolme.grupKalemleri(l[0], l).map((e) => e['local_id']).toList(), [41, 42]);
      expect(KalemBolme.grupKalemleri(l[2], l).map((e) => e['local_id']).toList(), [43]);
    });
    test('cevrimici bicim (server_id yok) degismedi', () {
      final c = [
        {'id': 509158, 'unit_price': 120, 'quantity': 1, 'split_seq': 1, 'split_parts': 2},
        {'id': 509191, 'unit_price': 60, 'quantity': 1, 'split_parent_id': 509158, 'split_seq': 2, 'split_parts': 2},
      ];
      final s = KalemBolme.parcalariAnaSatiraKatla(c);
      expect(s.length, 1);
      expect(KalemBolme.ondalik((s[0] as Map)['unit_price']), 180.0);
    });
  });
}
