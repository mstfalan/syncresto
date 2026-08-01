// 1 Ağu 2026 — ÜRÜN İÇERİKLERİ + VARYANT SEÇİM GRUPLARI
// Mustafa: "bizim aslında içerikler kısmını da eklememiz lazım. onu webde gösteriyoruz
// ama POS'da göstermiyoruz. keza çoklu seçimi de?"
//
// 🔴 ASIL AMAÇ REGRESYON: içerik VE gruplu varyant YOKSA hiçbir şey değişmemeli —
// ürün eski akışla eklenmeli, ek bölüm çizilmemeli.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

// --- add_item_modal.dart ile AYNI kurallar ---
List<Map<String, dynamic>> urunIcerikleri(Map<String, dynamic> p) {
  final raw = p['ingredients'];
  List list;
  if (raw is List) {
    list = raw;
  } else if (raw is String && raw.trim().isNotEmpty) {
    try { final d = jsonDecode(raw); list = d is List ? d : const []; } catch (_) { return const []; }
  } else {
    return const [];
  }
  return list
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .where((e) => (e['name'] ?? '').toString().trim().isNotEmpty)
      .toList();
}

Map<String, List<Map<String, dynamic>>> varyantGruplari(List variants) {
  final g = <String, List<Map<String, dynamic>>>{};
  for (final raw in variants) {
    if (raw is! Map) continue;
    final v = Map<String, dynamic>.from(raw);
    (g[(v['group_name'] ?? '').toString().trim()] ??= []).add(v);
  }
  return g;
}

bool grupluVaryantli(Map<String, dynamic> p) {
  final v = (p['variants'] is List) ? p['variants'] as List : const [];
  return v.any((x) => x is Map && (x['group_name'] ?? '').toString().trim().isNotEmpty);
}

double icerikFiyati(Map<String, dynamic> i) {
  final p = i['price'];
  if (p is num) return p.toDouble();
  return double.tryParse('${p ?? ''}') ?? 0;
}

double varyantMod(Map v) {
  final rm = v['restaurant_modifier'];
  if (rm != null) return (rm as num).toDouble();
  return (v['price_modifier'] as num?)?.toDouble() ?? 0;
}

double toplam(double baz, List<Map<String, dynamic>> varyant,
        List<Map<String, dynamic>> eklenen, List<Map<String, dynamic>> cikarilan) =>
    baz +
    varyant.fold<double>(0, (t, v) => t + varyantMod(v)) +
    eklenen.fold<double>(0, (t, e) => t + icerikFiyati(e)) +
    cikarilan.fold<double>(0, (t, c) => t + icerikFiyati(c));

