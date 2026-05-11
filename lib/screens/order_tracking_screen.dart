import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../widgets/order_tracking/item_card.dart';
import '../widgets/order_tracking/table_sidebar.dart';

/// MASA TAKIP ekranı:
///  - Sol sidebar: açık adisyon olan masalar + pending count badge
///  - Sağ üst (%65): bekleyen ürünler (büyük kart, çift tıkla teslim işaretle)
///  - Sağ alt (%35): teslim edilen ürünler (kompakt kart, çift tıkla geri al)
///  - 2 sn'de bir polling + optimistic update + self-heal
class OrderTrackingScreen extends StatefulWidget {
  final ApiService apiService;
  final StorageService storageService;
  final Map<String, dynamic> waiter;

  const OrderTrackingScreen({
    super.key,
    required this.apiService,
    required this.storageService,
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
  // Sidebar siralama (kalici tercih StorageService'te). Default: 'time_asc' (en eski bekleyen ustte = en acil)
  // Degerler: 'time_asc', 'time_desc', 'table_asc', 'table_desc'
  String _sortMode = 'time_asc';

  // Toggle sirasinda polling pause + ust uste fetch onleme.
  bool _isFetching = false;
  // Kullanici son etkilesiminden sonra X ms boyunca polling skip.
  // Garson hizli teslime cekerken arka plan refresh UI'i bombardiman etmesin.
  DateTime? _lastUserAction;

  @override
  void initState() {
    super.initState();
    _sortMode = widget.storageService.getOrderTrackingSort();
    _load();
    // 5 saniye — 2sn cok agresifti, donmaya yol aciyordu
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    // Onceki fetch hala devam ediyorsa bekle (yigilma onleme)
    if (_isFetching) return;
    // Kullanici son 1.5sn icinde toggle yaptiysa polling skip — animasyon bitsin
    if (silent && _lastUserAction != null &&
        DateTime.now().difference(_lastUserAction!).inMilliseconds < 1500) {
      return;
    }
    _isFetching = true;
    if (!silent) setState(() => _isLoading = true);
    try {
      final rows = await widget.apiService.getPendingOrders();
      if (!mounted) return;
      setState(() {
        _raw = rows;
        _byTable = _group(rows);
        if (_selectedTableId != null && !_byTable.containsKey(_selectedTableId)) {
          _selectedTableId = _byTable.keys.isEmpty ? null : _byTable.keys.first;
        }
        _selectedTableId ??= _byTable.keys.isEmpty ? null : _byTable.keys.first;
        _isLoading = false;
      });
    } finally {
      _isFetching = false;
    }
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
    _lastUserAction = DateTime.now(); // polling pause penceresi
    // Optimistic — item field set + bundle list'leri tasi (full rebuild yok)
    setState(() {
      item['delivered_at'] = wasDelivered ? null : DateTime.now().toIso8601String();
      _moveItemBetweenLists(item, wasDelivered);
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
      // Rollback — yine sadece tasi
      setState(() {
        item['delivered_at'] = wasDelivered ? DateTime.now().toIso8601String() : null;
        _moveItemBetweenLists(item, !wasDelivered);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error']?.toString() ?? 'Islem basarisiz'),
          backgroundColor: Colors.red[700],
        ),
      );
    }
  }

  // Toggle sonrasi item'i pending<->delivered listeleri arasinda tasi.
  // _byTable'i tum yeniden insa etmek yerine sadece ilgili bundle'i mutate et — UI flicker'i azaltir.
  // wasDelivered=true => simdi pending'e geri tasi, wasDelivered=false => delivered'a tasi
  void _moveItemBetweenLists(Map<String, dynamic> item, bool wasDelivered) {
    final tidRaw = item['table_id'];
    final tid = tidRaw is int ? tidRaw : int.tryParse(tidRaw?.toString() ?? '');
    if (tid == null) return;
    final bundle = _byTable[tid];
    if (bundle == null) return;
    if (wasDelivered) {
      bundle.delivered.removeWhere((it) => it['item_id'] == item['item_id']);
      bundle.pending.add(item);
    } else {
      bundle.pending.removeWhere((it) => it['item_id'] == item['item_id']);
      bundle.delivered.add(item);
    }
  }

  int? _extractInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  // Bundle'in en eski bekleyen item'inin item_created_at'i — zamana gore siralama icin.
  // Bos pending icin DateTime.now() (siralama sonuna at).
  DateTime _oldestPendingTime(TableBundle b) {
    DateTime? oldest;
    for (final it in b.pending) {
      final s = it['item_created_at']?.toString();
      if (s == null || s.isEmpty) continue;
      try {
        final dt = DateTime.parse(s).toLocal();
        if (oldest == null || dt.isBefore(oldest)) oldest = dt;
      } catch (_) {}
    }
    return oldest ?? DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);

    // Pending olan tum bundle'lar — kullanicinin sectigi siralama (4 mod)
    final allBundlesWithPending =
        _byTable.values.where((b) => b.pending.isNotEmpty).toList()
          ..sort((a, b) {
            switch (_sortMode) {
              case 'time_asc': // Zamana Gore - Once (en eski ustte = en acil)
                return _oldestPendingTime(a).compareTo(_oldestPendingTime(b));
              case 'time_desc': // Zamana Gore - Sonra (en yeni ustte)
                return _oldestPendingTime(b).compareTo(_oldestPendingTime(a));
              case 'table_desc': // Masaya Gore - Buyukten Kucuge
                final ai = int.tryParse(a.tableNumber) ?? 0;
                final bi = int.tryParse(b.tableNumber) ?? 0;
                return bi.compareTo(ai);
              case 'table_asc': // Masaya Gore - Kucukten Buyuge
              default:
                final ai = int.tryParse(a.tableNumber) ?? 0;
                final bi = int.tryParse(b.tableNumber) ?? 0;
                return ai.compareTo(bi);
            }
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

    // Secili masa filtrede yoksa anlik direkt assign — addPostFrameCallback +
    // setState build sirasinda surekli reentrant rebuild ureterek donmaya yol aciyordu.
    // _selectedTableId state ama mevcut build'de okudugumuz icin assign + sonraki build dogal akisla yansir.
    if (_selectedTableId != null && !bundles.any((b) => b.tableId == _selectedTableId)) {
      _selectedTableId = bundles.isEmpty ? null : bundles.first.tableId;
    } else if (_selectedTableId == null && bundles.isNotEmpty) {
      _selectedTableId = bundles.first.tableId;
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
          // SIRALAMA — 4 secenek (kalici tercih)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Container(
              height: 52,
              constraints: const BoxConstraints(minWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4)],
              ),
              child: Row(
                children: [
                  Icon(Icons.sort, color: theme.primaryColor, size: 22),
                  const SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _sortMode,
                      icon: Icon(Icons.arrow_drop_down, color: theme.primaryColor),
                      style: TextStyle(
                        color: theme.primaryColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'time_asc', child: Text('Zamana Göre - Önce')),
                        DropdownMenuItem(value: 'time_desc', child: Text('Zamana Göre - Sonra')),
                        DropdownMenuItem(value: 'table_asc', child: Text('Masaya Göre - Küçükten Büyüğe')),
                        DropdownMenuItem(value: 'table_desc', child: Text('Masaya Göre - Büyükten Küçüğe')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _sortMode = v);
                        // Kalici tercih — garson tekrar tekrar secmesin
                        widget.storageService.setOrderTrackingSort(v);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // TUM BEKLEYENLER - dokunmatik icin buyuk buton
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () => _showAllOrdersDialog(theme),
                icon: const Icon(Icons.list_alt, size: 28),
                label: const Text(
                  'TÜM SİPARİŞLER',
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
                          // Sort/filter degisince Flutter ListView'i yeniden insa etsin
                          key: ValueKey('sidebar-$_sortMode-${_sectionFilter ?? "all"}-${bundles.length}'),
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
    // Tum item'lar (pending + delivered) raw kaynaktan
    final all = _raw.map((r) => Map<String, dynamic>.from(r as Map)).toList();
    // Salon listesi — bos olanlar 'Diger'
    final sectionSet = <String>{};
    for (final m in all) {
      sectionSet.add((m['section_name']?.toString() ?? '').isEmpty ? 'Diger' : m['section_name'].toString());
    }
    final sectionList = sectionSet.toList()..sort();
    String? popupFilter; // null = Tumu

    int sortItems(Map a, Map b) {
      final s = (a['section_name']?.toString() ?? '').compareTo(b['section_name']?.toString() ?? '');
      if (s != 0) return s;
      final ta = int.tryParse(a['table_number']?.toString() ?? '') ?? 0;
      final tb = int.tryParse(b['table_number']?.toString() ?? '') ?? 0;
      if (ta != tb) return ta.compareTo(tb);
      final da = a['item_created_at']?.toString() ?? '';
      final db = b['item_created_at']?.toString() ?? '';
      return da.compareTo(db);
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          // Filtreli listeler
          final filtered = popupFilter == null
              ? all
              : all.where((m) {
                  final sn = (m['section_name']?.toString() ?? '').isEmpty ? 'Diger' : m['section_name'].toString();
                  return sn == popupFilter;
                }).toList();
          final pendingItems = filtered.where((m) => m['delivered_at'] == null).toList()..sort(sortItems);
          final deliveredItems = filtered.where((m) => m['delivered_at'] != null).toList()..sort(sortItems);

          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: DefaultTabController(
              length: 2,
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
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ]),
                  ),
                  // Salon filtresi — ortada chip'ler (Tumu + dinamik salonlar)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _popupSectionChip('Tüm Salonlar', popupFilter == null, theme,
                            () => setStateDialog(() => popupFilter = null)),
                        for (final s in sectionList)
                          _popupSectionChip(s, popupFilter == s, theme,
                              () => setStateDialog(() => popupFilter = s)),
                      ],
                    ),
                  ),
                  // Tabs
                  Container(
                    color: Colors.white,
                    child: TabBar(
                      labelColor: theme.primaryColor,
                      unselectedLabelColor: Colors.grey[600],
                      indicatorColor: theme.primaryColor,
                      indicatorWeight: 3,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                      tabs: [
                        Tab(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.schedule, size: 18, color: Colors.orange[800]),
                            const SizedBox(width: 6),
                            Text('BEKLEYEN (${pendingItems.length})'),
                          ]),
                        ),
                        Tab(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.check_circle, size: 18, color: Colors.green[700]),
                            const SizedBox(width: 6),
                            Text('GİDEN (${deliveredItems.length})'),
                          ]),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(children: [
                      _buildAllOrdersList(pendingItems, false),
                      _buildAllOrdersList(deliveredItems, true),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _popupSectionChip(String label, bool selected, ThemeProvider theme, VoidCallback onTap) {
    return Material(
      color: selected ? theme.primaryColor : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAllOrdersList(List<Map<String, dynamic>> items, bool isDelivered) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          isDelivered ? 'Henüz teslim edilen yok' : 'Bekleyen sipariş yok',
          style: const TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }
    return Column(children: [
      // Tablo header
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Colors.grey[200],
        child: Row(children: [
          const SizedBox(width: 110, child: Text('SALON', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          const SizedBox(width: 70, child: Text('MASA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          const SizedBox(width: 50, child: Text('ADET', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          const Expanded(child: Text('ÜRÜN', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          SizedBox(width: 130, child: Text(isDelivered ? 'TESLİM' : 'GİRİŞ', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey[200]),
          itemBuilder: (_, i) {
            final it = items[i];
            final timeStr = isDelivered
                ? _fmtTime(it['delivered_at'])
                : _fmtTime(it['item_created_at']);
            final whoStr = isDelivered
                ? (it['delivered_by_name']?.toString() ?? '')
                : (it['added_by_name']?.toString() ?? '');
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: isDelivered ? const Color(0xFFF0FDF4) : Colors.white,
              child: Row(children: [
                SizedBox(width: 110, child: Text(it['section_name']?.toString() ?? '-', style: const TextStyle(fontSize: 13))),
                SizedBox(width: 70, child: Text('Masa ${it['table_number'] ?? '-'}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                SizedBox(width: 50, child: Text('${it['quantity'] ?? 1}x', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(it['product_name']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
                      if ((it['notes']?.toString() ?? '').isNotEmpty)
                        Text(it['notes'].toString(), style: TextStyle(fontSize: 11, color: Colors.grey[600], fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(timeStr, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                      if (whoStr.isNotEmpty)
                        Text(whoStr, style: TextStyle(fontSize: 11, color: Colors.grey[700])),
                    ],
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  String _fmtTime(dynamic iso) {
    if (iso == null) return '-';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '-';
    }
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
