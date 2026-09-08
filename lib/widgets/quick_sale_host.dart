// 8 Eyl 2026 — HIZLI SATIŞ kabuğu.
//
// Mustafa: "bildiğimiz masa açma gibi olacak ama ödeme alındığında ekran KAPANMAYACAK".
// Bu widget tek bir showDialog içinde yaşar; AddItemModal'ı quickSale modunda gösterir.
// Ödeme/iptal/taşıma bitince (onTicketDone) AYNI gizli masada YENİ adisyon açar ve
// AddItemModal'ı yeni key ile yeniden kurar — dialog kapanmaz, sadece içerik değişir.
// Tek çıkış: AddItemModal'ın X (onClose) → onExit.
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/quick_sale_flow.dart';
import 'add_item_modal.dart';

class QuickSaleHost extends StatefulWidget {
  final ApiService apiService;
  final PrinterService? printerService;
  final Map<String, dynamic> waiter;
  final Map<String, dynamic> section;
  final Map<String, dynamic> table;
  final bool showProductImages;
  final int initialTicketId;
  final QuickSaleFlow flow;
  final VoidCallback onExit;

  const QuickSaleHost({
    super.key,
    required this.apiService,
    required this.printerService,
    required this.waiter,
    required this.section,
    required this.table,
    required this.showProductImages,
    required this.initialTicketId,
    required this.flow,
    required this.onExit,
  });

  @override
  State<QuickSaleHost> createState() => _QuickSaleHostState();
}

class _QuickSaleHostState extends State<QuickSaleHost> {
  int? _ticketId;
  bool _loading = false;
  String? _error;
  int _satisSayisi = 0; // bu oturumda tamamlanan hızlı satış adedi (bilgi)

  @override
  void initState() {
    super.initState();
    _ticketId = widget.initialTicketId;
  }

  int get _waiterId => (widget.waiter['id'] as num).toInt();

  /// Adisyon bitti (paid/void/transfer) → aynı masada yeni adisyon.
  Future<void> _onTicketDone(String reason) async {
    if (!mounted) return;
    if (reason == 'paid') _satisSayisi++;
    setState(() {
      _ticketId = null;
      _loading = true;
      _error = null;
    });
    await _yeniAdisyon();
  }

  Future<void> _yeniAdisyon() async {
    try {
      final r = await widget.flow.hazirla(table: widget.table, waiterId: _waiterId, resume: false);
      if (!mounted) return;
      if (r.ok) {
        setState(() {
          _ticketId = r.ticketId;
          _loading = false;
          _error = null;
        });
      } else {
        setState(() {
          _loading = false;
          _error = _hataMetni(r);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Yeni adisyon açılamadı: $e';
      });
    }
  }

  String _hataMetni(QuickSaleOpenResult r) {
    switch (r.kind) {
      case 'already_open':
        return 'Bu hızlı satış salonunda başka bir kasadan açılmış adisyon var. Her kasa için ayrı hızlı satış salonu kullanın.';
      case 'lan_denied':
        return 'Bu masa başka kasada açık (LAN).';
      case 'other_device':
        return 'Adisyon ${r.deviceName ?? "başka"} kasasında açık.';
      default:
        return r.error ?? 'Yeni adisyon açılamadı';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tid = _ticketId;
    if (tid != null) {
      return AddItemModal(
        key: ValueKey<int>(tid),
        apiService: widget.apiService,
        printerService: widget.printerService,
        ticketId: tid,
        waiterId: _waiterId,
        tableId: (widget.table['id'] as num).toInt(),
        table: widget.table,
        waiter: widget.waiter,
        section: widget.section,
        showProductImages: widget.showProductImages,
        quickSale: true,
        onTicketDone: _onTicketDone,
        onItemAdded: () {},
        onClose: widget.onExit,
      );
    }

    // Geçiş durumu: yeni adisyon açılıyor / hata.
    return Dialog(
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bolt, color: Color(0xFFF59E0B), size: 28),
                const SizedBox(width: 8),
                Text('HIZLI SATIŞ — ${widget.section['name'] ?? ''}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 18),
            if (_loading) ...[
              const CircularProgressIndicator(color: Color(0xFFF59E0B)),
              const SizedBox(height: 14),
              Text(
                _satisSayisi > 0 ? 'Satış tamamlandı ($_satisSayisi). Yeni adisyon açılıyor…' : 'Yeni adisyon açılıyor…',
                style: const TextStyle(fontSize: 16),
              ),
            ] else ...[
              Icon(Icons.warning_amber_rounded, color: Colors.orange[700], size: 40),
              const SizedBox(height: 10),
              SizedBox(
                width: 420,
                child: Text(_error ?? 'Adisyon açılamadı',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 150,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: widget.onExit,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
                      child: const Text('Çık', style: TextStyle(fontSize: 17)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _error = null;
                        });
                        _yeniAdisyon();
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.white),
                      child: const Text('Tekrar Dene', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
