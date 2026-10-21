// 21 Eki 2026 — cevrimdisi mutfak fisi daha once basilmis
// kalemleri yeniden basti. Kok: ayna printed'i lokal degerden koruyordu. Bu dosya saf kurallari
// (ayna printed birlestirme + push ile aynalanacak masa secimi) dogrular.
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/ayna_printed.dart';
import 'package:syncresto_pos/services/push_ayna.dart';

void main() {
  group('printedBirlestir — tek yonlu max(lokal, sunucu)', () {
    test('lokal 0 + sunucu 1 -> 1 (baska kasa/WebPOS basti)', () {
      expect(printedBirlestir(lokal: 0, sunucu: 1), 1);
    });
    test('lokal 1 + sunucu 0 -> 1 (cevrimdisi basildi, mark_printed bekliyor)', () {
      expect(printedBirlestir(lokal: 1, sunucu: 0), 1);
    });
    test('lokal 0 + sunucu 0 -> 0 (mesru ilk basim korunur)', () {
      expect(printedBirlestir(lokal: 0, sunucu: 0), 0);
    });
    test('lokal 1 + sunucu 1 -> 1', () {
      expect(printedBirlestir(lokal: 1, sunucu: 1), 1);
    });
    test('lokal satir yok -> sunucu degeri', () {
      expect(printedBirlestir(lokal: null, sunucu: 1), 1);
      expect(printedBirlestir(lokal: null, sunucu: 0), 0);
    });
    test('sunucu tip varyantlari: true / "1" -> 1; false / null / "0" -> 0', () {
      expect(printedBirlestir(lokal: 0, sunucu: true), 1);
      expect(printedBirlestir(lokal: 0, sunucu: '1'), 1);
      expect(printedBirlestir(lokal: 0, sunucu: false), 0);
      expect(printedBirlestir(lokal: 0, sunucu: null), 0);
      expect(printedBirlestir(lokal: 0, sunucu: '0'), 0);
      expect(printedBirlestir(lokal: null, sunucu: null), 0);
    });
  });

  group('pushAynaMasalariSec — table_status push payload', () {
    test('table_ids yok (eski sunucu) -> bos', () {
      expect(pushAynaMasalariSec({'types': ['table_status']}), isEmpty);
      expect(pushAynaMasalariSec({'table_ids': []}), isEmpty);
    });
    test('id var, satir yok -> hepsi alinir', () {
      expect(pushAynaMasalariSec({'table_ids': [5, 7]}), {5, 7});
    });
    test('satir bos masa (status!=occupied, current_ticket_id null) -> atlanir', () {
      final r = pushAynaMasalariSec({
        'table_ids': [5, 7],
        'tables': [
          {'id': 5, 'status': 'available', 'current_ticket_id': null},
          {'id': 7, 'status': 'occupied', 'current_ticket_id': 172163},
        ],
      });
      expect(r, {7});
    });
    test('status bos ama current_ticket_id var -> alinir', () {
      final r = pushAynaMasalariSec({
        'table_ids': [9],
        'tables': [
          {'id': 9, 'status': 'available', 'current_ticket_id': 12},
        ],
      });
      expect(r, {9});
    });
    test('string id -> int; bozuk id -> atlanir', () {
      expect(pushAynaMasalariSec({'table_ids': ['12', 'x', null, 3]}), {12, 3});
    });
  });
}
