import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../providers/theme_provider.dart';
import '../screens/printer_settings_screen.dart';
import 'add_item_modal.dart';
import 'discount_modal.dart';

class TicketModal extends StatefulWidget {
  final Map<String, dynamic> table;
  final ApiService apiService;
  final PrinterService printerService;
  final Map<String, dynamic> waiter;
  final VoidCallback onClose;
  final bool showProductImages;

  const TicketModal({
    super.key,
    required this.table,
    required this.apiService,
    required this.printerService,
    required this.waiter,
    required this.onClose,
    this.showProductImages = true,
  });

  @override
  State<TicketModal> createState() => _TicketModalState();
}

class _TicketModalState extends State<TicketModal> {
  Map<String, dynamic>? _ticket;
  bool _isLoading = true;
  int _customerCount = 1;
  double _localDiscount = 0;
  String _localDiscountType = 'percentage';

  @override
  void initState() {
    super.initState();
    _loadTicket();
  }

  int get _tableId {
    final id = widget.table['id'];
    if (id == null) throw Exception('Table ID is null');
    return (id as num).toInt();
  }

  int get _waiterId {
    final id = widget.waiter['id'];
    if (id == null) throw Exception('Waiter ID is null');
    return (id as num).toInt();
  }

  int? _safeInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  /// Garsonun belirli bir yetkiye sahip olup olmadığını kontrol eder
  /// - Online modda: Garsonun yetkilerine göre butonlar gösterilir
  /// - Offline modda: Sadece temel işlemlere izin verilir (adisyon aç, ürün ekle, nakit/kart ile kapat, iptal)
  bool _hasPermission(String permission) {
    // Offline moddayken sadece belirli işlemlere izin ver
    if (!widget.apiService.isOnline) {
      // Offline modda izin verilen işlemler:
      // - open_ticket: Adisyon açma
      // - add_item: Ürün ekleme
      // - close_ticket: Hesap kapatma (nakit/kart)
      // - void_ticket: Adisyon iptal
      const offlineAllowedPermissions = ['open_ticket', 'add_item', 'close_ticket', 'void_ticket'];
      return offlineAllowedPermissions.contains(permission);
    }

    // Online modda garsonun yetkilerini kontrol et
    final permissions = widget.waiter['permissions'] as Map<String, dynamic>?;
    if (permissions == null) return false; // Yetki bilgisi yoksa varsayılan olarak izin verme
    return permissions[permission] == true;
  }

