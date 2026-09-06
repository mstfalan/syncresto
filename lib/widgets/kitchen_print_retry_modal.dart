import 'dart:async';
import 'package:flutter/material.dart';
import '../services/printer_service.dart';
import '../services/api_service.dart';
import '../services/log_service.dart';
import '../services/print_queue_reprint_decision.dart'; // 6 Eyl 2026: kuyruk×popup yarisi

/// 18 May 2026: Mutfak fisi yazici hatasi pop-up.
/// Backend printKitchen zaten printed=1 SET etti — bu modal SADECE TCP retry yapar
/// (mukerrer fis riski yok). Basarisiz print_job'lar listelenir; "Tekrar Yazdir"
/// her bir grup icin _printerService.printKitchenReceiptToIp + markItemsPrinted
/// telemetri update'i yapar. Tum gruplar gidince modal otomatik kapanir.
class KitchenPrintRetryModal extends StatefulWidget {
  final PrinterService printerService;
  final ApiService apiService;
  final int ticketId;
  final Map<String, dynamic> ticketInfo;
  /// Her bir failed group: { printer_ip, printer_port, printer_name, items, job_id }
  final List<Map<String, dynamic>> failedGroups;

  const KitchenPrintRetryModal({
    super.key,
    required this.printerService,
    required this.apiService,
    required this.ticketId,
    required this.ticketInfo,
    required this.failedGroups,
  });

  @override
  State<KitchenPrintRetryModal> createState() => _KitchenPrintRetryModalState();
}

class _KitchenPrintRetryModalState extends State<KitchenPrintRetryModal> {
  late List<Map<String, dynamic>> _groups;
  final Map<int, bool> _retrying = {};
  final Map<int, String?> _lastError = {};
  final Map<int, int> _retryAttempts = {}; // her grup icin kac kez denendi
  bool _retryingAll = false;
  bool _showPrinterCheckHint = false; // 2+ fail sonrasi yazici kontrol uyarisi

  StreamSubscription<int>? _queueSub;

  @override
  void initState() {
    super.initState();
    _groups = List<Map<String, dynamic>>.from(widget.failedGroups);
    // 6 Eyl 2026: arka plan PrintQueueService bu satırlardan birini basarsa satırı düşür
    // (kullanıcı ikinci kez basmasın). Kendi manuel basımımız _retrying guard'ıyla ayrılır.
    _queueSub = widget.printerService.queueJobCompleted.listen(_onQueueJobCompleted);
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    super.dispose();
  }

  void _onQueueJobCompleted(int queueId) {
    if (!mounted) return;
    final idx = _groups.indexWhere((g) => g['queue_job_id'] == queueId);
    if (idx < 0) return;
    if (_retrying[idx] == true) return; // bu satırı şu an biz basıyoruz → _retryGroup halleder
    _dropAlreadyPrinted(_groups[idx], queueId, source: 'arka plan kuyruk');
  }

  /// Satırı KİMLİĞİYLE (Map örneği) kaldır ve indeks-anahtarlı bayrak haritalarını kaydır.
  /// (Fable K-2, 6 Eyl 2026): eşzamanlı silme indeksleri kaydırır; kaydırmazsak yanlış satıra
  /// "basılıyor"/"hata" yazılır. setState çağıranın sorumluluğu DEĞİL — burada yapılır.
  void _removeGroup(Map<String, dynamic> g) {
    final i = _groups.indexOf(g);
    if (i < 0) return;
    Map<int, T> shift<T>(Map<int, T> m) {
      final out = <int, T>{};
      m.forEach((k, v) {
        if (k < i) {
          out[k] = v;
        } else if (k > i) {
          out[k - 1] = v;
        }
      });
      return out;
    }
    final r = shift(_retrying);
    final e = shift(_lastError);
    final a = shift(_retryAttempts);
    setState(() {
      _groups.removeAt(i);
      _retrying
        ..clear()
        ..addAll(r);
      _lastError
        ..clear()
        ..addAll(e);
      _retryAttempts
        ..clear()
        ..addAll(a);
    });
  }

