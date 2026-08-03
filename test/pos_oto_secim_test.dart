// 3 Agu 2026 — Yeni eklenen kalem OTO-SECIM testleri.
//
// Mustafa: adisyon listesi ters sirali (en yeni ustte) — o kalem ayni anda SECILI
// de gelsin. Uretim kodu (_addProductWithPrice) PosOtoSecim'in kendisini cagirir;
// burada dogrulanan kod canli koddur.
//
// Kritik senaryolar:
//   - yeni kalem eklenince secim ona gecer (baska kalem secili olsa bile)
//   - combo paketinde SADECE ILK kalem secili gelir
//   - gecici (negatif) id seciliyken sync olursa secim gercek id'ye tasinir, KAYBOLMAZ
//   - kullanici sync beklerken BASKA kalem sectiyse esleme ona DOKUNMAZ

import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/widgets/add_item_modal.dart';

void main() {
  group('PosOtoSecim.eklemede — yeni kalem secili gelir', () {
    test('secim yokken ekleme -> yeni (gecici) kalem secilir', () {
      expect(PosOtoSecim.eklemede(mevcut: null, tempId: -1722600000000, secilsin: true),
          -1722600000000);
    });
    test('baska kalem seciliyken ekleme -> secim YENI urune gecer (beklenen davranis)', () {
      expect(PosOtoSecim.eklemede(mevcut: 42, tempId: -99, secilsin: true), -99);
    });
    test('combo 2..N kalemleri (secilsin=false) -> mevcut secim KORUNUR', () {
      // Combo dongusu: i==0 secilsin=true, sonrakiler false -> paketin ILK kalemi secili
      expect(PosOtoSecim.eklemede(mevcut: -77, tempId: -78, secilsin: false), -77);
    });
    test('combo simulasyonu: 3 kalemlik pakette ILK kalem secili kalir', () {
      int? secim;
      final tempIds = [-101, -102, -103];
      for (var i = 0; i < tempIds.length; i++) {
        secim = PosOtoSecim.eklemede(mevcut: secim, tempId: tempIds[i], secilsin: i == 0);
      }
      expect(secim, -101);
    });
  });

  group('PosOtoSecim.syncSonrasi — gecici id -> gercek id, secim kaybolmaz', () {
    test('gecici id seciliyken sync -> secim gercek id`ye tasinir', () {
      expect(PosOtoSecim.syncSonrasi(mevcut: -99, tempId: -99, realId: 5501), 5501);
    });
    test('kullanici bu arada BASKA kalem sectiyse dokunulmaz', () {
      expect(PosOtoSecim.syncSonrasi(mevcut: 42, tempId: -99, realId: 5501), 42);
    });
    test('secim yoksa (null) null kalir', () {
      expect(PosOtoSecim.syncSonrasi(mevcut: null, tempId: -99, realId: 5501), isNull);
    });
    test('uctan uca: ekle -> secili -> sync -> hala secili (gercek id ile)', () {
      int? secim;
      const tempId = -1722600000123;
      secim = PosOtoSecim.eklemede(mevcut: secim, tempId: tempId, secilsin: true);
      expect(secim, tempId);
      secim = PosOtoSecim.syncSonrasi(mevcut: secim, tempId: tempId, realId: 8807);
      expect(secim, 8807); // secim KAYBOLMADI
    });
  });
}
