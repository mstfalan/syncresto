import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/crash_beacon.dart';
import '../services/log_service.dart';
import '../services/storage_service.dart';

/// 14 Eyl 2026 — Gri `ErrorWidget` yerine: ne olduğunu söyleyen ve sunucuya bildiren ekran.
/// `MaterialApp` DIŞINDA da çalışır (Directionality + düz stiller) çünkü kök build patladığında
/// ağaçta hiçbir şey yoktur.
///
/// 🔴 Denetim bulgusu (kritik): `ErrorWidget.builder` YALNIZ kök için değil, HERHANGİ bir parçanın
/// çizim hatası için de çağrılır (bir ürün kartı, bir pencere, bir liste satırı). O durumda uygulama
/// çalışmaya devam ediyordur; "ayarları onar" düğmesi SAĞLAM ayar dosyasını kenara alır, yazıcı ayarı
/// gider, mutfak fişi durur. Bu yüzden onarım/kapat düğmeleri YALNIZ ayar dosyası şüpheliyken
/// ([CrashBeacon.prefsSuspect] veya `_prefs` hatası) gösterilir; diğer hatalarda ekran sadece bilgi verir
/// ve kasiyer işine devam eder.
class PosErrorScreen extends StatefulWidget {
  final FlutterErrorDetails details;

  /// Uygulama hiç açılamadı mı? (zone kancası bu ekranı KÖK olarak çiziyorsa true.) O durumda
  /// "geri kalanı çalışıyor" demek YANLIŞ olur ve kasiyerin basacak bir düğmesi bile kalmaz.
  final bool fatal;
  const PosErrorScreen({super.key, required this.details, this.fatal = false});

  @override
  State<PosErrorScreen> createState() => _PosErrorScreenState();
}

class _PosErrorScreenState extends State<PosErrorScreen> {
  bool _busy = false;
  String? _note;

  bool get _olumcul => widget.fatal;

  /// Yıkıcı düğmelerin TEK kapısı: açılışta gerçekten prefs sorunu yaşandı mı?
  /// Eskiden hata metninde '_prefs'/'SharedPreferences' geçmesi yetiyordu — çalışan bir kasada
  /// alakasız bir hata bu sezgiyi tetikleyip SAĞLAM ayar dosyasını sildirebiliyordu (denetim bulgusu).
  bool get _ayarSuphesi => CrashBeacon.prefsSuspect;

  @override
  void initState() {
    super.initState();
    // Ölümcül yolda zone kancası raporu ZATEN gönderdi; aşama farklı olduğu için dedup tutmaz ve
    // 3'lük bütçenin ikisi tek olaya giderdi (denetim bulgusu).
    if (!widget.fatal) {
      CrashBeacon.send(stage: 'flutter', error: widget.details.exception, stack: widget.details.stack);
    }
  }

  Future<void> _repair() async {
    setState(() => _busy = true);
    // ÖNCE DOĞRULA: dosya okunabiliyorsa karantinaya ALMA (sağlam ayarları silmek = yazıcı ayarı gider).
    if (await StorageService.prefsOkunabilir()) {
      setState(() {
        _busy = false;
        _note = 'Ayar dosyası sağlam görünüyor, onarım gerekmedi. Uygulamayı kapatıp tekrar açın.';
      });
      return;
    }
    final moved = await StorageService.quarantineCorruptPrefsFile();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = moved == null
          ? 'Ayar dosyası bulunamadı. Uygulamayı kapatıp tekrar açın; sorun sürerse destek ile görüşün.'
          : 'Ayarlar onarıldı. Uygulama kapanıyor, lütfen tekrar açın.';
    });
    if (moved != null) {
      await _kapat();
    }
  }

  /// Çıkmadan önce kanıtı kurtar: bekleyen loglar diske/sunucuya, çökme raporu kuyruğu gönderilsin.
  /// (Eskiden düz `exit(0)` idi; son 30 sn'lik fiş/ödeme kaydı ve raporun kendisi buharlaşıyordu.)
  Future<void> _kapat() async {
    try {
      await LogService().flush().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await CrashBeacon.flushSpool().timeout(const Duration(seconds: 4));
    } catch (_) {}
    exit(0);
  }

  Widget _button(String label, VoidCallback onTap, {bool primary = false}) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: primary ? const Color(0xFF2563EB) : const Color(0xFF334155),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.details.exceptionAsString();
    final ayar = _ayarSuphesi;
    // ErrorWidget.builder bir liste satırı/ızgara hücresi için de çağrılır. Flutter'ın stok
    // RenderErrorBox'ı her kısıtta güvenlidir; bu zengin ağaç değil (dikey kaydırma + padding).
    // Dar/sınırsız slotta sade bir kutuya düşeriz, yoksa hata ekranının KENDİSİ patlar.
    return LayoutBuilder(builder: (context, k) {
      final darSlot = !k.hasBoundedHeight || k.maxHeight < 220 || k.maxWidth < 280;
      if (darSlot) {
        return const ColoredBox(
          color: Color(0xFF7F1D1D),
          child: Center(
            child: Text('Görüntülenemedi',
                textDirection: TextDirection.ltr,
                style: TextStyle(color: Colors.white, fontSize: 12, decoration: TextDecoration.none)),
          ),
        );
      }
      return _tamEkran(msg, ayar);
    });
  }

  Widget _tamEkran(String msg, bool ayar) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF0F172A),
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(ayar || _olumcul ? 'Uygulama açılamadı' : 'Bu bölüm görüntülenemedi',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none)),
                    const SizedBox(height: 10),
                    Text(
                      ayar
                          ? 'Ayar dosyası bozulmuş görünüyor. Hata SyncResto destek ekibine otomatik bildirildi. '
                              '"Ayarları onar" bozuk dosyayı kenara alır ve uygulamayı kapatır; tekrar açmanız yeterlidir. '
                              'Sipariş ve ürün verileriniz silinmez.'
                          : _olumcul
                              ? 'Hata SyncResto destek ekibine otomatik bildirildi. Uygulamayı kapatıp tekrar açın; '
                                  'sorun sürerse destek ile görüşün. Sipariş ve ürün verileriniz silinmez.'
                              : 'Hata SyncResto destek ekibine otomatik bildirildi. Uygulamanın geri kalanı çalışmaya devam ediyor; '
                                  'işleminize başka bir ekrandan devam edebilirsiniz.',
                      style: const TextStyle(
                          color: Color(0xFFCBD5E1), fontSize: 14, height: 1.4, decoration: TextDecoration.none),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(8)),
                      child: Text(CrashBeacon.mask(msg.length > 400 ? '${msg.substring(0, 400)}…' : msg),
                          style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              fontFamily: 'monospace',
                              decoration: TextDecoration.none)),
                    ),
                    if (_note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_note!,
                            style: const TextStyle(
                                color: Color(0xFF86EFAC), fontSize: 13, decoration: TextDecoration.none)),
                      ),
                    // Yıkıcı düğmeler YALNIZ ayar şüphesinde. Diğer hatalarda uygulama çalışıyordur:
                    // exit(0) sahiplenilmiş ama basılmamış mutfak fişini yutabilir.
                    if (ayar || _olumcul) ...<Widget>[
                      const SizedBox(height: 20),
                      Wrap(spacing: 12, runSpacing: 10, children: <Widget>[
                        if (ayar) _button('Ayarları onar ve kapat', _repair, primary: true),
                        _button('Kapat', () => unawaited(_kapat()), primary: !ayar),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
