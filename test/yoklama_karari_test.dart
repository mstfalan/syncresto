import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/yoklama_karari.dart';

void main() {
  test('online iken tek basarisiz yoklama offline yapmaz, teyit bekler', () {
    final k = YoklamaKarari();
    expect(k.uygula(basarili: false, erisilebilir: true), isTrue);
    expect(k.teyitBekliyor, isTrue);
  });

  test('ust uste iki hata offline yapar', () {
    final k = YoklamaKarari();
    var d = k.uygula(basarili: false, erisilebilir: true);
    d = k.uygula(basarili: false, erisilebilir: d);
    expect(d, isFalse);
    expect(k.teyitBekliyor, isFalse);
  });

  test('hata sonrasi basari sayaci sifirlar', () {
    final k = YoklamaKarari();
    var d = k.uygula(basarili: false, erisilebilir: true);
    d = k.uygula(basarili: true, erisilebilir: d);
    expect(d, isTrue);
    d = k.uygula(basarili: false, erisilebilir: d);
    expect(d, isTrue); // yeniden tek hata: hala online
  });

  test('offline iken tek basari online yapar, tek hata offline tutar', () {
    final k = YoklamaKarari();
    expect(k.uygula(basarili: false, erisilebilir: false), isFalse);
    expect(k.uygula(basarili: true, erisilebilir: false), isTrue);
  });

  test('sifirla sonrasi ilk hata yine tolere edilir', () {
    final k = YoklamaKarari();
    k.uygula(basarili: false, erisilebilir: true);
    k.sifirla();
    expect(k.uygula(basarili: false, erisilebilir: true), isTrue);
  });
}
