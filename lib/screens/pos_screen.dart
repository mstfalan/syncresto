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

    try {
      await widget.apiService.addTicketItem(
        ticketId: _currentTicket!['id'],
        productId: product['id'],
        productName: product['name'],
        unitPrice: (product['price'] as num).toDouble(),
        waiterId: widget.waiter['id'],
      );

      // Refresh ticket
      final response = await widget.apiService.getTableTicket(_selectedTable!['id']);
      if (response != null && response['ticket'] != null) {
        setState(() => _currentTicket = response['ticket']);
      }
      _showSuccess('${product['name']} eklendi');
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

  /// Mutfağa gönder - sadece yazdırılmamış ürünleri yazıcıya gönderir
  Future<void> _sendToKitchen() async {
    if (_currentTicket == null) {
      _showError('Adisyon yok');
      return;
    }

    if (!widget.printerService.isConfigured) {
      _showError('Yazici ayarlanmamis. Ayarlar\'dan yazici ekleyin.');
      return;
    }

    try {
      // API'den yazdırılmamış ürünleri al ve printed=1 yap
      final result = await widget.apiService.printKitchen(
        ticketId: _currentTicket!['id'],
        waiterId: widget.waiter['id'],
      );

      if (result['success'] != true) {
        _showError(result['error'] ?? 'Mutfak fisi alinamadi');
        return;
      }

      final items = result['items'] as List? ?? [];
      final ticket = result['ticket'] as Map<String, dynamic>? ?? _currentTicket!;

      if (items.isEmpty) {
        _showSuccess('Yazdirilacak yeni urun yok');
        return;
      }

      // Yazıcıya gönder
      final success = await widget.printerService.printKitchenReceipt(
        ticket: ticket,
        items: items,
      );

      if (success) {
        _showSuccess('Mutfaga gonderildi (${items.length} urun)');
        // Ticket'ı yenile (items'daki printed flag güncellendi)
        final response = await widget.apiService.getTableTicket(_selectedTable!['id']);
        if (response != null && response['ticket'] != null) {
          setState(() => _currentTicket = response['ticket']);
        }
      } else {
        _showError('Yazici hatasi');
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
                                '${product['price']} TL',
                                style: const TextStyle(
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
