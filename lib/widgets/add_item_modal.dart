import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/image_cache_service.dart';
import '../providers/theme_provider.dart';

class AddItemModal extends StatefulWidget {
  final ApiService apiService;
  final PrinterService? printerService;
  final int ticketId;
  final int waiterId;
  final VoidCallback onItemAdded;
  final VoidCallback onClose;
  final bool showProductImages;
  final int tableId;
  final Map<String, dynamic>? table;
  final Map<String, dynamic>? waiter;
  final Map<String, dynamic>? section;

  const AddItemModal({
    super.key,
    required this.apiService,
    required this.ticketId,
    required this.waiterId,
    required this.onItemAdded,
    required this.onClose,
    this.showProductImages = true,
    this.tableId = 0,
    this.printerService,
    this.table,
    this.waiter,
    this.section,
  });

  @override
  State<AddItemModal> createState() => _AddItemModalState();
}

class _AddItemModalState extends State<AddItemModal> {
  List<dynamic> _categories = [];
  List<dynamic> _products = [];
  List<dynamic> _filteredProducts = [];
  List<dynamic> _ticketItems = [];
  bool _isLoading = true;
  int? _selectedCategoryId;
  String _searchQuery = '';
  int? _selectedItemIndex;
  final TextEditingController _searchController = TextEditingController();
  final ImageCacheService _imageCache = ImageCacheService();
  bool _imageCacheReady = false;

  int? _safeInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _safeDouble(dynamic value, [double defaultValue = 0]) {
    if (value == null) return defaultValue;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? defaultValue;
  }