void main() {
  tekKararTestleri();
  grupsuzVaryantTestleri();
  ucluSecimTestleri();
  group('🔴 REGRESYON — içerik/grup YOKSA eski davranış', () {
    test('ingredients alanı hiç yok → boş liste, bölüm çizilmez', () {
      expect(urunIcerikleri({'name': 'Çay'}), isEmpty);
    });
    test('ingredients boş dizi → boş', () {
      expect(urunIcerikleri({'ingredients': []}), isEmpty);
    });
    test('bozuk JSON metin → boş (patlamaz)', () {
      expect(urunIcerikleri({'ingredients': '{bozuk'}), isEmpty);
    });
    test('adı boş içerik atlanır', () {
      expect(urunIcerikleri({'ingredients': [{'name': '  '}, {'name': 'Soğan'}]}).length, 1);
    });
    test('group_name yoksa gruplu sayılmaz → düz liste', () {
      expect(grupluVaryantli({'variants': [{'id': 1, 'name': 'Büyük'}]}), false);
    });
    test('group_name boş string → gruplu sayılmaz', () {
      expect(grupluVaryantli({'variants': [{'id': 1, 'group_name': '  '}]}), false);
    });
  });

  group('İçerik okuma', () {
    final p = {
      'ingredients': [
        {'id': 1, 'name': 'Soğan', 'role': 'removable', 'price': -20},
        {'id': 2, 'name': 'Ekstra Peynir', 'role': 'addon', 'price': 10},
      ]
    };
    test('JSON metin de çözülür (çevrimdışı cache)', () {
      expect(urunIcerikleri({'ingredients': jsonEncode(p['ingredients'])}).length, 2);
    });
    test('rol ayrımı doğru', () {
      final ic = urunIcerikleri(p);
      expect(ic.where((x) => x['role'] == 'removable').length, 1);
      expect(ic.where((x) => x['role'] == 'addon').length, 1);
    });
    test('fiyat metin gelse de çözülür', () {
      expect(icerikFiyati({'price': '10.5'}), 10.5);
      expect(icerikFiyati({'price': null}), 0);
    });
  });

  group('Varyant grupları', () {
    final variants = [
      {'id': 1, 'name': 'Patates', 'group_name': 'Yan ürün seçimi 1', 'group_required': true, 'group_multi': false, 'price_modifier': 0},
      {'id': 2, 'name': 'Salata', 'group_name': 'Yan ürün seçimi 1', 'group_required': true, 'group_multi': false, 'price_modifier': 10},
      {'id': 3, 'name': 'Acılı', 'group_name': 'Acılı / Acısız', 'group_required': true, 'group_multi': false, 'price_modifier': 0},
      {'id': 4, 'name': 'Büyük Boy', 'price_modifier': 50},
    ];
    test('gruplar ayrışır, grupsuzlar boş anahtarda toplanır', () {
      final g = varyantGruplari(variants);
      expect(g.keys.toSet(), {'Yan ürün seçimi 1', 'Acılı / Acısız', ''});
      expect(g['Yan ürün seçimi 1']!.length, 2);
      expect(g['']!.length, 1);
    });
    test('gruplu ürün tespit edilir', () {
      expect(grupluVaryantli({'variants': variants}), true);
    });
  });

  group('💰 Fiyat matematiği', () {
    test('ana + varyant + eklenen + çıkarılan', () {
      final t = toplam(
        300,
        [{'price_modifier': 50}],              // +50
        [{'price': 10}],                        // +10
        [{'price': -20}],                       // -20
      );
      expect(t, 340);
    });
    test('hiç seçim yoksa ana fiyat', () {
      expect(toplam(300, [], [], []), 300);
    });
    test('çıkarılan içerik fiyatı 0 ise tutar değişmez', () {
      expect(toplam(300, [], [], [{'price': 0}]), 300);
    });
    test('restaurant_modifier price_modifier\'ı ezer', () {
      expect(toplam(100, [{'price_modifier': 50, 'restaurant_modifier': 20}], [], []), 120);
    });
    test('çoklu grup seçimi toplanır', () {
      expect(toplam(200, [{'price_modifier': 10}, {'price_modifier': 15}], [], []), 225);
    });
  });

  group('Zorunlu grup kuralı', () {
    bool hazir(List variants, Map<String, List> secilen) {
      final g = varyantGruplari(variants);
      for (final ad in g.keys) {
        if (ad.isEmpty) continue;
        if (g[ad]!.first['group_required'] == true && (secilen[ad]?.isEmpty ?? true)) return false;
      }
      return true;
    }
    final v = [
      {'id': 1, 'group_name': 'G1', 'group_required': true},
      {'id': 2, 'group_name': 'G2', 'group_required': false},
    ];
    test('zorunlu grup seçilmeden eklenemez', () {
      expect(hazir(v, {}), false);
    });
    test('zorunlu grup seçilince eklenebilir (opsiyonel boş olsa da)', () {
      expect(hazir(v, {'G1': [{'id': 1}]}), true);
    });
    test('hiç zorunlu grup yoksa her zaman hazır', () {
      expect(hazir([{'id': 1, 'group_name': 'G', 'group_required': false}], {}), true);
    });
  });
}

// 1 Ağu 2026 — TEK KARAR NOKTASI (_varyantEkraniAc)
// Mustafa: "combo ve varyant aynı anda açıksa POS'ta seçim ekranı gösteriyorduk,
// bunda nasıl yapabiliriz?" → Artık 3 varyant ekranı var; hangisinin açılacağına
// TEK yer karar veriyor ve 4 giriş noktası (ürüne tıklama, varyant butonu,
// combo seçim ekranının "Varyant" dalı, çoklu) hepsi ondan geçiyor.
enum Ekran { icerikGruplu, coklu, tekli }

