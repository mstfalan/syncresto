// SyncResto POS smoke test.
//
// Eski Flutter boilerplate (MyApp counter) bu projeye ait degildi ve paket adi
// greenchef_pos -> syncresto_pos degistiginden derlenmiyordu. Yerine tema sistemi
// (ThemeProvider saf/static yardimcilari) icin bagimliliksiz gercek testler.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/providers/theme_provider.dart';

void main() {
  group('ThemeProvider.parseColor', () {
    test('6-hane hex (# ile) -> dogru Color', () {
      expect(ThemeProvider.parseColor('#dc2626', Colors.black), const Color(0xFFDC2626));
    });
    test('6-hane hex (# olmadan) -> dogru Color', () {
      expect(ThemeProvider.parseColor('2563eb', Colors.black), const Color(0xFF2563EB));
    });
    test('3-hane hex genisletilir', () {
      expect(ThemeProvider.parseColor('#f00', Colors.black), const Color(0xFFFF0000));
    });
    test('null/bos/gecersiz -> default doner', () {
      const def = Color(0xFF123456);
      expect(ThemeProvider.parseColor(null, def), def);
      expect(ThemeProvider.parseColor('', def), def);
      expect(ThemeProvider.parseColor('zzz-not-hex', def), def);
    });
  });

  group('ThemeProvider.generateSecondary', () {
    test('primary den daha koyu ton uretir', () {
      final primary = HSLColor.fromColor(const Color(0xFF2563EB));
      final secondary = HSLColor.fromColor(ThemeProvider.generateSecondary(const Color(0xFF2563EB)));
      expect(secondary.lightness, lessThan(primary.lightness));
    });
  });

  group('ThemeProvider varsayilanlar', () {
    test('yeni provider SyncResto mavisi + marka ile baslar', () {
      final tp = ThemeProvider();
      expect(tp.primaryColor, const Color(0xFF2563EB));
      expect(tp.brandName, 'SyncResto POS');
      expect(tp.brandLogoUrl, isNull);
    });
    test('backgroundGradient primary + daha koyu tonu icerir', () {
      final tp = ThemeProvider();
      final g = tp.backgroundGradient;
      expect(g.colors.length, 2);
      expect(g.colors.first, tp.primaryColor);
    });
  });
}
