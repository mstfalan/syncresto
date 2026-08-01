// 1 Ağu 2026 — EXTRA HEDİYE ARTIK ADİSYONA/MUTFAĞA FİZİKSEL SATIR OLARAK GİRER
//
// Mustafa: "hediye ürün seçtim diyelim ürün adisyona direkt fiyatıyla geliyor?"
//          → "mutfak görmesi lazım olur mu canım. önerilen daha iyi o zaman."
//
// SORUN (eski davranış): `extra` modda (2 al 1 hediye) POS hediye kalemini adisyona
// HİÇ eklemiyordu. Backend kapanışta ₺0 satır yazıyordu ama `printed=1` ile — yani
// MUTFAK O ÜRÜNÜ HİÇ GÖRMÜYORDU. Müşteri 3 ürün seçiyor, mutfak 2 tane yapıyordu.
//
// ÇÖZÜM: seçilen TÜM kalemler (N+G) adisyona girer.
//
// 🔴 BU TESTİN ASIL İŞİ: PARANIN DEĞİŞMEDİĞİNİ KANITLAMAK.
// Hediye BEDAVA olduğu için onun varyant sürşarjı pakete eklenmez → bölünecek tutar
// eskisiyle BİREBİR aynı, sadece daha çok kaleme bölünür. Afrodit Waffle Cup'ın
// varyantlarında gerçek modifier var (+50/+50/+50/+20), yani bu fark ÖNEMLİ.
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/combo_calculator.dart';

double topla(List<double> l) =>
    ((l.fold<double>(0, (a, b) => a + b) * 100).round()) / 100;

void main() {
  group('🔴 PARA DEĞİŞMEDİ — eski 2 kalem toplamı == yeni 3 kalem toplamı', () {
    /// Eski davranış: paket SADECE ödenen kalemlere bölünürdü.
    /// Yeni davranış: aynı paket, hediye dahil TÜM kalemlere bölünür.
    void paraAyni(String ad, List<double> tumMods, double baz, int giftCount) {
      test(ad, () {
        // Hediye = en ucuz giftCount kalem (paidPicksAfterGift ile aynı kural)
        final picks = tumMods
            .map((m) => <String, dynamic>{'mod': m, 'realValue': baz + m})
            .toList();
        final odenen = ComboCalculator.paidPicksAfterGift(picks, giftCount);
        final odenenMods = odenen.map((p) => p['mod'] as double).toList();

        final eski = ComboCalculator.splitComboPackagePrice(odenenMods, baz);
        final yeni = ComboCalculator.splitComboPackagePrice(odenenMods, baz,
            satirSayisi: picks.length);

        expect(yeni.length, picks.length,
            reason: 'hediye dahil TÜM kalemler adisyona girmeli');
        expect(eski.length, odenen.length);
        expect(topla(yeni), topla(eski),
            reason: 'MÜŞTERİDEN TAHSİL EDİLEN TUTAR DEĞİŞEMEZ');
      });
    }

    // Afrodit Waffle Cup gerçek varyantları: +50 / +50 / +50 / +20 / 0
    paraAyni('Afrodit: 3 varyant da +50, baz 300, 1 hediye', [50, 50, 50], 300, 1);
    paraAyni('Afrodit: +50/+50/+20, baz 300, 1 hediye', [50, 50, 20], 300, 1);
    paraAyni('Afrodit: hepsi ₺0 modifier, baz 300, 1 hediye', [0, 0, 0], 300, 1);
    paraAyni('karışık: 0/+20/+50, baz 300, 1 hediye', [0, 20, 50], 300, 1);
    paraAyni('negatif modifier karışık', [-100, 0, 50], 940, 1);
    paraAyni('2 hediye (N=2 G=2)', [0, 10, 20, 30], 500, 2);
    paraAyni('katlanan set: N=2 G=1 ×2 set = 6 seçim', [0, 0, 10, 10, 20, 20], 600, 2);
    paraAyni('baz 0, sadece modifier', [100, 200, 300], 0, 1);
    paraAyni('kuruşlu baz', [33.33, 11.11, 0], 199.99, 1);
  });

  group('Bölme doğruluğu', () {
    test('400 TL 3 kaleme → kuruş kaybı YOK', () {
      final r = ComboCalculator.splitComboPackagePrice([50, 50], 300, satirSayisi: 3);
      expect(r.length, 3);
      expect(topla(r), 400.00, reason: 'kuruş artığı son kaleme eklenmeli');
      // 133.33 + 133.33 + 133.34
      expect(r[0], closeTo(133.33, 0.001));
      expect(r[2], closeTo(133.34, 0.001));
    });

    test('hediyenin sürşarjı pakete EKLENMEZ (bedava demek)', () {
      // 3 kalem de +50; hediye 1 tane. Ödenen mods = [50,50] → paket 300+100 = 400.
      // Eğer hediyenin +50'si de eklenseydi 450 olurdu = müşteriden 50 TL FAZLA.
      final r = ComboCalculator.splitComboPackagePrice([50, 50], 300, satirSayisi: 3);
      expect(topla(r), 400.00);
      expect(topla(r), isNot(450.00),
          reason: 'hediyenin varyant farkı tahsil edilemez');
    });

    test('satirSayisi verilmezse ESKİ davranış birebir korunur (geri uyum)', () {
      final eski = ComboCalculator.splitComboPackagePrice([50, 50], 300);
      expect(eski.length, 2);
      expect(topla(eski), 400.00);
      expect(eski[0], 200.0);
    });

    test('satirSayisi 0/negatif → boş liste (patlamaz)', () {
      expect(ComboCalculator.splitComboPackagePrice([50], 300, satirSayisi: 0), isEmpty);
      expect(ComboCalculator.splitComboPackagePrice([50], 300, satirSayisi: -3), isEmpty);
    });

    test('boş modifier + satirSayisi → baz fiyat bölünür', () {
      final r = ComboCalculator.splitComboPackagePrice([], 300, satirSayisi: 3);
      expect(r.length, 3);
      expect(topla(r), 300.00);
    });
  });

  group('within/percent/amount modları ETKİLENMEDİ (regresyon)', () {
    test('giftCount=0 → tüm seçilenler zaten ödenen, bölme aynı', () {
      final picks = [0.0, 50.0]
          .map((m) => <String, dynamic>{'mod': m, 'realValue': 300 + m})
          .toList();
      final odenen = ComboCalculator.paidPicksAfterGift(picks, 0);
      expect(odenen.length, 2, reason: 'within modda hiçbir kalem çıkarılmaz');
      final mods = odenen.map((p) => p['mod'] as double).toList();
      final eski = ComboCalculator.splitComboPackagePrice(mods, 300);
      final yeni = ComboCalculator.splitComboPackagePrice(mods, 300,
          satirSayisi: picks.length);
      expect(yeni, eski, reason: 'within modda çıktı BİREBİR aynı olmalı');
    });
  });
}
