// 31 Tem 2026 — FİŞTE SEÇİM SATIRI (_extraSatiri)
//
// 🔴 Fiş olmazsa olmaz. Bu testin ASIL amacı GERİ UYUMLULUK: `extras` içinde String
// olan eski kayıtlar/eski POS sürümleri fişte BİREBİR eskisi gibi basılmalı. Yeni POS
// varyant çoklu seçimi {name, price} map gönderiyor — bu map eskiden fişe
// "{name: Cikolatali, price: 50}" diye HAM basılıyordu (mutfak fişi dahil).
//
// printer_service.dart:_extraSatiri ile AYNI kural.
import 'package:flutter_test/flutter_test.dart';

String extraSatiri(dynamic e) {
  if (e is Map) {
    var ad = (e['name'] ?? e['label'] ?? e['title'] ?? '').toString().trim();
    if (ad.isEmpty) return '';
    final cikarilan = ad.startsWith('-');
    if (cikarilan) ad = ad.substring(1).trim();
    if (ad.isEmpty) return '';
    final f = e['price'] ?? e['amount'];
    final tutar = f is num ? f.toDouble() : double.tryParse('${f ?? ''}') ?? 0;
    final onek = cikarilan ? 'CIKAR: ' : '';
    if (tutar == 0) return onek + ad;
    final isaret = tutar > 0 ? '+' : '-';
    return '$onek$ad ($isaret${tutar.abs().toStringAsFixed(2)} TL)';
  }
  return e?.toString() ?? '';
}

void main() {
  group('GERİ UYUMLULUK — eski String extras çıktısı DEĞİŞMEMELİ', () {
    test('düz string aynen basılır', () {
      expect(extraSatiri('Ekstra Peynir'), 'Ekstra Peynir');
    });
    test('içinde parantez/rakam olan eski string bozulmaz', () {
      expect(extraSatiri('Sos (2 adet)'), 'Sos (2 adet)');
    });
    test('boş string boş kalır', () {
      expect(extraSatiri(''), '');
    });
    test('null → boş (satır basılmaz)', () {
      expect(extraSatiri(null), '');
    });
  });

  group('YENİ — POS varyant çoklu seçimi {name, price}', () {
    test('fiyat farkı varsa tutar yazılır', () {
      expect(extraSatiri({'name': 'Cikolatali', 'price': 50}), 'Cikolatali (+50.00 TL)');
    });
    test('fiyat 0 ise SADECE ad — anlamsız "+0.00 TL" basılmaz', () {
      expect(extraSatiri({'name': 'Fistikli', 'price': 0}), 'Fistikli');
    });
    test('fiyat alanı hiç yoksa sadece ad', () {
      expect(extraSatiri({'name': 'Cilekli'}), 'Cilekli');
    });
    test('negatif fark eksi işaretiyle', () {
      expect(extraSatiri({'name': 'Sade', 'price': -100}), 'Sade (-100.00 TL)');
    });
    test('ondalık tutar 2 hane', () {
      expect(extraSatiri({'name': 'X', 'price': 12.5}), 'X (+12.50 TL)');
    });
    test('metin fiyat ("50") da çözülür', () {
      expect(extraSatiri({'name': 'X', 'price': '50'}), 'X (+50.00 TL)');
    });
    test('label/title alternatif ad alanları', () {
      expect(extraSatiri({'label': 'Kasar', 'price': 15}), 'Kasar (+15.00 TL)');
      expect(extraSatiri({'title': 'Zeytin'}), 'Zeytin');
    });
  });

  group('BOZUK VERİ — fiş düşmemeli, satır atlanmalı', () {
    test('adsız map → boş (satır basılmaz, fiş devam eder)', () {
      expect(extraSatiri({'price': 50}), '');
    });
    test('boş map → boş', () {
      expect(extraSatiri(<String, dynamic>{}), '');
    });
    test('çözülemeyen fiyat → tutarsız ad basılır', () {
      expect(extraSatiri({'name': 'X', 'price': 'abc'}), 'X');
    });
  });

  group('1 Ağu — ÇIKARILAN malzeme (içerik ekranı "-" önekiyle yazar)', () {
    test('çıkarılan → "CIKAR:" etiketi, önek temizlenir', () {
      expect(extraSatiri({'name': '-Soğan', 'price': 0}), 'CIKAR: Soğan');
    });
    test('çıkarılan + fiyat etkisi', () {
      expect(extraSatiri({'name': '-Soğan', 'price': -20}), 'CIKAR: Soğan (-20.00 TL)');
    });
    test('eklenen (önek yok) eskisi gibi', () {
      expect(extraSatiri({'name': 'Peynir', 'price': 10}), 'Peynir (+10.00 TL)');
    });
    test('sadece "-" → boş (satır basılmaz)', () {
      expect(extraSatiri({'name': '-'}), '');
    });
    test('🔴 eski String extras hâlâ aynen basılır', () {
      expect(extraSatiri('Ekstra Peynir'), 'Ekstra Peynir');
    });
  });

  group('Gerçek vaka — Dora test adisyonu (kalem 237529, ₺350)', () {
    test('300₺ ana + Cikolatali +50 → fişte tek tutarlı satır', () {
      final ex = [
        {'name': 'Cikolatali', 'price': 50},
        {'name': 'Fistikli', 'price': 0},
        {'name': 'Cilekli', 'price': 0},
      ];
      final satirlar = ex.map(extraSatiri).where((x) => x.isNotEmpty).toList();
      expect(satirlar, ['Cikolatali (+50.00 TL)', 'Fistikli', 'Cilekli']);
    });
  });
}
