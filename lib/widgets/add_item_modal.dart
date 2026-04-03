import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/image_cache_service.dart';
import '../providers/theme_provider.dart';
import 'product_detail_modal.dart';

class AddItemModal extends StatefulWidget {
  final ApiService apiService;
  final int ticketId;
  final int waiterId;
  final VoidCallback onItemAdded;
  final VoidCallback onClose;
  final bool showProductImages;
  final int tableId;

  const AddItemModal({
    super.key,
    required this.apiService,
    required this.ticketId,
    required this.waiterId,
    required this.onItemAdded,
    required this.onClose,
    this.showProductImages = true,
    this.tableId = 0,
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

      // Ticket items'ı yükle
      await _loadTicketItems();
    } catch (e) {
      if (mounted) _showError('Veri yuklenemedi: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTicketItems() async {
    try {
      if (widget.tableId > 0) {
        final ticketData = await widget.apiService.getTableTicket(widget.tableId);
        if (ticketData != null && mounted) {
          final ticket = ticketData['ticket'] as Map<String, dynamic>?;
          if (ticket != null) {
            setState(() {
              _ticketItems = (ticket['items'] as List?) ?? [];
            });
          }
        }
      }
    } catch (e) {
      print('[AddItemModal] Ticket items yüklenemedi: $e');
    }
  }

  void _filterProducts() {
    setState(() {
      _filteredProducts = _products.where((p) {
        if (_selectedCategoryId != null) {
          final productCategoryId = _safeInt(p['category_id']);
          if (productCategoryId != _selectedCategoryId) return false;
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

  Future<void> _selectProduct(Map<String, dynamic> product) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ProductDetailModal(
        apiService: widget.apiService,
        product: product,
        ticketId: widget.ticketId,
        waiterId: widget.waiterId,
        onItemAdded: () {
          widget.onItemAdded();
          _loadTicketItems();
        },
        onClose: () {
          Navigator.pop(context);
          widget.onClose();
        },
        onCloseAndReturn: () {
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
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
      child: Container(
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
                        // SOL: Kategoriler
                        _buildCategoriesPanel(theme),
                        // ORTA: Ürünler
                        Expanded(
                          flex: 3,
                          child: _buildProductsPanel(theme),
                        ),
                        // SAĞ: Eklenen ürünler
                        _buildTicketPanel(theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeProvider theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.primaryColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.add_circle, color: Colors.white, size: 24),
          const SizedBox(width: 10),
          const Text(
            'Urun Ekle',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 16),
          // Arama
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearch,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Urun ara...',
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
              child: const Icon(Icons.close, color: Colors.white, size: 24),
            ),
          ),
        ],
      ),
    );
  }

  // SOL PANEL: Kategoriler - dikey dikdörtgen butonlar
  Widget _buildCategoriesPanel(ThemeProvider theme) {
    return Container(
      width: 140,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(right: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        children: [
          // "Tümü" butonu
          _buildCategoryButton(theme, null, 'Tumu', Icons.apps),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                final icon = cat['icon']?.toString() ?? '';
                return _buildCategoryButton(
                  theme,
                  _safeInt(cat['id']),
                  cat['name']?.toString() ?? '',
                  null,
                  emoji: icon,
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectCategory(categoryId),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? theme.primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? theme.primaryColor : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: theme.primaryColor.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))]
              : [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 2, offset: const Offset(0, 1))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (emoji.isNotEmpty)
              Text(emoji, style: const TextStyle(fontSize: 22))
            else if (icon != null)
              Icon(icon, color: isSelected ? Colors.white : Colors.grey[700], size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[800],
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ORTA PANEL: Ürünler grid
  Widget _buildProductsPanel(ThemeProvider theme) {
    if (_filteredProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Urun bulunamadi', style: TextStyle(color: Colors.grey[500], fontSize: 18)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Ekran genişliğine göre sütun sayısını hesapla
        final crossAxisCount = (constraints.maxWidth / 140).floor().clamp(2, 6);

        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: widget.showProductImages ? 0.85 : 1.8,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: _filteredProducts.length,
          itemBuilder: (context, index) {
            final product = _filteredProducts[index];
            return _buildProductCard(product, theme);
          },
        );
      },
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product, ThemeProvider theme) {
    final isOutOfStock = product['is_out_of_stock'] == 1 || product['is_out_of_stock'] == true;
    final hasImage = product['image'] != null && product['image'].toString().isNotEmpty;

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isOutOfStock ? null : () => _selectProduct(product),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey[200]!),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showProductImages)
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(10),
                      topRight: Radius.circular(10),
                    ),
                    child: hasImage ? _buildProductImage(product) : _buildPlaceholder(product),
                  ),
                ),
              Expanded(
                flex: widget.showProductImages ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: widget.showProductImages ? MainAxisAlignment.start : MainAxisAlignment.center,
                    children: [
                      Text(
                        product['name']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: const Color(0xFF1f2937),
                        ),
                      ),
                      if (widget.showProductImages) const Spacer(),
                      if (!widget.showProductImages) const SizedBox(height: 4),
                      Text(
                        '${product['price'] ?? 0} TL',
                        style: TextStyle(
                          color: theme.primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
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
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
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

  // SAĞ PANEL: Eklenen ürünler listesi
  Widget _buildTicketPanel(ThemeProvider theme) {
    final activeItems = _ticketItems.where((item) => item['status'] != 'cancelled').toList();

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Colors.grey[300]!)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Başlık
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long, size: 18, color: theme.primaryColor),
                const SizedBox(width: 8),
                Text(
                  'Adisyon',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${activeItems.length}',
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
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
                        Icon(Icons.restaurant_menu, size: 40, color: Colors.grey[300]),
                        const SizedBox(height: 8),
                        Text(
                          'Henuz urun eklenmedi',
                          style: TextStyle(color: Colors.grey[400], fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: activeItems.length,
                    itemBuilder: (context, index) {
                      final item = activeItems[index];
                      return _buildTicketItemRow(item, theme);
                    },
                  ),
          ),

          // Toplam
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(top: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'TOPLAM',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
                Text(
                  '${_ticketTotal.toStringAsFixed(2)} TL',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: theme.primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketItemRow(Map<String, dynamic> item, ThemeProvider theme) {
    final quantity = _safeInt(item['quantity']) ?? 1;
    final unitPrice = _safeDouble(item['unit_price']);
    final total = unitPrice * quantity;
    final notes = item['notes'] as String?;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey[100]!)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Miktar
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: theme.primaryColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                '$quantity',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Ürün adı
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['product_name']?.toString() ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1F2937)),
                ),
                if (notes != null && notes.isNotEmpty)
                  Text(
                    notes,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // Fiyat
          Text(
            '${total.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
          ),
        ],
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
      } catch (e) {
        // Cache hatası
      }
    }

    return FutureBuilder<String?>(
      future: _imageCache.downloadAndCache(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey[200],
            child: Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
              ),
            ),
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
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 36))),
    );
  }
}
