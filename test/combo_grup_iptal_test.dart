// 1 Ağu 2026 — COMBO PAKETİ BÜTÜN HALİNDE İPTAL (Fable denetimi, bulgu ①)
//
// Combo paketinin fiyatı üyelere BÖLÜNEREK yazılır (splitComboPackagePrice).
// Tek üye iptal edilirse kalan üyeler bölünmüş fiyatta kalır → paket bedeli
// orantısız düşer. `extra` modda hediye de artık fiziksel satır ve mutfağa
// gidiyor: mutfak 3 ürünü yaptıktan sonra bir satır iptal edilirse müşteri
// 3 ürün alıp 2 ürün parası öder.
//
// 🔴 BU TESTİN ASIL İŞİ: hangi kalemlerin iptal edileceği kuralı.
// Yanlış kalem toplanırsa ALAKASIZ ürün iptal edilir (ciro kaybı + müşteri mağduriyeti).
// add_item_modal.dart:_cancelSelectedItem içindeki kural ile AYNI.
import 'package:flutter_test/flutter_test.dart';

/// _cancelSelectedItem ile BİREBİR aynı kural.
List<Map<String, dynamic>> iptalEdilecekler(
    Map<String, dynamic> secili, List<dynamic> ticketItems) {
  final gid = (secili['combo_group_id'] ?? '').toString().trim();
  if (gid.isEmpty) return [secili];
  final uyeler = ticketItems
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .where((e) =>
          (e['combo_group_id'] ?? '').toString().trim() == gid &&
          (e['status'] ?? 'active').toString() != 'cancelled')
      .toList();
  return uyeler.isEmpty ? [secili] : uyeler;
}

Map<String, dynamic> k(int id, String ad, {String? gid, String? status}) => {
      'id': id,
      'product_name': ad,
      if (gid != null) 'combo_group_id': gid,
      if (status != null) 'status': status,
    };

void main() {
  group('🔴 REGRESYON — combo OLMAYAN kalem: davranış BİREBİR eskisi gibi', () {
    test('gid alanı hiç yok → SADECE seçili kalem', () {
      final secili = k(1, 'Kola');
      final r = iptalEdilecekler(secili, [secili, k(2, 'Ayran'), k(3, 'Su')]);
      expect(r.length, 1);
      expect(r.first['id'], 1);
    });

    test('gid boş string → SADECE seçili kalem', () {
      final secili = k(1, 'Kola', gid: '');
      expect(iptalEdilecekler(secili, [secili, k(2, 'Ayran', gid: '')]).length, 1);
    });

    test('gid sadece boşluk → SADECE seçili kalem (grup sanılmamalı)', () {
      final secili = k(1, 'Kola', gid: '   ');
      expect(iptalEdilecekler(secili, [secili, k(2, 'Ayran', gid: '   ')]).length, 1);
    });

    test('gid null → SADECE seçili kalem', () {
      final secili = <String, dynamic>{'id': 1, 'product_name': 'Kola', 'combo_group_id': null};
      expect(iptalEdilecekler(secili, [secili]).length, 1);
    });
  });

  group('Combo paketi — TÜM üyeler toplanır', () {
    test('3 üyeli paket → 3 kalem', () {
      final items = [k(1, 'Waffle Çikolatalı', gid: 'cg1'), k(2, 'Waffle Fıstıklı', gid: 'cg1'),
        k(3, 'Waffle Çilekli', gid: 'cg1')];
      final r = iptalEdilecekler(items[1], items);
      expect(r.map((e) => e['id']).toList(), [1, 2, 3]);
    });

    test('🔴 BAŞKA paketin üyeleri KARIŞMAZ', () {
      final items = [k(1, 'A', gid: 'cg1'), k(2, 'B', gid: 'cg1'),
        k(3, 'C', gid: 'cg2'), k(4, 'D', gid: 'cg2')];
      final r = iptalEdilecekler(items[0], items);
      expect(r.map((e) => e['id']).toList(), [1, 2],
          reason: 'cg2 paketine DOKUNULMAMALI');
    });

    test('🔴 grup DIŞI serbest kalemler KARIŞMAZ', () {
      final items = [k(1, 'Paket A', gid: 'cg1'), k(2, 'Paket B', gid: 'cg1'),
        k(3, 'Serbest Kola'), k(4, 'Serbest Ayran', gid: '')];
      final r = iptalEdilecekler(items[0], items);
      expect(r.map((e) => e['id']).toList(), [1, 2]);
    });

    test('zaten iptal edilmiş üye TEKRAR iptal edilmez', () {
      final items = [k(1, 'A', gid: 'cg1'), k(2, 'B', gid: 'cg1', status: 'cancelled'),
        k(3, 'C', gid: 'cg1')];
      final r = iptalEdilecekler(items[0], items);
      expect(r.map((e) => e['id']).toList(), [1, 3]);
    });

    test('status alanı yoksa aktif sayılır (eski kayıtlar)', () {
      final items = [k(1, 'A', gid: 'cg1'), k(2, 'B', gid: 'cg1')];
      expect(iptalEdilecekler(items[0], items).length, 2);
    });

    test('tek üyeli grup → tek kalem (uyarı çıkmaz, akış aynı)', () {
      final items = [k(1, 'A', gid: 'cg1'), k(2, 'Serbest')];
      expect(iptalEdilecekler(items[0], items).length, 1);
    });

    test('hepsi iptal edilmişse → seçiliye düşer (boş liste dönmez, patlamaz)', () {
      final secili = k(1, 'A', gid: 'cg1', status: 'cancelled');
      final r = iptalEdilecekler(secili, [k(9, 'X', gid: 'cg9')]);
      expect(r.length, 1);
      expect(r.first['id'], 1);
    });

    test('6 satırlık iki set aynı gid → hepsi (tek seçim ekranı = tek paket)', () {
      final items = List.generate(6, (i) => k(i + 1, 'Ürün ${i + 1}', gid: 'cg1'));
      expect(iptalEdilecekler(items[3], items).length, 6);
    });
  });

  group('Bozuk veri — patlamamalı', () {
    test('ticketItems içinde Map olmayan öğe → atlanır', () {
      final secili = k(1, 'A', gid: 'cg1');
      final r = iptalEdilecekler(secili, [secili, 'bozuk', 42, null, k(2, 'B', gid: 'cg1')]);
      expect(r.map((e) => e['id']).toList(), [1, 2]);
    });

    test('gid sayısal gelirse metne çevrilip eşleşir', () {
      final items = [
        <String, dynamic>{'id': 1, 'product_name': 'A', 'combo_group_id': 12345},
        <String, dynamic>{'id': 2, 'product_name': 'B', 'combo_group_id': 12345},
      ];
      expect(iptalEdilecekler(items[0], items).length, 2);
    });
  });
}
