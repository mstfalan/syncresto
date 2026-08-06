// 6 Ağu 2026 — NOT PENCERESİ / VARYANT GÜNCELLEME FİYAT ARİTMETİĞİ
//
// İki para kaybı denetimde bulundu (ikisi de 1.6.8'de vardı, 1.6.9'da düzeltildi):
//
//   #20  add_item_modal.dart — not penceresinde fiyat SIFIRDAN kurulurken kalemin
//        `extras` içindeki varyant farkı hesaba katılmıyordu.
//        baz 200 + "Büyük" +50 = 250 TL kalem; kasiyer nota "(+20TL)" yazınca
//        200 + 0 + 20 = 220 → varyantın 50 TL'si iz bırakmadan uçuyordu.
//
//   #21  çoklu varyant GÜNCELLEME yolu — nottaki "(+10TL)" token'ı fiyata
//        eklenmiyordu ama not metninde duruyordu (canlıda 6.512 not token taşıyor).
//        Tekli varyant yolu bunu zaten ekliyordu; iki yol tutarsızdı.
//
// 🔴 AYRIK KÜME KURALI (ikisinin de dayandığı temel):
//   Varyant/çoklu seçim farkı SADECE `extras`'ta durur; varyant akışı nota ASLA
//   fiyat yazmaz (add_item_modal.dart:868-869 ve 889-890 — backend'in unit_price
//   safety-net'i nottaki '+NTL' desenine bakar). Bu yüzden extras toplamı ile not
//   token toplamını BİRLİKTE eklemek çift sayım DEĞİLDİR. Bu test o kuralı kilitler.
//
// ⚠️ Buradaki yardımcılar add_item_modal.dart'takilerin kopyasıdır (State sınıfının
// private metotları test'ten import edilemiyor) — repodaki fis_extras_satiri_test.dart
// ile aynı desen. Kaynak değişirse burası da güncellenmeli.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

// --- _sumExtraPriceTokens kopyası (nottaki '(+N TL)' token toplamı) ---
double notTokenToplami(String notes) {
  if (notes.isEmpty) return 0;
  double total = 0;
  for (final m in RegExp(r'\(\+\s*(\d+(?:[.,]\d+)?)\s*TL\)', caseSensitive: false).allMatches(notes)) {
    total += double.tryParse((m.group(1) ?? '0').replaceAll(',', '.')) ?? 0;
  }
  return total;
}

// --- _sumExtrasPrices kopyası (extras dizisindeki fiyat toplamı) ---
double extrasToplami(dynamic extrasRaw) {
  if (extrasRaw == null) return 0;
  dynamic veri = extrasRaw;
  if (veri is String) {
    final s = veri.trim();
    if (s.isEmpty) return 0;
    try {
      veri = jsonDecode(s);
    } catch (_) {
      return 0;
    }
  }
  if (veri is! List) return 0;
  double t = 0;
  for (final e in veri) {
    if (e is Map) {
      final v = e['price'] ?? e['amount'];
      t += (v is num) ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
    }
  }
  return t;
}

/// #20 — not penceresi fiyatı. Ürün kaydı BULUNDUĞUNDA (base > 0).
double notPenceresiFiyat({
  required double base,
  required dynamic kalemExtras,
  required double chipsPrice,
  required double freeSum,
}) =>
    base + extrasToplami(kalemExtras) + chipsPrice + freeSum;

/// #20 — ürün kaydı BULUNAMADIĞINDA: baz mevcut fiyattan türetilir ve
/// currentUnitPrice extras'ı ZATEN içerdiği için extras EKLENMEZ.
double notPenceresiFiyatFallback({
  required double currentUnitPrice,
  required double initialChipsPrice,
  required double initialFreeSum,
  required double chipsPrice,
  required double freeSum,
}) {
  var base = currentUnitPrice - initialChipsPrice - initialFreeSum;
  if (base < 0) base = currentUnitPrice;
  return base + chipsPrice + freeSum;
}

/// #21 — çoklu varyant güncelleme fiyatı.
double cokluVaryantFiyat({
  required double basePrice,
  required double toplamFark,
  required String notlar,
}) =>
    basePrice + toplamFark + notTokenToplami(notlar);