Ekran varyantEkrani(Map<String, dynamic> p) {
  if (urunIcerikleri(p).isNotEmpty || grupluVaryantli(p)) return Ekran.icerikGruplu;
  final v = p['variants_allow_multiple_pos'];
  if (v == true || v == 1 || v == '1' || v == 'true') return Ekran.coklu;
  return Ekran.tekli;
}

void tekKararTestleri() {
  final duzVaryant = [
    {'id': 1, 'name': 'Büyük', 'price_modifier': 50}
  ];
  final grupluVaryant = [
    {'id': 1, 'name': 'Patates', 'group_name': 'Yan ürün', 'group_required': true}
  ];
  final icerik = [
    {'id': 1, 'name': 'Soğan', 'role': 'removable', 'price': -20}
  ];

  group('Tek karar noktası — hangi ekran açılır', () {
    test('içerik VAR → içerik/gruplu ekran (en zengin)', () {
      expect(varyantEkrani({'variants': duzVaryant, 'ingredients': icerik}),
          Ekran.icerikGruplu);
    });

    test('gruplu varyant VAR → içerik/gruplu ekran', () {
      expect(varyantEkrani({'variants': grupluVaryant}), Ekran.icerikGruplu);
    });

    test('içerik + çoklu birlikte → içerik/gruplu KAZANIR', () {
      expect(
          varyantEkrani({
            'variants': duzVaryant,
            'ingredients': icerik,
            'variants_allow_multiple_pos': true
          }),
          Ekran.icerikGruplu);
    });

    test('sadece çoklu → çoklu ekran', () {
      expect(
          varyantEkrani({'variants': duzVaryant, 'variants_allow_multiple_pos': true}),
          Ekran.coklu);
    });

    test('🔴 hiçbiri yok → TEKLİ (eski akış birebir korunur)', () {
      expect(varyantEkrani({'variants': duzVaryant}), Ekran.tekli);
    });

    test('boş içerik dizisi tekliyi bozmaz', () {
      expect(varyantEkrani({'variants': duzVaryant, 'ingredients': []}), Ekran.tekli);
    });
  });

  group('Combo + varyant birlikte — seçim ekranı çıkmalı mı', () {
    bool secimEkraniCikar(Map<String, dynamic> p) {
      final comboAktif = p['combo_enabled'] == true || p['combo_enabled'] == 1;
      final v = (p['variants'] is List) ? p['variants'] as List : const [];
      if (!comboAktif || v.isEmpty) return false;
      final coklu = p['variants_allow_multiple_pos'] == true;
      return coklu || urunIcerikleri(p).isNotEmpty || grupluVaryantli(p);
    }

    test('combo + çoklu → seçim ekranı', () {
      expect(
          secimEkraniCikar({
            'combo_enabled': true,
            'variants': duzVaryant,
            'variants_allow_multiple_pos': true
          }),
          true);
    });

    test('combo + İÇERİK → seçim ekranı (yeni kural)', () {
      expect(
          secimEkraniCikar(
              {'combo_enabled': true, 'variants': duzVaryant, 'ingredients': icerik}),
          true);
    });

    test('combo + GRUPLU varyant → seçim ekranı (yeni kural)', () {
      expect(secimEkraniCikar({'combo_enabled': true, 'variants': grupluVaryant}), true);
    });

    test('🔴 combo + düz varyant (özellik yok) → seçim ekranı ÇIKMAZ, combo ekranı', () {
      expect(secimEkraniCikar({'combo_enabled': true, 'variants': duzVaryant}), false);
    });

    test('combo yok → seçim ekranı çıkmaz', () {
      expect(secimEkraniCikar({'variants': duzVaryant, 'ingredients': icerik}), false);
    });
  });
}

