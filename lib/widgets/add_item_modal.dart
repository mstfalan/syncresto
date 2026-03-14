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

  const AddItemModal({
    super.key,
    required this.apiService,
    required this.ticketId,
    required this.waiterId,
    required this.onItemAdded,
    required this.onClose,
    this.showProductImages = true,
  });

  @override
  State<AddItemModal> createState() => _AddItemModalState();
}

class _AddItemModalState extends State<AddItemModal> {
  List<dynamic> _categories = [];
  List<dynamic> _products = [];
  List<dynamic> _filteredProducts = [];
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    print('[AddItemModal] _init başladı');
    // Önce image cache'i başlat
    try {
      await _imageCache.init();
      print('[AddItemModal] ImageCache init başarılı');
      if (mounted) {
        setState(() => _imageCacheReady = true);
      }
    } catch (e) {
      print('[AddItemModal] ImageCache init hatası: $e');
    }

    // Sonra verileri yükle
    await _loadData();
    print('[AddItemModal] _init tamamlandı');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    print('[AddItemModal] _loadData başladı');
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      print('[AddItemModal] Kategoriler yükleniyor...');
      final categories = await widget.apiService.getCategories();
      print('[AddItemModal] Kategoriler yüklendi: ${categories.length}');

      print('[AddItemModal] Ürünler yükleniyor...');
      final products = await widget.apiService.getProducts();
      print('[AddItemModal] Ürünler yüklendi: ${products.length}');

      if (!mounted) return;
      setState(() {
        _categories = categories;
        _products = products;
        _filteredProducts = products;
      });
      print('[AddItemModal] State güncellendi');
    } catch (e) {
      print('[AddItemModal] _loadData hatası: $e');
      if (mounted) _showError('Veri yuklenemedi: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterProducts() {
    setState(() {
      _filteredProducts = _products.where((p) {
        // Category filter
        if (_selectedCategoryId != null) {
          final productCategoryId = _safeInt(p['category_id']);
          if (productCategoryId != _selectedCategoryId) {
            return false;
          }
        }

        // Search filter
        if (_searchQuery.isNotEmpty) {
          final name = (p['name'] ?? '').toString().toLowerCase();
          final desc = (p['description'] ?? '').toString().toLowerCase();
          if (!name.contains(_searchQuery) && !desc.contains(_searchQuery)) {
            return false;
          }
        }

        // Only active products
        final isActive = p['is_active'] == 1 || p['is_active'] == true;
        if (!isActive) return false;

        return true;
      }).toList();
    });
  }

  void _selectCategory(int? categoryId) {
    setState(() {
      _selectedCategoryId = categoryId;
    });
    _filterProducts();
  }

  void _onSearch(String query) {
    _searchQuery = query.toLowerCase().trim();
    _filterProducts();
  }

  Future<void> _selectProduct(Map<String, dynamic> product) async {
    // Open product detail modal
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
        },
        onClose: () {
          // Ekle & Kapat - hem product detail hem add item modal'i kapat
          Navigator.pop(context); // Product detail modal'i kapat
          widget.onClose(); // Add item modal'i kapat (ticket modal'a don)
        },
        onCloseAndReturn: () {
          Navigator.pop(context);
          // Stay in add item modal
        },
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        decoration: const BoxDecoration(
          color: Colors.white,
        ),
        child: Column(
          children: [
            // Header
            _buildHeader(),

            // Search
            _buildSearch(),

            // Categories (Wrap - flows to next line)
            _buildCategories(),

            // Products grid
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: Provider.of<ThemeProvider>(context, listen: false).primaryColor))
                  : _buildProductsGrid(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.add_circle, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          const Text(
            'Urun Ekle',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.grey[50],
      child: TextField(
        controller: _searchController,
        onChanged: _onSearch,
        style: const TextStyle(color: Color(0xFF1F2937)),
        decoration: InputDecoration(
          hintText: 'Urun ara...',
          hintStyle: TextStyle(color: Colors.grey[500]),
          prefixIcon: Icon(Icons.search, color: Colors.grey[500]),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey[300]!),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey[300]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Provider.of<ThemeProvider>(context, listen: false).primaryColor, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildCategories() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      color: Colors.grey[50],
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          // All button
          _buildCategoryChip(null, 'Tumu'),
          // Category buttons
          ..._categories.map((cat) => _buildCategoryChip(
                _safeInt(cat['id']),
                '${cat['icon'] ?? ''} ${cat['name'] ?? ''}',
              )),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(int? categoryId, String label) {
    final isSelected = _selectedCategoryId == categoryId;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _selectCategory(categoryId),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.grey[300]!,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.grey[700],
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductsGrid() {
    if (_filteredProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'Urun bulunamadi',
              style: TextStyle(color: Colors.grey[500], fontSize: 18),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.showProductImages ? 5 : 6,
        childAspectRatio: widget.showProductImages ? 0.8 : 2.0,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _filteredProducts.length,
      itemBuilder: (context, index) {
        final product = _filteredProducts[index];
        return _buildProductCard(product);
      },
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product) {
    final isOutOfStock = product['is_out_of_stock'] == 1 || product['is_out_of_stock'] == true;
    final hasImage = product['image'] != null && product['image'].toString().isNotEmpty;

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isOutOfStock ? null : () => _selectProduct(product),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Image (sadece showProductImages true ise göster)
                if (widget.showProductImages)
                  Expanded(
                    flex: 3,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12),
                      ),
                      child: hasImage
                          ? _buildProductImage(product)
                          : _buildPlaceholder(product),
                    ),
                  ),

                // Info
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
                          maxLines: widget.showProductImages ? 2 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: widget.showProductImages ? 13 : 14,
                            color: const Color(0xFF1f2937),
                          ),
                        ),
                        if (widget.showProductImages) const Spacer(),
                        if (!widget.showProductImages) const SizedBox(height: 4),
                        Text(
                          '${product['price'] ?? 0} TL',
                          style: TextStyle(
                            color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                            fontWeight: FontWeight.bold,
                            fontSize: widget.showProductImages ? 15 : 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Out of stock badge
                if (isOutOfStock)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'Tukendi',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductImage(Map<String, dynamic> product) {
    final imagePath = product['image']?.toString() ?? '';
    if (imagePath.isEmpty) {
      return _buildPlaceholder(product);
    }

    final imageUrl = widget.apiService.getImageUrl(imagePath);

    // Cache hazır mı ve dosya var mı kontrol et
    if (_imageCacheReady) {
      try {
        final cachePath = _imageCache.getCachePath(imageUrl);
        if (cachePath.isNotEmpty) {
          final cacheFile = File(cachePath);
          if (cacheFile.existsSync()) {
            return Image.file(
              cacheFile,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildPlaceholder(product),
            );
          }
        }
      } catch (e) {
        // Cache hatası - network'e düş
      }
    }

    // Cache'de yoksa FutureBuilder ile indir ve göster
    return FutureBuilder<String?>(
      future: _imageCache.downloadAndCache(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey[200],
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: Provider.of<ThemeProvider>(context, listen: false).primaryColor),
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          final cacheFile = File(snapshot.data!);
          if (cacheFile.existsSync()) {
            return Image.file(
              cacheFile,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildPlaceholder(product),
            );
          }
        }

        // İndirme başarısız - placeholder göster
        return _buildPlaceholder(product);
      },
    );
  }

  Widget _buildPlaceholder(Map<String, dynamic> product) {
    final emoji = product['category_icon'] ?? '🍽️';
    return Container(
      color: Colors.grey[100],
      child: Center(
        child: Text(emoji, style: const TextStyle(fontSize: 40)),
      ),
    );
  }
}
