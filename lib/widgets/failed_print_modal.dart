import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/printer_service.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/log_service.dart';
import '../services/failed_prints_notifier.dart';
import '../providers/theme_provider.dart';

/// 24 Tem 2026 — ÇIKMAYAN FİŞ pop-up'ı (retry 5/5 tükenmiş mutfak fişleri).
/// Badge'e tıklayınca VE (toggle açıksa) yeni bir fiş çıkmayınca otomatik açılır.
/// Kaynak: LocalDbService.getFailedKitchenPrints (fişi giren kasanın lokal print_queue'su).
///
/// Fable kararları:
/// - "Tekrar Yazdır" = TEK deneme, doğrudan printKitchenReceiptToIp (C3: resetPrintJob YASAK,
///   yoksa 5sn background timer'la yarışıp çift fiş). Job-id in-flight kilit (çift-dokunuş).
/// - Başarılı → failed row'u resolved (C2) + sunucuya reportPrintFailed'ı geri almaya gerek yok
///   (job zaten failed'dı, şimdi bastı → Faz2 rapor ile printed olur), listeden düş.
/// - Başarısız → satır KALIR + "hâlâ ulaşılamıyor, yazıcıyı kontrol edin" (H1: log spam yok,
///   printer_service dedup zaten var). Garson yazıcıyı düzeltir VEYA fişi elle götürür.
/// - Parçalı-basım uyarısı (M3): "kısmen çıkmış olabilir, mutfağı kontrol edin".
/// - CANLI liste (M1): failedKitchenPrintsChanged dinler, snapshot değil.
class FailedPrintModal extends StatefulWidget {
  final PrinterService printerService;
  final ApiService apiService;

  const FailedPrintModal({
    super.key,
    required this.printerService,
    required this.apiService,
  });

  /// Aç (badge tıklama veya otomatik). Zaten açıksa tekrar açmaz (route guard).
  static Future<void> show(BuildContext context,
      {required PrinterService printerService, required ApiService apiService}) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => FailedPrintModal(printerService: printerService, apiService: apiService),
    );
  }

  @override
  State<FailedPrintModal> createState() => _FailedPrintModalState();
}

