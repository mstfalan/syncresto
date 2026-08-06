// 6 Ağu 2026 — MASA TAKİP ÜRÜN DETAYI (takipDetayParcalari / takipDetayOzet)
//
// Mustafa: "flutter posda varyant ve combo vs. ekledik ya, bunlar adisyon kısmında ve
// fişte her yerde çıkıyor problem yok ama masa takip kısmında bunun detayları
// gözükmüyor maalesef ... flutter ve garson webde de".
//
// Kök sebep backend'deydi (getPendingOrders `extras`'ı hiç seçmiyordu); bu test
// istemci tarafındaki biçimlendirmeyi kilitler.
//
// 🔴 İKİ BİÇİM ZORUNLU: online tarafta jsonb DİZİ gelir, çevrimdışı SQLite'ta aynı
// veri JSON METİN olarak durur. Yardımcı ikisini de kabul etmezse özellik çevrimdışı
// sessizce kaybolur (katı kural: her POS özelliği cache+offline).
//
// NOT: fiş tarafındaki _extraSatiri'nden BİLİNÇLİ olarak ayrışır — takip ekranında
// fiyat gösterilmez (mutfak/servis içeriği önemser, satır dar) ve çıkarılanlar
// "CIKAR: Sogan" yerine "Sogan yok" diye yazılır.
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/widgets/order_tracking/item_card.dart';

void main() {
  group('takipDetayParcalari — biçim toleransı', () {
    test('online jsonb dizi (Map listesi) okunur', () {
      // Canlı örnek: "Çıtır Tavuk 4'lü" — notes NULL, bilgi SADECE extras'ta
      final p = takipDetayParcalari([
        {'name': 'Acısız', 'price': 0},
        {'name': "4'lü", 'price': 0},
      ]);
      expect(p.map((x) => x.ad).toList(), ['Acısız', "4'lü"]);
      expect(p.every((x) => !x.cikarilan), isTrue);
    });

    test('çevrimdışı JSON METİN de okunur (SQLite)', () {
      final p = takipDetayParcalari('[{"name":"1.5 Porsiyon","price":100}]');
      expect(p.length, 1);
      expect(p.first.ad, '1.5 Porsiyon');
    });

    test('bozuk JSON metni çökertmez, boş döner', () {
      expect(takipDetayParcalari('{bozuk'), isEmpty);
    });

    test('eski kayıtlardaki düz String öğeler korunur', () {
      final p = takipDetayParcalari(['Ketçap', 'Mayonez']);
      expect(p.map((x) => x.ad).toList(), ['Ketçap', 'Mayonez']);
    });

    test('null / boş / dizi olmayan girdi boş döner', () {
      expect(takipDetayParcalari(null), isEmpty);
      expect(takipDetayParcalari(''), isEmpty);
      expect(takipDetayParcalari('   '), isEmpty);
      expect(takipDetayParcalari(42), isEmpty);
      expect(takipDetayParcalari({'name': 'tek'}), isEmpty); // Map, List değil
    });
  });

  group('takipDetayParcalari — çıkarılan malzeme', () {
    test("'-' öneki çıkarılan demektir, önek temizlenir", () {
      // Canlı örnek: [{"name":"örnek ekle"},{"name":"-örnek çıkar"}]
      final p = takipDetayParcalari([
        {'name': 'örnek ekle', 'price': 10},
        {'name': '-örnek çıkar', 'price': -10},
      ]);
      expect(p[0].ad, 'örnek ekle');
      expect(p[0].cikarilan, isFalse);
      expect(p[1].ad, 'örnek çıkar'); // önek YOK
      expect(p[1].cikarilan, isTrue);
    });

    test("sadece '-' olan ad elenir (boşa satır açmaz)", () {
      expect(takipDetayParcalari([{'name': '-'}]), isEmpty);
      expect(takipDetayParcalari([{'name': '   '}]), isEmpty);
    });
  });

  group('takipDetayParcalari — alan adı toleransı', () {
    test('name yoksa label/title okunur', () {
      final p = takipDetayParcalari([
        {'label': 'Az Pişmiş'},
        {'title': 'Bol Sos'},
      ]);
      expect(p.map((x) => x.ad).toList(), ['Az Pişmiş', 'Bol Sos']);
    });

    test('adı olmayan öğe atlanır, diğerleri korunur', () {
      final p = takipDetayParcalari([
        {'price': 50},
        {'name': 'Sucuk'},
      ]);
      expect(p.length, 1);
      expect(p.first.ad, 'Sucuk');
    });
  });

  group('takipDetayOzet — ekran metni', () {
    test('nokta ayraçla birleştirir', () {
      expect(
        takipDetayOzet([
          {'name': 'Acısız'},
          {'name': "4'lü"},
        ]),
        "Acısız · 4'lü",
      );
    });

    test("çıkarılan '... yok' olarak yazılır", () {
      expect(
        takipDetayOzet([
          {'name': 'Sucuk', 'price': 20},
          {'name': '-Soğan'},
        ]),
        'Sucuk · Soğan yok',
      );
    });

    test('detay yoksa BOŞ döner (satır hiç çizilmez)', () {
      expect(takipDetayOzet(null), '');
      expect(takipDetayOzet([]), '');
      expect(takipDetayOzet('[]'), '');
    });

    test('fiyat ekranda GÖSTERİLMEZ', () {
      final s = takipDetayOzet([
        {'name': 'Patates kızartması', 'price': 10}
      ]);
      expect(s, 'Patates kızartması');
      expect(s.contains('10'), isFalse);
      expect(s.contains('TL'), isFalse);
    });

    test('aynı ad tekrarı BİRLEŞTİRİLMEZ (adet bilgisi oradan okunuyor)', () {
      // Canlı örnek: iki porsiyon patates = iki ayrı kayıt
      expect(
        takipDetayOzet([
          {'name': 'Patates kızartması', 'price': 10},
          {'name': 'Patates kızartması', 'price': 10},
        ]),
        'Patates kızartması · Patates kızartması',
      );
    });

    test('Türkçe karakterler bozulmadan döner', () {
      expect(takipDetayOzet([{'name': 'Şeftalili Ğ İçecek'}]), 'Şeftalili Ğ İçecek');
    });
  });
}
