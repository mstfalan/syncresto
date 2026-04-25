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
  String? _sectionFilter; // null = tum salonlar

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

    // Pending olan tum bundle'lar (sirali)
    final allBundlesWithPending =
        _byTable.values.where((b) => b.pending.isNotEmpty).toList()
          ..sort((a, b) {
            final ai = int.tryParse(a.tableNumber) ?? 0;
            final bi = int.tryParse(b.tableNumber) ?? 0;
            return ai.compareTo(bi);
          });

    // Salon listesi (alfabetik, ucu bos olanlar 'Diger' olarak)
    final sections = <String>{};
    for (final b in allBundlesWithPending) {
      sections.add(b.sectionName.isEmpty ? 'Diger' : b.sectionName);
    }
    final sectionList = sections.toList()..sort();

    // Filtreli bundle listesi
    final bundles = _sectionFilter == null
        ? allBundlesWithPending
        : allBundlesWithPending.where((b) {
            final sn = b.sectionName.isEmpty ? 'Diger' : b.sectionName;
            return sn == _sectionFilter;
          }).toList();

    // Seçili masa filtreli listede yoksa ilk masaya geç
    if (_selectedTableId != null) {
      final inFiltered =
          bundles.any((b) => b.tableId == _selectedTableId);
      if (!inFiltered) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selectedTableId = bundles.isEmpty ? null : bundles.first.tableId;
          });
        });
      }
    } else if (bundles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _selectedTableId = bundles.first.tableId);
      });
    }

    final totalPending = allBundlesWithPending.fold<int>(
        0, (sum, b) => sum + b.pending.length);

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
        toolbarHeight: 72,
        actions: [
          // TUM BEKLEYENLER - dokunmatik icin buyuk buton
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () => _showAllOrdersDialog(theme),
                icon: const Icon(Icons.list_alt, size: 28),
                label: const Text(
                  'TÜM BEKLEYENLER',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: theme.primaryColor,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading && _raw.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : allBundlesWithPending.isEmpty
              ? const Center(
                  child: Text(
                    'Acik adisyon yok',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                )
              : Row(children: [
                  // SOL: Salon filter + masalar
                  SizedBox(
                    width: 260,
                    child: Column(children: [
                      _buildSectionFilter(sectionList, theme),
                      const Divider(height: 1),
                      Expanded(
                        child: TableSidebar(
                          bundles: bundles,
                          selectedTableId: _selectedTableId,
                          onSelect: (id) =>
                              setState(() => _selectedTableId = id),
                        ),
                      ),
                    ]),
                  ),
                  const VerticalDivider(width: 1),
                  // ORTA + SAG: Secili masa detayi
                  Expanded(
                    child: _selectedTableId == null ||
                            !_byTable.containsKey(_selectedTableId)
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

  Widget _buildSectionFilter(List<String> sectionList, ThemeProvider theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: Colors.grey[50],
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _sectionChip('Tümü', _sectionFilter == null, theme,
              () => setState(() => _sectionFilter = null)),
          for (final s in sectionList)
            _sectionChip(s, _sectionFilter == s, theme,
                () => setState(() => _sectionFilter = s)),
        ],
      ),
    );
  }

  Widget _sectionChip(
      String label, bool selected, ThemeProvider theme, VoidCallback onTap) {
    return Material(
      color: selected ? theme.primaryColor : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? theme.primaryColor : Colors.grey[300]!,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.grey[800],
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  void _showAllOrdersDialog(ThemeProvider theme) {
    // Tum item'lari topla (pending + delivered), salon-masa-tarih sirasiyla
    final allItems = List<Map<String, dynamic>>.from(
      _raw.map((r) => Map<String, dynamic>.from(r as Map)),
    );
    // Sirala: salon, masa, urun olusturma tarihi
    allItems.sort((a, b) {
      final s = (a['section_name']?.toString() ?? '')
          .compareTo(b['section_name']?.toString() ?? '');
      if (s != 0) return s;
      final ta = int.tryParse(a['table_number']?.toString() ?? '') ?? 0;
      final tb = int.tryParse(b['table_number']?.toString() ?? '') ?? 0;
      if (ta != tb) return ta.compareTo(tb);
      final da = a['item_created_at']?.toString() ?? '';
      final db = b['item_created_at']?.toString() ?? '';
      return da.compareTo(db);
    });

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.9,
          height: MediaQuery.of(ctx).size.height * 0.9,
          child: Column(children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.primaryColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
              ),
              child: Row(children: [
                const Icon(Icons.list_alt, color: Colors.white, size: 24),
                const SizedBox(width: 10),
                const Text(
                  'TÜM SİPARİŞLER',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${allItems.length} kalem',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ]),
            ),
            // Tablo header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.grey[200],
              child: Row(children: const [
                SizedBox(width: 110, child: Text('SALON', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                SizedBox(width: 70, child: Text('MASA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                SizedBox(width: 90, child: Text('DURUM', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                SizedBox(width: 50, child: Text('ADET', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                Expanded(child: Text('ÜRÜN', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
              ]),
            ),
            // Liste
            Expanded(
              child: allItems.isEmpty
                  ? const Center(
                      child: Text('Hiç sipariş yok',
                          style: TextStyle(color: Colors.grey, fontSize: 16)))
                  : ListView.separated(
                      itemCount: allItems.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: Colors.grey[200]),
                      itemBuilder: (_, i) {
                        final it = allItems[i];
                        final isDelivered = it['delivered_at'] != null;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          color: isDelivered
                              ? const Color(0xFFF0FDF4)
                              : Colors.white,
                          child: Row(children: [
                            SizedBox(
                              width: 110,
                              child: Text(
                                it['section_name']?.toString() ?? '-',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            SizedBox(
                              width: 70,
                              child: Text(
                                'Masa ${it['table_number'] ?? '-'}',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: isDelivered
                                      ? Colors.green[100]
                                      : Colors.orange[100],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  isDelivered ? 'GİDEN' : 'BEKLİYOR',
                                  style: TextStyle(
                                    color: isDelivered
                                        ? Colors.green[800]
                                        : Colors.orange[900],
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 50,
                              child: Text(
                                '${it['quantity'] ?? 1}x',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                it['product_name']?.toString() ?? '',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
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
      // 2 sutun: ORTA = BEKLEYEN, SAG = TESLIM EDILEN
      Expanded(
        child: Row(children: [
          // BEKLEYEN sutunu
          Expanded(
            flex: 6,
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
          // Dikey ayirici
          Container(width: 2, color: Colors.grey[300]),
          // TESLIM EDILEN sutunu
          Expanded(
            flex: 4,
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
        ]),
      ),
    ]);
  }
}