  Future<void> _loadTicket() async {
    setState(() => _isLoading = true);
    try {
      final response = await widget.apiService.getTableTicket(_tableId);
      print('[TicketModal] _loadTicket response: $response');
      setState(() {
        // Online API returns {ticket: {...}} or {ticket: null}
        // Offline returns directly {...}
        if (response != null && response['ticket'] != null) {
          // Online response with ticket
          _ticket = response['ticket'];
        } else if (response != null && !response.containsKey('ticket') && response['id'] != null) {
          // Offline response (direct ticket object)
          _ticket = response;
        } else {
          // No ticket
          _ticket = null;
        }
        print('[TicketModal] _ticket set: $_ticket');
      });
    } catch (e) {
      print('[TicketModal] _loadTicket error: $e');
      setState(() => _ticket = null);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _openTicket() async {
    try {
      final result = await widget.apiService.openTicket(
        tableId: _tableId,
        waiterId: _waiterId,
        customerCount: _customerCount,
      );

      if (result['success'] == true) {
        _showSuccess('Adisyon acildi');
        // Ticket detaylarini yeniden yukle
        await _loadTicket();
      } else {
        _showError(result['error'] ?? 'Adisyon acilamadi');
      }
    } catch (e) {
      _showError('Adisyon acilamadi: $e');
    }
  }

  Future<void> _closeTicket(String paymentMethod) async {
    if (_ticket == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hesap Kapat'),
        content: Text('${paymentMethod == 'cash' ? 'Nakit' : 'Kredi Karti'} ile hesap kapatilacak. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Iptal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Kapat', style: TextStyle(color: paymentMethod == 'cash' ? Colors.green : Colors.blue)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Offline ticket için local_id kullan, online için id kullan
      final isOffline = _ticket!['offline'] == true;
      final ticketId = isOffline
          ? _safeInt(_ticket!['local_id']) ?? _safeInt(_ticket!['id'])
          : _safeInt(_ticket!['id']);
      if (ticketId == null) throw Exception('Ticket ID is null');

      print('[TicketModal] closeTicket: ticketId=$ticketId, isOffline=$isOffline');
      await widget.apiService.closeTicket(
        ticketId: ticketId,
        paymentMethod: paymentMethod,
        waiterId: _waiterId,
      );
      _showSuccess('Hesap kapatildi');
      widget.onClose();
    } catch (e) {
      _showError('Hesap kapatilamadi: $e');
    }
  }

  Future<void> _voidTicket() async {
    if (_ticket == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adisyon Iptal'),
        content: const Text('Adisyon iptal edilecek. Bu islem geri alinamaz. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgec')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Iptal Et', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Offline ticket için local_id kullan, online için id kullan
      final isOffline = _ticket!['offline'] == true;
      final ticketId = isOffline
          ? _safeInt(_ticket!['local_id']) ?? _safeInt(_ticket!['id'])
          : _safeInt(_ticket!['id']);
      if (ticketId == null) throw Exception('Ticket ID is null');

      print('[TicketModal] voidTicket: ticketId=$ticketId, isOffline=$isOffline');
      await widget.apiService.voidTicket(
        ticketId: ticketId,
        waiterId: _waiterId,
      );
      _showSuccess('Adisyon iptal edildi');
      widget.onClose();
    } catch (e) {
      _showError('Adisyon iptal edilemedi: $e');
    }
  }

  Future<void> _cancelItem(int itemId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Urun Iptal'),
        content: const Text('Bu urun iptal edilecek. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgec')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Iptal Et', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final ticketId = _safeInt(_ticket!['id']);
      if (ticketId == null) throw Exception('Ticket ID is null');
      await widget.apiService.deleteTicketItem(
        ticketId: ticketId,
        itemId: itemId,
        waiterId: _waiterId,
      );
      await _loadTicket();
      _showSuccess('Urun iptal edildi');
    } catch (e) {
      _showError('Urun iptal edilemedi: $e');
    }
  }

  Future<void> _openAddItemModal() async {
    print('[TicketModal] _openAddItemModal çağrıldı');
    if (_ticket == null) {
      print('[TicketModal] _ticket null, lütfen önce adisyon açın');
      _showError('Lütfen önce adisyon açın');
      return;
    }

    print('[TicketModal] _ticket keys: ${_ticket!.keys.toList()}');
    print('[TicketModal] _ticket: $_ticket');
    // Try id first, then local_id
    final ticketId = _safeInt(_ticket!['id']) ?? _safeInt(_ticket!['local_id']);
    print('[TicketModal] ticketId: $ticketId');
    if (ticketId == null) {
      _showError('Ticket ID bulunamadi');
      return;
    }
    print('[TicketModal] AddItemModal açılıyor...');
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AddItemModal(
        apiService: widget.apiService,
        ticketId: ticketId,
        waiterId: _waiterId,
        onItemAdded: () => _loadTicket(),
        onClose: () => Navigator.pop(context),
        showProductImages: widget.showProductImages,
      ),
    );
  }

  /// Mutfağa gönder - sadece yazdırılmamış ürünleri yazıcıya gönderir
  /// Ürünler yazıcılara göre gruplanır ve her yazıcıya ayrı fiş gönderilir
  Future<void> _sendToKitchen() async {
    if (_ticket == null) {
      _showError('Adisyon yok');
      return;
    }

    try {
      final ticketId = _safeInt(_ticket!['id']);
      if (ticketId == null) {
        _showError('Ticket ID bulunamadi');
        return;
      }

      // API'den yazdırılmamış ürünleri al ve printed=1 yap
      final result = await widget.apiService.printKitchen(
        ticketId: ticketId,
        waiterId: _waiterId,
      );

      if (result['success'] != true) {
        _showError(result['error'] ?? 'Mutfak fisi alinamadi');
        return;
      }

      final items = result['items'] as List? ?? [];
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};

      // Ticket bilgilerini ekle
      ticketInfo['table_number'] = widget.table['table_number'] ?? 'Masa ${widget.table['id']}';
      ticketInfo['section_name'] = widget.table['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter['name'] ?? '';

      if (items.isEmpty) {
        _showSuccess('Yazdirilacak yeni urun yok');
        return;
      }

      // Her yazıcı grubuna ayrı fiş gönder
      int successCount = 0;
      int failCount = 0;

      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        final printerName = group['printer_name'] as String? ?? 'Varsayilan';

        if (groupItems.isEmpty) continue;

        bool success = false;

        if (printerIp != null && printerIp.isNotEmpty) {
          // Sunucudan gelen yazıcı bilgileriyle yazdır
          success = await widget.printerService.printKitchenReceiptToIp(
            ticket: ticketInfo,
            items: groupItems,
            ip: printerIp,
            port: printerPort,
          );
        } else {
          // Varsayılan yazıcıya gönder
          success = await widget.printerService.printKitchenReceipt(
            ticket: ticketInfo,
            items: groupItems,
          );
        }

        if (success) {
          successCount += groupItems.length;
          print('[TicketModal] $printerName yazicisina ${groupItems.length} urun gonderildi');
        } else {
          failCount += groupItems.length;
          print('[TicketModal] $printerName yazicisina gonderilemedi');
        }
      }

      // Sonucu göster
      if (failCount == 0) {
        _showSuccess('Mutfaga gonderildi ($successCount urun)');
      } else if (successCount > 0) {
        _showError('$successCount urun gonderildi, $failCount urun gonderilemedi');
      } else {
        _showError('Yazici hatasi - hicbir urun gonderilemedi');
      }

      // Ticket'ı yenile
      await _loadTicket();
    } catch (e) {
      print('[TicketModal] Mutfaga gonderme hatasi: $e');
      _showError('Hata: $e');
    }
  }

