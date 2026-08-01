// 1 Ağu 2026 — COMBO TÜM HEDİYE TİPLERİ × TÜM İHTİMALLER: JS↔Dart PARİTE
//
// Mustafa: "combonun hediye tiplerinin tamamını denesene emin ol zorunludur"
//          "tüm seçenekleri ve ihtimalleriyle bu arada"
//
// 🔴 PARA KRİTİK — bu testin varlık sebebi:
//   POS (Dart) adisyon ekranında combo indirimini GÖSTERİR.
//   Backend (JS comboCalculator) hesabı kapatırken AUTHORITATIVE hesaplar
//   (tickets.js close → panel_products'tan SQL ile okur, POS payload'ına GÜVENMEZ).
//   İkisi 1 kuruş ayrışırsa müşteriye gösterilen ile tahsil edilen tutar farklı olur.
//
// fixtures/combo_matris.json CANLI backend'de (18.194.103.51) gerçek üretim
// comboCalculator.js çalıştırılarak üretildi. Beklenen değerler benim yazdığım
// değil, ÜRETİM KODUNUN ÇIKTISI. Üretmek için: scratchpad/combo_matris.js → node.
//
// İKİ AYRI ŞEKİL denenir — ikisi de gerçek:
//   ONLINE  şekil: combo_enabled=true (PostgreSQL boolean, backend feed'i)
//   OFFLINE şekil: combo_enabled=1    (SQLite INTEGER — boolean tipi YOK)
// Çevrimdışı kasa aynı ürüne aynı indirimi göstermek ZORUNDA.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/combo_calculator.dart';

/// SQLite'ın gerçekten döndürdüğü şekle çevir: boolean YOK, INTEGER var.
/// local_db_service.dart:827/833/839 bu üç alanı 0/1 olarak yazar.
Map<String, dynamic> offlineSekli(Map<String, dynamic> urun) {
  final o = Map<String, dynamic>.from(urun);
  for (final k in ['combo_enabled', 'combo_repeat', 'combo_pos_unlimited']) {
    if (o[k] is bool) o[k] = (o[k] as bool) ? 1 : 0;
  }
  return o;
}

