// 6 Eki 2026 — MUTFAK FISINDE AYNI KALEMLERI BIRLESTIR (lib/services/mutfak_birlestir.dart)
//
// 🔴 Fis olmazsa olmaz. ASIL amac REGRESYON KORUMASI: birlesecek kalem YOKSA liste
// AYNI NESNELER ve AYNI SIRA ile donmeli -> _generateKitchenReceipt'in geri kalani hic
// degismedigi icin fis BAYT BAYT eskisiyle ayni.
//
// Gercek veri testi: MUTFAK_FIXTURE ortam degiskeni (son 7 gun gercek mutfak isleri, JSON).
// Musteri notu icerdigi icin depoya KONMAZ; yoksa test atlanir.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/mutfak_birlestir.dart';

// printer_service.dart:_mutfakBirlesmeAnahtari ile AYNI alanlar. garson·saat yerine
// testte garson adi + HH:mm (fisteki metnin kaynagi bunlar).
String? anahtar(Map k) {
  final ad = (k['product_name'] ?? '').toString();
  if (ad.trim().isEmpty) return null;
  if ((k['combo_group_id'] ?? '').toString().trim().isNotEmpty) return null;
  dynamic ex = k['extras'];
  if (ex is String) { try { ex = jsonDecode(ex); } catch (_) { ex = []; } }
  final secimler = (ex is List ? ex : const [])
      .map((e) => e is Map ? jsonEncode(e) : e.toString()).toList();
  final t = DateTime.tryParse((k['created_at'] ?? '').toString())?.toLocal();
  final saat = t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return jsonEncode([
    (k['product_id'] ?? '').toString(), ad, (k['portion'] ?? '').toString(),
    (k['notes'] ?? '').toString(), secimler, '${k['added_by_name'] ?? ''}·$saat',
    (k['combo_pick_name'] ?? '').toString(),
  ]);
}

List<Map<String, dynamic>> tekler(List<Map<String, dynamic>> l) =>
    l.map((e) => <String, dynamic>{'tip': 'tek', 'kalem': e}).toList();

Map<String, dynamic> k(String ad, {int adet = 1, String? not, dynamic ex, String garson = 'Elmas',
        String saat = '2026-10-06T10:26:00Z', int? pid, String? combo, String? porsiyon}) =>
    {
      'product_id': pid ?? ad.hashCode, 'product_name': ad, 'quantity': adet,
      'notes': not, 'extras': ex ?? [], 'added_by_name': garson, 'created_at': saat,
      if (combo != null) 'combo_group_id': combo,
      if (porsiyon != null) 'portion': porsiyon,
    };

int adetOf(Map s) => (s['kalem'] as Map)['quantity'] as int;