  bool _hasPermission(String permission) {
    if (!widget.apiService.isOnline) {
      const offlineAllowed = ['open_ticket', 'add_item', 'close_ticket', 'void_ticket'];
      return offlineAllowed.contains(permission);
    }
    final permissions = widget.waiter?['permissions'] as Map<String, dynamic>?;
    if (permissions == null) return true;
    return permissions[permission] == true;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _imageCache.init();
      if (mounted) setState(() => _imageCacheReady = true);
    } catch (e) {
      print('[AddItemModal] ImageCache init hatası: $e');
    }
    await _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final categories = await widget.apiService.getCategories();
      final products = await widget.apiService.getProducts();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _products = products;
        _filteredProducts = products;
      });
      await _loadTicketItems();
    } catch (e) {
      if (mounted) _showError('Veri yüklenemedi: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTicketItems() async {
    try {
      if (widget.tableId > 0) {
        print('[AddItemModal] _loadTicketItems: tableId=${widget.tableId}');
        final ticketData = await widget.apiService.getTableTicket(widget.tableId);
        print('[AddItemModal] ticketData: $ticketData');
        if (ticketData != null && mounted) {
          final ticket = ticketData['ticket'] as Map<String, dynamic>?;
          if (ticket != null) {
            final items = (ticket['items'] as List?) ?? [];
            print('[AddItemModal] items loaded: ${items.length}');
            setState(() {
              _ticketItems = items;
            });
          } else {
            // ticket null ama ticketData var — belki doğrudan ticket objesi
            if (ticketData['items'] != null) {
              final items = (ticketData['items'] as List?) ?? [];
              print('[AddItemModal] items from direct ticketData: ${items.length}');
              setState(() {
                _ticketItems = items;
              });
            } else {
              print('[AddItemModal] ticket is null, no items found');
            }
          }
        }
      } else {
        print('[AddItemModal] tableId is 0, skipping _loadTicketItems');
      }
    } catch (e) {
      print('[AddItemModal] Ticket items yüklenemedi: $e');
    }
  }

  void _filterProducts() {
    setState(() {
      _filteredProducts = _products.where((p) {
        if (_selectedCategoryId != null) {
          if (_safeInt(p['category_id']) != _selectedCategoryId) return false;
        }
        if (_searchQuery.isNotEmpty) {
          final name = (p['name'] ?? '').toString().toLowerCase();
          final desc = (p['description'] ?? '').toString().toLowerCase();
          if (!name.contains(_searchQuery) && !desc.contains(_searchQuery)) return false;
        }
        final isActive = p['is_active'] == 1 || p['is_active'] == true;
        if (!isActive) return false;
        return true;
      }).toList();
    });
  }

  void _selectCategory(int? categoryId) {
    setState(() => _selectedCategoryId = categoryId);
    _filterProducts();
  }

  void _onSearch(String query) {
    _searchQuery = query.toLowerCase().trim();
    _filterProducts();
  }

  /// Ürüne tıkla → direkt ekle (popup yok)
  Future<void> _addProductDirectly(Map<String, dynamic> product) async {
    try {
      final productId = _safeInt(product['id']);
      if (productId == null) return;

      await widget.apiService.addTicketItem(
        ticketId: widget.ticketId,
        productId: productId,
        productName: product['name']?.toString() ?? '',
        unitPrice: _safeDouble(product['price']),
        quantity: 1,
        waiterId: widget.waiterId,
      );
      widget.onItemAdded();
      await _loadTicketItems();
    } catch (e) {
      _showError('Ürün eklenemedi: $e');
    }
  }

  /// Seçili ürüne not ekle popup
  Future<void> _openNoteDialog() async {
    if (_selectedItemIndex == null) return;

    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (_selectedItemIndex! >= activeItems.length) return;

    final item = activeItems[_selectedItemIndex!];
    final currentNote = item['notes']?.toString() ?? '';
    final controller = TextEditingController(text: currentNote);

    final note = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Provider.of<ThemeProvider>(ctx, listen: false);
        return Material(
          type: MaterialType.transparency,
          child: Center(
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item['product_name']} - Not', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Ürün notu girin...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: theme.primaryColor, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, controller.text),
                        style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, foregroundColor: Colors.white),
                        child: const Text('Kaydet'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (note == null) return;

    try {
      final itemId = _safeInt(item['id']);
      final ticketId = widget.ticketId;
      if (itemId == null) return;

      await widget.apiService.updateTicketItem(
        ticketId: ticketId,
        itemId: itemId,
        notes: note,
      );
      await _loadTicketItems();
      widget.onItemAdded();
    } catch (e) {
      _showError('Not eklenemedi: $e');
    }
  }

  /// Ürün iptal
  Future<void> _cancelSelectedItem() async {
    print('[AddItemModal] _cancelSelectedItem called, _selectedItemIndex=$_selectedItemIndex');
    if (_selectedItemIndex == null) return;

    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    print('[AddItemModal] activeItems.length=${activeItems.length}');
    if (_selectedItemIndex! >= activeItems.length) return;

    final item = activeItems[_selectedItemIndex!];
    final itemId = _safeInt(item['id']);
    print('[AddItemModal] item=${item['product_name']}, itemId=$itemId');
    if (itemId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ürün İptal'),
        content: Text('${item['product_name']} iptal edilecek. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgec')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İptal Et', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await widget.apiService.deleteTicketItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        waiterId: widget.waiterId,
      );
      setState(() => _selectedItemIndex = null);
      await _loadTicketItems();
      widget.onItemAdded();
      _showSuccess('Ürün iptal edildi');
    } catch (e) {
      _showError('Ürün iptal edilemedi: $e');
    }
  }

  /// Mutfağa gönder
  Future<void> _sendToKitchen() async {
    if (widget.printerService == null) return;
    try {
      final result = await widget.apiService.printKitchen(
        ticketId: widget.ticketId,
        waiterId: widget.waiterId,
      );
      if (result['success'] != true) {
        _showError(result['error'] ?? 'Mutfak fişi alınamadı');
        return;
      }
      final items = result['items'] as List? ?? [];
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};

      ticketInfo['table_number'] = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';
      ticketInfo['section_name'] = widget.table?['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter?['name'] ?? '';

      if (items.isEmpty) {
        _showSuccess('Yazdırılacak yeni ürün yok');
        return;
      }

      int successCount = 0;
      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty) continue;

        bool success = false;
        if (printerIp != null && printerIp.isNotEmpty) {
          success = await widget.printerService!.printKitchenReceiptToIp(
            ticket: ticketInfo, items: groupItems, ip: printerIp, port: printerPort,
          );
        } else {
          success = await widget.printerService!.printKitchenReceipt(
            ticket: ticketInfo, items: groupItems,
          );
        }
        if (success) successCount += groupItems.length;
      }

      // Salon özet fişi (salon yazıcısı tanımlıysa tüm ürünlerle)
      try { await _printSummaryReceipt(''); } catch (_) {}

      _showSuccess('Mutfağa gönderildi ($successCount ürün)');
      await _loadTicketItems();
      widget.onItemAdded();
    } catch (e) {
      _showError('Mutfağa gönderilemedi: $e');
    }
  }

  /// Yazdır
  Future<void> _printTicket() async {
    print('[AddItemModal] _printTicket: printerService=${widget.printerService != null}, tableId=${widget.tableId}');
    if (widget.printerService == null) return;
    try {
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      print('[AddItemModal] _printTicket ticketData: ${ticketData != null}');
      if (ticketData == null) return;
      final ticket = ticketData['ticket'] as Map<String, dynamic>?;
      print('[AddItemModal] _printTicket ticket: ${ticket != null}, items: ${ticket?['items']?.length}');
      if (ticket == null) return;

      final ticketToPrint = Map<String, dynamic>.from(ticket);
      final sectionName = widget.table?['section_name'] ?? '';
      final tableNumber = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';
      ticketToPrint['table_name'] = '$sectionName - $tableNumber';
      ticketToPrint['waiter_name'] = widget.waiter?['name'] ?? '';

      final success = await widget.printerService!.printTicket(ticketToPrint);
      if (success) {
        _showSuccess('Fiş yazdırıldı');
      } else {
        _showError('Yazıcı hatası');
      }
    } catch (e) {
      _showError('Yazdır hatası: $e');
    }
  }

  /// Hesap kapat — tüm ürünleri ödeyerek kapat
  Future<void> _closeTicket(String paymentMethod) async {
    // Ödenmemiş ürünleri bul
    await _loadTicketItems();
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    final unpaidItems = activeItems.where((i) => i['payment_status'] != 'paid').toList();
    final unpaidIds = unpaidItems.map((i) => (i['id'] as num).toInt()).toList();

    if (unpaidIds.isEmpty) {
      // Tüm ürünler zaten ödendi, direkt kapat
      try {
        await widget.apiService.closeTicket(
          ticketId: widget.ticketId,
          paymentMethod: paymentMethod,
          waiterId: widget.waiterId,
        );
        _showSuccess('Hesap kapatıldı');
        widget.onItemAdded();
        widget.onClose();
      } catch (e) {
        _showError('Hesap kapatılamadı: $e');
      }
      return;
    }

    final label = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Kartı';
    double unpaidTotal = 0;
    for (var item in unpaidItems) {
      unpaidTotal += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesap Kapat'),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve hesap kapatılacak.\n\nDevam edilsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Öde ve Kapat', style: TextStyle(color: paymentMethod == 'cash' ? Colors.green : Colors.blue, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: unpaidIds,
        paymentMethod: paymentMethod,
        waiterId: widget.waiterId,
      );

      if (result['success'] == true) {
        _showSuccess('Hesap kapatıldı');
        widget.onItemAdded();
        widget.onClose();
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Hesap kapatılamadı: $e');
    }
  }

  /// Yazdır + kapat
  Future<void> _printAndCloseTicket(String paymentMethod) async {
    final label = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Karti';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yazdir ve Kapat'),
        content: Text('$label ile hesap kapatılacak ve fiş yazdırılacak. Devam edilsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Yazdır ve Kapat', style: TextStyle(color: paymentMethod == 'cash' ? Colors.green : Colors.blue)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (widget.printerService != null) {
        // 1. Mutfağa gönder (yazdırılmamış ürünler varsa)
        try { await _sendToKitchenSilent(); } catch (_) {}
        // 2. Adisyon fişi yazdır (varsayılan yazıcıya)
        try { await _printTicket(); } catch (_) {}
        // 3. Salon özet fişi (salon yazıcısı tanımlıysa)
        try { await _printSummaryReceipt(paymentMethod); } catch (_) {}
      }

      await widget.apiService.closeTicket(
        ticketId: widget.ticketId,
        paymentMethod: paymentMethod,
        waiterId: widget.waiterId,
      );

      _showSuccess('Hesap kapatıldı');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Hesap kapatılamadı: $e');
    }
  }

  Future<void> _sendToKitchenSilent() async {
    if (widget.printerService == null) return;
    try {
      final result = await widget.apiService.printKitchen(ticketId: widget.ticketId, waiterId: widget.waiterId);
      if (result['success'] != true) return;
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};
      ticketInfo['table_number'] = widget.table?['table_number'] ?? '';
      ticketInfo['section_name'] = widget.table?['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter?['name'] ?? '';
      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty || printerIp == null) continue;
        await widget.printerService!.printKitchenReceiptToIp(
          ticket: ticketInfo, items: groupItems, ip: printerIp, port: printerPort,
        );
      }
    } catch (_) {}
  }

  Future<void> _printSummaryReceipt(String paymentMethod) async {
    print('[AddItemModal] _printSummaryReceipt: printerService=${widget.printerService != null}, section=${widget.section}');
    if (widget.printerService == null || widget.section == null) {
      print('[AddItemModal] SKIP: printerService veya section null');
      return;
    }
    final summaryPrinterId = widget.section!['summary_printer_id'];
    print('[AddItemModal] summaryPrinterId=$summaryPrinterId');
    if (summaryPrinterId == null) {
      print('[AddItemModal] SKIP: summaryPrinterId null');
      return;
    }
    try {
      final printers = await widget.apiService.getPrinters();
      final targetId = summaryPrinterId is String ? int.tryParse(summaryPrinterId) : summaryPrinterId;
      final printer = printers.firstWhere(
        (p) {
          final pid = p['id'] is String ? int.tryParse(p['id']) : p['id'];
          return pid == targetId;
        },
        orElse: () => <String, dynamic>{},
      );
      if (printer.isEmpty) return;
      final ip = (printer['ip'] ?? printer['ip_address']) as String?;
      final port = (printer['port'] as num?)?.toInt() ?? 9100;
      if (ip == null || ip.isEmpty) return;
      final brandName = Provider.of<ThemeProvider>(context, listen: false).brandName;

      // Ticket bilgisini çek
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      if (ticketData == null) return;
      final ticket = ticketData['ticket'] as Map<String, dynamic>?;
      if (ticket == null) return;

      await widget.printerService!.printClosingReceipt(
        ticket: ticket,
        table: widget.table ?? {},
        waiterName: widget.waiter?['name'] ?? '',
        paymentMethod: paymentMethod,
        targetIp: ip,
        targetPort: port,
        brandName: brandName,
      );
    } catch (_) {}
  }

  /// Parçalı ödeme popup
  Future<void> _openPartialPayment() async {
    // Ticket items'ı yenile
    await _loadTicketItems();
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (activeItems.isEmpty) return;

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PartialPaymentDialog(
        items: activeItems,
        ticketId: widget.ticketId,
        apiService: widget.apiService,
        onPaymentComplete: (allPaid) {
          Navigator.pop(ctx);
          if (allPaid) {
            // Tüm ürünler ödendi, adisyon kapandı
            widget.onItemAdded();
            widget.onClose();
          } else {
            // Kısmi ödeme yapıldı, items'ı yenile
            _loadTicketItems();
          }
        },
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  /// Adisyon iptal
  Future<void> _voidTicket() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon İptal'),
        content: const Text('Adisyon iptal edilecek. Bu işlem geri alınamaz. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgec')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İptal Et', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.apiService.voidTicket(ticketId: widget.ticketId, waiterId: widget.waiterId);
      _showSuccess('Adisyon iptal edildi');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Adisyon iptal edilemedi: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    print('[AddItemModal] ERROR: $message');
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (_) {
      // Dialog içinde Scaffold yoksa overlay ile göster
      _showOverlayMessage(message, Colors.red);
    }
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    print('[AddItemModal] SUCCESS: $message');
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
    } catch (_) {
      _showOverlayMessage(message, Colors.green);
    }
  }

  void _showOverlayMessage(String message, Color color) {
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 50,
        left: 50,
        right: 50,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 14), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () => entry.remove());
  }

  double get _paidTotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      if (item['payment_status'] == 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  double get _unpaidTotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      if (item['payment_status'] != 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  double get _ticketTotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Scaffold(
        body: Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        color: Colors.white,
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: theme.primaryColor))
                  : Row(
                      children: [
                        // SOL: Kategoriler (2 sütun)
                        _buildCategoriesPanel(theme),
                        // ORTA: Ürünler
                        Expanded(flex: 3, child: _buildProductsPanel(theme)),
                        // SAĞ: Adisyon + aksiyon butonları
                        _buildTicketPanel(theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(ThemeProvider theme) {
    final sectionName = widget.table?['section_name'] ?? '';
    final tableNumber = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.primaryColor,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Text(
            '$sectionName - $tableNumber',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 16),
          // Arama
          Expanded(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearch,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Ürün ara...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.7), size: 20),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  // SOL: Kategoriler - 2 sütun
  Widget _buildCategoriesPanel(ThemeProvider theme) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(right: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        children: [
          // "Tümü" butonu - tam genişlik
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: _buildCategoryButton(theme, null, 'Tümü', Icons.apps),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                return _buildCategoryButton(
                  theme,
                  _safeInt(cat['id']),
                  cat['name']?.toString() ?? '',
                  null,
                  emoji: cat['icon']?.toString() ?? '',
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryButton(ThemeProvider theme, int? categoryId, String label, IconData? icon, {String emoji = ''}) {
    final isSelected = _selectedCategoryId == categoryId;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (_) => _selectCategory(categoryId),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? theme.primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? theme.primaryColor : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: theme.primaryColor.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))]
              : [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 2, offset: const Offset(0, 1))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (emoji.isNotEmpty)
              Text(emoji, style: const TextStyle(fontSize: 20))
            else if (icon != null)
              Icon(icon, color: isSelected ? Colors.white : Colors.grey[700], size: 20),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[800],
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ORTA: Ürünler grid
  Widget _buildProductsPanel(ThemeProvider theme) {
    if (_filteredProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Ürün bulunamadı', style: TextStyle(color: Colors.grey[500], fontSize: 18)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 130).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: widget.showProductImages ? 0.85 : 1.8,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _filteredProducts.length,
          itemBuilder: (context, index) => _buildProductCard(_filteredProducts[index], theme),
        );
      },
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product, ThemeProvider theme) {
    final isOutOfStock = product['is_out_of_stock'] == 1 || product['is_out_of_stock'] == true;
    final hasImage = product['image'] != null && product['image'].toString().isNotEmpty;

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: isOutOfStock ? null : (_) => _addProductDirectly(product),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey[200]!),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showProductImages)
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10)),
                    child: hasImage ? _buildProductImage(product) : _buildPlaceholder(product),
                  ),
                ),
              Expanded(
                flex: widget.showProductImages ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: widget.showProductImages ? MainAxisAlignment.start : MainAxisAlignment.center,
                    children: [
                      Text(
                        product['name']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Color(0xFF1f2937)),
                      ),
                      if (widget.showProductImages) const Spacer(),
                      if (!widget.showProductImages) const SizedBox(height: 2),
                      Text(
                        '${product['price'] ?? 0} TL',
                        style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              if (isOutOfStock)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.only(bottomLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
                  ),
                  child: const Center(
                    child: Text('Tukendi', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // SAĞ: Adisyon paneli + aksiyon butonları
  Widget _buildTicketPanel(ThemeProvider theme) {
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    final hasItems = activeItems.isNotEmpty;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Colors.grey[300]!)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(-2, 0))],
      ),
      child: Column(
        children: [
          // Başlık
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long, size: 16, color: theme.primaryColor),
                const SizedBox(width: 6),
                Text('Adisyon', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${activeItems.length}', style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),

          // Ürün listesi
          Expanded(
            child: activeItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.restaurant_menu, size: 36, color: Colors.grey[300]),
                        const SizedBox(height: 8),
                        Text('Henüz ürün eklenmedi', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: activeItems.length,
                    itemBuilder: (context, index) {
                      final item = activeItems[index];
                      final isSelected = _selectedItemIndex == index;
                      return _buildTicketItemRow(item, theme, index, isSelected);
                    },
                  ),
          ),

          // Toplam + ödeme durumu
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(top: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Column(
              children: [
                if (_paidTotal > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Ödenen', style: TextStyle(fontSize: 11, color: Colors.green[700])),
                      Text('${_paidTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green[700])),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Kalan', style: TextStyle(fontSize: 11, color: Colors.orange[700])),
                      Text('${_unpaidTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('TOPLAM', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                    Text('${_ticketTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.primaryColor)),
                  ],
                ),
              ],
            ),
          ),

          // Aksiyon butonları
          _buildActionButtons(theme, hasItems),
        ],
      ),
    );
  }

  Widget _buildTicketItemRow(Map<String, dynamic> item, ThemeProvider theme, int index, bool isSelected) {
    final quantity = _safeInt(item['quantity']) ?? 1;
    final unitPrice = _safeDouble(item['unit_price']);
    final total = unitPrice * quantity;
    final notes = item['notes'] as String?;
    final isPaid = item['payment_status'] == 'paid';
    final payMethod = item['payment_method']?.toString().toUpperCase() ?? '';

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (_) => setState(() => _selectedItemIndex = isSelected ? null : index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isPaid
              ? Colors.green[50]
              : (isSelected ? theme.primaryColor.withOpacity(0.08) : Colors.transparent),
          border: Border(
            bottom: BorderSide(color: Colors.grey[100]!),
            left: isSelected ? BorderSide(color: theme.primaryColor, width: 3) : BorderSide.none,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isPaid ? Colors.green : theme.primaryColor,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Center(child: Text('$quantity', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['product_name']?.toString() ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
                    ),
                  ),
                  if (notes != null && notes.isNotEmpty)
                    Text(notes, style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic)),
                  if (isPaid)
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: payMethod == 'CASH' ? Colors.green : Colors.blue,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        payMethod == 'CASH' ? 'NAKİT' : 'KART',
                        style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${total.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ThemeProvider theme, bool hasItems) {
    print('[AddItemModal] _buildActionButtons: hasItems=$hasItems, _selectedItemIndex=$_selectedItemIndex, cancel_perm=${_hasPermission("cancel_item")}');
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Column(
        children: [
          // İlk satır: Not Ekle + Urun Iptal
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.edit_note,
                  label: 'Not Ekle',
                  color: Colors.blueGrey,
                  onTap: hasItems && _selectedItemIndex != null ? _openNoteDialog : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.close,
                  label: 'Ürün İptal',
                  color: Colors.red[400]!,
                  onTap: hasItems && _selectedItemIndex != null
                      ? () async {
                          print('[AddItemModal] Ürün İptal butonuna tıklandı! selectedIndex=$_selectedItemIndex');
                          if (!_hasPermission('cancel_item')) {
                            print('[AddItemModal] cancel_item yetkisi YOK');
                            await showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Yetki Hatası'),
                                content: const Text('Ürün iptal yetkiniz bulunmamaktadır'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam')),
                                ],
                              ),
                            );
                            return;
                          }
                          print('[AddItemModal] cancel_item yetkisi VAR, _cancelSelectedItem çağrılıyor');
                          _cancelSelectedItem();
                        }
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // İkinci satır: Mutfağa Gönder + Yazdır
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.restaurant,
                  label: 'Mutfak',
                  color: const Color(0xFFF59E0B),
                  onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.print,
                  label: 'Yazdır',
                  color: Colors.blueGrey,
                  onTap: hasItems && _hasPermission('print_receipt') ? _printTicket : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Parçalı Ödeme (tam genişlik)
          SizedBox(
            width: double.infinity,
            child: _buildActionBtn(
              icon: Icons.splitscreen,
              label: 'Parçalı Ödeme',
              color: const Color(0xFF7C3AED),
              onTap: hasItems && _hasPermission('close_ticket') ? _openPartialPayment : null,
            ),
          ),
          const SizedBox(height: 6),
          // Üçüncü satır: Nakit + Kredi Kartı
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.payments,
                  label: 'Nakit',
                  color: theme.primaryColor,
                  onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.credit_card,
                  label: 'Kredi Kartı',
                  color: const Color(0xFF3B82F6),
                  onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('credit_card') : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Dördüncü satır: Yazdır+Nakit + Yazdır+Kart
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.receipt_long,
                  label: 'Yaz+Nakit',
                  color: const Color(0xFF059669),
                  onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt')
                      ? () => _printAndCloseTicket('cash')
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.receipt_long,
                  label: 'Yaz+Kart',
                  color: const Color(0xFF2563EB),
                  onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt')
                      ? () => _printAndCloseTicket('credit_card')
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Son satır: Adisyon İptal
          if (_hasPermission('void_ticket'))
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                icon: Icons.delete_outline,
                label: 'Adisyon İptal',
                color: const Color(0xFFDC2626),
                onTap: _voidTicket,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: isDisabled ? null : (_) => onTap(),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[200] : color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isDisabled ? Colors.grey[400] : Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductImage(Map<String, dynamic> product) {
    final imagePath = product['image']?.toString() ?? '';
    if (imagePath.isEmpty) return _buildPlaceholder(product);
    final imageUrl = widget.apiService.getImageUrl(imagePath);

    if (_imageCacheReady) {
      try {
        final cachePath = _imageCache.getCachePath(imageUrl);
        if (cachePath.isNotEmpty) {
          final cacheFile = File(cachePath);
          if (cacheFile.existsSync()) {
            return Image.file(cacheFile, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildPlaceholder(product));
          }
        }
      } catch (_) {}
    }

    return FutureBuilder<String?>(
      future: _imageCache.downloadAndCache(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey[200],
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Provider.of<ThemeProvider>(context, listen: false).primaryColor)),
          );
        }
        if (snapshot.hasData && snapshot.data != null) {
          final cacheFile = File(snapshot.data!);
          if (cacheFile.existsSync()) {
            return Image.file(cacheFile, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildPlaceholder(product));
          }
        }
        return _buildPlaceholder(product);
      },
    );
  }

  Widget _buildPlaceholder(Map<String, dynamic> product) {
    final emoji = product['category_icon'] ?? '🍽️';
    return Container(
      color: Colors.grey[100],
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 32))),
    );
  }
}