// 1 Ağu 2026 — ÜÇ SEÇENEKLİ EKRAN + TOGGLE KURALI
// Mustafa: "eklenebilir çıkartılabilir varyantı eziyor. hepsi dolu olduğunda pop
// penceresinde seçenek çıksın COMBO - VARYANT - EKLE/ÇIKAR" + "ayarlarda bu pop
// direkt açılsın açılmasın seçeneği var, yine ona uyacağız"
void ucluSecimTestleri() {
  final duz = [{'id': 1, 'name': 'Büyük', 'price_modifier': 50}];
  final gruplu = [{'id': 1, 'name': 'Patates', 'group_name': 'Yan ürün', 'group_required': true}];
  final ic = [{'id': 1, 'name': 'Soğan', 'role': 'removable', 'price': -20}];

  // Seçim ekranında kaç kart çıkar
  List<String> kartlar(Map<String, dynamic> p) {
    final combo = p['combo_enabled'] == true;
    final v = (p['variants'] is List) ? p['variants'] as List : const [];
    final icerik = urunIcerikleri(p).isNotEmpty;
    final coklu = p['variants_allow_multiple_pos'] == true;
    final varyantOzelligi = coklu || grupluVaryantli(p) || icerik;
    final out = <String>[];
    if (combo) {
      // içerik ARTIK ayrı kart değil — "Varyant" seçilince açılan pencerede sekme
      if (v.isNotEmpty && varyantOzelligi) { out.add('varyant'); out.add('combo'); }
      return out;
    }
    // 1 Ağu: varyant+içerik ARA EKRAN AÇMAZ — tek pencerede sekme olur
    return const [];
  }

  // "Sorayım mı" — global toggle kuralı
  bool sorulacak(Map<String, dynamic> p, {required bool toggle}) {
    final v = (p['variants'] is List) ? p['variants'] as List : const [];
    final zorunluGrup = v.any((x) =>
        x is Map &&
        (x['group_name'] ?? '').toString().trim().isNotEmpty &&
        x['group_required'] == true);
    final zorunluPos = p['variants_required_pos'] == true;
    return zorunluGrup || zorunluPos || toggle;
  }

  group('Seçim ekranı — kaç kart', () {
    test('COMBO + VARYANT + İÇERİK → 2 kart (içerik sekmede)', () {
      final k = kartlar({'combo_enabled': true, 'variants': gruplu, 'ingredients': ic});
      expect(k.toSet(), {'varyant', 'combo'});
    });

    test('combo + içerik → varyant + combo (içerik sekmede)', () {
      final k = kartlar({'combo_enabled': true, 'variants': duz, 'ingredients': ic});
      expect(k.contains('combo'), true);
    });

    test('🔑 combo yok, varyant + içerik → ARA EKRAN YOK (sekmeli tek pencere)', () {
      // 1 Ağu (Mustafa): "boşa tık yapmasın sonuçta aynı ürüne ait"
      expect(kartlar({'variants': duz, 'ingredients': ic}), isEmpty);
    });

    test('🔴 sadece düz varyant → kart YOK, doğrudan varyant ekranı', () {
      expect(kartlar({'variants': duz}), isEmpty);
    });

    test('sadece içerik, varyant yok → kart yok (tek ekran)', () {
      expect(kartlar({'variants': [], 'ingredients': ic}), isEmpty);
    });

    test('🔑 sekme SADECE hem varyant hem içerik varsa çıkar', () {
      bool sekmeVar(Map<String, dynamic> p) {
        final v = (p['variants'] is List) ? p['variants'] as List : const [];
        return v.isNotEmpty && urunIcerikleri(p).isNotEmpty;
      }
      expect(sekmeVar({'variants': duz, 'ingredients': ic}), true);
      expect(sekmeVar({'variants': duz}), false);
      expect(sekmeVar({'variants': [], 'ingredients': ic}), false);
    });
  });

  group('🔑 Global toggle (POS Davranışı) kuralı korunuyor', () {
    test('toggle KAPALI + hiçbir zorunluluk yok → SORMAZ (doğrudan ekle)', () {
      expect(sorulacak({'variants': duz, 'ingredients': ic}, toggle: false), false);
    });

    test('toggle AÇIK → sorar', () {
      expect(sorulacak({'variants': duz, 'ingredients': ic}, toggle: true), true);
    });

    test('zorunlu GRUP varsa toggle kapalı olsa da sorar', () {
      expect(sorulacak({'variants': gruplu}, toggle: false), true);
    });

    test('variants_required_pos açıksa toggle kapalı olsa da sorar', () {
      expect(
          sorulacak({'variants': duz, 'variants_required_pos': true}, toggle: false), true);
    });
  });
}

