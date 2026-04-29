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
  Map<String, dynamic>? _ticketInfo;
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
      // Önce cache'ten yükle (anında), sonra API'den güncelle (arka plan)
      final cachedCats = await widget.apiService.getCachedCategories();
      final cachedProds = await widget.apiService.getCachedProducts();
      if (mounted && cachedCats.isNotEmpty) {
        setState(() {
          _categories = cachedCats;
          _products = cachedProds;
          _filteredProducts = cachedProds;
          _isLoading = false;
        });
      }
      // Ticket items yükle
      await _loadTicketItems();
      // API'den taze veri (arka planda)
      widget.apiService.getCategories().then((cats) {
        if (mounted && cats.isNotEmpty) setState(() => _categories = cats);
      }).catchError((_) {});
      widget.apiService.getProducts().then((prods) {
        if (mounted && prods.isNotEmpty) setState(() { _products = prods; _filteredProducts = prods; });
      }).catchError((_) {});
    } catch (e) {
      // Cache de yoksa API'den dene
      try {
        final categories = await widget.apiService.getCategories();
        final products = await widget.apiService.getProducts();
        if (!mounted) return;
        setState(() { _categories = categories; _products = products; _filteredProducts = products; });
        await _loadTicketItems();
      } catch (e2) {
        if (mounted) _showError('Veri yuklenemedi: $e2');
      }
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
            print('[AddItemModal] items loaded: ${items.length}, discount: ${ticket['discount']}, discount_type: ${ticket['discount_type']}');
            setState(() {
              _ticketItems = items;
              _ticketInfo = ticket;
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

  /// Ürüne tıkla → direkt sepete ekle (varyant secimi sepetten "Varyant" butonu ile yapilir)
  Future<void> _addProductDirectly(Map<String, dynamic> product) async {
    _addProductWithPrice(product, product['name']?.toString() ?? '',
      _safeDouble((product['restaurant_price'] != null && product['restaurant_price'] != 0) ? product['restaurant_price'] : product['price']));
  }

  /// Secili sepet item'inin urunu icin varyant kayitlari var mi?
  List _variantsForSelectedItem() {
    if (_selectedItemIndex == null) return const [];
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (_selectedItemIndex! >= activeItems.length) return const [];
    final item = activeItems[_selectedItemIndex!];
    final productId = item['product_id'];
    if (productId == null) return const [];
    final prod = _products.where((p) => p['id'] == productId).firstOrNull;
    if (prod == null) return const [];
    final raw = prod['variants'];
    return raw is List ? raw : const [];
  }

  /// Sepetteki secili item icin varyant secim dialog'u
  Future<void> _openVariantDialogForSelected() async {
    if (_selectedItemIndex == null) return;
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (_selectedItemIndex! >= activeItems.length) return;
    final item = activeItems[_selectedItemIndex!];
    final productId = item['product_id'];
    if (productId == null) return;
    final prod = _products.where((p) => p['id'] == productId).firstOrNull;
    if (prod == null) return;

    final variants = (prod['variants'] is List) ? prod['variants'] as List : const [];
    if (variants.isEmpty) return;

    final basePrice = _safeDouble(
      (prod['restaurant_price'] != null && prod['restaurant_price'] != 0)
          ? prod['restaurant_price']
          : prod['price'],
    );
    final productName = prod['name']?.toString() ?? '';
    final currentNotes = item['notes']?.toString() ?? '';

    // Hangi varyant secili (notes icinden parse — basit eslestirme)
    int? currentSelectedId;
    for (final v in variants) {
      final vname = v['name']?.toString() ?? '';
      if (vname.isNotEmpty && currentNotes.contains(vname)) {
        currentSelectedId = _safeInt(v['id']);
        break;
      }
    }

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(productName,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx, null),
                  ),
                ]),
                Text('Varyant secin', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                const SizedBox(height: 14),
                // 1 Porsiyon (varyantsiz) - tikla, direkt uygula
                _variantOptionTile(
                  label: '1 Porsiyon',
                  price: basePrice,
                  selected: currentSelectedId == null,
                  onTap: () => Navigator.pop(ctx, {'variant': null}),
                  color: Colors.blue[600]!,
                ),
                const SizedBox(height: 8),
                ...variants.map((v) {
                  final id = _safeInt(v['id']);
                  final modifier = _safeDouble(v['price_modifier']);
                  final variantPrice = basePrice + modifier;
                  final vname = v['name']?.toString() ?? '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _variantOptionTile(
                      label: vname,
                      price: variantPrice,
                      modifier: modifier,
                      selected: currentSelectedId == id,
                      onTap: () => Navigator.pop(ctx, {'variant': v}),
                      color: Colors.orange[600]!,
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (result == null) return; // Iptal (X butonu)
    final selectedVariant = result['variant'];

    // Eski varyant adlarini notes'tan temizle, yeni varyant adini ekle
    String newNotes = currentNotes;
    for (final v in variants) {
      final vname = v['name']?.toString() ?? '';
      if (vname.isEmpty) continue;
      newNotes = newNotes
          .replaceAll(RegExp(',\\s*' + RegExp.escape(vname) + '(\\s*\\(\\+[0-9.]+TL\\))?'), '')
          .replaceAll(RegExp('^' + RegExp.escape(vname) + '(\\s*\\(\\+[0-9.]+TL\\))?,?\\s*'), '')
          .replaceAll(vname, '')
          .trim();
    }
    newNotes = newNotes.replaceAll(RegExp(',\\s*,'), ',').replaceAll(RegExp('^,|,\$'), '').trim();

    if (selectedVariant != null) {
      final vname = selectedVariant['name']?.toString() ?? '';
      final mod = _safeDouble(selectedVariant['price_modifier']);
      final label = mod != 0
          ? '$vname (${mod > 0 ? '+' : ''}${mod.toStringAsFixed(0)}TL)'
          : vname;
      newNotes = newNotes.isEmpty ? label : '$newNotes, $label';
    }

    // Yeni unit_price
    final newUnitPrice = basePrice +
        (selectedVariant != null ? _safeDouble(selectedVariant['price_modifier']) : 0);

    final itemId = _safeInt(item['id']);
    if (itemId == null) return;

    try {
      final res = await widget.apiService.updateTicketItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        notes: newNotes.isEmpty ? null : newNotes,
        unitPrice: newUnitPrice,
        waiterId: widget.waiterId,
      );
      if (res['success'] == true) {
        await _loadTicketItems();
      } else {
        _showError(res['error']?.toString() ?? 'Varyant uygulanamadi');
      }
    } catch (e) {
      _showError('Varyant hatasi: $e');
    }
  }

  Widget _variantOptionTile({
    required String label,
    required double price,
    double? modifier,
    required bool selected,
    required VoidCallback onTap,
    required Color color,
  }) {
    final modText = (modifier != null && modifier != 0)
        ? ' (${modifier > 0 ? '+' : ''}${modifier.toStringAsFixed(0)} TL)'
        : '';
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color : Colors.white,
          foregroundColor: selected ? Colors.white : color,
          side: BorderSide(color: color, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text('$label$modText', overflow: TextOverflow.ellipsis)),
            Text('₺${price.toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Future<void> _addProductWithPrice(Map<String, dynamic> product, String displayName, double price) async {
    try {
      final productId = _safeInt(product['id']);
      if (productId == null) return;

      final name = displayName;

      // Optimistic update - aninda UI'ya ekle
      setState(() {
        final existingIndex = _ticketItems.indexWhere((i) => i['product_id'] == productId && i['status'] != 'cancelled' && (i['notes'] == null || i['notes'] == ''));
        if (existingIndex >= 0) {
          _ticketItems[existingIndex] = Map<String, dynamic>.from(_ticketItems[existingIndex])
            ..['quantity'] = (_ticketItems[existingIndex]['quantity'] ?? 1) + 1;
        } else {
          _ticketItems.add({
            'id': -DateTime.now().millisecondsSinceEpoch, // temp ID
            'product_id': productId,
            'product_name': name,
            'unit_price': price,
            'quantity': 1,
            'status': 'active',
            'printed': 0,
            'notes': null,
            'extras': [],
          });
        }
      });

      // Arka planda sunucuya gonder (UI beklemez)
      // NOT: Success path'te _loadTicketItems() COKMUSUNCE 5sn donmaya yol aciyordu.
      // Optimistic update zaten yapildi (yukarida). Gercek ID'ler bir sonraki acilista
      // veya manuel refresh'te senkronize olur. Error path'te rollback icin reload tutuyoruz.
      widget.apiService.addTicketItem(
        ticketId: widget.ticketId,
        productId: productId,
        productName: name,
        unitPrice: price,
        quantity: 1,
        waiterId: widget.waiterId,
      ).then((_) {
        widget.onItemAdded();
      }).catchError((e) {
        _showError('Sunucu hatasi: $e');
        _loadTicketItems(); // Geri al — optimistic update'i temizle
      });
    } catch (e) {
      _showError('Urun eklenemedi: $e');
    }
  }

  /// Seçili ürüne not ekle popup — hazır notlar + serbest yazı
  Future<void> _openNoteDialog() async {
    if (_selectedItemIndex == null) return;

    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (_selectedItemIndex! >= activeItems.length) return;

    final item = activeItems[_selectedItemIndex!];
    final currentNote = item['notes']?.toString() ?? '';
    final controller = TextEditingController(text: currentNote);

    // Ürünün category_id'sini bul
    final productId = item['product_id'];
    int? categoryId;
    if (productId != null) {
      final allProducts = await widget.apiService.getProducts();
      final prod = (allProducts as List).where((p) => p['id'] == productId).firstOrNull;
      if (prod != null) categoryId = prod['category_id'] as int?;
    }

    // Paralel API çağrıları
    final results = await Future.wait([
      widget.apiService.getProductNotes(),
      widget.apiService.getGlobalVariants(categoryId: categoryId),
      widget.apiService.getGlobalExtras(categoryId: categoryId),
    ]);
    final predefinedNotes = results[0] as List;
    final globalVariants = results[1] as List;
    final globalExtras = results[2] as List;

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final theme = Provider.of<ThemeProvider>(ctx, listen: false);
        final Set<String> selectedNotes = {};
        final Set<int> selectedVariantIds = {};
        final Set<int> selectedExtraIds = {};
        int activeTab = 0; // 0=Notlar, 1=Varyantlar, 2=Ekstralar
        double extraPrice = 0;

        if (currentNote.isNotEmpty) {
          for (var n in predefinedNotes) {
            final noteText = n['note']?.toString() ?? '';
            if (currentNote.contains(noteText)) selectedNotes.add(noteText);
          }
          for (var v in globalVariants) {
            if (currentNote.contains(v['name']?.toString() ?? '')) selectedVariantIds.add(v['id']);
          }
          for (var e in globalExtras) {
            if (currentNote.contains(e['name']?.toString() ?? '')) selectedExtraIds.add(e['id']);
          }
        }

        void rebuildNote(void Function(void Function()) setState) {
          final parts = <String>[];
          final freeText = controller.text.split(',').where((t) {
            final trimmed = t.trim();
            if (trimmed.isEmpty) return false;
            if (predefinedNotes.any((p) => p['note'] == trimmed)) return false;
            if (globalVariants.any((v) => v['name'] == trimmed || '${v['name']} (+${_safeDouble(v['price']).toStringAsFixed(0)}TL)' == trimmed)) return false;
            if (globalExtras.any((e) => e['name'] == trimmed || '${e['name']} (+${_safeDouble(e['price']).toStringAsFixed(0)}TL)' == trimmed)) return false;
            return true;
          }).join(', ');
          if (freeText.isNotEmpty) parts.add(freeText);
          parts.addAll(selectedNotes);
          for (var vid in selectedVariantIds) {
            final v = globalVariants.firstWhere((x) => x['id'] == vid, orElse: () => null);
            if (v != null) {
              final p = _safeDouble(v['price']);
              parts.add(p > 0 ? '${v['name']} (+${p.toStringAsFixed(0)}TL)' : v['name']);
            }
          }
          for (var eid in selectedExtraIds) {
            final e = globalExtras.firstWhere((x) => x['id'] == eid, orElse: () => null);
            if (e != null) {
              final p = _safeDouble(e['price']);
              parts.add(p > 0 ? '${e['name']} (+${p.toStringAsFixed(0)}TL)' : e['name']);
            }
          }
          controller.text = parts.join(', ');
          controller.selection = TextSelection.fromPosition(TextPosition(offset: controller.text.length));

          extraPrice = 0;
          for (var vid in selectedVariantIds) {
            final v = globalVariants.firstWhere((x) => x['id'] == vid, orElse: () => null);
            if (v != null) extraPrice += _safeDouble(v['price']);
          }
          for (var eid in selectedExtraIds) {
            final e = globalExtras.firstWhere((x) => x['id'] == eid, orElse: () => null);
            if (e != null) extraPrice += _safeDouble(e['price']);
          }
        }

        Widget buildChips(List items, Set<int> selectedIds, String nameKey, void Function(void Function()) setState) {
          return Wrap(
            spacing: 8, runSpacing: 8,
            children: items.map<Widget>((item) {
              final id = item['id'] as int;
              final name = item[nameKey]?.toString() ?? '';
              final price = _safeDouble(item['price']);
              final isSelected = selectedIds.contains(id);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (isSelected) { selectedIds.remove(id); } else { selectedIds.add(id); }
                    rebuildNote(setState);
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected ? theme.primaryColor : Colors.grey[100],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isSelected ? theme.primaryColor : Colors.grey[300]!, width: isSelected ? 2 : 1),
                  ),
                  child: Text(
                    price > 0 ? '$name +${price.toStringAsFixed(0)}₺' : name,
                    style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                  ),
                ),
              );
            }).toList(),
          );
        }

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Material(
              type: MaterialType.transparency,
              child: Center(
                child: Container(
                  width: 600,
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
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
                      Row(
                        children: [
                          Expanded(child: Text('${item['product_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                          if (extraPrice > 0) Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                            child: Text('+${extraPrice.toStringAsFixed(0)} TL', style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Serbest not girin...',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primaryColor, width: 2)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Tab butonları
                      Row(
                        children: [
                          _buildNoteTab('Notlar (${predefinedNotes.length})', 0, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                          const SizedBox(width: 6),
                          if (globalVariants.isNotEmpty) _buildNoteTab('Varyantlar (${globalVariants.length})', 1, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                          if (globalVariants.isNotEmpty) const SizedBox(width: 6),
                          if (globalExtras.isNotEmpty) _buildNoteTab('Ekstralar (${globalExtras.length})', 2, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Tab içeriği
                      Flexible(
                        child: SingleChildScrollView(
                          child: activeTab == 0
                            ? Wrap(
                                spacing: 8, runSpacing: 8,
                                children: predefinedNotes.map<Widget>((n) {
                                  final noteText = n['note']?.toString() ?? '';
                                  final isSelected = selectedNotes.contains(noteText);
                                  return GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        if (isSelected) { selectedNotes.remove(noteText); } else { selectedNotes.add(noteText); }
                                        rebuildNote(setDialogState);
                                      });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: isSelected ? theme.primaryColor : Colors.grey[100],
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: isSelected ? theme.primaryColor : Colors.grey[300]!, width: isSelected ? 2 : 1),
                                      ),
                                      child: Text(noteText, style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                                    ),
                                  );
                                }).toList(),
                              )
                            : activeTab == 1
                              ? buildChips(globalVariants, selectedVariantIds, 'name', setDialogState)
                              : buildChips(globalExtras, selectedExtraIds, 'name', setDialogState),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox(width: 120, height: 48, child: ElevatedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
                            child: const Text('İptal', style: TextStyle(fontSize: 16)),
                          )),
                          const SizedBox(width: 8),
                          SizedBox(width: 150, height: 48, child: ElevatedButton(
                            onPressed: () => Navigator.pop(ctx, {'note': controller.text, 'extraPrice': extraPrice}),
                            style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, foregroundColor: Colors.white),
                            child: Text(extraPrice > 0 ? 'Kaydet (+${extraPrice.toStringAsFixed(0)}₺)' : 'Kaydet', style: const TextStyle(fontSize: 16)),
                          )),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null) return;

    try {
      final itemId = _safeInt(item['id']);
      final ticketId = widget.ticketId;
      if (itemId == null) return;

      final note = result['note'] as String? ?? '';
      final addedPrice = result['extraPrice'] as double? ?? 0;

      // Tek API çağrısında hem not hem fiyat güncelle
      final currentPrice = _safeDouble(item['unit_price']);
      final newPrice = addedPrice > 0 ? currentPrice + addedPrice : null;

      await widget.apiService.updateTicketItem(
        ticketId: ticketId,
        itemId: itemId,
        notes: note,
        unitPrice: newPrice,
      );

      await _loadTicketItems();
      widget.onItemAdded();
    } catch (e) {
      _showError('Not eklenemedi: $e');
    }
  }

  Widget _buildNoteTab(String label, int index, int activeTab, ThemeProvider theme, void Function(int) onTap) {
    final isActive = activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: isActive ? theme.primaryColor : Colors.grey[100],
            borderRadius: BorderRadius.circular(10),
            border: isActive ? null : Border.all(color: Colors.grey[300]!),
          ),
          child: Center(child: Text(label, style: TextStyle(color: isActive ? Colors.white : Colors.grey[700], fontSize: 14, fontWeight: FontWeight.w600))),
        ),
      ),
    );
  }

  /// Ürün iptal — sebep seçimi zorunlu
  Future<void> _cancelSelectedItem() async {
    if (_selectedItemIndex == null) return;
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (_selectedItemIndex! >= activeItems.length) return;
    final item = activeItems[_selectedItemIndex!];
    final itemId = _safeInt(item['id']);
    if (itemId == null) return;

    // İptal sebeplerini API'den çek
    final reasons = await widget.apiService.getCancelReasons();

    if (!mounted) return;

    final selectedReason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Provider.of<ThemeProvider>(ctx, listen: false);
        String? picked;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Material(
              type: MaterialType.transparency,
              child: Center(
                child: Container(
                  width: 450,
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
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
                      Row(
                        children: [
                          const Icon(Icons.cancel, color: Colors.red, size: 24),
                          const SizedBox(width: 8),
                          Expanded(child: Text('${item['product_name']} - İptal Sebebi', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Lütfen iptal sebebini seçin', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                      const SizedBox(height: 16),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: reasons.map<Widget>((r) {
                              final reason = r['reason']?.toString() ?? '';
                              final isSelected = picked == reason;
                              return GestureDetector(
                                onTap: () => setDialogState(() => picked = reason),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.red : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: isSelected ? Colors.red : Colors.grey[300]!, width: isSelected ? 2 : 1),
                                  ),
                                  child: Text(reason, style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: picked != null ? () => Navigator.pop(ctx, picked) : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: picked != null ? Colors.red : Colors.grey[300],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('İptal Et', style: TextStyle(color: picked != null ? Colors.white : Colors.grey[500], fontWeight: FontWeight.bold)),
                            ),
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
      },
    );

    if (selectedReason == null) return;

    try {
      await widget.apiService.deleteTicketItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        cancelReason: selectedReason,
        waiterId: widget.waiterId,
      );
      setState(() => _selectedItemIndex = null);
      await _loadTicketItems();
      widget.onItemAdded();
      _showSuccess('Ürün iptal edildi: $selectedReason');
    } catch (e) {
      _showError('Ürün iptal edilemedi: $e');
    }
  }

  /// Mutfağa gönder
  Future<void> _sendToKitchen() async {
    if (widget.printerService == null) return;

    final hasSummaryPrinter = widget.section?['summary_printer_id'] != null;

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
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};

      ticketInfo['table_number'] = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';
      ticketInfo['section_name'] = widget.table?['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter?['name'] ?? '';

      if (items.isEmpty) {
        _showSuccess('Yazdırılacak yeni ürün yok');
        return;
      }

      // printerGroups ile tüm yazıcılara gönder (özet yazıcı dahil)
      final printerGroups = result['printerGroups'] as List? ?? [];
      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty) continue;

        if (printerIp != null && printerIp.isNotEmpty) {
          await widget.printerService!.printKitchenReceiptToIp(
            ticket: ticketInfo, items: groupItems, ip: printerIp, port: printerPort,
          );
        } else {
          await widget.printerService!.printKitchenReceipt(
            ticket: ticketInfo, items: groupItems,
          );
        }
      }

      // Masalar ekranına dön (hem AddItemModal'ı hem alttaki TicketModal'ı kapat)
      widget.onClose();
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesap Kapat', style: TextStyle(fontSize: 22)),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve hesap kapatılacak.\n\nDevam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            width: 150, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('İptal', style: TextStyle(fontSize: 18)),
            ),
          ),
          SizedBox(
            width: 200, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white),
              child: const Text('Öde ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
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
        // Ödeme başarılı, şimdi ticket'ı kapat
        await widget.apiService.closeTicket(
          ticketId: widget.ticketId,
          paymentMethod: paymentMethod,
          waiterId: widget.waiterId,
        );
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Yazdır ve Kapat', style: TextStyle(fontSize: 22)),
        content: Text('$label ile hesap kapatılacak ve fiş yazdırılacak. Devam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            width: 150, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('İptal', style: TextStyle(fontSize: 18)),
            ),
          ),
          SizedBox(
            width: 200, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white),
              child: const Text('Yazdır ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
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

  /// Modal X ile kapatılırken çağrılır.
  /// Yazdırılmamış (printed=0) ürün varsa önce mutfağa otomatik gönderir,
  /// sonra modal'ı kapatır. Garson "Mutfağa Gönder"e basmayı unutsa bile
  /// mutfak çıktısı kaybolmaz.
  Future<void> _handleClose() async {
    // _ticketItems içinde aktif (cancelled olmayan) ve printed=0 olan var mı?
    final hasUnprinted = _ticketItems.any((it) {
      final m = it as Map<String, dynamic>;
      if (m['status'] == 'cancelled') return false;
      final p = m['printed'];
      if (p == null) return true;
      if (p is bool) return !p;
      if (p is num) return p == 0;
      final s = p.toString();
      return s == '0' || s.isEmpty || s == 'false';
    });

    if (hasUnprinted) {
      // Server-side _sendToKitchenSilent zaten unprinted filtresi yapıyor; arkada gönder
      try { await _sendToKitchenSilent(); } catch (_) {}
    }

    if (mounted) widget.onClose();
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

    // Ticket'in server'a sync olduğunu doğrula ve gerçek server ID'sini al
    int? serverTicketId;
    try {
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      final serverTicket = ticketData?['ticket'] as Map<String, dynamic>?;
      if (serverTicket != null && serverTicket['offline'] != true) {
        final id = serverTicket['id'];
        serverTicketId = id is int ? id : int.tryParse(id?.toString() ?? '');
      }
    } catch (_) {}

    if (serverTicketId == null) {
      _showError('Adisyon henuz sunucuya senkronize edilmedi. Lutfen birkac saniye bekleyip tekrar deneyin veya internet baglantinizi kontrol edin.');
      return;
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PartialPaymentDialog(
        items: activeItems,
        ticketId: serverTicketId!,
        waiterId: widget.waiterId,
        apiService: widget.apiService,
        onPaymentComplete: (allPaid) {
          if (allPaid) {
            // Tüm ürünler ödendi, adisyon kapanır - dialog ve modal kapanır
            Navigator.pop(ctx);
            widget.onItemAdded();
            widget.onClose();
          } else {
            // Kısmi ödeme - dialog açık kalır, sadece arkadaki listeyi tazele
            widget.onItemAdded();
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon İptal', style: TextStyle(fontSize: 22, color: Colors.red)),
        content: const Text('Adisyon iptal edilecek. Bu işlem geri alınamaz. Emin misiniz?', style: TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            width: 150, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('Vazgeç', style: TextStyle(fontSize: 18)),
            ),
          ),
          SizedBox(
            width: 200, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('İptal Et', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
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

  /// Masa değiştir
  Future<void> _transferTable() async {
    try {
      // Boş masaları al
      final tables = await widget.apiService.getTables();
      final emptyTables = (tables as List).where((t) => t['status'] == 'empty').toList();
      if (emptyTables.isEmpty) {
        _showError('Boş masa yok');
        return;
      }

      final selectedTable = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Masa Değiştir', style: TextStyle(fontSize: 22)),
          content: SizedBox(
            width: 400,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mevcut: ${widget.table?['section_name'] ?? ''} - Masa ${widget.table?['table_number'] ?? ''}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 14)),
                const SizedBox(height: 12),
                const Text('Yeni masa seçin:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: emptyTables.length,
                    itemBuilder: (context, index) {
                      final table = emptyTables[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        leading: CircleAvatar(
                          radius: 22,
                          backgroundColor: Color(int.parse((table['section_color'] ?? '#3b82f6').replaceAll('#', '0xFF'))),
                          child: Text('${table['table_number']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                        title: Text('Masa ${table['table_number']}', style: const TextStyle(fontSize: 16)),
                        subtitle: Text(table['section_name'] ?? '', style: const TextStyle(fontSize: 13)),
                        onTap: () => Navigator.pop(ctx, table),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            SizedBox(width: 150, height: 50, child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('İptal', style: TextStyle(fontSize: 16)),
            )),
          ],
        ),
      );

      if (selectedTable == null) return;

      await widget.apiService.transferTable(
        ticketId: widget.ticketId,
        newTableId: (selectedTable['id'] as num).toInt(),
        waiterId: widget.waiterId,
      );
      _showSuccess('Masa değiştirildi: ${selectedTable['section_name']} - Masa ${selectedTable['table_number']}');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Masa değiştirilemedi: $e');
    }
  }

  /// İndirim dialog
  Future<void> _openDiscountDialog() async {
    double? discount;
    String type = 'percentage';

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        String localType = 'percentage';
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('İndirim Uygula', style: TextStyle(fontSize: 22)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => localType = 'percentage'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: localType == 'percentage' ? const Color(0xFFE11D48) : Colors.grey[200],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(child: Text('% Yüzde', style: TextStyle(color: localType == 'percentage' ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold))),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => localType = 'amount'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: localType == 'amount' ? const Color(0xFFE11D48) : Colors.grey[200],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(child: Text('₺ Tutar', style: TextStyle(color: localType == 'amount' ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold))),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: localType == 'percentage' ? '%' : '₺',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.spaceEvenly,
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              SizedBox(width: 140, height: 50, child: ElevatedButton(onPressed: () => Navigator.pop(ctx), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 16)))),
              SizedBox(width: 160, height: 50, child: ElevatedButton(
                onPressed: () {
                  final val = double.tryParse(controller.text);
                  if (val != null && val > 0) Navigator.pop(ctx, {'type': localType, 'value': val});
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE11D48), foregroundColor: Colors.white),
                child: const Text('Uygula', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )),
            ],
          ),
        );
      },
    );

    if (result == null) return;
    try {
      await widget.apiService.applyDiscount(
        ticketId: widget.ticketId,
        discountType: result['type'],
        discountValue: result['value'],
        waiterId: widget.waiterId,
      );
      _showSuccess('İndirim uygulandı');
      await _loadTicketItems();
    } catch (e) {
      _showError('İndirim uygulanamadı: $e');
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

  double get _ticketSubtotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    }
    return total;
  }

  double get _ticketDiscount {
    if (_ticketInfo == null) return 0;
    final d = _ticketInfo!['discount_amount'] ?? _ticketInfo!['discount'];
    if (d == null) return 0;
    return d is num ? d.toDouble() : double.tryParse(d.toString()) ?? 0;
  }

  String? get _ticketDiscountType => _ticketInfo?['discount_type']?.toString();

  double get _ticketTotal {
    return _ticketSubtotal - _ticketDiscount;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);

    return PopScope(
      // Modal sistem geri tuşu/ESC ile kapatılırsa da otomatik mutfağa gönder
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _handleClose();
      },
      child: Dialog(
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
                        // 1. SOL: Kategoriler
                        _buildCategoriesPanel(theme),
                        // 2. ORTA-SOL: Ürünler (geniş)
                        Expanded(flex: 4, child: _buildProductsPanel(theme)),
                        // 3. ORTA-SAĞ: Adisyon listesi (scroll)
                        _buildTicketPanel(theme),
                        // 4. SAĞ: Aksiyon butonları
                        _buildActionPanel(theme),
                      ],
                    ),
            ),
          ],
        ),
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
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                // X ile kapatırken yazdırılmamış ürünler otomatik mutfağa gönderilsin
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(12),
                child: const SizedBox(
                  width: 64,
                  height: 64,
                  child: Icon(Icons.close, color: Colors.white, size: 36),
                ),
              ),
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

    return GestureDetector(
      onTap: () => _selectCategory(categoryId),
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
        // Min 3 sutun garanti: pencere kuculurse urunler o oranda kuculsun
        final crossAxisCount = (constraints.maxWidth / 160).floor().clamp(3, 6);
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: widget.showProductImages ? 0.85 : 1.5,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
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
      child: GestureDetector(
        onTap: isOutOfStock ? null : () => _addProductDirectly(product),
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
              // Gorsel sadece varsa goster, yoksa hic yer kaplamasin
              if (widget.showProductImages && hasImage)
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10)),
                    child: _buildProductImage(product),
                  ),
                ),
              Expanded(
                flex: (widget.showProductImages && hasImage) ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: (widget.showProductImages && hasImage) ? MainAxisAlignment.start : MainAxisAlignment.center,
                    children: [
                      Text(
                        product['name']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Color(0xFF1f2937)),
                      ),
                      if (widget.showProductImages && hasImage) const Spacer(),
                      if (!(widget.showProductImages && hasImage)) const SizedBox(height: 2),
                      Text(
                        '${(product['restaurant_price'] != null && product['restaurant_price'] != 0) ? product['restaurant_price'] : product['price'] ?? 0} TL',
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
                if (_ticketDiscount > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Ara Toplam', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      Text('${_ticketSubtotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _ticketDiscountType == 'percentage'
                            ? 'İndirim (%${(_ticketSubtotal > 0 ? (_ticketDiscount / _ticketSubtotal * 100) : 0).toStringAsFixed(0)})'
                            : 'İndirim',
                        style: TextStyle(fontSize: 11, color: Colors.red[700]),
                      ),
                      Text('-${_ticketDiscount.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red[700])),
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

        ],
      ),
    );
  }

  Widget _buildActionPanel(ThemeProvider theme) {
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    final hasItems = activeItems.isNotEmpty;

    return Container(
      width: 130,
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(left: BorderSide(color: Colors.grey[200]!)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // Grup 1: Not Ekle, Varyant, Ürün İptal, Mutfak, Yazdır
            _buildActionBtnVertical(icon: Icons.edit_note, label: 'Not Ekle', color: Colors.blueGrey, onTap: hasItems && _selectedItemIndex != null ? _openNoteDialog : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(
              icon: Icons.tune,
              label: 'Varyant',
              color: const Color(0xFFF59E0B),
              onTap: hasItems && _selectedItemIndex != null && _variantsForSelectedItem().isNotEmpty
                  ? _openVariantDialogForSelected
                  : null,
            ),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.close, label: 'Ürün İptal', color: Colors.red[400]!, onTap: hasItems && _selectedItemIndex != null && _hasPermission('cancel_item') ? _cancelSelectedItem : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.restaurant, label: 'Mutfak', color: const Color(0xFFF59E0B), onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.print, label: 'Yazdır', color: Colors.blueGrey, onTap: hasItems && _hasPermission('print_receipt') ? _printTicket : null),

            const SizedBox(height: 12),
            Divider(color: Colors.grey[300], height: 1),
            const SizedBox(height: 12),

            // Grup 2: İndirim, Masa Değiştir, Parçalı Ödeme
            if (_hasPermission('apply_discount')) ...[
              _buildActionBtnVertical(icon: Icons.percent, label: 'İndirim', color: const Color(0xFFE11D48), onTap: hasItems ? _openDiscountDialog : null),
              const SizedBox(height: 5),
            ],
            if (_hasPermission('transfer_table')) ...[
              _buildActionBtnVertical(icon: Icons.swap_horiz, label: 'Masa Değiştir', color: const Color(0xFF0EA5E9), onTap: hasItems ? _transferTable : null),
              const SizedBox(height: 5),
            ],
            _buildActionBtnVertical(icon: Icons.splitscreen, label: 'Parçalı Ödeme', color: const Color(0xFF7C3AED), onTap: hasItems && _hasPermission('close_ticket') ? _openPartialPayment : null),

            const SizedBox(height: 12),
            Divider(color: Colors.grey[300], height: 1),
            const SizedBox(height: 12),

            // Grup 3: Ödeme kapama
            _buildActionBtnVertical(icon: Icons.payments, label: 'Nakit Kapat', color: theme.primaryColor, onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.credit_card, label: 'Kart Kapat', color: const Color(0xFF3B82F6), onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('credit_card') : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.receipt_long, label: 'Yaz+Nakit', color: const Color(0xFF059669), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('cash') : null),
            const SizedBox(height: 5),
            _buildActionBtnVertical(icon: Icons.receipt_long, label: 'Yaz+Kart', color: const Color(0xFF2563EB), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('credit_card') : null),

            const SizedBox(height: 12),
            Divider(color: Colors.grey[300], height: 1),
            const SizedBox(height: 12),

            // Grup 4: Adisyon İptal
            if (_hasPermission('void_ticket'))
              _buildActionBtnVertical(icon: Icons.delete_outline, label: 'Adisyon İptal', color: const Color(0xFFDC2626), onTap: _voidTicket),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBtnVertical({required IconData icon, required String label, required Color color, VoidCallback? onTap}) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[200] : color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isDisabled ? Colors.grey[300]! : color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: isDisabled ? Colors.grey[400] : color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: isDisabled ? Colors.grey[400] : color), textAlign: TextAlign.center),
          ],
        ),
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

    return GestureDetector(
      onTap: () => setState(() => _selectedItemIndex = isSelected ? null : index),
      child: Container(
        // Dokunmatik ekran icin 2x - padding + fontSize artirildi
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isPaid
              ? Colors.green[50]
              : (isSelected ? theme.primaryColor.withOpacity(0.08) : Colors.transparent),
          border: Border(
            bottom: BorderSide(color: Colors.grey[200]!),
            left: isSelected ? BorderSide(color: theme.primaryColor, width: 4) : BorderSide.none,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isPaid ? Colors.green : theme.primaryColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(child: Text('$quantity', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['product_name']?.toString() ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
                    ),
                  ),
                  if (notes != null && notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(notes, style: TextStyle(fontSize: 14, color: Colors.grey[600], fontStyle: FontStyle.italic)),
                    ),
                  if (isPaid)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: payMethod == 'CASH' ? Colors.green : Colors.blue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        payMethod == 'CASH' ? 'NAKİT' : 'KART',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${total.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 18,
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
          // İlk satır: Not Ekle + Varyant + Urun Iptal
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
                  icon: Icons.tune,
                  label: 'Varyant',
                  color: const Color(0xFFF59E0B),
                  onTap: hasItems && _selectedItemIndex != null && _variantsForSelectedItem().isNotEmpty
                      ? _openVariantDialogForSelected
                      : null,
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
          // Masa Değiştir + İndirim
          Row(
            children: [
              if (_hasPermission('transfer_table'))
                Expanded(
                  child: _buildActionBtn(
                    icon: Icons.swap_horiz,
                    label: 'Masa Değiştir',
                    color: const Color(0xFF0EA5E9),
                    onTap: hasItems ? _transferTable : null,
                  ),
                ),
              if (_hasPermission('transfer_table')) const SizedBox(width: 6),
              if (_hasPermission('apply_discount'))
                Expanded(
                  child: _buildActionBtn(
                    icon: Icons.percent,
                    label: 'İndirim',
                    color: const Color(0xFFE11D48),
                    onTap: hasItems ? _openDiscountDialog : null,
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
    return GestureDetector(
      onTap: isDisabled ? null : () => onTap(),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[200] : color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isDisabled ? Colors.grey[400] : Colors.white,
                fontSize: 14,
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
  final int? waiterId;
  final ApiService apiService;
  final Function(bool allPaid) onPaymentComplete;
  final VoidCallback onClose;

  const _PartialPaymentDialog({
    required this.items,
    required this.ticketId,
    required this.apiService,
    required this.onPaymentComplete,
    required this.onClose,
    this.waiterId,
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

        // Tüm ürünler ödendi mi? Evet ise ticket'i de kapat (masa bossun)
        final allPaid = _items.every((i) => i['payment_status'] == 'paid');
        if (allPaid) {
          try {
            await widget.apiService.closeTicket(
              ticketId: widget.ticketId,
              paymentMethod: paymentMethod,
              waiterId: widget.waiterId,
            );
          } catch (e) {
            _showError('Adisyon kapatilamadi: $e');
            return;
          }
        }
        widget.onPaymentComplete(allPaid);
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon Kapat', style: TextStyle(fontSize: 22)),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve adisyon kapatılacak.\n\nDevam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white), child: const Text('Öde ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
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
        // Tum urunler odendi - adisyonu kapat
        try {
          await widget.apiService.closeTicket(
            ticketId: widget.ticketId,
            paymentMethod: paymentMethod,
            waiterId: widget.waiterId,
          );
        } catch (e) {
          _showError('Adisyon kapatilamadi: $e');
          return;
        }
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
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      // Scaffold yerine direkt Container kullan ki arkada beyaz Scaffold pencere çıkmasın
      // Center ile ekranın ortasına yerleştir
      child: Center(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.7,
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
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
                    GestureDetector(
                                onTap: () => _selectedIds.length == unpaidItems.length ? _clearSelection() : _selectAll(),
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
                    GestureDetector(
                                onTap: () => widget.onClose(),
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

    // Renk şeması:
    //   Ödenmiş → yeşil
    //   Seçili (ödenmemiş) → mor (purple seçim rengi)
    //   Ödenmemiş (seçilmemiş) → kırmızı/uyarı
    final unpaidBg = const Color(0xFFFEE2E2);  // red-100
    final unpaidBorder = const Color(0xFFEF4444);  // red-500
    final unpaidText = const Color(0xFFB91C1C);  // red-700

    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final Color qtyBg;
    if (isPaid) {
      bgColor = Colors.green[50]!;
      borderColor = Colors.green[300]!;
      textColor = Colors.green[700]!;
      qtyBg = Colors.green;
    } else if (isSelected) {
      bgColor = const Color(0xFF7C3AED).withOpacity(0.10);
      borderColor = const Color(0xFF7C3AED);
      textColor = const Color(0xFF1F2937);
      qtyBg = const Color(0xFF7C3AED);
    } else {
      bgColor = unpaidBg;
      borderColor = unpaidBorder;
      textColor = unpaidText;
      qtyBg = unpaidBorder;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isPaid ? null : () { if (itemId != null) _toggleItem(itemId); },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
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
                    border: Border.all(color: isSelected ? const Color(0xFF7C3AED) : unpaidBorder, width: 2),
                  ),
                  child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                ),
              // Miktar
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: qtyBg,
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
                    color: textColor,
                  ),
                ),
              ),
              // Badge (ödenmişse — yeşil/mavi; ödenmemişse — kırmızı "ÖDENMEDİ")
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
                )
              else if (!isSelected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: unpaidBorder,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'ÖDENMEDİ',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              // Fiyat
              Text(
                '${price.toStringAsFixed(2)} TL',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ],
          ),
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
    return GestureDetector(
      onTap: isDisabled ? null : () => onTap(),
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