void main() {
  group('#20 — not penceresinde varyant farkı yutulmamalı', () {
    test('🔴 ASIL SENARYO: varyantlı kaleme nota fiyat yazılınca varyant korunur', () {
      // baz 200 + "Büyük" +50 = 250 TL kalem. Kasiyer nota "(+20TL)" ekliyor.
      final fiyat = notPenceresiFiyat(
        base: 200,
        kalemExtras: [
          {'name': 'Büyük', 'price': 50}
        ],
        chipsPrice: 0,
        freeSum: 20,
      );
      expect(fiyat, 270); // 200 + 50 + 20 — ESKİDEN 220 ÇIKIYORDU (50 uçuyordu)
      expect(fiyat, isNot(220));
    });

    test('extras yoksa davranış eskisiyle BİREBİR aynı', () {
      expect(
        notPenceresiFiyat(base: 200, kalemExtras: null, chipsPrice: 0, freeSum: 20),
        220,
      );
      expect(
        notPenceresiFiyat(base: 200, kalemExtras: [], chipsPrice: 0, freeSum: 0),
        200,
      );
    });

    test('birden fazla seçim toplanır', () {
      expect(
        notPenceresiFiyat(
          base: 340,
          kalemExtras: [
            {'name': 'Makarna', 'price': 0},
            {'name': 'Sucuk', 'price': 20},
            {'name': '1.5 Porsiyon', 'price': 100},
          ],
          chipsPrice: 0,
          freeSum: 0,
        ),
        460,
      );
    });

    test('negatif fiyatlı seçim (çıkarma) düşülür', () {
      // Canlı örnek: [{"name":"örnek ekle","price":10},{"name":"-örnek çıkar","price":-10}]
      expect(
        notPenceresiFiyat(
          base: 100,
          kalemExtras: [
            {'name': 'örnek ekle', 'price': 10},
            {'name': '-örnek çıkar', 'price': -10},
          ],
          chipsPrice: 0,
          freeSum: 0,
        ),
        100,
      );
    });

    test('çevrimdışı JSON METİN biçimi de sayılır', () {
      expect(
        notPenceresiFiyat(
          base: 200,
          kalemExtras: '[{"name":"Büyük","price":50}]',
          chipsPrice: 0,
          freeSum: 0,
        ),
        250,
      );
    });

    test('bozuk extras fiyatı ÇÖKERTMEZ, 0 sayılır', () {
      expect(notPenceresiFiyat(base: 200, kalemExtras: '{bozuk', chipsPrice: 0, freeSum: 0), 200);
      expect(notPenceresiFiyat(base: 200, kalemExtras: 42, chipsPrice: 0, freeSum: 0), 200);
    });

    test('FALLBACK dalı extras EKLEMEZ (çift sayım olurdu)', () {
      // Ürün kaydı yok: base mevcut fiyattan türetilir, o zaten extras'ı içeriyor.
      // 250 TL kalem, açılışta chip 0 / serbest 0 → base = 250, yeni serbest 20.
      expect(
        notPenceresiFiyatFallback(
          currentUnitPrice: 250,
          initialChipsPrice: 0,
          initialFreeSum: 0,
          chipsPrice: 0,
          freeSum: 20,
        ),
        270,
      );
    });

    test('FALLBACK: açılıştaki token çıkarılır, yenisi eklenir', () {
      // 260 TL kalem = 250 baz + notta "(+10TL)". Kasiyer token'ı 25'e çıkarıyor.
      // base = 260 - 0 - 10 = 250 → 250 + 0 + 25 = 275
      expect(
        notPenceresiFiyatFallback(
          currentUnitPrice: 260,
          initialChipsPrice: 0,
          initialFreeSum: 10,
          chipsPrice: 0,
          freeSum: 25,
        ),
        275,
      );
    });

    test('FALLBACK: negatif baz clamp\'lenir (bozuk veriye karşı)', () {
      // Tutarsız kayıt: açılış token'ı fiyattan büyük → base negatife düşer.
      // Clamp devreye girer, base = currentUnitPrice olur.
      expect(
        notPenceresiFiyatFallback(
          currentUnitPrice: 100,
          initialChipsPrice: 0,
          initialFreeSum: 150,
          chipsPrice: 0,
          freeSum: 0,
        ),
        100,
      );
    });

    test('🔴 BAZ FİYATI 0 olan ürün fallback\'e düşer (canlıda 1.068 ürün)', () {
      // Örnek: "FROZEN MOİ" price=0, extras [{"name":"ORTA","price":175}] → 175 TL kalem.
      // base > 0 dalına girseydi 175 + 175 = 350 olurdu. Fallback doğru dal.
      expect(
        notPenceresiFiyatFallback(
          currentUnitPrice: 175,
          initialChipsPrice: 0,
          initialFreeSum: 0,
          chipsPrice: 0,
          freeSum: 0,
        ),
        175,
      );
    });

    test('çevrimdışı JSON METİN\'de negatif fiyat', () {
      expect(
        notPenceresiFiyat(
          base: 100,
          kalemExtras: '[{"name":"-Sogan","price":-10}]',
          chipsPrice: 0,
          freeSum: 0,
        ),
        90,
      );
    });
  });

  group('#21 — çoklu varyant güncellemede not token\'ı düşmemeli', () {
    test('🔴 ASIL SENARYO: eski "(+10TL)" notu fiyatta korunur', () {
      // Eski genel-varyant döneminden kalma not + yeni varyant seçimi
      final fiyat = cokluVaryantFiyat(
        basePrice: 300,
        toplamFark: 50,
        notlar: 'Büyük, Cips (+10TL)',
      );
      expect(fiyat, 360); // 300 + 50 + 10 — ESKİDEN 350 ÇIKIYORDU (10 düşüyordu)
      expect(fiyat, isNot(350));
    });

    test('token yoksa davranış eskisiyle BİREBİR aynı', () {
      expect(cokluVaryantFiyat(basePrice: 300, toplamFark: 50, notlar: 'Büyük, acısız olsun'), 350);
      expect(cokluVaryantFiyat(basePrice: 300, toplamFark: 0, notlar: ''), 300);
    });

    test('birden fazla token toplanır, ondalık virgül/nokta ikisi de', () {
      expect(cokluVaryantFiyat(basePrice: 100, toplamFark: 0, notlar: 'A (+10TL), B (+5,50TL)'), 115.5);
      expect(cokluVaryantFiyat(basePrice: 100, toplamFark: 0, notlar: 'A (+2.25TL)'), 102.25);
    });

    test('tekli ve çoklu yol AYNI sonucu vermeli (tutarsızlık kapandı)', () {
      // Tekli yol: basePrice + variantModifier + existingExtrasTotal
      const tekli = 300 + 50 + 10.0;
      final coklu = cokluVaryantFiyat(basePrice: 300, toplamFark: 50, notlar: 'Cips (+10TL)');
      expect(coklu, tekli);
    });
  });

  group('AYRIK KÜME kuralı', () {
    test('extras fiyatı ile not token\'ı ÇAKIŞMAZ — ikisi birden eklenir', () {
      // Varyant akışı nota fiyat YAZMAZ; nottaki token yalnızca eski genel-varyant
      // döneminden veya kasiyerin elle yazdığından gelir.
      final fiyat = notPenceresiFiyat(
        base: 200,
        kalemExtras: [
          {'name': 'Büyük', 'price': 50}
        ],
        chipsPrice: 0,
        freeSum: 10,
      );
      expect(fiyat, 260); // 50 extras'tan + 10 nottan, çift sayım yok
    });

    test('extras adı notta geçse bile fiyatı iki kez sayılmaz', () {
      // Not "Büyük" yazar ama FİYAT TOKEN'I taşımaz (kural bu) → sadece extras'tan 50
      expect(
        notPenceresiFiyat(
          base: 200,
          kalemExtras: [
            {'name': 'Büyük', 'price': 50}
          ],
          chipsPrice: 0,
          freeSum: notTokenToplami('Büyük, acısız'),
        ),
        250,
      );
    });
  });
}