void main() {
  final ham = File('test/fixtures/combo_matris.json').readAsStringSync();
  final senaryolar = (jsonDecode(ham) as List).cast<Map<String, dynamic>>();

  // Üretimde gerçekten oluşabilecek şekiller: combo_enabled GERÇEK boolean.
  // ('true' metni / 1 sayısı gibi sentetik tipler ONLINE feed'de asla oluşmaz —
  //  onlar ayrı grupta, "katı guard" kanıtı olarak sınanır.)
  bool bolAlanSaglam(Map u) => ['combo_enabled', 'combo_repeat', 'combo_pos_unlimited']
      .every((k) => !u.containsKey(k) || u[k] == null || u[k] is bool);
  final uretimSekli =
      senaryolar.where((s) => bolAlanSaglam(s['urun'] as Map)).toList();

  ComboResult calc(Map<String, dynamic> urun, Map<String, dynamic> s) =>
      ComboCalculator.calcComboForProduct(
        urun,
        (s['satirlar'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );

  /// Bir sonucu JS beklentisiyle karşılaştır; ayrışmaları listeye yaz.
  void kiyasla(ComboResult r, Map<String, dynamic> s, List<String> hatalar,
      String etiket) {
    final bek = s['bek'] as Map<String, dynamic>;
    void kar(String alan, Object? dart, Object? js) {
      if (dart.toString() != js.toString()) {
        hatalar.add('#${s['id']} [$etiket ${s['ad']}] $alan: Dart=$dart JS=$js');
      }
    }

    kar('eligible', r.eligible, bek['eligible']);
    kar('sets', r.sets, bek['sets']);
    kar('giftUnits', r.giftUnits, bek['giftUnits']);
    kar('mode', r.mode, bek['mode']);
    kar('label', r.label, bek['label']);

    // Para alanları: tolerans YOK, kuruşu kuruşuna.
    final dI = (r.discountAmount * 100).round() / 100;
    final jI = ((bek['discountAmount'] as num).toDouble() * 100).round() / 100;
    if (dI != jI) {
      hatalar.add('#${s['id']} [$etiket ${s['ad']}] discountAmount: '
          'Dart=$dI JS=$jI · FARK ${(dI - jI).toStringAsFixed(2)} TL');
    }
    final dH = (r.giftUnitPrice * 100).round() / 100;
    final jH = ((bek['giftUnitPrice'] as num).toDouble() * 100).round() / 100;
    if (dH != jH) {
      hatalar.add('#${s['id']} [$etiket ${s['ad']}] giftUnitPrice: Dart=$dH JS=$jH');
    }
  }

  test('matris gerçekten dolu — boş kıyasla "geçti" demeyelim', () {
    expect(senaryolar.length, greaterThan(4000));
    expect(uretimSekli.length, greaterThan(4000));
    final indirimli =
        senaryolar.where((s) => (s['bek']['discountAmount'] as num) > 0).length;
    final hediyeli =
        senaryolar.where((s) => (s['bek']['giftUnits'] as num) > 0).length;
    final modlar = senaryolar.map((s) => s['bek']['mode'] as String).toSet();
    expect(indirimli, greaterThan(2000),
        reason: 'İndirim üreten senaryo yoksa test hiçbir şeyi kanıtlamaz');
    expect(hediyeli, greaterThan(1000), reason: 'Hediye üreten senaryo yok');
    expect(modlar, containsAll(<String>{
      'none', 'gift-within', 'gift-extra', 'percent', 'amount',
    }), reason: 'Hediye tiplerinin TAMAMI denenmeli (Mustafa: "zorunludur")');
    // ignore: avoid_print
    print('MATRİS: ${senaryolar.length} senaryo · üretim şekli=${uretimSekli.length} '
        '· indirimli=$indirimli · hediyeli=$hediyeli · modlar=$modlar');
  });

  test('ONLINE şekil (PG boolean): Dart == JS, kuruşu kuruşuna', () {
    final hatalar = <String>[];
    for (final s in uretimSekli) {
      kiyasla(calc(Map<String, dynamic>.from(s['urun'] as Map), s), s, hatalar,
          'ONLINE');
    }
    if (hatalar.isNotEmpty) {
      fail('${hatalar.length} AYRIŞMA (ilk 25):\n${hatalar.take(25).join('\n')}');
    }
    // ignore: avoid_print
    print('✓ ONLINE ${uretimSekli.length} senaryo — Dart ile JS BİREBİR');
  });

  test('🔴 OFFLINE şekil (SQLite INTEGER 0/1): çevrimdışı kasa AYNI indirimi göstermeli',
      () {
    // SQLite boolean tutmaz. İnternet gidince POS ürünü cached_products'tan okur ve
    // combo_enabled/combo_repeat/combo_pos_unlimited 0/1 INTEGER gelir. Kasa aynı
    // ürüne çevrimiçiyken gösterdiği indirimi çevrimdışıyken de göstermek ZORUNDA —
    // aksi halde ekranda bir tutar, kapanışta (backend authoritative) başka tutar.
    final hatalar = <String>[];
    for (final s in uretimSekli) {
      final urun = offlineSekli(Map<String, dynamic>.from(s['urun'] as Map));
      kiyasla(calc(urun, s), s, hatalar, 'OFFLINE');
    }
    if (hatalar.isNotEmpty) {
      final paraliy = hatalar.where((h) => h.contains('FARK')).toList();
      fail('${hatalar.length} AYRIŞMA (${paraliy.length} tanesi PARA farkı).\n'
          'İlk 25:\n${hatalar.take(25).join('\n')}');
    }
    // ignore: avoid_print
    print('✓ OFFLINE ${uretimSekli.length} senaryo — çevrimdışı == çevrimiçi');
  });

  test('katı guard: sentetik tipler ("true" metni, 1 sayısı) ONLINE feed\'de yok',
      () {
    // Bu şekiller PostgreSQL'den ASLA gelmez; JS `!== true` ile eler.
    // Dart'ta _truthy bilerek gevşek — SQLite INTEGER'ı kabul etmek ZORUNDA
    // (yukarıdaki OFFLINE testi bunun taşıyıcı olduğunu kanıtlıyor).
    // Yani buradaki fark BİLİNÇLİ ve üretimde tetiklenmez.
    // NOT: sadece combo_enabled'ın TİPİ eleme sebebidir (JS `!== true`).
    // combo_repeat:'false' gibi metinler JS'te eleme YAPMAZ (`!== false` → repeat açık) —
    // bu yüzden "tüm sentetikler reddedilir" demek YANLIŞ olurdu.
    final acmaSentetik = senaryolar
        .where((s) => !((s['urun'] as Map)['combo_enabled'] is bool))
        .toList();
    expect(acmaSentetik, isNotEmpty);
    for (final s in acmaSentetik) {
      expect(s['bek']['eligible'], false,
          reason: 'JS combo_enabled non-boolean şekli elemeli (#${s['id']} ${s['ad']})');
    }
  });

  group('İş kuralı kanıtları', () {
    /// Adı parçayı içeren VE sepeti dolu (Q>0) ilk senaryo.
    Map<String, dynamic> bul(String parca) => senaryolar.firstWhere((s) =>
        (s['ad'] as String).contains(parca) &&
        (s['satirlar'] as List).isNotEmpty &&
        (s['bek']['eligible'] as bool));

    test('TEK MOD: hediye varsa yüzde/sabit YOK SAYILIR', () {
      final s = bul('catisma-G1+yuzde50+sabit500');
      expect(s['bek']['mode'], 'gift-within',
          reason: 'Hediye + yüzde + sabit birlikte tanımlıysa HEDİYE kazanır');
    });

    test('yüzde + sabit birlikte → YÜZDE öncelikli', () {
      expect(bul('catisma-yuzde20+sabit100')['bek']['mode'], 'percent');
    });

    test('extra hediyede indirim 0 — bedava ÜRÜN verilir', () {
      final ler = senaryolar.where((s) =>
          s['bek']['mode'] == 'gift-extra' && (s['bek']['giftUnits'] as num) > 0);
      expect(ler, isNotEmpty);
      for (final s in ler) {
        expect(s['bek']['discountAmount'], 0,
            reason: 'extra modda indirim yok, fiziksel hediye var (#${s['id']})');
      }
    });

    test('kısmi sette extra hediye FİZİKSEL ürün vermez (ciro koruması)', () {
      // Bu senaryo bilerek eligible=FALSE döner: yarım sete ne bedava ürün ne
      // indirim verilir; müşteri seçtiği kadarını normal fiyattan öder.
      final s = senaryolar.firstWhere((x) => (x['ad'] as String).contains('kismi extra'));
      expect(s['bek']['giftUnits'], 0, reason: 'yarım sete fiziksel hediye YASAK');
      expect(s['bek']['discountAmount'], 0, reason: 'yarım sete indirim de yok');
    });

    test('pos_unlimited KAPALIYKEN eksik set indirim ALMAZ', () {
      final ler = senaryolar.where((s) {
        final u = s['urun'] as Map;
        final N = u['combo_required_qty'];
        if (u['combo_pos_unlimited'] != false || N is! int || N < 2) return false;
        final adet = (s['satirlar'] as List).length;
        return adet > 0 && adet < N;   // eksik set
      });
      expect(ler.length, greaterThan(50), reason: 'Eksik-set senaryosu az');
      for (final s in ler) {
        expect(s['bek']['eligible'], false,
            reason: 'limitsiz kapalıyken Q<N indirim almamalı (#${s['id']} ${s['ad']})');
        expect(s['bek']['discountAmount'], 0);
      }
    });

    test('indirim hiçbir senaryoda sepet tutarını AŞAMAZ', () {
      for (final s in senaryolar) {
        var toplam = 0.0;
        for (final l in (s['satirlar'] as List)) {
          final up = double.tryParse('${(l as Map)['unit_price'] ?? 0}') ?? 0;
          final q = int.tryParse('${l['qty'] ?? 0}') ?? 0;
          if (q > 0) toplam += up * q;
        }
        expect((s['bek']['discountAmount'] as num).toDouble(),
            lessThanOrEqualTo(toplam + 0.001),
            reason: '#${s['id']} [${s['ad']}] indirim > sepet → NEGATİF TUTAR riski');
      }
    });

    test('indirim hiçbir senaryoda NEGATİF olamaz', () {
      for (final s in senaryolar) {
        expect((s['bek']['discountAmount'] as num).toDouble(),
            greaterThanOrEqualTo(0),
            reason: '#${s['id']} [${s['ad']}] negatif indirim = fiyat ARTIŞI');
      }
    });
  });
}
