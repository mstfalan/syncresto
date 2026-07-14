import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../providers/theme_provider.dart';
import 'pin_login_screen.dart';

class PosScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final Map<String, dynamic> waiter;

  const PosScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.waiter,
  });

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  List<dynamic> _sections = [];
  List<dynamic> _tables = [];
  List<dynamic> _categories = [];
  List<dynamic> _products = [];
  bool _isLoading = true;

  int? _selectedSectionId;
  Map<String, dynamic>? _selectedTable;
  Map<String, dynamic>? _currentTicket;
  int? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      print('[POS] Loading sections...');
      final sections = await widget.apiService.getSections();
      print('[POS] Sections loaded: ${sections.length}');

      print('[POS] Loading tables...');
      final tables = await widget.apiService.getTables();
      print('[POS] Tables loaded: ${tables.length}');

      print('[POS] Loading categories...');
      final categories = await widget.apiService.getCategories();
      print('[POS] Categories loaded: ${categories.length}');

      print('[POS] Loading products...');
      final products = await widget.apiService.getProducts();
      print('[POS] Products loaded: ${products.length}');

      setState(() {
        _sections = sections;
        _tables = tables;
        _categories = categories;
        _products = products;
        if (sections.isNotEmpty) {
          _selectedSectionId = sections[0]['id'];
        }
        if (categories.isNotEmpty) {
          _selectedCategoryId = categories[0]['id'];
        }
      });
      print('[POS] All data loaded successfully');
    } catch (e, stack) {
      print('[POS] ERROR loading data: $e');
      print('[POS] Stack: $stack');
      _showError('Veri yuklenemedi: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _selectTable(Map<String, dynamic> table) async {
    setState(() => _selectedTable = table);

    // Check if table has an open ticket
    try {
      final response = await widget.apiService.getTableTicket(table['id']);
      // Response is {"ticket": {...}} or {"ticket": null}
      if (response != null && response['ticket'] != null) {
        setState(() => _currentTicket = response['ticket']);
      } else {
        setState(() => _currentTicket = null);
      }
    } catch (e) {
      // No ticket or error
      setState(() => _currentTicket = null);
    }
  }

  Future<void> _openTicket() async {
    if (_selectedTable == null) return;

    try {
      print('[POS] Opening ticket for table ${_selectedTable!['id']} by waiter ${widget.waiter['id']}');
      final result = await widget.apiService.openTicket(
        tableId: _selectedTable!['id'],
        waiterId: widget.waiter['id'],
      );
      print('[POS] Open ticket result: $result');

      if (result['success'] == true) {
        setState(() => _currentTicket = result['ticket']);
        _showSuccess('Adisyon acildi');
      } else {
        _showError(result['error'] ?? 'Adisyon acilamadi');
      }
    } catch (e) {
      print('[POS] Open ticket error: $e');
      _showError('Adisyon acilamadi: $e');
    }
  }

  Future<void> _addProduct(Map<String, dynamic> product) async {
    if (_currentTicket == null) {
      // Open ticket first
      await _openTicket();
      if (_currentTicket == null) return;
    }

    final rawVariants = product['variants'];
    final variants = rawVariants is List ? rawVariants : [];
    final showVariants = product['show_variants_pos'] == 1 || product['show_variants_pos'] == true;
    print('[POS] Product: ${product['name']}, show_variants_pos: ${product['show_variants_pos']}, variants: ${variants.length}, rawType: ${rawVariants.runtimeType}');

    if (showVariants && variants.isNotEmpty) {
      _showVariantPopup(product, variants);
      return;
    }

    await _addProductDirect(product, product['name'],
      ((product['restaurant_price'] != null && product['restaurant_price'] != 0 ? product['restaurant_price'] : product['price']) as num).toDouble());
  }

  void _showVariantPopup(Map<String, dynamic> product, List variants) {
    final basePrice = ((product['restaurant_price'] != null && product['restaurant_price'] != 0 ? product['restaurant_price'] : product['price']) as num).toDouble();
    final productName = product['name'] as String;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(productName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              // Ana porsiyon (base)
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[600],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _addProductDirect(product, productName, basePrice);
                  },
                  child: Text('1 Porsiyon  -  ₺${basePrice.toStringAsFixed(0)}'),
                ),
              ),
              const SizedBox(height: 8),
              // Varyantlar
              ...variants.map((v) {
                final modifier = (v['price_modifier'] as num?)?.toDouble() ?? 0;
                final variantPrice = basePrice + modifier;
                final variantName = v['name'] as String;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange[600],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _addProductDirect(product, '$productName ($variantName)', variantPrice);
                      },
                      child: Text('$variantName  -  ₺${variantPrice.toStringAsFixed(0)}'),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('İptal', style: TextStyle(fontSize: 14, color: Colors.grey)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addProductDirect(Map<String, dynamic> product, String displayName, double unitPrice) async {
    try {
      final basePrice = ((product['restaurant_price'] != null && product['restaurant_price'] != 0
          ? product['restaurant_price']
          : product['price']) as num).toDouble();
      final extrasAmount = unitPrice > basePrice ? (unitPrice - basePrice) : 0.0;
      await widget.apiService.addTicketItem(
        ticketId: _currentTicket!['id'],
        productId: product['id'],
        productName: displayName,
        unitPrice: unitPrice,
        extrasAmount: extrasAmount,
        waiterId: widget.waiter['id'],
      );

      // Refresh ticket
      final response = await widget.apiService.getTableTicket(_selectedTable!['id']);
      if (response != null && response['ticket'] != null) {
        setState(() => _currentTicket = response['ticket']);
      }
      _showSuccess('$displayName eklendi');
    } catch (e) {
      print('[POS] Error adding product: $e');
      _showError('Urun eklenemedi: $e');
    }
  }

  Future<void> _closeTicket(String paymentMethod) async {
    if (_currentTicket == null) return;

    try {
      // Ticket'i yazdir (kapatmadan once)
      if (widget.printerService.isConfigured) {
        final ticketToPrint = Map<String, dynamic>.from(_currentTicket!);
        ticketToPrint['payment_method'] = paymentMethod;
        ticketToPrint['table_name'] = _selectedTable?['table_number'] ?? 'Masa ${_selectedTable?['id']}';
        await widget.printerService.printTicket(ticketToPrint);
      }

      await widget.apiService.closeTicket(
        ticketId: _currentTicket!['id'],
        paymentMethod: paymentMethod,
        waiterId: widget.waiter['id'],
      );

      setState(() {
        _currentTicket = null;
        _selectedTable = null;
      });
      _showSuccess('Hesap kapatildi');
      _loadData(); // Refresh tables
    } catch (e) {
      _showError('Hesap kapatilamadi');
    }
  }

  Future<void> _printTicket() async {
    if (_currentTicket == null) {
      _showError('Yazdirilacak adisyon yok');
      return;
    }

    if (!widget.printerService.isConfigured) {
      _showError('Yazici ayarlanmamis. Ayarlar\'dan yazici ekleyin.');
      return;
    }

    final ticketToPrint = Map<String, dynamic>.from(_currentTicket!);
    ticketToPrint['table_name'] = _selectedTable?['table_number'] ?? 'Masa ${_selectedTable?['id']}';
    ticketToPrint['waiter_name'] = widget.waiter['name'];

    final success = await widget.printerService.printTicket(ticketToPrint);
    if (success) {
      _showSuccess('Fis yazdirildi');
    } else {
      _showError('Yazici hatasi');
    }
  }

  /// Mutfağa gönder - yazıcı gruplarına göre ürünleri ilgili yazıcılara gönderir
  Future<void> _sendToKitchen() async {
    if (_currentTicket == null) {
      _showError('Adisyon yok');
      return;
    }

    try {
      // 11 May 2026: dry_run=true — backend printed=1 SET ETMEZ.
      // Yazici basari sonrasi mark-items-printed (zaten asagida cagriliyor),
      // fail durumunda unmark/reportPrintFailed.
      final result = await widget.apiService.printKitchen(
        ticketId: _currentTicket!['id'],
        waiterId: widget.waiter['id'],
        dryRun: true,
      );

      if (result['success'] != true) {
        _showError(result['error'] ?? 'Mutfak fisi alinamadi');
        return;
      }

      final items = result['items'] as List? ?? [];
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticket = result['ticket'] as Map<String, dynamic>? ?? _currentTicket!;

      if (items.isEmpty) {
        _showSuccess('Yazdirilacak yeni urun yok');
        return;
      }

      // Her yazıcı grubuna ayrı fiş gönder
      int successCount = 0;
      int failCount = 0;
      // Sunucuda printed=1 yapilacak item ID'leri ve panel_print_jobs ID'leri.
      // Mutfak yazicilarinin basari/fail durumu telemetri tablosuna yazilir.
      // Ozet fis (type=summary) basarisi printed=1 tetiklemez (mutfak'la ayni item'i tekrarlar).
      final Set<int> printedItemIds = <int>{};
      final Set<int> printedJobIds = <int>{};

      int? _toInt(dynamic x) {
        if (x is int) return x;
        if (x is String) return int.tryParse(x);
        if (x is double) return x.toInt();
        return null;
      }

      final Map<String, List<Map<String, dynamic>>> byIpMap = {};
      for (final g in printerGroups) {
        final group = (g as Map).cast<String, dynamic>();
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty) continue;
        final ip = (group['printer_ip'] as String?)?.trim();
        final key = (ip == null || ip.isEmpty) ? '__default__' : ip;
        byIpMap.putIfAbsent(key, () => []).add(group);
      }

      final perBucket = await Future.wait(byIpMap.values.map((sameIpGroups) async {
        final out = <Map<String, dynamic>>[];
        for (final group in sameIpGroups) {
          final printerIp = group['printer_ip'] as String?;
          final printerPort = group['printer_port'] as int? ?? 9100;
          final groupItems = group['items'] as List? ?? [];
          bool ok = false;
          String? failReason;
          try {
            if (printerIp != null && printerIp.isNotEmpty) {
              ok = await widget.printerService.printKitchenReceiptToIp(
                ticket: ticket,
                items: groupItems,
                ip: printerIp,
                port: printerPort,
              );
              if (!ok) failReason = 'TCP/print failed at $printerIp:$printerPort';
            } else {
              ok = await widget.printerService.printKitchenReceipt(
                ticket: ticket,
                items: groupItems,
              );
              if (!ok) failReason = 'Local printer failed';
            }
          } catch (e) {
            ok = false;
            failReason = e.toString();
          }
          out.add({'group': group, 'ok': ok, 'failReason': failReason});
        }
        return out;
      }));

      for (final bucket in perBucket) {
        for (final r in bucket) {
          final group = r['group'] as Map<String, dynamic>;
          final success = r['ok'] as bool;
          final failReason = r['failReason'] as String?;
          final groupItems = group['items'] as List? ?? [];
          final printerName = group['printer_name'] as String? ?? 'Varsayilan';
          final groupType = group['type'] as String? ?? 'kitchen';
          final jobId = _toInt(group['job_id']);

          if (success) {
            successCount += groupItems.length;
            print('[POS] $printerName yazicisina ${groupItems.length} urun gonderildi');
            if (groupType == 'kitchen') {
              // Sadece mutfak grubu basarisi printed=1 ve job_id 'printed' yapma yetkisi verir
              for (final it in groupItems) {
                final id = _toInt((it is Map) ? it['id'] : null);
                if (id != null) printedItemIds.add(id);
              }
              if (jobId != null) printedJobIds.add(jobId);
            }
          } else {
            failCount += groupItems.length;
            print('[POS] $printerName yazicisina gonderilemedi: $failReason');
            // Telemetri: fail bildir
            if (jobId != null) {
              widget.apiService.reportPrintFailed(
                ticketId: _currentTicket!['id'],
                jobId: jobId,
                error: failReason ?? 'unknown',
              ); // fire-and-forget; UI'yi bloklama
            }
          }
        }
      }

      // printerGroups boşsa ama items varsa, fallback olarak local yazıcıya gönder
      if (printerGroups.isEmpty && items.isNotEmpty) {
        final success = await widget.printerService.printKitchenReceipt(
          ticket: ticket,
          items: items,
        );
        if (success) {
          successCount = items.length;
          for (final it in items) {
            final id = _toInt((it is Map) ? it['id'] : null);
            if (id != null) printedItemIds.add(id);
          }
        } else {
          failCount = items.length;
        }
      }

      // Yaziciya basariyla bastiktan sonra sunucuda printed=1 ve telemetri'de 'printed' isaretle.
      if (printedItemIds.isNotEmpty || printedJobIds.isNotEmpty) {
        final marked = await widget.apiService.markItemsPrinted(
          ticketId: _currentTicket!['id'],
          itemIds: printedItemIds.toList(),
          jobIds: printedJobIds.isEmpty ? null : printedJobIds.toList(),
        );
        if (!marked) {
          print('[POS] mark-items-printed basarisiz; sunucuda printed=0 kalmis olabilir');
        }
      }

      // Sonucu göster ve masalar ekranına dön
      if (failCount == 0 && successCount > 0) {
        if (mounted) Navigator.pop(context);
      } else if (successCount > 0) {
        _showError('$successCount urun gonderildi, $failCount urun gonderilemedi');
      } else {
        _showError('Yazici hatasi - hicbir urun gonderilemedi');
      }
    } catch (e) {
      print('[POS] Mutfaga gonderme hatasi: $e');
      _showError('Hata: $e');
    }
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cikis Yap'),
        content: const Text('Oturumu kapatmak istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () async {
              await widget.storageService.clearWaiterSession();
              widget.apiService.clearWaiterToken();
              if (mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => PinLoginScreen(
                      storageService: widget.storageService,
                      apiService: widget.apiService,
                      printerService: widget.printerService,
                    ),
                  ),
                );
              }
            },
            child: const Text('Cikis', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Provider.of<ThemeProvider>(context, listen: false).primaryColor),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Row(
        children: [
          // Left sidebar - Tables
          Container(
            width: 280,
            color: Colors.white,
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                  child: Row(
                    children: [
                      const Icon(Icons.restaurant, color: Colors.white),
                      const SizedBox(width: 8),
                      const Text(
                        'SyncResto POS',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: _logout,
                        icon: const Icon(Icons.logout, color: Colors.white),
                        tooltip: 'Cikis Yap',
                      ),
                    ],
                  ),
                ),

                // Waiter info
                Container(
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFFEFF6FF),
                  child: Row(
                    children: [
                      Icon(Icons.person, color: Provider.of<ThemeProvider>(context, listen: false).primaryColor, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        widget.waiter['name'] ?? 'Garson',
                        style: TextStyle(
                          color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                // Section tabs
                SizedBox(
                  height: 50,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    itemCount: _sections.length,
                    itemBuilder: (context, index) {
                      final section = _sections[index];
                      final isSelected = section['id'] == _selectedSectionId;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(section['name']),
                          selected: isSelected,
                          onSelected: (_) {
                            setState(() => _selectedSectionId = section['id']);
                          },
                          selectedColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : Colors.black,
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Tables grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 1,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _tables
                        .where((t) => t['section_id'] == _selectedSectionId)
                        .length,
                    itemBuilder: (context, index) {
                      final filteredTables = _tables
                          .where((t) => t['section_id'] == _selectedSectionId)
                          .toList();
                      final table = filteredTables[index];
                      final isSelected = _selectedTable?['id'] == table['id'];
                      final hasTicket = table['status'] == 'occupied';

                      return GestureDetector(
                        onTap: () => _selectTable(table),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Provider.of<ThemeProvider>(context, listen: false).primaryColor
                                : hasTicket
                                    ? const Color(0xFFFEF3C7)
                                    : const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? Provider.of<ThemeProvider>(context, listen: false).primaryColor
                                  : hasTicket
                                      ? const Color(0xFFF59E0B)
                                      : const Color(0xFFE5E7EB),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.table_restaurant,
                                  color: isSelected
                                      ? Colors.white
                                      : hasTicket
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF6B7280),
                                  size: 28,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  table['table_number'] ?? 'M${table['id']}',
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.black,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // Main content - Products
          Expanded(
            child: Column(
              children: [
                // Category tabs
                Container(
                  height: 60,
                  color: Colors.white,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: _categories.length,
                    itemBuilder: (context, index) {
                      final category = _categories[index];
                      final isSelected = category['id'] == _selectedCategoryId;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${category['icon'] ?? ''} ${category['name']}'),
                          selected: isSelected,
                          onSelected: (_) {
                            setState(() => _selectedCategoryId = category['id']);
                          },
                          selectedColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : Colors.black,
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Products grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      childAspectRatio: 1,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: _products
                        .where((p) =>
                            p['category_id'] == _selectedCategoryId &&
                            p['is_active'] == 1)
                        .length,
                    itemBuilder: (context, index) {
                      final filteredProducts = _products
                          .where((p) =>
                              p['category_id'] == _selectedCategoryId &&
                              p['is_active'] == 1)
                          .toList();
                      final product = filteredProducts[index];

                      final isDisabled = _selectedTable == null;
                      return Opacity(
                        opacity: isDisabled ? 0.5 : 1.0,
                        child: GestureDetector(
                          onTap: isDisabled
                              ? () => _showError('Once masa seciniz')
                              : () => _addProduct(product),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isDisabled ? Colors.grey[100] : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (product['image'] != null)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    widget.apiService.getImageUrl(product['image']?.toString()),
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.fastfood,
                                      size: 40,
                                      color: Color(0xFF9CA3AF),
                                    ),
                                  ),
                                )
                              else
                                const Icon(
                                  Icons.fastfood,
                                  size: 40,
                                  color: Color(0xFF9CA3AF),
                                ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  product['name'],
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${(product['restaurant_price'] != null && product['restaurant_price'] != 0) ? product['restaurant_price'] : product['price']} TL',
                                style: TextStyle(
                                  color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // Right sidebar - Ticket
          Container(
            width: 320,
            color: Colors.white,
            child: Column(
              children: [
                // Ticket header
                Container(
                  padding: const EdgeInsets.all(16),
                  color: const Color(0xFF1F2937),
                  child: Row(
                    children: [
                      const Icon(Icons.receipt_long, color: Colors.white),
                      const SizedBox(width: 8),
                      Text(
                        _selectedTable != null
                            ? 'Masa: ${_selectedTable!['table_number'] ?? _selectedTable!['id']}'
                            : 'Masa Seciniz',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),

                // Ticket items
                Expanded(
                  child: _currentTicket != null
                      ? ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: (_currentTicket!['items'] as List?)?.length ?? 0,
                          itemBuilder: (context, index) {
                            final items = _currentTicket!['items'] as List;
                            final item = items[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF9FAFB),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${item['quantity']}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item['product_name'],
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        if (item['notes'] != null)
                                          Text(
                                            item['notes'],
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '${((item['unit_price'] as num) * (item['quantity'] as num)).toStringAsFixed(2)} TL',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )
                      : Center(
                          child: Text(
                            _selectedTable != null
                                ? 'Adisyon bos'
                                : 'Masa seciniz',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 16,
                            ),
                          ),
                        ),
                ),

                // Total and actions
                if (_currentTicket != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      border: Border(
                        top: BorderSide(color: Color(0xFFE5E7EB)),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'TOPLAM',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                            Text(
                              '${_currentTicket!['total'] ?? 0} TL',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 24,
                                color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Mutfağa Gönder butonu (öncelikli)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _sendToKitchen,
                            icon: const Icon(Icons.restaurant),
                            label: const Text('Mutfaga Gonder'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Fiş Yazdır butonu
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _printTicket,
                            icon: const Icon(Icons.print),
                            label: const Text('Fis Yazdir'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF6B7280),
                              side: const BorderSide(color: Color(0xFFE5E7EB)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _closeTicket('cash'),
                                icon: const Icon(Icons.money),
                                label: const Text('Nakit'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _closeTicket('credit_card'),
                                icon: const Icon(Icons.credit_card),
                                label: const Text('Kart'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF3B82F6),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else if (_selectedTable != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _openTicket,
                        icon: const Icon(Icons.add),
                        label: const Text('Adisyon Ac'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
