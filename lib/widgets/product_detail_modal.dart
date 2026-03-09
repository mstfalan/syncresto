import 'dart:io';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/image_cache_service.dart';

class ProductDetailModal extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> product;
  final int ticketId;
  final int waiterId;
  final VoidCallback onItemAdded;
  final VoidCallback onClose;
  final VoidCallback onCloseAndReturn;

  const ProductDetailModal({
    super.key,
    required this.apiService,
    required this.product,
    required this.ticketId,
    required this.waiterId,
    required this.onItemAdded,
    required this.onClose,
    required this.onCloseAndReturn,
  });

  @override
  State<ProductDetailModal> createState() => _ProductDetailModalState();
}

class _ProductDetailModalState extends State<ProductDetailModal> {
  int _quantity = 1;
  String _notes = '';
  double? _customPrice;
  final List<Map<String, dynamic>> _selectedExtras = [];
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  bool _isLoading = false;
  final ImageCacheService _imageCache = ImageCacheService();

  // API'den gelen ekstralar
  List<dynamic> _extras = [];

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
    // Ürün extras varsa kullan
    _extras = (widget.product['extras'] as List?) ?? [];
  }

  @override
  void dispose() {
    _notesController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  double get _basePrice => _safeDouble(widget.product['price']);

  double get _extrasTotal {
    double total = 0;
    for (var extra in _selectedExtras) {
      total += _safeDouble(extra['price']);
    }
    return total;
  }

  double get _unitPrice {
    if (_customPrice != null) return _customPrice!;
    return _basePrice + _extrasTotal;
  }

  double get _totalPrice => _unitPrice * _quantity;

  String _buildNotes() {
    List<String> notes = [];

    // Seçilen ekstralar
    for (var extra in _selectedExtras) {
      notes.add('+${extra['name']}');
    }

    // Özel not
    if (_notes.isNotEmpty) {
      notes.add(_notes);
    }

    return notes.join(', ');
  }

  void _toggleExtra(Map<String, dynamic> extra) {
    setState(() {
      final index = _selectedExtras.indexWhere((e) => e['id'] == extra['id']);
      if (index >= 0) {
        _selectedExtras.removeAt(index);
      } else {
        _selectedExtras.add(extra);
      }
    });
  }

  bool _isExtraSelected(Map<String, dynamic> extra) {
    return _selectedExtras.any((e) => e['id'] == extra['id']);
  }

  Future<void> _addItem({bool closeAfter = false}) async {
    setState(() => _isLoading = true);

    try {
      final productId = _safeInt(widget.product['id']);
      if (productId == null) throw Exception('Product ID is null');
      await widget.apiService.addTicketItem(
        ticketId: widget.ticketId,
        productId: productId,
        productName: widget.product['name']?.toString() ?? '',
        unitPrice: _unitPrice,
        quantity: _quantity,
        notes: _buildNotes().isNotEmpty ? _buildNotes() : null,
        waiterId: widget.waiterId,
      );

      widget.onItemAdded();

      if (closeAfter) {
        widget.onClose();
      } else {
        widget.onCloseAndReturn();
      }
    } catch (e) {
      _showError('Urun eklenemedi: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.product['image'] != null &&
        widget.product['image'].toString().isNotEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.8,
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // Header
            _buildHeader(),

            // Content
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left: Image
                  Expanded(
                    flex: 2,
                    child: _buildImageSection(hasImage),
                  ),

                  // Center: Info & Options
                  Expanded(
                    flex: 3,
                    child: _buildOptionsSection(),
                  ),

                  // Right: Actions
                  Expanded(
                    flex: 2,
                    child: _buildActionsSection(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF16A34A),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.restaurant_menu, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.product['name'] ?? 'Urun',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onCloseAndReturn,
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildImageSection(bool hasImage) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Image
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: hasImage
                    ? _buildProductImage()
                    : _buildPlaceholder(),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Price
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${_basePrice.toStringAsFixed(2)} TL',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Description
          if (widget.product['description'] != null)
            Text(
              widget.product['description'],
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _buildProductImage() {
    final imagePath = widget.product['image']?.toString() ?? '';
    final imageUrl = 'https://greenchef.com.tr$imagePath';

    // Önce cache'den dene
    try {
      final cachePath = _imageCache.getCachePath(imageUrl);
      if (cachePath.isNotEmpty) {
        final cacheFile = File(cachePath);
        if (cacheFile.existsSync()) {
          return Image.file(
            cacheFile,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildPlaceholder(),
          );
        }
      }
    } catch (e) {
      // Cache hatası - network'e düş
    }

    // Cache'de yoksa FutureBuilder ile indir
    return FutureBuilder<String?>(
      future: _imageCache.downloadAndCache(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey[200],
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF16A34A)),
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          final cacheFile = File(snapshot.data!);
          if (cacheFile.existsSync()) {
            return Image.file(
              cacheFile,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildPlaceholder(),
            );
          }
        }

        return _buildPlaceholder();
      },
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[100],
      child: const Center(
        child: Text('🍽️', style: TextStyle(fontSize: 80)),
      ),
    );
  }

  Widget _buildOptionsSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Colors.grey[200]!),
          right: BorderSide(color: Colors.grey[200]!),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Ekstralar (API'den)
            if (_extras.isNotEmpty) ...[
              _buildSectionTitle('Ekstralar'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _extras.map((extra) {
                  final isSelected = _isExtraSelected(extra);
                  final price = _safeDouble(extra['price']);
                  return _buildOptionChip(
                    label: price > 0
                        ? '${extra['name']} (+${price.toStringAsFixed(0)} TL)'
                        : extra['name'],
                    isSelected: isSelected,
                    onTap: () => _toggleExtra(extra),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
            ],

            // Not
            _buildSectionTitle('Ozel Not'),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              onChanged: (value) => setState(() => _notes = value),
              style: const TextStyle(color: Color(0xFF1F2937)),
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Mutfak icin not ekleyin...',
                hintStyle: TextStyle(color: Colors.grey[500]),
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF16A34A), width: 2),
                ),
              ),
            ),

            if (_extras.isEmpty) ...[
              const SizedBox(height: 32),
              Center(
                child: Column(
                  children: [
                    Icon(Icons.info_outline, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 8),
                    Text(
                      'Bu urun icin ekstra secenegi bulunmuyor',
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Color(0xFF1F2937),
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildOptionChip({
    required String label,
    required bool isSelected,
    Color color = const Color(0xFF16A34A),
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? color : Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? color : Colors.grey[300]!,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? Colors.white : Colors.grey[500],
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[700],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionsSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: const BorderRadius.only(
          bottomRight: Radius.circular(16),
        ),
      ),
      child: Column(
        children: [
          // Adet seçimi
          _buildSectionTitle('Adet'),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildQuantityButton(
                icon: Icons.remove,
                onTap: () {
                  if (_quantity > 1) {
                    setState(() => _quantity--);
                  }
                },
              ),
              Container(
                width: 60,
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.symmetric(
                    horizontal: BorderSide(color: Colors.grey[300]!),
                  ),
                ),
                child: Text(
                  '$_quantity',
                  style: const TextStyle(
                    color: Color(0xFF1F2937),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _buildQuantityButton(
                icon: Icons.add,
                onTap: () => setState(() => _quantity++),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Özel Fiyat
          _buildSectionTitle('Ozel Fiyat (Opsiyonel)'),
          const SizedBox(height: 8),
          TextField(
            controller: _priceController,
            onChanged: (value) {
              setState(() {
                _customPrice = double.tryParse(value);
              });
            },
            style: const TextStyle(color: Color(0xFF1F2937)),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: '${_basePrice.toStringAsFixed(2)} TL',
              hintStyle: TextStyle(color: Colors.grey[500]),
              suffixText: 'TL',
              suffixStyle: const TextStyle(color: Color(0xFF1F2937)),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF16A34A), width: 2),
              ),
            ),
          ),

          const Spacer(),

          // Toplam fiyat
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF16A34A)),
            ),
            child: Column(
              children: [
                Text(
                  'Toplam',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_totalPrice.toStringAsFixed(2)} TL',
                  style: const TextStyle(
                    color: Color(0xFF16A34A),
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_quantity > 1)
                  Text(
                    '($_quantity x ${_unitPrice.toStringAsFixed(2)} TL)',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Ekle butonu
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : () => _addItem(closeAfter: false),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Ekle',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),

          const SizedBox(height: 8),

          // Ekle & Kapat butonu
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _isLoading ? null : () => _addItem(closeAfter: true),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF16A34A),
                side: const BorderSide(color: Color(0xFF16A34A)),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Ekle & Kapat',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuantityButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF16A34A),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
