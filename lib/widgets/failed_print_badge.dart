import 'package:flutter/material.dart';
import '../services/local_db_service.dart';
import '../services/failed_prints_notifier.dart';

/// 24 Tem 2026 — POS sağ-üst "çıkmayan fiş" rozeti (yazıcı ikonunun yanında).
/// Retry 5/5 tükenmiş mutfak fişi varsa yanıp söner + sayaç gösterir. Tıklayınca pop-up.
/// Sayaç 0 → gizli + animasyon durur (CPU yakmaz).
///
/// Bağımsız widget (Fable M2): kendi AnimationController'ı — TablesScreen'in büyük State'ine
/// TickerProvider mixin eklemeden, dispose güvenli. failedKitchenPrintsChanged'i dinler +
/// badge poll'undan bağımsız kendi sayısını çeker (getFailedKitchenPrints).
class FailedPrintBadge extends StatefulWidget {
  final Color color; // yanıp sönen uyarı rengi (kırmızı — anlam sabit)
  final VoidCallback onTap;
  final int refreshTick; // dışarıdan (badge poll) yenileme sinyali; değişince yeniden çeker

  const FailedPrintBadge({
    super.key,
    required this.color,
    required this.onTap,
    this.refreshTick = 0,
  });

  @override
  State<FailedPrintBadge> createState() => _FailedPrintBadgeState();
}

class _FailedPrintBadgeState extends State<FailedPrintBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _refresh();
    failedKitchenPrintsChanged.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant FailedPrintBadge old) {
    super.didUpdateWidget(old);
    if (old.refreshTick != widget.refreshTick) _refresh();
  }

  @override
  void dispose() {
    failedKitchenPrintsChanged.removeListener(_refresh);
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rows = await LocalDbService().getFailedKitchenPrints();
    if (!mounted) return;
    final n = rows.length;
    setState(() => _count = n);
    // Sayaç 0 → animasyon dur (CPU); >0 → yanıp sön
    if (n > 0) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink(); // hiç yoksa gizli

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // 0.55 → 1.0 arası opaklık pulse
        final op = 0.55 + 0.45 * _pulse.value;
        return Opacity(opacity: op, child: child);
      },
      child: Tooltip(
        message: '$_count fiş çıkmadı — görüntüle',
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(size: const Size(24, 24), painter: _AlertPainter(widget.color)),
                Positioned(
                  right: -6, top: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      '$_count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Üçgen ünlem ikonu (pro SVG hissi, CustomPaint) — failed_print_modal ile aynı stil.
class _AlertPainter extends CustomPainter {
  final Color color;
  _AlertPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.12)
      ..lineTo(w * 0.92, h * 0.85)
      ..lineTo(w * 0.08, h * 0.85)
      ..close();
    canvas.drawPath(path, p);
    canvas.drawLine(Offset(w * 0.5, h * 0.40), Offset(w * 0.5, h * 0.62), p);
    canvas.drawCircle(Offset(w * 0.5, h * 0.74), 1.3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _AlertPainter old) => old.color != color;
}
