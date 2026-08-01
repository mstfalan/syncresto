// 1 Ağu 2026 — COMBO FİŞ GRUPLAMASI
//
// 🔴 Fiş olmazsa olmaz. Bu testin ASIL amacı REGRESYON KORUMASI:
// combo içermeyen bir siparişte gruplayıcı çıktıyı DEĞİŞTİRMEMELİ — kalem sayısı,
// sırası ve içeriği birebir aynı kalmalı. Gruplama ancak KANIT varsa devreye girer:
// combo_group_id dolu VE aynı kimlikte ≥2 kalem.
//
// printer_service.dart:_comboGrupla ile AYNI kural.
import 'package:flutter_test/flutter_test.dart';

num? sayi(dynamic v) => v is num ? v : num.tryParse('${v ?? ''}');
double? ondalik(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

List<Map<String, dynamic>> comboGrupla(List<dynamic> kalemler) {
  final sonuc = <Map<String, dynamic>>[];
  final sayac = <String, int>{};
  for (final k in kalemler) {
    if (k is! Map) continue;
    final g = (k['combo_group_id'] ?? '').toString().trim();
    if (g.isEmpty) continue;
    sayac[g] = (sayac[g] ?? 0) + 1;
  }
  final acilanlar = <String>{};
  for (final k in kalemler) {
    if (k is! Map) { sonuc.add({'tip': 'tek', 'kalem': k}); continue; }
    final g = (k['combo_group_id'] ?? '').toString().trim();
    if (g.isEmpty || (sayac[g] ?? 0) < 2) {
      sonuc.add({'tip': 'tek', 'kalem': k});
      continue;
    }
    if (acilanlar.contains(g)) continue;
    acilanlar.add(g);
    final uyeler = kalemler.where((x) =>
        x is Map && (x['combo_group_id'] ?? '').toString().trim() == g).toList();
    double tutar = 0;
    int adet = 0;
    final secimler = <String>[];
    for (final u in uyeler) {
      final m = u as Map;
      final q = sayi(m['quantity']) ?? 1;
      adet += q.toInt();
      tutar += (ondalik(m['unit_price']) ?? 0) * q;
      final sec = (m['combo_pick_name'] ?? m['product_name'] ?? '').toString().trim();
      if (sec.isNotEmpty) secimler.add(sec);
    }
    final ad = (uyeler.first as Map)['combo_group_name']?.toString().trim();
    sonuc.add({
      'tip': 'grup',
      'ad': (ad != null && ad.isNotEmpty) ? ad : ((uyeler.first as Map)['product_name'] ?? '').toString(),
      'adet': adet, 'tutar': tutar, 'secimler': secimler, 'uyeler': uyeler,
    });
  }
  return sonuc;
}

Map<String, dynamic> k(String ad, double fiyat,
        {int adet = 1, String? gid, String? gad, String? pick}) =>
    {
      'product_name': ad, 'unit_price': fiyat, 'quantity': adet,
      if (gid != null) 'combo_group_id': gid,
      if (gad != null) 'combo_group_name': gad,
      if (pick != null) 'combo_pick_name': pick,
    };

void main() {
  group('🔴 REGRESYON — combo YOKSA çıktı BİREBİR aynı kalmalı', () {
    test('combo alanı hiç olmayan 3 kalem → 3 tek kalem, sıra aynı', () {
      final g = comboGrupla([k('Adana', 250), k('Ayran', 30), k('Künefe', 180)]);
      expect(g.length, 3);
      expect(g.every((x) => x['tip'] == 'tek'), true);
      expect(g.map((x) => x['kalem']['product_name']).toList(),
          ['Adana', 'Ayran', 'Künefe']);
    });

    test('boş string combo_group_id → gruplanmaz', () {
      final g = comboGrupla([k('A', 10, gid: ''), k('B', 20, gid: '   ')]);
      expect(g.length, 2);
      expect(g.every((x) => x['tip'] == 'tek'), true);
    });

    test('TEK kalemlik grup → gruplanmaz (görsel kazanç yok, risk var)', () {
      final g = comboGrupla([k('Pizza', 470, gid: 'cg1', gad: '2 Al 1 Öde', pick: 'Margarita')]);
      expect(g.length, 1);
      expect(g.first['tip'], 'tek');
    });

    test('boş liste → boş sonuç', () {
      expect(comboGrupla([]), isEmpty);
    });

    test('Map olmayan bozuk öğe → tek kalem olarak geçer, patlamaz', () {
      final g = comboGrupla(['bozuk', k('A', 10)]);
      expect(g.length, 2);
      expect(g.first['tip'], 'tek');
    });
  });

  group('Gruplama — kanıt VARSA', () {
    test('aynı kimlikte 2 kalem → tek grup, ana ürün adı üstte', () {
      final g = comboGrupla([
        k('2 Al 1 Öde Pizza', 470, gid: 'cg1', gad: '2 Al 1 Öde Pizza', pick: 'Margarita'),
        k('2 Al 1 Öde Pizza', 470, gid: 'cg1', gad: '2 Al 1 Öde Pizza', pick: 'Sucuklu'),
      ]);
      expect(g.length, 1);
      expect(g.first['tip'], 'grup');
      expect(g.first['ad'], '2 Al 1 Öde Pizza');
      expect(g.first['secimler'], ['Margarita', 'Sucuklu']);
      expect(g.first['adet'], 2);
      expect(g.first['tutar'], 940);
    });

    test('grubun SIRASI ilk üyesinin sırasıdır (fiş sırası korunur)', () {
      final g = comboGrupla([
        k('Çay', 20),
        k('Combo', 100, gid: 'cg1', gad: 'Combo', pick: 'A'),
        k('Ayran', 30),
        k('Combo', 100, gid: 'cg1', gad: 'Combo', pick: 'B'),
      ]);
      expect(g.length, 3);
      expect(g[0]['kalem']['product_name'], 'Çay');
      expect(g[1]['tip'], 'grup');
      expect(g[1]['secimler'], ['A', 'B']);
      expect(g[2]['kalem']['product_name'], 'Ayran');
    });

    test('İKİ ayrı combo paketi karışmaz', () {
      final g = comboGrupla([
        k('P', 100, gid: 'cgA', gad: 'Paket A', pick: 'a1'),
        k('P', 100, gid: 'cgB', gad: 'Paket B', pick: 'b1'),
        k('P', 100, gid: 'cgA', gad: 'Paket A', pick: 'a2'),
        k('P', 100, gid: 'cgB', gad: 'Paket B', pick: 'b2'),
      ]);
      expect(g.length, 2);
      expect(g[0]['ad'], 'Paket A');
      expect(g[0]['secimler'], ['a1', 'a2']);
      expect(g[1]['ad'], 'Paket B');
      expect(g[1]['secimler'], ['b1', 'b2']);
    });

    test('combo_group_name boşsa ürün adına düşer', () {
      final g = comboGrupla([
        k('Menü', 50, gid: 'cg1', pick: 'X'),
        k('Menü', 50, gid: 'cg1', pick: 'Y'),
      ]);
      expect(g.first['ad'], 'Menü');
    });

    test('combo_pick_name boşsa ürün adı seçim olarak yazılır', () {
      final g = comboGrupla([
        k('Menü', 50, gid: 'cg1', gad: 'Menü'),
        k('Menü', 50, gid: 'cg1', gad: 'Menü'),
      ]);
      expect(g.first['secimler'], ['Menü', 'Menü']);
    });

    test('adet>1 olan üyelerde toplam adet ve tutar doğru', () {
      final g = comboGrupla([
        k('C', 100, adet: 2, gid: 'cg1', gad: 'C', pick: 'x'),
        k('C', 100, adet: 3, gid: 'cg1', gad: 'C', pick: 'y'),
      ]);
      expect(g.first['adet'], 5);
      expect(g.first['tutar'], 500);
    });

    test('gruplu + grupsuz karışık: toplam kalem sayısı korunur', () {
      final kalemler = [
        k('Çay', 20),
        k('C', 100, gid: 'cg1', gad: 'C', pick: 'a'),
        k('C', 100, gid: 'cg1', gad: 'C', pick: 'b'),
        k('C', 100, gid: 'cg1', gad: 'C', pick: 'c'),
        k('Su', 10),
      ];
      final g = comboGrupla(kalemler);
      expect(g.length, 3); // çay + grup + su
      expect(g[1]['secimler'].length, 3);
      // hiçbir kalem kaybolmadı: grup üyeleri + tekler = 5
      final toplamKalem = g.fold<int>(0, (t, x) =>
          t + (x['tip'] == 'grup' ? (x['uyeler'] as List).length : 1));
      expect(toplamKalem, 5);
    });
  });
}