  Future<void> _printTicket() async {
    if (_ticket == null) {
      _showError('Yazdirilacak adisyon yok');
      return;
    }

    // Yazici ayarli degil ise ayarlar sayfasini ac
    if (!widget.printerService.isConfigured) {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => PrinterSettingsScreen(
            printerService: widget.printerService,
            apiService: widget.apiService, // Sunucudan yazıcı çekmek için
          ),
        ),
      );

      // Ayarlar kaydedildiyse tekrar yazdir
      if (result == true && widget.printerService.isConfigured) {
        await _printTicket();
      }
      return;
    }

    final sectionName = widget.table['section_name'] ?? '';
    final tableNumber = widget.table['table_number'] ?? 'Masa ${widget.table['id']}';

    final ticketToPrint = Map<String, dynamic>.from(_ticket!);
    ticketToPrint['table_name'] = '$sectionName - $tableNumber';
    ticketToPrint['waiter_name'] = widget.waiter['name'];

    final success = await widget.printerService.printTicket(ticketToPrint);
    if (success) {
      _showSuccess('Fis yazdirildi');
    } else {
      _showError('Yazici hatasi');
    }
  }

  void _openDiscountModal() {
    if (_ticket == null) return;

    final subtotal = (_ticket!['subtotal'] as num?)?.toDouble() ?? 0;

    showDialog(
      context: context,
      builder: (context) => DiscountModal(
        currentTotal: subtotal,
        currentDiscount: _localDiscount > 0 ? _localDiscount : null,
        currentDiscountType: _localDiscount > 0 ? _localDiscountType : null,
        onApply: (discount, type) {
          setState(() {
            _localDiscount = discount;
            _localDiscountType = type;
          });
        },
        onRemove: () {
          setState(() {
            _localDiscount = 0;
            _localDiscountType = 'percentage';
          });
        },
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  Future<void> _openTransferTableModal() async {
    if (_ticket == null) return;

    // Boş masaları getir
    List<dynamic> emptyTables = [];
    try {
      final tables = await widget.apiService.getTables();
      emptyTables = tables.where((t) {
        final status = t['status']?.toString() ?? 'empty';
        final tableId = _safeInt(t['id']);
        final currentTableId = _safeInt(widget.table['id']);
        return status == 'empty' && tableId != currentTableId;
      }).toList();
    } catch (e) {
      _showError('Masalar yuklenemedi');
      return;
    }

    if (emptyTables.isEmpty) {
      _showError('Bos masa bulunamadi');
      return;
    }

    if (!mounted) return;

    // Masa seçim dialogu
    final selectedTable = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Masa Degistir'),
        content: SizedBox(
          width: 400,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mevcut: ${widget.table['section_name']} - Masa ${widget.table['table_number']}',
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 16),
              const Text('Yeni masa secin:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: emptyTables.length,
                  itemBuilder: (context, index) {
                    final table = emptyTables[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Color(
                          int.parse((table['section_color'] ?? '#3b82f6').replaceAll('#', '0xFF')),
                        ),
                        child: Text(
                          '${table['table_number']}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Text('Masa ${table['table_number']}'),
                      subtitle: Text(table['section_name'] ?? ''),
                      onTap: () => Navigator.pop(context, table),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Iptal'),
          ),
        ],
      ),
    );

    if (selectedTable == null) return;

    // Masa değiştir
    try {
      final ticketId = _safeInt(_ticket!['id']);
      final newTableId = _safeInt(selectedTable['id']);
      if (ticketId == null || newTableId == null) {
        _showError('Gecersiz masa bilgisi');
        return;
      }

      await widget.apiService.transferTable(
        ticketId: ticketId,
        newTableId: newTableId,
        waiterId: _waiterId,
      );

      _showSuccess('Masa degistirildi: ${selectedTable['section_name']} - Masa ${selectedTable['table_number']}');
      widget.onClose();
    } catch (e) {
      _showError('Masa degistirilemedi: $e');
    }
  }

  double get _calculatedDiscount {
    if (_ticket == null) return 0;
    final subtotal = (_ticket!['subtotal'] as num?)?.toDouble() ?? 0;

    if (_localDiscount <= 0) return 0;

    if (_localDiscountType == 'percentage') {
      return subtotal * _localDiscount / 100;
    }
    return _localDiscount;
  }

  double get _calculatedTotal {
    if (_ticket == null) return 0;
    final subtotal = (_ticket!['subtotal'] as num?)?.toDouble() ?? 0;
    return subtotal - _calculatedDiscount;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sectionName = widget.table['section_name'] ?? '';
    final tableNumber = widget.table['table_number'] ?? 'Masa ${widget.table['id']}';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long, color: Colors.white, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    '$sectionName - $tableNumber',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Body
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: Provider.of<ThemeProvider>(context, listen: false).primaryColor))
                  : _ticket == null
                      ? _buildEmptyTicket()
                      : _buildTicketContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyTicket() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 24),
          Text(
            'Masa bos',
            style: TextStyle(
              color: Colors.grey[800],
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Adisyon acmak icin butona tiklayin',
            style: TextStyle(color: Colors.grey[600]),
          ),

          const SizedBox(height: 32),

          // Customer count - 1-10 arası butonlar
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  'Kisi Sayisi',
                  style: TextStyle(
                    color: Colors.grey[700],
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                // İlk satır: 1-5
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final count = index + 1;
                    final isSelected = _customerCount == count;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () => setState(() => _customerCount = count),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.grey[300]!,
                              width: 2,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: Provider.of<ThemeProvider>(context, listen: false).primaryColor.withOpacity(0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Text(
                              '$count',
                              style: TextStyle(
                                color: isSelected ? Colors.white : const Color(0xFF1F2937),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),
                // İkinci satır: 6-10
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final count = index + 6;
                    final isSelected = _customerCount == count;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        onTap: () => setState(() => _customerCount = count),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : Colors.grey[300]!,
                              width: 2,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: Provider.of<ThemeProvider>(context, listen: false).primaryColor.withOpacity(0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    )
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Text(
                              '$count',
                              style: TextStyle(
                                color: isSelected ? Colors.white : const Color(0xFF1F2937),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Open ticket button - open_ticket yetkisi gerekli
          if (_hasPermission('open_ticket'))
            SizedBox(
              width: 300,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _openTicket,
                icon: const Icon(Icons.receipt_long),
                label: const Text('Adisyon Ac', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange[700], size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Adisyon acma yetkiniz yok',
                    style: TextStyle(color: Colors.orange[700], fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTicketContent() {
    final items = (_ticket!['items'] as List?) ?? [];

    return Row(
      children: [
        // Left panel - Items and summary
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ticket info
                _buildTicketInfo(),

                const SizedBox(height: 16),

                // Items list
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.restaurant_menu, size: 48, color: Colors.grey[300]),
                              const SizedBox(height: 12),
                              Text(
                                'Henuz urun eklenmedi',
                                style: TextStyle(color: Colors.grey[500]),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) => _buildItemRow(items[index]),
                        ),
                ),

                // Summary
                _buildSummary(),
              ],
            ),
          ),
        ),

        // Right panel - Action buttons (scrollable)
        Container(
          width: 180,
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: const BorderRadius.only(
              bottomRight: Radius.circular(16),
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // Ürün Ekle - add_item yetkisi gerekli
              if (_hasPermission('add_item')) ...[
                _buildSmallActionButton(
                  icon: Icons.add,
                  label: 'Urun Ekle',
                  color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                  onPressed: _openAddItemModal,
                ),
                const SizedBox(height: 8),
              ],
              // Mutfağa Gönder - print_receipt yetkisi gerekli
              if (_hasPermission('print_receipt')) ...[
                _buildSmallActionButton(
                  icon: Icons.restaurant,
                  label: 'Mutfaga Gonder',
                  color: const Color(0xFFF59E0B),
                  onPressed: _sendToKitchen,
                ),
                const SizedBox(height: 8),
              ],
              // Yazdır - print_receipt yetkisi gerekli
              if (_hasPermission('print_receipt')) ...[
                _buildSmallActionButton(
                  icon: Icons.print,
                  label: 'Yazdir',
                  color: Colors.blueGrey,
                  onPressed: _printTicket,
                ),
                const SizedBox(height: 8),
              ],
              // Masa Değiştir - transfer_table yetkisi gerekli
              if (_hasPermission('transfer_table')) ...[
                _buildSmallActionButton(
                  icon: Icons.swap_horiz,
                  label: 'Masa Degistir',
                  color: Colors.blueGrey,
                  onPressed: _openTransferTableModal,
                ),
                const SizedBox(height: 8),
              ],
              // İndirim - apply_discount yetkisi gerekli
              if (_hasPermission('apply_discount')) ...[
                _buildSmallActionButton(
                  icon: Icons.percent,
                  label: _localDiscount > 0 ? 'Indirim (%${_localDiscount.toStringAsFixed(0)})' : 'Indirim',
                  color: _localDiscount > 0 ? const Color(0xFFF59E0B) : Colors.blueGrey,
                  onPressed: _openDiscountModal,
                ),
                const SizedBox(height: 8),
              ],

              // Ödeme butonları için divider (en az biri varsa göster)
              if (_hasPermission('close_ticket') || _hasPermission('void_ticket'))
                Divider(color: Colors.grey[300], height: 20),

              // Nakit - close_ticket yetkisi gerekli
              if (_hasPermission('close_ticket')) ...[
                _buildSmallActionButton(
                  icon: Icons.payments,
                  label: 'Nakit',
                  color: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                  onPressed: () => _closeTicket('cash'),
                ),
                const SizedBox(height: 8),
              ],
              // Kredi Kartı - close_ticket yetkisi gerekli
              if (_hasPermission('close_ticket')) ...[
                _buildSmallActionButton(
                  icon: Icons.credit_card,
                  label: 'Kredi Karti',
                  color: const Color(0xFF3B82F6),
                  onPressed: () => _closeTicket('credit_card'),
                ),
                const SizedBox(height: 8),
              ],
              // Adisyon İptal - void_ticket yetkisi gerekli
              if (_hasPermission('void_ticket'))
                _buildSmallActionButton(
                  icon: Icons.delete_outline,
                  label: 'Adisyon Iptal',
                  color: const Color(0xFFDC2626),
                  onPressed: _voidTicket,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTicketInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildInfoItem('Adisyon', _ticket!['ticket_number'] ?? '-'),
          const SizedBox(width: 32),
          _buildInfoItem('Garson', _ticket!['waiter_name'] ?? '-'),
          const SizedBox(width: 32),
          _buildInfoItem('Sure', '${_ticket!['duration_minutes'] ?? 0} dk'),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey[600], fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildItemRow(Map<String, dynamic> item) {
    final isCancelled = item['status'] == 'cancelled';
    final notes = item['notes'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCancelled ? Colors.red[50] : Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isCancelled ? Colors.red[200]! : Colors.grey[200]!),
      ),
      child: Row(
        children: [
          // Quantity
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isCancelled ? Colors.red[300] : Provider.of<ThemeProvider>(context, listen: false).primaryColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                '${item['quantity']}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Name and notes
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['product_name'],
                  style: TextStyle(
                    color: isCancelled ? Colors.red[400] : const Color(0xFF1F2937),
                    fontWeight: FontWeight.w500,
                    decoration: isCancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (notes != null && notes.isNotEmpty)
                  Text(
                    notes,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),

          // Price
          Text(
            '${((item['unit_price'] as num) * (item['quantity'] as num)).toStringAsFixed(2)} TL',
            style: TextStyle(
              color: isCancelled ? Colors.red[400] : const Color(0xFF1F2937),
              fontWeight: FontWeight.bold,
              decoration: isCancelled ? TextDecoration.lineThrough : null,
            ),
          ),

          // Cancel button - cancel_item yetkisi gerekli
          if (!isCancelled && _hasPermission('cancel_item'))
            IconButton(
              onPressed: () {
                final itemId = _safeInt(item['id']);
                if (itemId != null) _cancelItem(itemId);
              },
              icon: const Icon(Icons.close, size: 18),
              color: Colors.red[400],
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final subtotal = (_ticket!['subtotal'] as num?)?.toDouble() ?? 0;
    final discountAmount = _calculatedDiscount;
    final total = _calculatedTotal;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _buildSummaryRow('Ara Toplam', '${subtotal.toStringAsFixed(2)} TL'),
          if (discountAmount > 0)
            _buildSummaryRow(
              _localDiscountType == 'percentage'
                  ? 'Indirim (%${_localDiscount.toStringAsFixed(0)})'
                  : 'Indirim',
              '-${discountAmount.toStringAsFixed(2)} TL',
              isDiscount: true,
            ),
          Divider(color: Colors.grey[300]),
          _buildSummaryRow('TOPLAM', '${total.toStringAsFixed(2)} TL', isTotal: true),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isDiscount = false, bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDiscount ? Colors.red : (isTotal ? const Color(0xFF1F2937) : Colors.grey[600]),
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 18 : 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: isDiscount ? Colors.red : (isTotal ? Provider.of<ThemeProvider>(context, listen: false).primaryColor : const Color(0xFF1F2937)),
              fontWeight: isTotal ? FontWeight.bold : FontWeight.w500,
              fontSize: isTotal ? 24 : 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildSmallActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}