/// Parçalı Ödeme Dialog
class _PartialPaymentDialog extends StatefulWidget {
  final List<dynamic> items;
  final int ticketId;
  final ApiService apiService;
  final Function(bool allPaid) onPaymentComplete;
  final VoidCallback onClose;

  const _PartialPaymentDialog({
    required this.items,
    required this.ticketId,
    required this.apiService,
    required this.onPaymentComplete,
    required this.onClose,
  });

  @override
  State<_PartialPaymentDialog> createState() => _PartialPaymentDialogState();
}

class _PartialPaymentDialogState extends State<_PartialPaymentDialog> {
  late List<Map<String, dynamic>> _items;
  final Set<int> _selectedIds = {};
  bool _isProcessing = false;

  double _safeDouble(dynamic value, [double defaultValue = 0]) {
    if (value == null) return defaultValue;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? defaultValue;
  }

  @override
  void initState() {
    super.initState();
    _items = widget.items.map((i) => Map<String, dynamic>.from(i)).toList();
  }

  double get _selectedTotal {
    double total = 0;
    for (var item in _items) {
      final itemId = item['id'] as int?;
      if (itemId != null && _selectedIds.contains(itemId)) {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  double get _totalAmount {
    double total = 0;
    for (var item in _items) {
      if (item['payment_status'] != 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  void _toggleItem(int itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  void _selectAll() {
    setState(() {
      for (var item in _items) {
        if (item['payment_status'] != 'paid') {
          final id = item['id'] as int?;
          if (id != null) _selectedIds.add(id);
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  Future<void> _paySelected(String paymentMethod) async {
    if (_selectedIds.isEmpty || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: _selectedIds.toList(),
        paymentMethod: paymentMethod,
      );

      if (result['success'] == true) {
        // Ödenen ürünleri güncelle
        for (var item in _items) {
          if (_selectedIds.contains(item['id'])) {
            item['payment_status'] = 'paid';
            item['payment_method'] = paymentMethod;
          }
        }
        _selectedIds.clear();

        // Tüm ürünler ödendi mi?
        final allPaid = _items.every((i) => i['payment_status'] == 'paid');
        if (allPaid) {
          widget.onPaymentComplete(true);
        } else {
          setState(() {});
        }
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Ödeme hatası: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _closeAll(String paymentMethod) async {
    if (_isProcessing) return;

    final unpaidIds = _items
        .where((i) => i['payment_status'] != 'paid')
        .map((i) => i['id'] as int)
        .toList();

    if (unpaidIds.isEmpty) return;

    // Toplam tutarı hesapla
    double unpaidTotal = 0;
    for (var item in _items) {
      if (item['payment_status'] != 'paid') {
        unpaidTotal += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }

    final label = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Kartı';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon Kapat'),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve adisyon kapatılacak.\n\nDevam edilsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Öde ve Kapat', style: TextStyle(color: paymentMethod == 'cash' ? Colors.green : Colors.blue, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isProcessing = true);

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: unpaidIds,
        paymentMethod: paymentMethod,
      );

      if (result['success'] == true) {
        widget.onPaymentComplete(true);
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Ödeme hatası: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    final unpaidItems = _items.where((i) => i['payment_status'] != 'paid').toList();
    final paidItems = _items.where((i) => i['payment_status'] == 'paid').toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Scaffold(
        body: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.9,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.splitscreen, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Text('Parçalı Ödeme', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    // Tümünü Seç / Seçimi Kaldır
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerUp: (_) => _selectedIds.length == unpaidItems.length ? _clearSelection() : _selectAll(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _selectedIds.length == unpaidItems.length ? 'Seçimi Kaldır' : 'Tümünü Seç',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerUp: (_) => widget.onClose(),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),

              // Ürün listesi
              Expanded(
                child: Row(
                  children: [
                    // Sol: Ürünler
                    Expanded(
                      flex: 3,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (unpaidItems.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Ödenmemiş Ürünler', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                            ),
                            ...unpaidItems.map((item) => _buildPaymentItem(item, theme, false)),
                          ],
                          if (paidItems.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Ödenen Ürünler', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[700])),
                            ),
                            ...paidItems.map((item) => _buildPaymentItem(item, theme, true)),
                          ],
                        ],
                      ),
                    ),

                    // Sağ: Özet + butonlar
                    Container(
                      width: 220,
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        border: Border(left: BorderSide(color: Colors.grey[200]!)),
                      ),
                      child: Column(
                        children: [
                          // Seçili ürünler özeti
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Seçili: ${_selectedIds.length} ürün', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_selectedTotal.toStringAsFixed(2)} TL',
                                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.primaryColor),
                                  ),
                                  const Divider(),
                                  Text('Kalan: ${_totalAmount.toStringAsFixed(2)} TL', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                ],
                              ),
                            ),
                          ),

                          // Ödeme butonları
                          Container(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                // Seçilenleri öde
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildPayBtn(
                                        icon: Icons.payments,
                                        label: 'Nakit',
                                        color: theme.primaryColor,
                                        onTap: _selectedIds.isNotEmpty && !_isProcessing ? () => _paySelected('cash') : null,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _buildPayBtn(
                                        icon: Icons.credit_card,
                                        label: 'Kart',
                                        color: const Color(0xFF3B82F6),
                                        onTap: _selectedIds.isNotEmpty && !_isProcessing ? () => _paySelected('card') : null,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Divider(),
                                const SizedBox(height: 8),
                                // Tümünü kapat
                                SizedBox(
                                  width: double.infinity,
                                  child: _buildPayBtn(
                                    icon: Icons.payments,
                                    label: 'Adisyon Kapat Nakit',
                                    color: const Color(0xFF059669),
                                    onTap: !_isProcessing ? () => _closeAll('cash') : null,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: double.infinity,
                                  child: _buildPayBtn(
                                    icon: Icons.credit_card,
                                    label: 'Adisyon Kapat Kart',
                                    color: const Color(0xFF2563EB),
                                    onTap: !_isProcessing ? () => _closeAll('card') : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Loading bar
              if (_isProcessing)
                LinearProgressIndicator(color: const Color(0xFF7C3AED)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentItem(Map<String, dynamic> item, ThemeProvider theme, bool isPaid) {
    final itemId = item['id'] as int?;
    final isSelected = itemId != null && _selectedIds.contains(itemId);
    final qty = item['quantity'] ?? 1;
    final price = _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    final paymentMethod = item['payment_method']?.toString().toUpperCase() ?? '';

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: isPaid ? null : (_) { if (itemId != null) _toggleItem(itemId); },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isPaid ? Colors.green[50] : (isSelected ? const Color(0xFF7C3AED).withOpacity(0.08) : Colors.white),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isPaid ? Colors.green[300]! : (isSelected ? const Color(0xFF7C3AED) : Colors.grey[200]!),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            // Checkbox
            if (!isPaid)
              Container(
                width: 24, height: 24,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF7C3AED) : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isSelected ? const Color(0xFF7C3AED) : Colors.grey[300]!, width: 2),
                ),
                child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
              ),
            // Miktar
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: isPaid ? Colors.green : theme.primaryColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(child: Text('$qty', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
            ),
            const SizedBox(width: 10),
            // Ürün adı
            Expanded(
              child: Text(
                item['product_name']?.toString() ?? '',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
                ),
              ),
            ),
            // Badge (ödenmişse)
            if (isPaid)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: paymentMethod == 'CASH' ? Colors.green : Colors.blue,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  paymentMethod == 'CASH' ? 'NAKİT' : 'KART',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            // Fiyat
            Text(
              '${price.toStringAsFixed(2)} TL',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPayBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: isDisabled ? null : (_) => onTap(),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[200] : color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: isDisabled ? Colors.grey[400] : Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