  /// Kuyruk (arka plan) zaten bastı → satırı düşür, TEKRAR BASMA. Tüm satırlar bitince modal kapanır.
  void _dropAlreadyPrinted(Map<String, dynamic> g, int queueId, {required String source}) {
    if (!mounted || !_groups.contains(g)) return;
    final printerName = g['printer_name'] as String? ?? 'Yazici';
    LogService().logAction(
      'Mutfak fisi pop-up: $source zaten basti, tekrar BASILMADI: $printerName',
      details: {'ticket_id': widget.ticketId, 'queue_job_id': queueId, 'job_id': g['job_id']},
    );
    _removeGroup(g);
    try {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('$printerName: fiş arka planda zaten basıldı, tekrar basılmadı.'),
        duration: const Duration(seconds: 4),
      ));
    } catch (_) {}
    if (_groups.isEmpty && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// Satır kimliği = Map örneği (g). Her await sonrası indeks g'den YENİDEN bulunur (Fable K-2):
  /// arka plan kuyruk yayını bu arada daha düşük indeksli bir satırı silmiş olabilir.
  Future<bool> _retryGroup(int startIdx) async {
    if (startIdx < 0 || startIdx >= _groups.length) return false;
    final g = _groups[startIdx];
    int idx() => _groups.indexOf(g);
    final ip = g['printer_ip'] as String?;
    final port = (g['printer_port'] as int?) ?? 9100;
    final items = (g['items'] as List?) ?? [];
    final jobId = g['job_id'] as int?;
    final printerName = g['printer_name'] as String? ?? 'Yazici';

    if (ip == null || ip.isEmpty || items.isEmpty) {
      setState(() => _lastError[startIdx] = 'Yazici IP veya urun bilgisi eksik');
      return false;
    }

    void setErr(String msg) {
      final i = idx();
      if (mounted && i >= 0) setState(() => _lastError[i] = msg);
    }

    // 6 Eyl 2026 — KUYRUK×POPUP YARIŞI (Green Chef çift fiş): arka plan PrintQueueService aynı işi
    // 5 sn'de bir zaten deniyor. Basmadan ÖNCE kuyruk durumuna bak; 'completed' ise TEKRAR BASMA,
    // 'printing' ise bekle, 'pending' ise işi ATOMİK sahiplen (arka plan artık dokunamaz).
    final queueJobId = g['queue_job_id'] as int?;
    bool claimedHere = false;
    if (queueJobId != null) {
      var action = PrintQueueReprintDecision.decide(await widget.printerService.getQueueJobStatus(queueJobId));
      if (!mounted) return false;
      if (idx() < 0) return true; // satır bu arada düştü (arka plan bastı)
      if (action == ManualReprintAction.waitInProgress) {
        setErr('Arka plan şu an basıyor, bekleyin…');
        await Future.delayed(const Duration(seconds: 3));
        if (!mounted) return false;
        if (idx() < 0) return true;
        action = PrintQueueReprintDecision.decide(await widget.printerService.getQueueJobStatus(queueJobId));
        if (!mounted) return false;
        if (idx() < 0) return true;
        if (action == ManualReprintAction.waitInProgress) {
          setErr('Arka plan hâlâ basıyor; birkaç saniye sonra tekrar deneyin');
          return false;
        }
      }
      if (action == ManualReprintAction.skipAlreadyPrinted) {
        _dropAlreadyPrinted(g, queueJobId, source: 'arka plan kuyruk');
        return true;
      }
      if (action == ManualReprintAction.printWithClaim) {
        claimedHere = await widget.printerService.claimQueueJobForManual(queueJobId);
        if (!mounted) {
          if (claimedHere) await widget.printerService.releaseQueueJobClaim(queueJobId);
          return false;
        }
        if (idx() < 0) {
          if (claimedHere) await widget.printerService.releaseQueueJobClaim(queueJobId);
          return true;
        }
        if (!claimedHere) {
          // pending'den başka duruma geçti (arka plan kaptı ya da bitirdi) → yeniden değerlendir
          final st = await widget.printerService.getQueueJobStatus(queueJobId);
          if (!mounted) return false;
          if (idx() < 0) return true;
          if (st == 'completed') {
            _dropAlreadyPrinted(g, queueJobId, source: 'arka plan kuyruk');
            return true;
          }
          if (st == 'printing') {
            setErr('Arka plan şu an basıyor, bekleyin…');
            return false;
          }
          // 'failed'/null → arka plan dokunmaz, manuel devam (claim'siz)
        }
      }
      // printWithoutClaim ('failed' tükenmiş / kayıt yok) → claim gerekmez, eski davranış
    }

    {
      final i = idx();
      if (i < 0) {
        if (claimedHere && queueJobId != null) await widget.printerService.releaseQueueJobClaim(queueJobId);
        return true;
      }
      setState(() {
        _retrying[i] = true;
        _lastError[i] = null;
        _retryAttempts[i] = (_retryAttempts[i] ?? 0) + 1;
      });
    }

    final ok = await widget.printerService.printKitchenReceiptToIp(
      ticket: widget.ticketInfo,
      items: items,
      ip: ip,
      port: port,
    );

    if (ok) {
      // Telemetri: job_id artik basili — backend'e bildir.
      if (jobId != null) {
        widget.apiService.markItemsPrinted(
          ticketId: widget.ticketId,
          itemIds: const [],
          jobIds: [jobId],
        ).catchError((_) => false);
      }
      // 18 May 2026: Sag ust badge'deki kuyruktan da dus — yoksa PrintQueueService
      // arka planda ayni isi tekrar yazdirir (cift TCP retransmit). (6 Eyl: claim zaten 'printing'
      // yaptı; completed'a çevirir ve popup dinleyicisine yayınlar — _retrying guard'ı bizi atlar.)
      if (queueJobId != null) {
        await widget.printerService.markQueueJobCompleted(queueJobId);
      }
      LogService().logAction(
        'Mutfak fisi pop-up tekrar yazdirma BASARILI: $printerName',
        details: {'ticket_id': widget.ticketId, 'job_id': jobId, 'queue_job_id': queueJobId, 'items': items.length},
      );
      if (!mounted) return true;
      _removeGroup(g);
      // Kalan grup yoksa modal kapansin
      if (_groups.isEmpty && mounted) {
        Navigator.of(context).pop(true);
      }
      return true;
    } else {
      // 6 Eyl 2026: manuel basım başarısız → sahiplendiysek bırak, arka plan kuyruğu denemeye devam etsin.
      if (claimedHere && queueJobId != null) {
        await widget.printerService.releaseQueueJobClaim(queueJobId);
      }
      if (!mounted) return false;
      final i = idx();
      if (i < 0) return false;
      setState(() {
        _retrying[i] = false;
        _lastError[i] = 'Yaziciya ulasilamadi';
        // 2 veya daha fazla deneme sonrasi hala fail ise yazici kontrol uyarisi goster
        if ((_retryAttempts[i] ?? 0) >= 2) {
          _showPrinterCheckHint = true;
        }
      });
      LogService().warning(
        LogType.error,
        'Mutfak fisi pop-up tekrar yazdirma BASARISIZ: $printerName',
        details: {'ticket_id': widget.ticketId, 'job_id': jobId, 'attempt': _retryAttempts[i]},
      );
      return false;
    }
  }

  Future<void> _retryAll() async {
    if (_retryingAll) return;
    setState(() => _retryingAll = true);
    // Index sapmasi olmasin: hep ilk eleman icin dene (basarili olunca silinir, sira ilerler)
    final initialCount = _groups.length;
    for (int n = 0; n < initialCount; n++) {
      if (_groups.isEmpty) break;
      await _retryGroup(0);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) setState(() => _retryingAll = false);
  }

  String _itemsSummary(List items) {
    if (items.isEmpty) return '-';
    final parts = items.take(3).map((it) {
      final qty = it['quantity'] ?? it['qty'] ?? 1;
      final name = it['product_name'] ?? it['name'] ?? '?';
      return '${qty}x $name';
    }).toList();
    if (items.length > 3) parts.add('+${items.length - 3} daha');
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final tableLabel = widget.ticketInfo['table_number']?.toString() ?? '-';
    return WillPopScope(
      onWillPop: () async => !_retryingAll,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Baslik
                Row(
                  children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.print_disabled, color: Color(0xFFDC2626), size: 26),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Yazici Hatasi',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Masa $tableLabel — ${_groups.length} fis yaziciya gitmedi',
                            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Uyari kutusu
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 18, color: Color(0xFFB45309)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Urunler mutfak sistemine kaydedildi (cift fis riski yok). '
                          'Arka planda her 5 saniyede otomatik tekrar denenir, '
                          'yukarida "Tekrar Yazdir" ile de elle deneyebilirsiniz.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF78350F), height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                // 18 May 2026: 2+ deneme sonrasi yazici kontrol uyarisi
                if (_showPrinterCheckHint) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 20, color: Color(0xFFB91C1C)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'YAZICIYI KONTROL EDIN',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF991B1B)),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '• Yazici acik mi? (ekranda yesil isik)\n'
                                '• Kagit bitti mi? (rulo takili mi)\n'
                                '• Kapak tam kapali mi?\n'
                                '• Ag kablosu (LAN) takili mi, ledler yaniyor mu?\n'
                                '• Ayni agda mi? (Yazici IP\'sine ping atilabilir mi)\n'
                                '• Yaziciyi kapatip 10 sn bekleyip tekrar acin.',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF7F1D1D), height: 1.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Liste
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final g = _groups[idx];
                      final printerName = g['printer_name'] as String? ?? 'Yazici';
                      final ip = g['printer_ip'] as String? ?? '-';
                      final items = (g['items'] as List?) ?? [];
                      final busy = _retrying[idx] == true;
                      final error = _lastError[idx];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF9FAFB),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.print, size: 16, color: Color(0xFF6B7280)),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              printerName,
                                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF3F4F6),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              ip,
                                              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontFamily: 'monospace'),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${items.length} urun: ${_itemsSummary(items)}',
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
                                      ),
                                      if (error != null) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Icon(Icons.error_outline, size: 14, color: Color(0xFFDC2626)),
                                            const SizedBox(width: 4),
                                            Text(
                                              error,
                                              style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton.icon(
                                    onPressed: busy || _retryingAll ? null : () => _retryGroup(idx),
                                    icon: busy
                                        ? const SizedBox(
                                            width: 14, height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                        : const Icon(Icons.refresh, size: 16),
                                    label: Text(busy ? '...' : 'Tekrar'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2563EB),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                // Alt butonlar
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _retryingAll ? null : () => Navigator.of(context).pop(false),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Kapat'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          foregroundColor: const Color(0xFF6B7280),
                          side: const BorderSide(color: Color(0xFFD1D5DB)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _retryingAll || _groups.isEmpty ? null : _retryAll,
                        icon: _retryingAll
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_retryingAll ? 'Yazdiriliyor...' : 'Tumunu Tekrar Yazdir (${_groups.length})'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
