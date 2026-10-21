import 'dart:async';

import 'package:dio/dio.dart';

import 'log_service.dart';

/// Sunucu istek süresi ölçümü: "gönderirken bekletiyor" şikâyetini sayıya döker.
///  - her istek: gönderim -> yanıt/hata süresi (ms), uç adı rakamlardan arındırılır (/tickets/N/items)
///  - 5 dakikada bir TEK özet satırı: toplam + en yavaş uçlar
///  - 3 sn üstü ya da zaman aşımı/bağlantı hatası: ayrı 'Yavas istek' satırı (5 dk'da en çok 20)
/// /api/pos/logs ölçülmez (log gönderimi kendini loglamasın).
/// Interceptor hep takılıdır ama sunucu ayarı kapalıyken HİÇBİR ŞEY yapmaz (performans_olcum.dart).
class IstekOlcum extends Interceptor {
  static final IstekOlcum _instance = IstekOlcum._internal();
  factory IstekOlcum() => _instance;
  IstekOlcum._internal();

  static const _ozetAraligi = Duration(minutes: 5);
  static const _yavasEsik = 3000;
  static const _yavasTavan = 20;
  static const _azamiOrnek = 5000;
  static const _anahtar = '_istek_olcum_t0';

  final _sw = Stopwatch()..start();
  final _sureler = <String, List<int>>{};
  final _hatalar = <String, int>{};
  int _ornekSayisi = 0;
  int _yavasYollanan = 0;
  Timer? _ozetTimer;
  bool _acik = false;

  void ac() {
    if (_acik) return;
    _acik = true;
    _ozetTimer = Timer.periodic(_ozetAraligi, (_) => _ozetGonder());
  }

  void kapat() {
    _acik = false;
    _ozetTimer?.cancel();
    _ozetTimer = null;
    _sureler.clear();
    _hatalar.clear();
    _ornekSayisi = 0;
    _yavasYollanan = 0;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_acik) {
      try {
        options.extra[_anahtar] = _sw.elapsedMilliseconds;
      } catch (_) {}
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _kaydet(response.requestOptions, durum: response.statusCode);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _kaydet(err.requestOptions, durum: err.response?.statusCode, hata: err.type.name);
    handler.next(err);
  }

  void _kaydet(RequestOptions o, {int? durum, String? hata}) {
    try {
      if (!_acik) return;
      final t0 = o.extra[_anahtar];
      if (t0 is! int) return;
      if (o.path.contains('/api/pos/logs')) return;
      final ms = _sw.elapsedMilliseconds - t0;
      final uc = istekUcu(o.method, o.path);
      if (_ornekSayisi < _azamiOrnek) {
        (_sureler[uc] ??= <int>[]).add(ms);
        _ornekSayisi++;
      }
      final agHatasi = hata != null && hata != 'badResponse';
      if (agHatasi) _hatalar[uc] = (_hatalar[uc] ?? 0) + 1;
      if ((ms >= _yavasEsik || agHatasi) && _yavasYollanan < _yavasTavan) {
        _yavasYollanan++;
        LogService().warning(LogType.general, 'Yavas istek: $uc ${ms}ms', details: {
          'uc': uc,
          'ms': ms,
          if (durum != null) 'durum': durum,
          if (hata != null) 'hata': hata,
        });
      }
    } catch (_) {
      // ölçüm isteği asla bozmaz
    }
  }

  void _ozetGonder() {
    try {
      final ozet = istekOzeti(_sureler, _hatalar);
      if (ozet != null) {
        LogService().info(LogType.general, 'Istek performansi (5 dk)', details: ozet);
      }
    } catch (_) {
    } finally {
      _sureler.clear();
      _hatalar.clear();
      _ornekSayisi = 0;
      _yavasYollanan = 0;
    }
  }
}

/// "GET", "/api/pos/tickets/172314/items?x=1" -> "GET /tickets/N/items"
String istekUcu(String method, String path) {
  var p = path;
  final q = p.indexOf('?');
  if (q >= 0) p = p.substring(0, q);
  final u = Uri.tryParse(p);
  if (u != null && u.hasScheme) p = u.path;
  p = p.replaceFirst(RegExp(r'^/api/pos'), '');
  p = p.replaceAll(RegExp(r'/\d+(?=/|$)'), '/N');
  return '${method.toUpperCase()} ${p.isEmpty ? '/' : p}';
}

int _yuzdelik(List<int> sirali, double p) {
  if (sirali.isEmpty) return 0;
  return sirali[((sirali.length - 1) * p).round()];
}

/// Saf özet: istek yoksa null. 'en_yavas': max'a göre ilk 6 uç (sayi/p50/p90/max/ag_hata).
Map<String, dynamic>? istekOzeti(Map<String, List<int>> sureler, Map<String, int> hatalar) {
  if (sureler.isEmpty) return null;
  final hepsi = <int>[for (final l in sureler.values) ...l]..sort();
  final uclar = sureler.entries.map((e) {
    final s = [...e.value]..sort();
    return <String, dynamic>{
      'uc': e.key,
      'sayi': s.length,
      'p50': _yuzdelik(s, 0.5),
      'p90': _yuzdelik(s, 0.9),
      'max': s.last,
      if ((hatalar[e.key] ?? 0) > 0) 'ag_hata': hatalar[e.key],
    };
  }).toList()
    ..sort((a, b) => (b['max'] as int).compareTo(a['max'] as int));
  return {
    'istek_sayi': hepsi.length,
    'istek_p50_ms': _yuzdelik(hepsi, 0.5),
    'istek_p90_ms': _yuzdelik(hepsi, 0.9),
    'istek_max_ms': hepsi.last,
    'istek_3sn_sayi': hepsi.where((m) => m >= 3000).length,
    'ag_hata_sayi': hatalar.values.fold<int>(0, (a, b) => a + b),
    'en_yavas': uclar.take(6).toList(),
  };
}