// 1 Ağu 2026 — GRUPSUZ VARYANT KAYBI (Mustafa: "çoklu seçim yok, onu eklememişsin")
// İçerik/gruplu ekranında `if (grupAdi.isEmpty) return;` ile grupsuz varyantlar
// ATLANIYORDU ve "düz varyantlar aşağıda" notu vardı ama aşağıda bölüm YOKTU.
// Sonuç: gruplu + düz varyantı olan üründe DÜZ OLANLAR KAYBOLUYORDU.
void grupsuzVaryantTestleri() {
  // Ekranda çizilecek bölümleri döndürür (add_item_modal ile aynı kural)
  List<String> bolumler(Map<String, dynamic> p, {String mod = 'hepsi'}) {
    final varyantGoster = mod == 'hepsi' || mod == 'varyant';
    final icerikGoster = mod == 'hepsi' || mod == 'icerik';
    final v = (p['variants'] is List) ? p['variants'] as List : const [];
    final g = varyantGoster ? varyantGruplari(v) : <String, List<Map<String, dynamic>>>{};
    final ic = icerikGoster ? urunIcerikleri(p) : <Map<String, dynamic>>[];
    final out = <String>[];
    g.forEach((ad, list) { if (ad.isNotEmpty) out.add('grup:$ad'); });
    if ((g[''] ?? const []).isNotEmpty) out.add('duz-varyant');
    if (ic.any((x) => x['role'] == 'removable')) out.add('cikar');
    if (ic.any((x) => x['role'] == 'addon')) out.add('ekle');
    return out;
  }

  final karisik = [
    {'id': 1, 'name': 'Patates', 'group_name': 'Yan ürün', 'group_required': true},
    {'id': 2, 'name': 'Salata', 'group_name': 'Yan ürün', 'group_required': true},
    {'id': 3, 'name': 'Büyük Boy', 'price_modifier': 50},   // GRUPSUZ
    {'id': 4, 'name': 'Acılı', 'price_modifier': 0},        // GRUPSUZ
  ];
  final ic = [
    {'id': 1, 'name': 'Soğan', 'role': 'removable', 'price': -20},
    {'id': 2, 'name': 'Peynir', 'role': 'addon', 'price': 10},
  ];

  group('🔴 Grupsuz varyantlar KAYBOLMAMALI', () {
    test('gruplu + düz karışık → HER İKİSİ de çizilir', () {
      final b = bolumler({'variants': karisik});
      expect(b.contains('grup:Yan ürün'), true);
      expect(b.contains('duz-varyant'), true, reason: 'düz varyantlar kayboldu');
    });

    test('sadece düz varyant → düz bölüm çizilir', () {
      final b = bolumler({'variants': [{'id': 1, 'name': 'Büyük'}]});
      expect(b, ['duz-varyant']);
    });

    test('mod=varyant → içerik çizilmez, düz varyant KALIR', () {
      final b = bolumler({'variants': karisik, 'ingredients': ic}, mod: 'varyant');
      expect(b.contains('duz-varyant'), true);
      expect(b.contains('ekle'), false);
      expect(b.contains('cikar'), false);
    });

    test('mod=icerik → varyantlar çizilmez, içerik kalır', () {
      final b = bolumler({'variants': karisik, 'ingredients': ic}, mod: 'icerik');
      expect(b.contains('duz-varyant'), false);
      expect(b.contains('grup:Yan ürün'), false);
      expect(b.toSet(), {'cikar', 'ekle'});
    });

    test('hepsi birlikte → 4 bölüm (grup + düz + çıkar + ekle)', () {
      final b = bolumler({'variants': karisik, 'ingredients': ic});
      expect(b.length, 4);
    });
  });

  group('Düz varyantta çoklu seçim ayarı', () {
    // coklu ACIK -> birden fazla seçilebilir, KAPALI -> tek seçim
    List<int> sec(List<int> mevcut, int yeni, bool coklu) {
      if (mevcut.contains(yeni)) return mevcut.where((x) => x != yeni).toList();
      if (!coklu) return [yeni];
      return [...mevcut, yeni];
    }
    test('çoklu KAPALI → ikinci seçim öncekini değiştirir', () {
      expect(sec([1], 2, false), [2]);
    });
    test('çoklu AÇIK → ikinci seçim birikir', () {
      expect(sec([1], 2, true), [1, 2]);
    });
    test('aynısına tekrar basınca seçim kalkar (her iki modda)', () {
      expect(sec([1, 2], 2, true), [1]);
      expect(sec([1], 1, false), isEmpty);
    });
  });
}
