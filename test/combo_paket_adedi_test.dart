// 2 Ağu 2026 — GERÇEK FİŞ HATASI (Mustafa fotoğrafı, adisyon 260802-9920, İzabelle Pizza)
//
// Fişte "2 x Lezzet Partisi Menu" yazıyordu. Adisyonun gerçeği: 2 kalem × 1 adet = TEK paket.
// O "2", paket adedi değil GRUBUN ÜYE SAYISI'ydı (_comboGrupla adet'i topluyordu).
// Ayrıca her seçim iki kez basılıyordu: "- San Remo Pizza" + "* San Remo Pizza",
// çünkü POS varyant adını hem combo_pick_name'e hem notes'a yazıyor.
//
// Tutarlar DOĞRUYDU (2×650=1300, toplam 2600) — sorun yalnızca gösterimdi.
import 'package:flutter_test/flutter_test.dart';

/// printer_service.dart `_comboGrupla` ile AYNI kural:
/// bir combo grubu = bir paket. Paket adedi = üyelerin EN KÜÇÜK adedi.
int paketAdedi(List<Map<String, dynamic>> uyeler) {
  int? enKucuk;
  for (final u in uyeler) {
    final q = (u['quantity'] as num?)?.toInt() ?? 1;
    if (enKucuk == null || q < enKucuk) enKucuk = q;
  }
  return (enKucuk == null || enKucuk < 1) ? 1 : enKucuk;
}

/// Üye notu, üstte yazılan seçim adıyla aynıysa fişe TEKRAR yazılmaz.
List<String> basilacakNotlar(List<String> secimler, List<String?> notlar) {
  final set = secimler.map((e) => e.trim().toLowerCase()).toSet();
  return notlar
      .map((n) => n?.trim() ?? '')
      .where((n) => n.isNotEmpty && !set.contains(n.toLowerCase()))
      .toList();
}

void main() {
  group('PAKET ADEDİ — "2 x" hatası', () {
    test('🔴 gerçek vaka: 2 üyeli tek paket → 1 (eskiden 2 yazıyordu)', () {
      expect(paketAdedi([
        {'quantity': 1, 'combo_pick_name': 'San Remo Pizza'},
        {'quantity': 1, 'combo_pick_name': 'Boscaiola Pizza'},
      ]), 1);
    });
    test('kasiyer paketi ikiye çıkarırsa (tüm üyeler 2) → 2 paket', () {
      expect(paketAdedi([{'quantity': 2}, {'quantity': 2}]), 2);
    });
    test('sadece bir üye artmışsa paket 1 kalır — yarım paket yok', () {
      expect(paketAdedi([{'quantity': 1}, {'quantity': 3}]), 1);
    });
    test('3 üyeli paket de 1 sayılır (üye sayısı ≠ paket adedi)', () {
      expect(paketAdedi([{'quantity': 1}, {'quantity': 1}, {'quantity': 1}]), 1);
    });
    test('bozuk/eksik adet → 1 (fiş patlamaz)', () {
      expect(paketAdedi([{'quantity': null}, {}]), 1);
      expect(paketAdedi([{'quantity': 0}, {'quantity': 0}]), 1);
      expect(paketAdedi([]), 1);
    });
  });

  group('ÇİFT SEÇİM — "* San Remo" tekrarı', () {
    test('🔴 seçim adıyla aynı not TEKRAR basılmaz', () {
      expect(basilacakNotlar(
        ['San Remo Pizza', 'Boscaiola Pizza'],
        ['San Remo Pizza', 'Boscaiola Pizza'],
      ), isEmpty);
    });
    test('GERÇEK not yine basılır — mutfak görmeli', () {
      expect(basilacakNotlar(['San Remo Pizza'],
          ['San Remo Pizza', 'az acili', '   ']), ['az acili']);
    });
    test('büyük/küçük harf + boşluk farkı da eşleşir', () {
      expect(basilacakNotlar(['San Remo Pizza'], ['  san remo pizza ']), isEmpty);
    });
    test('combo dışı kalemde kural işlemez (seçim listesi boş)', () {
      expect(basilacakNotlar([], ['az tuzlu']), ['az tuzlu']);
    });
  });
}
