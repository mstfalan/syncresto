import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

import 'log_service.dart';

/// Ekran tepki ölçümü: kasiyerin hissettiği gecikmeyi sayıya döker.
///  - basis: basış olayının Dart'a ulaşması -> UI'nin sonraki kareyi teslim ettiği an (raster hariç)
///  - birakma: bırakış (onTap burada tetiklenir) -> UI'nin sonraki kareyi teslim ettiği an
///  - kare: build (UI) ve raster (çizim) süreleri, 33/100 ms üstü kare sayısı
///  - dongu: ana isolate'in meşgul kaldığı süre (500 ms'lik zamanlayıcının kayması)
/// 5 dakikada bir, yalnız dokunuş ya da takılma varsa TEK log satırı yollar.
/// Yalnız sunucu ayarı açıkken çalışır (performans_olcum.dart).
class EkranOlcum {
  static final EkranOlcum _instance = EkranOlcum._internal();
  factory EkranOlcum() => _instance;
  EkranOlcum._internal();

  static const _ozetAraligi = Duration(minutes: 5);
  static const _donguAraligi = Duration(milliseconds: 500);
  static const _azamiOrnek = 2000; // 5 dk'da RAM tavanı

  bool _basladi = false;
  final _basis = <int>[];
  final _birakma = <int>[];
  int _kareBuildMax = 0;
  int _kareRasterMax = 0;
  int _kare33 = 0;
  int _kare100 = 0;
  int _donguMax = 0;
  int _dongu200 = 0;
  int _dongu1000 = 0;
  bool _basisBekliyor = false;
  bool _birakmaBekliyor = false;
  final _sw = Stopwatch();
  int _sonDongu = 0;
  Timer? _donguTimer;
  Timer? _ozetTimer;

  void baslat() {
    if (_basladi) return;
    try {
      _sw.start();
      SchedulerBinding.instance.addTimingsCallback(_kareler);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_isaretci);
      _sonDongu = _sw.elapsedMilliseconds;
      _donguTimer = Timer.periodic(_donguAraligi, (_) => _donguOlc());
      _ozetTimer = Timer.periodic(_ozetAraligi, (_) => _ozetGonder());
      _basladi = true;
    } catch (_) {
      // ölçüm uygulamayı asla durdurmaz; yarım kalan kayıt sökülür, sonraki ayar gelişinde yeniden denenir
      _sok();
    }
  }

  /// Sunucu ayarı kapatınca: zamanlayıcılar ve kancalar sökülür, birikmiş veri atılır.
  void durdur() {
    if (!_basladi) return;
    _basladi = false;
    _sok();
    _sifirla();
    _basisBekliyor = false;
    _birakmaBekliyor = false;
  }

  void _sok() {
    _donguTimer?.cancel();
    _ozetTimer?.cancel();
    _donguTimer = null;
    _ozetTimer = null;
    try {
      SchedulerBinding.instance.removeTimingsCallback(_kareler);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_isaretci);
    } catch (_) {}
  }

  void _isaretci(PointerEvent e) {
    if (e is PointerDownEvent) {
      if (_basisBekliyor) return;
      _basisBekliyor = true;
      _kareyeKadar(_basis, () => _basisBekliyor = false);
    } else if (e is PointerUpEvent) {
      if (_birakmaBekliyor) return;
      _birakmaBekliyor = true;
      _kareyeKadar(_birakma, () => _birakmaBekliyor = false);
    }
  }

  void _kareyeKadar(List<int> hedef, void Function() bitti) {
    final t0 = _sw.elapsedMilliseconds;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      bitti();
      if (!_basladi) return;
      if (hedef.length < _azamiOrnek) hedef.add(_sw.elapsedMilliseconds - t0);
    });
    binding.ensureVisualUpdate(); // dokunuş ekranı değiştirmese de kare gelsin
  }

  void _kareler(List<FrameTiming> liste) {
    for (final f in liste) {
      final build = f.buildDuration.inMilliseconds;
      final raster = f.rasterDuration.inMilliseconds;
      final toplam = f.totalSpan.inMilliseconds;
      if (build > _kareBuildMax) _kareBuildMax = build;
      if (raster > _kareRasterMax) _kareRasterMax = raster;
      if (toplam > 33) _kare33++;
      if (toplam > 100) _kare100++;
    }
  }

  void _donguOlc() {
    final simdi = _sw.elapsedMilliseconds;
    final kayma = donguKaymasi(_sonDongu, simdi, _donguAraligi.inMilliseconds);
    _sonDongu = simdi;
    if (kayma == 0) return;
    if (kayma > _donguMax) _donguMax = kayma;
    if (kayma >= 200) _dongu200++;
    if (kayma >= 1000) _dongu1000++;
  }

  void _ozetGonder() {
    try {
      final ozet = ekranOzeti(
        basis: _basis,
        birakma: _birakma,
        kare33: _kare33,
        kare100: _kare100,
        kareBuildMax: _kareBuildMax,
        kareRasterMax: _kareRasterMax,
        donguMax: _donguMax,
        dongu200: _dongu200,
        dongu1000: _dongu1000,
      );
      if (ozet != null) {
        LogService().info(LogType.general, 'Ekran performansi (5 dk)',
            details: {...ozet, 'dart': dartSurumu()});
      }
    } catch (_) {
    } finally {
      _sifirla();
    }
  }

  void _sifirla() {
    _basis.clear();
    _birakma.clear();
    _kare33 = 0;
    _kare100 = 0;
    _kareBuildMax = 0;
    _kareRasterMax = 0;
    _donguMax = 0;
    _dongu200 = 0;
    _dongu1000 = 0;
  }
}

/// Periyodik zamanlayıcının kayması (ms). Dart kaçırılan tick'leri atlar; takılmadan sonraki
/// tick erken gelir (negatif) -> 0 sayılır, çift sayım olmaz.
int donguKaymasi(int onceki, int simdi, int aralik) {
  final k = simdi - onceki - aralik;
  return k > 0 ? k : 0;
}

int _yuzdelik(List<int> sirali, double p) {
  if (sirali.isEmpty) return 0;
  return sirali[((sirali.length - 1) * p).round()];
}

Map<String, int> _seri(String ad, List<int> l) {
  final s = [...l]..sort();
  return {
    '${ad}_sayi': s.length,
    '${ad}_p50_ms': _yuzdelik(s, 0.5),
    '${ad}_p90_ms': _yuzdelik(s, 0.9),
    '${ad}_max_ms': s.isEmpty ? 0 : s.last,
  };
}

/// Saf özet: dokunuş yok ve takılma yoksa null (saat tiki gibi boşta kareler log üretmez).
Map<String, dynamic>? ekranOzeti({
  required List<int> basis,
  required List<int> birakma,
  required int kare33,
  required int kare100,
  required int kareBuildMax,
  required int kareRasterMax,
  required int donguMax,
  required int dongu200,
  required int dongu1000,
}) {
  if (basis.isEmpty && birakma.isEmpty && dongu200 == 0 && kare100 == 0) return null;
  return {
    ..._seri('basis', basis),
    ..._seri('birakma', birakma),
    'kare_33ms_sayi': kare33,
    'kare_100ms_sayi': kare100,
    'kare_build_max_ms': kareBuildMax,
    'kare_raster_max_ms': kareRasterMax,
    'dongu_max_ms': donguMax,
    'dongu_200ms_sayi': dongu200,
    'dongu_1sn_sayi': dongu1000,
  };
}