void main() {
  group('🔴 REGRESYON — birlesecek kalem yoksa AYNI nesneler, AYNI sira', () {
    test('farkli 3 urun', () {
      final g = tekler([k('Adana'), k('Ayran'), k('Kunefe')]);
      final s = ayniKalemleriBirlestir(g, anahtar);
      expect(s.length, 3);
      for (var i = 0; i < 3; i++) { expect(identical(s[i], g[i]), true); }
    });
    test('combo grubu ve tek kalemler dokunulmaz', () {
      final g = <Map<String, dynamic>>[
        {'tip': 'grup', 'ad': 'Menu', 'adet': 2, 'uyeler': [], 'secimler': []},
        ...tekler([k('Kofte'), k('Ayran')]),
      ];
      final s = ayniKalemleriBirlestir(g, anahtar);
      for (var i = 0; i < g.length; i++) { expect(identical(s[i], g[i]), true); }
    });
  });

  group('BIRLESME kurallari (Mustafa ornegi)', () {
    test('10 sade kofte -> tek satir 10', () {
      final s = ayniKalemleriBirlestir(tekler(List.generate(10, (_) => k('Kofte'))), anahtar);
      expect(s.length, 1);
      expect(adetOf(s.first), 10);
    });
    test('10 kofte, 1 i notlu -> 9 + 1 notlu, ilk yerinde', () {
      final l = List.generate(10, (i) => i == 4 ? k('Kofte', not: 'acisiz') : k('Kofte'));
      final s = ayniKalemleriBirlestir(tekler(l), anahtar);
      expect(s.length, 2);
      expect(adetOf(s[0]), 9);
      expect((s[1]['kalem'] as Map)['notes'], 'acisiz');
      expect(adetOf(s[1]), 1);
    });
    test('ayni not tasiyan iki kalem birlesir, farkli not ayri', () {
      final s = ayniKalemleriBirlestir(tekler([
        k('Kofte', not: 'acisiz'), k('Kofte', not: 'acisiz'), k('Kofte', not: 'acili')]), anahtar);
      expect(s.length, 2);
      expect(adetOf(s[0]), 2);
    });
    test('secimi (extras) farkli olan ayri; ayni secim birlesir', () {
      final s = ayniKalemleriBirlestir(tekler([
        k('Burger', ex: [{'name': 'Cheddar'}]), k('Burger', ex: [{'name': 'Cheddar'}]),
        k('Burger', ex: [{'name': '-Sogan'}]), k('Burger')]), anahtar);
      expect(s.length, 3);
      expect(adetOf(s[0]), 2);
    });
    test('farkli garson ya da farkli dakika ayri satir', () {
      final s = ayniKalemleriBirlestir(tekler([
        k('Kofte'), k('Kofte', garson: 'Serhat'), k('Kofte', saat: '2026-10-06T10:31:00Z'), k('Kofte')]), anahtar);
      expect(s.length, 3);
      expect(adetOf(s[0]), 2);
    });
    test('porsiyon farkli ayri; adetli kalemler toplanir', () {
      final s = ayniKalemleriBirlestir(tekler([
        k('Pilav', adet: 2), k('Pilav', adet: 3), k('Pilav', porsiyon: '1.5')]), anahtar);
      expect(s.length, 2);
      expect(adetOf(s[0]), 5);
    });
    test('combo uyesi tek kalem asla birlesmez', () {
      final s = ayniKalemleriBirlestir(tekler([k('Kofte', combo: 'g1'), k('Kofte', combo: 'g1')]), anahtar);
      expect(s.length, 2);
    });
    test('gecersiz adet birlesmez (0 / bos metin)', () {
      final a = k('Kofte')..['quantity'] = 0;
      final b = k('Kofte')..['quantity'] = 'x';
      final s = ayniKalemleriBirlestir(tekler([a, b, k('Kofte')]), anahtar);
      expect(s.length, 3);
    });
    test('girdi listesi ve kalemleri DEGISMEZ (kopya uzerinde calisir)', () {
      final l = [k('Kofte'), k('Kofte')];
      final g = tekler(l);
      ayniKalemleriBirlestir(g, anahtar);
      expect(l[0]['quantity'], 1);
      expect(g.length, 2);
    });
  });

  test('🔴 GERCEK VERI (son 7 gun, tum bayiler): degismeyen fisler birebir', () {
    final yol = Platform.environment['MUTFAK_FIXTURE'];
    if (yol == null || !File(yol).existsSync()) { markTestSkipped('MUTFAK_FIXTURE yok'); return; }
    final isler = jsonDecode(File(yol).readAsStringSync()) as List;
    var ayni = 0, degisen = 0, oncekiSatir = 0, sonrakiSatir = 0;
    for (final is_ in isler) {
      final items = (is_['items'] as List).cast<Map<String, dynamic>>();
      final g = tekler(items);
      final s = ayniKalemleriBirlestir(g, anahtar);
      // Toplam adet KORUNUR
      num top(List<Map<String, dynamic>> x) =>
          x.fold<num>(0, (a, e) => a + (num.tryParse('${(e['kalem'] as Map)['quantity'] ?? 1}') ?? 0));
      expect(top(s), top(g));
      oncekiSatir += g.length; sonrakiSatir += s.length;
      if (s.length == g.length) {
        for (var i = 0; i < g.length; i++) { expect(identical(s[i], g[i]), true); }
        ayni++;
      } else {
        degisen++;
      }
    }
    // ignore: avoid_print
    print('GERCEK VERI: ${isler.length} fis | birebir ayni: $ayni | birlesen: $degisen | satir $oncekiSatir -> $sonrakiSatir');
  });
}