class _FailedPrintModalState extends State<FailedPrintModal> {
  List<Map<String, dynamic>> _rows = [];
  final Set<int> _inFlight = {}; // job id -> tekrar-yazdır sürüyor (çift-dokunuş kilidi)
  final Map<int, String> _rowError = {}; // job id -> son deneme sonucu mesajı
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // CANLI: yeni fiş çıkmayınca / bir satır çözülünce liste yenilensin
    failedKitchenPrintsChanged.addListener(_onChanged);
  }

  @override
  void dispose() {
    failedKitchenPrintsChanged.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final rows = await LocalDbService().getFailedKitchenPrints();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
    // Liste boşaldıysa modalı kapat
    if (rows.isEmpty && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  /// Tekrar Yazdır — TEK deneme, doğrudan gönderim (Fable C3: reset YOK).
  Future<void> _retry(Map<String, dynamic> row) async {
    final id = row['id'] as int?;
    if (id == null || _inFlight.contains(id)) return;
    final ip = row['printer_ip'] as String?;
    if (ip == null || ip.isEmpty) {
      setState(() => _rowError[id] = 'Yazıcı adresi yok');
      return;
    }
    final port = (row['printer_port'] as int?) ?? 9100;

    // 24 Agu 2026 (P2): ESKİ/geç reprint uyarısı. Fiş girişi 60 dk'dan eskiyse (servis anı
    // geçmiş, adisyon kapanmış olabilir — masa 37 / 19:10 vakası) onay sor ki mutfak taze
    // sipariş sanmasın. ts_iso = giriş/son-deneme anı. Parse edilemezse uyarı yok (bugünkü).
    final girisDt = DateTime.tryParse((row['ts_iso'] ?? '').toString());
    if (girisDt != null && DateTime.now().difference(girisDt).inMinutes >= 60) {
      final dk = DateTime.now().difference(girisDt).inMinutes;
      final yasStr = dk >= 120 ? '${(dk / 60).floor()} saat' : '$dk dakika';
      if (!mounted) return;
      final onay = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Eski fiş — emin misiniz?'),
          content: Text(
              'Bu siparişin fişi yaklaşık $yasStr önce girilmişti (${row['at'] ?? ''}). '
              'Sipariş çoktan hazırlanmış veya adisyon kapanmış olabilir; mutfağa YENİ sipariş '
              'gibi gidecek. Yine de yazdırılsın mı?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yine de bas')),
          ],
        ),
      );
      if (onay != true) return; // vazgeçildi — basma
      if (!mounted) return; // dialog sırasında modal kapanmış olabilir (setState guard)
    }

    // receipt_data'dan basma verisi çöz. İKİ format: 'kitchen' → {ticket, items} (garson direkt);
    // 'kitchen_order' → {order, department} (online Web POS mutfak fişi). Doğru basma yolu seçilir.
    Map<String, dynamic>? ticket;
    List<dynamic> items = const [];
    Map<String, dynamic>? order;
    String orderDepartment = 'MUTFAK';
    final raw = row['receipt_data'];
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final t = decoded['ticket'];
          if (t is Map) ticket = Map<String, dynamic>.from(t);
          final its = decoded['items'];
          if (its is List) items = its;
          final o = decoded['order'];
          if (o is Map) order = Map<String, dynamic>.from(o);
          final dep = decoded['department'];
          if (dep is String && dep.isNotEmpty) orderDepartment = dep;
        }
      } catch (_) {}
    }
    // Ne ticket-formatı ne order-formatı çözülebildiyse basılamaz
    if ((ticket == null || items.isEmpty) && order == null) {
      setState(() => _rowError[id] = 'Fiş verisi okunamadı');
      return;
    }

    setState(() {
      _inFlight.add(id);
      _rowError.remove(id);
    });

    bool ok = false;
    try {
      if (ticket != null && items.isNotEmpty) {
        // 'kitchen' formatı — mutfak fişi doğrudan
        ok = await widget.printerService.printKitchenReceiptToIp(
          ticket: ticket, items: items, ip: ip, port: port);
      } else if (order != null) {
        // 'kitchen_order' formatı — online sipariş mutfak fişi, order-formatında bas.
        // enqueueOnFail:false (Fable D) → tekrar fail olursa MÜKERRER kuyruk satırı EKLEMEZ
        // (fiş zaten kuyrukta failed; başarısızsa mevcut satır kalır, çift bildirim olmaz).
        ok = await widget.printerService.printOrderReceipt(
          order, orderDepartment,
          targetPrinter: {'ip': ip, 'port': port, 'name': row['printer_name']},
          enqueueOnFail: false);
      }
    } catch (e) {
      ok = false;
    }

    if (!mounted) return;
    if (ok) {
      // BAŞARILI: failed row'u çözüldü işaretle (C2), Faz2 rapor server_job_id varsa printed yapar
      await LocalDbService().markFailedKitchenPrintResolved(id);
      final serverTicketId = row['server_ticket_id'];
      final serverJobId = row['server_job_id'];
      if (serverTicketId is int && serverJobId is int) {
        widget.apiService.markItemsPrinted(
          ticketId: serverTicketId, itemIds: const [], jobIds: [serverJobId],
        ).catchError((_) => false);
      }
      LogService().logAction('Cikmayan fis MANUEL tekrar yazdirma BASARILI',
          details: {'queue_id': id, 'table': row['table'], 'printer': row['printer_name']});
      setState(() {
        _inFlight.remove(id);
        _rowError.remove(id);
      });
      failedKitchenPrintsChanged.value = failedKitchenPrintsChanged.value + 1; // badge + liste yenile
      await _load();
    } else {
      // BAŞARISIZ: satır KALIR, uyarı göster (log spam yok — printer_service dedup zaten var)
      LogService().warning(LogType.error, 'Cikmayan fis MANUEL tekrar yazdirma yine BASARISIZ',
          details: {'queue_id': id, 'table': row['table'], 'printer': row['printer_name']});
      setState(() {
        _inFlight.remove(id);
        _rowError[id] = 'Hâlâ ulaşılamıyor — yazıcıyı kontrol edin';
      });
    }
  }

  /// Sil (manuel dismiss) — garson fişi elle götürdü/hallettiyse.
  Future<void> _dismiss(Map<String, dynamic> row) async {
    final id = row['id'] as int?;
    if (id == null) return;
    await LocalDbService().deleteFailedKitchenPrint(id);
    LogService().logAction('Cikmayan fis bildirimi silindi (manuel)',
        details: {'queue_id': id, 'table': row['table']});
    failedKitchenPrintsChanged.value = failedKitchenPrintsChanged.value + 1;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    final primary = theme.primaryColor;
    const danger = Color(0xFFDC2626); // "hiç çıkmadı" yerleşik kırmızı (tema değil, anlam sabit)

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(danger),
            const Divider(height: 1),
            _buildPartialWarning(),
            Flexible(
              child: _loading
                  ? const Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? _buildEmpty(primary)
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(16),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (_, i) => _buildRow(_rows[i], primary, danger),
                        ),
            ),
            const Divider(height: 1),
            _buildFooter(primary),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color danger) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
      child: Row(
        children: [
          _svgAlert(danger, 26),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Çıkmayan Fişler',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(height: 2),
                Text('Yazıcı denemeleri tükendi — bu fişler basılamadı',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B))),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildPartialWarning() {
    // Fable M3: parçalı basım uyarısı
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF7ED),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: const Text(
        'Not: Bu fişler kısmen çıkmış olabilir. Tekrar yazdırmadan önce mutfağı kontrol edin '
        '(çift fiş olmasın).',
        style: TextStyle(fontSize: 12, color: Color(0xFF9A3412), height: 1.35),
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> row, Color primary, Color danger) {
    final id = row['id'] as int?;
    final busy = id != null && _inFlight.contains(id);
    final err = id != null ? _rowError[id] : null;
    final items = (row['items'] as List?)?.cast<String>() ?? const [];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Masa + yazıcı + saat
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('Masa ${row['table'] ?? '-'}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: primary, fontSize: 14)),
              ),
              const SizedBox(width: 10),
              _svgPrinter(const Color(0xFF64748B), 15),
              const SizedBox(width: 4),
              Text('${row['printer_name'] ?? '-'}',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B))),
              const Spacer(),
              Text('${row['at'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            ],
          ),
          const SizedBox(height: 10),
          // Çıkmayan ürünler
          if (items.isNotEmpty)
            ...items.map((it) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [
                    const Text('• ', style: TextStyle(color: Color(0xFF475569))),
                    Expanded(child: Text(it, style: const TextStyle(fontSize: 13.5))),
                  ]),
                ))
          else
            const Text('(ürün bilgisi yok)',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), fontStyle: FontStyle.italic)),
          if (err != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.error_outline, size: 15, color: danger),
              const SizedBox(width: 5),
              Expanded(child: Text(err, style: TextStyle(fontSize: 12.5, color: danger))),
            ]),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy ? null : () => _retry(row),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  ),
                  icon: busy
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : _svgPrinter(Colors.white, 17),
                  label: Text(busy ? 'Deneniyor…' : 'Tekrar Yazdır'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: busy ? null : () => _dismiss(row),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF64748B),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
                child: _svgTrash(const Color(0xFF64748B), 17),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(Color primary) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _svgCheck(primary, 40),
        const SizedBox(height: 12),
        const Text('Çıkmayan fiş yok', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('Tüm fişler başarıyla yazdırıldı.',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8))),
      ]),
    );
  }

  Widget _buildFooter(Color primary) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(foregroundColor: primary),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  // --- Pro SVG ikonlar (emoji YASAK — feedback_design_svg_only) ---
  Widget _svgAlert(Color c, double s) => SizedBox(
        width: s, height: s,
        child: CustomPaint(painter: _AlertPainter(c)),
      );
  Widget _svgPrinter(Color c, double s) => Icon(Icons.print_outlined, size: s, color: c);
  Widget _svgTrash(Color c, double s) => Icon(Icons.delete_outline, size: s, color: c);
  Widget _svgCheck(Color c, double s) => Icon(Icons.check_circle_outline, size: s, color: c);
}

/// Üçgen ünlem (pro, tema-nötr kırmızı) — CustomPaint ile keskin SVG hissi.
class _AlertPainter extends CustomPainter {
  final Color color;
  _AlertPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.10)
      ..lineTo(w * 0.94, h * 0.86)
      ..lineTo(w * 0.06, h * 0.86)
      ..close();
    canvas.drawPath(path, p);
    // ünlem çizgisi + nokta
    canvas.drawLine(Offset(w * 0.5, h * 0.38), Offset(w * 0.5, h * 0.62), p);
    canvas.drawCircle(Offset(w * 0.5, h * 0.74), 1.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _AlertPainter old) => old.color != color;
}
