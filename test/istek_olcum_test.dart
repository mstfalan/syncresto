import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncresto_pos/services/istek_olcum.dart';
import 'package:syncresto_pos/services/performans_olcum.dart';

void main() {
  group('istekUcu', () {
    test('rakamlar N, sorgu ve /api/pos oneki atilir', () {
      expect(istekUcu('get', '/api/pos/tickets/172314/items?x=1'), 'GET /tickets/N/items');
      expect(istekUcu('POST', '/api/pos/tickets/table/37'), 'POST /tickets/table/N');
      expect(istekUcu('GET', 'https://api.syncresto.com/api/pos/tables'), 'GET /tables');
      expect(istekUcu('GET', '/api/pos'), 'GET /');
      expect(istekUcu('GET', '/api/pos/v2abc/12x'), 'GET /v2abc/12x');
    });
  });

  group('istekOzeti', () {
    test('istek yoksa null', () => expect(istekOzeti({}, {}), isNull));

    test('toplam, 3 sn ustu, ag hatasi ve en yavas siralama', () {
      final r = istekOzeti({
        'GET /tables': [100, 120, 140],
        'POST /tickets/N/items': [200, 3500],
      }, {'POST /tickets/N/items': 1})!;
      expect(r['istek_sayi'], 5);
      expect(r['istek_max_ms'], 3500);
      expect(r['istek_3sn_sayi'], 1);
      expect(r['ag_hata_sayi'], 1);
      final enYavas = r['en_yavas'] as List;
      expect(enYavas.first['uc'], 'POST /tickets/N/items');
      expect(enYavas.first['ag_hata'], 1);
      expect(enYavas.last.containsKey('ag_hata'), isFalse);
    });

    test('en_yavas en fazla 6 uc', () {
      final m = {for (var i = 0; i < 10; i++) 'GET /u$i': [i]};
      expect((istekOzeti(m, {})!['en_yavas'] as List).length, 6);
    });
  });

  group('performans anahtari', () {
    test('deger yorumu: yalniz acik degerler', () {
      for (final v in [true, 1, '1', 'true']) {
        expect(performansOlcumDegeri(v), isTrue, reason: '$v');
      }
      for (final v in [null, false, 0, '0', 'false', '', 'yes']) {
        expect(performansOlcumDegeri(v), isFalse, reason: '$v');
      }
    });

    test('varsayilan kapali; anahtar yoksa kapali kalir', () {
      performansOlcumAyarla({});
      expect(performansOlcumAcik, isFalse);
    });

    test('kapaliyken interceptor istegi isaretlemez', () {
      final o = RequestOptions(path: '/api/pos/tables');
      IstekOlcum().onRequest(o, RequestInterceptorHandler());
      expect(o.extra, isEmpty);
    });
  });
}
