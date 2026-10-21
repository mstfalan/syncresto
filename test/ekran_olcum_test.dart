import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/ekran_olcum.dart';
import 'package:syncresto_pos/services/log_service.dart';

const _bos = <int>[];

void main() {
  group('ekranOzeti', () {
    test('dokunus ve takilma yok -> null (bosta kareler log uretmez)', () {
      expect(
        ekranOzeti(
          basis: _bos, birakma: _bos, kare33: 40, kare100: 0,
          kareBuildMax: 20, kareRasterMax: 10, donguMax: 150, dongu200: 0, dongu1000: 0,
        ),
        isNull,
      );
    });

    test('dokunus yok ama dongu takilmasi var -> raporlanir', () {
      final r = ekranOzeti(
        basis: _bos, birakma: _bos, kare33: 0, kare100: 0,
        kareBuildMax: 0, kareRasterMax: 0, donguMax: 1500, dongu200: 2, dongu1000: 1,
      )!;
      expect(r['dongu_max_ms'], 1500);
      expect(r['dongu_1sn_sayi'], 1);
      expect(r['birakma_sayi'], 0);
      expect(r['birakma_max_ms'], 0);
    });

    test('100 ms ustu kare tek basina raporlatir', () {
      expect(
        ekranOzeti(
          basis: _bos, birakma: _bos, kare33: 1, kare100: 1,
          kareBuildMax: 140, kareRasterMax: 0, donguMax: 0, dongu200: 0, dongu1000: 0,
        ),
        isNotNull,
      );
    });

    test('basis/birakma yuzdelikleri sirasiz girdide dogru', () {
      final r = ekranOzeti(
        basis: [30, 10, 20],
        birakma: [300, 20, 40, 30, 50, 60, 70, 80, 90, 10],
        kare33: 3, kare100: 1, kareBuildMax: 90, kareRasterMax: 30,
        donguMax: 0, dongu200: 0, dongu1000: 0,
      )!;
      expect(r['basis_p50_ms'], 20);
      expect(r['birakma_sayi'], 10);
      expect(r['birakma_p50_ms'], 60);
      expect(r['birakma_p90_ms'], 90);
      expect(r['birakma_max_ms'], 300);
      expect(r['kare_100ms_sayi'], 1);
    });
  });

  group('donguKaymasi', () {
    test('zamaninda tick -> 0', () => expect(donguKaymasi(1000, 1500, 500), 0));
    test('takilma -> fazlalik', () => expect(donguKaymasi(1000, 2800, 500), 1300));
    test('takilma sonrasi erken tick (negatif) -> 0', () => expect(donguKaymasi(2800, 3000, 500), 0));
  });

  test('dartSurumu yalniz surum numarasi doner', () {
    expect(dartSurumu(), matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  testWidgets('baslat + dokunus uygulamayi bozmaz; durdur sonrasi da calisir', (tester) async {
    addTearDown(EkranOlcum().durdur);
    EkranOlcum().baslat();
    EkranOlcum().baslat(); // ikinci cagri etkisiz
    var tik = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: ElevatedButton(onPressed: () => tik++, child: const Text('x')))),
    ));
    await tester.tap(find.text('x'));
    await tester.pump();
    expect(tik, 1);
    EkranOlcum().durdur();
    await tester.tap(find.text('x'));
    await tester.pump();
    expect(tik, 2);
  });
}
