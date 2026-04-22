import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../widgets/order_tracking/item_card.dart';
import '../widgets/order_tracking/table_sidebar.dart';

/// MASA TAKIP ekranı:
///  - Sol sidebar: açık adisyon olan masalar + pending count badge
///  - Sağ üst (%65): bekleyen ürünler (büyük kart, çift tıkla teslim işaretle)
///  - Sağ alt (%35): teslim edilen ürünler (kompakt kart, çift tıkla geri al)
///  - 2 sn'de bir polling + optimistic update + self-heal
class OrderTrackingScreen extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> waiter;

  const OrderTrackingScreen({
    super.key,
    required this.apiService,
    required this.waiter,
  });

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  Timer? _refreshTimer;
  List<dynamic> _raw = [];
  Map<int, TableBundle> _byTable = {};
  int? _selectedTableId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // 2 saniye — başka cihazda/ekranda yeni masa açılınca hızlı yakalamak için
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _isLoading = true);
    final rows = await widget.apiService.getPendingOrders();
    if (!mounted) return;
    setState(() {
      _raw = rows;
      _byTable = _group(rows);
      // Seçili masa listede yoksa reset (ticket kapandı/void edildi)
      if (_selectedTableId != null && !_byTable.containsKey(_selectedTableId)) {
        _selectedTableId = _byTable.keys.isEmpty ? null : _byTable.keys.first;
      }
      _selectedTableId ??= _byTable.keys.isEmpty ? null : _byTable.keys.first;
      _isLoading = false;
    });
  }

  Map<int, TableBundle> _group(List<dynamic> rows) {
    final m = <int, TableBundle>{};
    for (final r in rows) {
      final tidRaw = r['table_id'];
      final tid = tidRaw is int ? tidRaw : int.tryParse(tidRaw?.toString() ?? '');
      if (tid == null) continue;
      m.putIfAbsent(
        tid,
        () => TableBundle(
          tableId: tid,
          tableNumber: r['table_number']?.toString() ?? '?',
          sectionName: r['section_name']?.toString() ?? '',
        ),
      );
      final item = Map<String, dynamic>.from(r as Map);
      if (item['delivered_at'] == null) {
        m[tid]!.pending.add(item);
      } else {
        m[tid]!.delivered.add(item);
      }
    }
    return m;
  }

  Future<void> _toggle(Map<String, dynamic> item) async {
    final wasDelivered = item['delivered_at'] != null;
    // Optimistic update
    setState(() {
      item['delivered_at'] =
          wasDelivered ? null : DateTime.now().toIso8601String();
      _byTable = _group(_raw);
    });

    final ticketId = _extractInt(item['ticket_id']);
    final itemId = _extractInt(item['item_id']);
    if (ticketId == null || itemId == null) return;

    final result = await widget.apiService.markItemAsServed(
      ticketId: ticketId,
      itemId: itemId,
      waiterId: _extractInt(widget.waiter['id']),
    );

    if (!mounted) return;
    if (result['success'] != true) {
      // Rollback
      setState(() {
        item['delivered_at'] =
            wasDelivered ? DateTime.now().toIso8601String() : null;
        _byTable = _group(_raw);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error']?.toString() ?? 'Islem basarisiz'),
          backgroundColor: Colors.red[700],
        ),
      );
    }
  }

  int? _extractInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);
    // Sidebar'da sadece bekleyeni OLAN masalar gorunur
    // Seçili masa artık bekleyeni yoksa seçimden düşer (build sirasinda addPostFrameCallback ile state temizle)
    final bundles = _byTable.values.where((b) => b.pending.isNotEmpty).toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.tableNumber) ?? 0;
        final bi = int.tryParse(b.tableNumber) ?? 0;
        return ai.compareTo(bi);
      });

    // Seçili masanın pending'i tükendiyse bir sonraki masaya geç (post-frame ile)
    if (_selectedTableId != null) {
      final sel = _byTable[_selectedTableId!];
      if (sel == null || sel.pending.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selectedTableId = bundles.isEmpty ? null : bundles.first.tableId;
          });
        });
      }
    }

    final totalPending =
        bundles.fold<int>(0, (sum, b) => sum + b.pending.length);

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text(
            'MASA TAKİP',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber[700],
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              'Bekleyen: $totalPending',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ]),
        backgroundColor: theme.primaryColor,
        foregroundColor: Colors.white,
      ),
      body: _isLoading && _raw.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : bundles.isEmpty
              ? const Center(
                  child: Text(
                    'Acik adisyon yok',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                )
              : Row(children: [
                  SizedBox(
                    width: 280,
                    child: TableSidebar(
                      bundles: bundles,
                      selectedTableId: _selectedTableId,
                      onSelect: (id) =>
                          setState(() => _selectedTableId = id),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _selectedTableId == null
                        ? const Center(
                            child: Text(
                              'Masa seciniz',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        : _TableDetailView(
                            bundle: _byTable[_selectedTableId]!,
                            onToggle: _toggle,
                          ),
                  ),
                ]),
    );
  }
}

class _TableDetailView extends StatelessWidget {
  final TableBundle bundle;
  final Future<void> Function(Map<String, dynamic>) onToggle;

  const _TableDetailView({required this.bundle, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Başlık
      Container(
        padding: const EdgeInsets.all(16),
        width: double.infinity,
        color: Colors.grey[50],
        child: Row(children: [
          Text(
            'Masa ${bundle.tableNumber}',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          if (bundle.sectionName.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(
              '(${bundle.sectionName})',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ]),
      ),
      // BEKLEYEN (%65)
      Expanded(
        flex: 65,
        child: Container(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.schedule, size: 18, color: Colors.orange[900]),
                const SizedBox(width: 6),
                Text(
                  'BEKLEYEN (${bundle.pending.length})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange[900],
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: bundle.pending.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 48, color: Colors.green[300]),
                            const SizedBox(height: 8),
                            const Text(
                              'Tum urunler teslim edildi',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: bundle.pending.length,
                        itemBuilder: (_, i) => ItemCard(
                          item: bundle.pending[i],
                          isDelivered: false,
                          onTap: () => onToggle(bundle.pending[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      // Ayırıcı
      Container(height: 2, color: Colors.grey[300]),
      // TESLİM EDİLEN (%35)
      Expanded(
        flex: 35,
        child: Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey[50],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.check_circle, size: 18, color: Colors.green[800]),
                const SizedBox(width: 6),
                Text(
                  'TESLİM EDİLEN (${bundle.delivered.length})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.green[800],
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: bundle.delivered.isEmpty
                    ? const Center(
                        child: Text(
                          'Henuz teslim edilen yok',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        itemCount: bundle.delivered.length,
                        itemBuilder: (_, i) => ItemCard(
                          item: bundle.delivered[i],
                          isDelivered: true,
                          compact: true,
                          onTap: () => onToggle(bundle.delivered[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }
}
