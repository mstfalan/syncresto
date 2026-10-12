// 12 Eki 2026 — KASA (ADISYON) FISINDE AYNI KALEMLERI BIRLESTIR (printer_service._kasaBirlesmeAnahtari)
//
// 🔴 Fis olmazsa olmaz. ASIL amac REGRESYON KORUMASI: birlesecek kalem YOKSA liste AYNI
// NESNELER ve AYNI SIRA ile donmeli -> _generateTicketReceipt'in geri kalani degismedigi icin
// fis BAYT BAYT eskisiyle ayni. Birlesen adisyonda satir tutarlarinin toplami DEGISMEMELI.
//
// Gercek veri testi: KASA_FIXTURE ortam degiskeni (son 7 gun gercek adisyon kalemleri, JSON).
// Musteri notu icerdigi icin depoya KONMAZ; yoksa test atlanir.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/mutfak_birlestir.dart';

double? ondalik(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

// printer_service.dart:_kasaBirlesmeAnahtari ile AYNI alanlar. garson·saat yerine testte
// garson adi + HH:mm (fisteki metnin kaynagi bunlar).
String? anahtar(Map k) {
  final ad = (k['product_name'] ?? '').toString();
  if (ad.trim().isEmpty) return null;
  if ((k['combo_group_id'] ?? '').toString().trim().isNotEmpty) return null;
  if ((k['status'] ?? '').toString() == 'cancelled') return null;
  final fiyat = ondalik(k['unit_price']);
  if (fiyat == null) return null;
  dynamic ex = k['extras'];
  if (ex is String) { try { ex = jsonDecode(ex); } catch (_) { ex = []; } }
  final secimler = (ex is List ? ex : const [])
      .map((e) => e is Map ? jsonEncode(e) : e.toString()).toList();
  final t = DateTime.tryParse((k['created_at'] ?? '').toString())?.toLocal();
  final saat = t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return jsonEncode([
    (k['product_id'] ?? '').toString(), ad, (k['portion'] ?? '').toString(),
    (k['notes'] ?? '').toString(), secimler, '${k['added_by_name'] ?? ''}·$saat',
    (k['combo_pick_name'] ?? '').toString(), fiyat.toStringAsFixed(4),
    (k['is_ikram'] ?? '').toString(), (k['payment_status'] ?? '').toString(),
  ]);
}

List<Map<String, dynamic>> tekler(List<Map<String, dynamic>> l) =>
    l.map((e) => <String, dynamic>{'tip': 'tek', 'kalem': e}).toList();

Map<String, dynamic> k(String ad, {int adet = 1, double fiyat = 100, String? not, bool ikram = false,
        String? odeme, String garson = 'Elmas', String saat = '2026-10-12T10:26:00Z'}) =>
    {
      'product_id': ad.hashCode, 'product_name': ad, 'quantity': adet, 'unit_price': fiyat,
      'notes': not, 'extras': [], 'added_by_name': garson, 'created_at': saat,
      'is_ikram': ikram, if (odeme != null) 'payment_status': odeme,
    };

int adetOf(Map s) => (s['kalem'] as Map)['quantity'] as int;
// Fisteki satir tutari: unit_price * quantity (printer_service TEK KALEM satiri)
double tutar(List<Map<String, dynamic>> l) => l.fold(0.0, (a, s) {
      final m = s['kalem'] as Map;
      return a + (ondalik(m['unit_price']) ?? 0) * (num.tryParse('${m['quantity'] ?? 1}') ?? 0);
    });

void main() {
  test('🔴 REGRESYON — farkli urunler: AYNI nesneler, AYNI sira', () {
    final g = tekler([k('Adana'), k('Ayran'), k('Kunefe')]);
    final s = ayniKalemleriBirlestir(g, anahtar);
    for (var i = 0; i < g.length; i++) { expect(identical(s[i], g[i]), true); }
  });

  test('5 sade kofte -> tek satir 5, tutar korunur', () {
    final g = tekler(List.generate(5, (_) => k('Kofte', fiyat: 120)));
    final s = ayniKalemleriBirlestir(g, anahtar);
    expect(s.length, 1);
    expect(adetOf(s.first), 5);
    expect(tutar(s), tutar(g));
  });

  test('farkli fiyat AYRI satir', () {
    final s = ayniKalemleriBirlestir(tekler([k('Kofte', fiyat: 120), k('Kofte', fiyat: 130)]), anahtar);
    expect(s.length, 2);
  });

  test('ikram olan ile olmayan AYRI satir', () {
    final s = ayniKalemleriBirlestir(tekler([k('Kofte'), k('Kofte', ikram: true), k('Kofte')]), anahtar);
    expect(s.length, 2);
    expect(adetOf(s[0]), 2);
  });

  test('odenmis ile odenmemis AYRI satir', () {
    final s = ayniKalemleriBirlestir(tekler([k('Kofte', odeme: 'paid'), k('Kofte'), k('Kofte', odeme: 'paid')]), anahtar);
    expect(s.length, 2);
    expect(adetOf(s[0]), 2);
  });

  test('notlu ayri, ayni notlular birlesir', () {
    final s = ayniKalemleriBirlestir(tekler([
      k('Kofte', not: 'acisiz'), k('Kofte'), k('Kofte', not: 'acisiz'), k('Kofte')]), anahtar);
    expect(s.length, 2);
    expect(adetOf(s[0]), 2);
    expect(adetOf(s[1]), 2);
  });

  test('iptal edilmis kalem birlesmez (cevrimdisi liste)', () {
    final s = ayniKalemleriBirlestir(tekler([k('Kofte'), k('Kofte')..['status'] = 'cancelled']), anahtar);
    expect(s.length, 2);
  });

  test('fiyati olmayan kalem birlesmez', () {
    final a = k('Kofte')..remove('unit_price');
    final b = k('Kofte')..remove('unit_price');
    expect(ayniKalemleriBirlestir(tekler([a, b]), anahtar).length, 2);
  });

  test('🔴 GERCEK VERI (son 7 gun, tum bayiler): degismeyen fisler birebir, tutar/adet korunur', () {
    final yol = Platform.environment['KASA_FIXTURE'];
    if (yol == null || !File(yol).existsSync()) { markTestSkipped('KASA_FIXTURE yok'); return; }
    final adisyonlar = jsonDecode(File(yol).readAsStringSync()) as List;
    var ayni = 0, degisen = 0, once = 0, sonra = 0;
    num topAdet(List<Map<String, dynamic>> x) =>
        x.fold<num>(0, (a, e) => a + (num.tryParse('${(e['kalem'] as Map)['quantity'] ?? 1}') ?? 0));
    for (final a in adisyonlar) {
      final g = tekler((a['items'] as List).cast<Map<String, dynamic>>());
      final s = ayniKalemleriBirlestir(g, anahtar);
      expect(topAdet(s), topAdet(g));
      expect((tutar(s) - tutar(g)).abs() < 0.005, true, reason: 'adisyon ${a['ticket_id']} tutar degisti');
      once += g.length; sonra += s.length;
      if (s.length == g.length) {
        for (var i = 0; i < g.length; i++) { expect(identical(s[i], g[i]), true); }
        ayni++;
      } else {
        degisen++;
      }
    }
    // ignore: avoid_print
    print('GERCEK VERI: ${adisyonlar.length} adisyon | birebir ayni: $ayni | birlesen: $degisen | satir $once -> $sonra');
  });
}
