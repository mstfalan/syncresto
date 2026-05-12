import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/log_service.dart';
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
  final Map<String, dynamic>? section;

  const TicketModal({
    super.key,
    required this.table,
    required this.apiService,
    required this.printerService,
    required this.waiter,
    required this.onClose,
    this.showProductImages = true,
    this.section,
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
  Timer? _waitTickTimer;

  @override
  void initState() {
    super.initState();
    _loadTicket();
    // 30sn'de bir setState — bekleme rengi/sayaci taze kalsin (ag cagrisi YOK)
    _waitTickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _waitTickTimer?.cancel();
    super.dispose();
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

  Future<void> _loadTicket({bool autoOpenAddItem = false}) async {
    setState(() => _isLoading = true);
    try {
      final response = await widget.apiService.getTableTicket(_tableId);
      print('[TicketModal] _loadTicket response: $response');
      setState(() {
        if (response != null && response['ticket'] != null) {
          _ticket = response['ticket'];
        } else if (response != null && !response.containsKey('ticket') && response['id'] != null) {
          _ticket = response;
        } else {
          _ticket = null;
        }
        // Sunucudan gelen indirim bilgisini yükle (discount her zaman tutar olarak saklanıyor)
        if (_ticket != null) {
          final serverDiscount = _ticket!['discount_amount'] ?? _ticket!['discount'];
          if (serverDiscount != null) {
            final discountVal = serverDiscount is num ? serverDiscount.toDouble() : double.tryParse(serverDiscount.toString()) ?? 0;
            if (discountVal > 0) {
              _localDiscount = discountVal;
              _localDiscountType = 'fixed'; // DB'de tutar olarak saklanıyor, her zaman fixed
            }
          }
        }
        print('[TicketModal] _ticket set: $_ticket, discount: $_localDiscount $_localDiscountType');
      });

      // Adisyon açıldıktan sonra otomatik ürün ekle ekranını aç
      if (autoOpenAddItem && _ticket != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openAddItemScreen();
        });
      }
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
        // Ticket detaylarini yeniden yukle ve otomatik ürün ekle ekranını aç
        await _loadTicket(autoOpenAddItem: true);
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesap Kapat', style: TextStyle(fontSize: 22)),
        content: Text('${paymentMethod == 'cash' ? 'Nakit' : 'Kredi Karti'} ile hesap kapatilacak. Emin misiniz?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white), child: const Text('Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
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

      // Salonun summary_printer_id'si varsa özet fiş yazdır
      await _printSummaryReceipt(paymentMethod);

      _showSuccess('Hesap kapatildi');
      widget.onClose();
    } catch (e) {
      _showError('Hesap kapatilamadi: $e');
    }
  }

  /// Yazdır ve Kapat - Mutfağa gönder + Özet fiş + Hesap kapat (tek butonla)
  Future<void> _printAndCloseTicket(String paymentMethod) async {
    if (_ticket == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Yazdir ve Kapat', style: TextStyle(fontSize: 22)),
        content: Text(
          '${paymentMethod == 'cash' ? 'Nakit' : 'Kredi Karti'} ile hesap kapatilacak.\n\n'
          '• Mutfaga siparis gonderilecek\n'
          '• Ozet fis yazdirilacak\n'
          '• Hesap kapatilacak\n\n'
          'Devam edilsin mi?',
          style: const TextStyle(fontSize: 16),
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white), child: const Text('Yazdır ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final isOffline = _ticket!['offline'] == true;
      final ticketId = isOffline
          ? _safeInt(_ticket!['local_id']) ?? _safeInt(_ticket!['id'])
          : _safeInt(_ticket!['id']);
      if (ticketId == null) throw Exception('Ticket ID is null');

      print('[TicketModal] printAndClose: ticketId=$ticketId, isOffline=$isOffline');

      // 1. Mutfağa gönder (yazdırılmamış ürünler varsa) - hata olsa da devam et
      try {
        await _sendToKitchenSilent();
      } catch (e) {
        print('[TicketModal] Mutfak gonderim hatasi (devam ediliyor): $e');
      }

      // 2. Özet fiş yazdır - hata olsa da devam et
      try {
        await _printSummaryReceipt(paymentMethod);
      } catch (e) {
        print('[TicketModal] Ozet fis hatasi (devam ediliyor): $e');
      }

      // 3. Hesabı kapat
      await widget.apiService.closeTicket(
        ticketId: ticketId,
        paymentMethod: paymentMethod,
        waiterId: _waiterId,
      );

      _showSuccess('Hesap kapatildi');
      widget.onClose();
    } catch (e) {
      print('[TicketModal] printAndClose hatasi: $e');
      _showError('Hesap kapatma hatasi: $e');
    }
  }

  /// Mutfağa sessiz gönderim (dialog göstermeden) — v1.2.0 atomik akis.
  /// 12 May 2026: 11 May'da eklenen dry_run + mark/unmark 3-step akisi GERI SARILDI
  /// (race condition + cift fis sorunu sahada cozulmedi). Backend printKitchen anlik
  /// printed=1 SET eder. Yazici fail olsa bile DB tutarli (manuel reprint Yazdirma
  /// Gecmisi'nden yapilir).
  Future<void> _sendToKitchenSilent() async {
    if (_ticket == null) return;

    try {
      final ticketId = _safeInt(_ticket!['id']);
      if (ticketId == null) {
        print('[TicketModal] Ticket ID bulunamadi');
        return;
      }

      // Race condition guard (pending addItem'lar commit olsun)
      await Future.delayed(const Duration(milliseconds: 500));

      final result = await widget.apiService.printKitchen(
        ticketId: ticketId,
        waiterId: _waiterId,
      );

      if (result['success'] != true) {
        print('[TicketModal] Mutfak fisi alinamadi: ${result['error']}');
        return;
      }

      final items = result['items'] as List? ?? [];
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};

      if (items.isEmpty) {
        print('[TicketModal] Yazdirilacak yeni urun yok');
        return;
      }

      // Ticket bilgilerini ekle
      ticketInfo['table_number'] = widget.table['table_number'] ?? 'Masa ${widget.table['id']}';
      ticketInfo['section_name'] = widget.table['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter['name'] ?? '';

      int successCount = 0;
      int failCount = 0;
      final List<int> successJobIds = [];
      final List<int> failJobIds = [];

      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        final printerName = group['printer_name'] as String? ?? 'Varsayilan';
        final jobId = _safeInt(group['job_id']);

        if (groupItems.isEmpty || printerIp == null) continue;

        final ok = await widget.printerService.printKitchenReceiptToIp(
          ticket: ticketInfo,
          items: groupItems,
          ip: printerIp,
          port: printerPort,
        );

        if (ok) {
          successCount += groupItems.length;
          if (jobId != null) successJobIds.add(jobId);
          print('[TicketModal] Silent: $printerName -> ${groupItems.length} urun BASILDI');
        } else {
          failCount += groupItems.length;
          if (jobId != null) failJobIds.add(jobId);
          print('[TicketModal] Silent: $printerName -> BASILAMADI (${groupItems.length} urun)');
        }
      }

      // Telemetri: print_jobs lifecycle (dashboard "stuck" fix)
      if (successJobIds.isNotEmpty) {
        widget.apiService.markItemsPrinted(
          ticketId: ticketId, itemIds: const [], jobIds: successJobIds,
        ).catchError((_) => false);
      }
      if (failJobIds.isNotEmpty) {
        widget.apiService.unmarkItemsPrinted(
          ticketId: ticketId, itemIds: const [], jobIds: failJobIds, error: 'TCP unreachable',
        ).catchError((_) => false);
      }

      // Telemetri log (admin panel POS Loglari)
      final tableLabel = widget.table['table_number']?.toString() ?? 'Masa ${widget.table['id']}';
      if (failCount > 0) {
        LogService().error(
          LogType.error,
          'Mutfak fisi EKSIK basildi (silent): $tableLabel — $failCount urun yaziciya gitmedi (printed=1 DB)',
          details: {
            'ticket_id': ticketId,
            'table': tableLabel,
            'printed_count': successCount,
            'failed_count': failCount,
          },
        );
      } else if (successCount > 0) {
        LogService().logAction(
          'Mutfak fisi basildi (silent): $tableLabel — $successCount urun',
          details: {
            'ticket_id': ticketId,
            'table': tableLabel,
            'printed_count': successCount,
          },
        );
      }
    } catch (e) {
      print('[TicketModal] Mutfaga gonderme hatasi: $e');
      LogService().error(
        LogType.error,
        'Mutfak fisi (silent) exception: $e',
        details: {'ticket_id': _safeInt(_ticket?['id'])},
      );
    }
  }

  /// Salonun summary_printer_id'sine göre özet fiş yazdırır
  Future<void> _printSummaryReceipt(String paymentMethod) async {
    print('[TicketModal] ========== OZET FIS BASLADI ==========');
    print('[TicketModal] section: ${widget.section}');
    print('[TicketModal] ticket: $_ticket');

    if (widget.section == null || widget.section!.isEmpty) {
      print('[TicketModal] Section null veya bos, ozet fis atlanacak');
      return;
    }

    final summaryPrinterId = widget.section!['summary_printer_id'];
    print('[TicketModal] summary_printer_id: $summaryPrinterId (type: ${summaryPrinterId.runtimeType})');

    if (summaryPrinterId == null) {
      print('[TicketModal] Salon icin ozet fis yazicisi tanimli degil');
      return;
    }

    try {
      // Yazıcı bilgilerini al
      print('[TicketModal] Yazicilar aliniyor...');
      final printers = await widget.apiService.getPrinters();
      print('[TicketModal] ${printers.length} yazici bulundu');

      // ID karşılaştırması - int veya string olabilir
      final targetId = summaryPrinterId is String ? int.tryParse(summaryPrinterId) : summaryPrinterId;
      final printer = printers.firstWhere(
        (p) {
          final printerId = p['id'] is String ? int.tryParse(p['id']) : p['id'];
          return printerId == targetId;
        },
        orElse: () => <String, dynamic>{},
      );

      if (printer.isEmpty) {
        print('[TicketModal] Yazici bulunamadi: $summaryPrinterId (targetId: $targetId)');
        print('[TicketModal] Mevcut yazicilar: ${printers.map((p) => '${p['id']}:${p['name']}').toList()}');
        return;
      }

      // getPrinters() 'ip' key'i döndürüyor, 'ip_address' değil
      final ip = (printer['ip'] ?? printer['ip_address']) as String?;
      final port = (printer['port'] as num?)?.toInt() ?? 9100;
      print('[TicketModal] Yazici bulundu: ${printer['name']} - $ip:$port');

      if (ip == null || ip.isEmpty) {
        print('[TicketModal] Yazici IP adresi bos');
        return;
      }

      // Brand name'i ThemeProvider'dan al
      final brandName = Provider.of<ThemeProvider>(context, listen: false).brandName;

      // Özet fiş yazdır
      print('[TicketModal] Ozet fis yazdiriliyor: $ip:$port, brand: $brandName');
      final success = await widget.printerService.printClosingReceipt(
        ticket: _ticket!,
        table: widget.table,
        waiterName: widget.waiter['name'] ?? 'Garson',
        paymentMethod: paymentMethod,
        targetIp: ip,
        targetPort: port,
        brandName: brandName,
      );
      print('[TicketModal] Ozet fis sonuc: $success');
    } catch (e, stack) {
      print('[TicketModal] Ozet fis yazdirma hatasi: $e');
      print('[TicketModal] Stack: $stack');
      // Hata olsa da hesap kapatmayı engelleme
    }
  }

  Future<void> _voidTicket() async {
    if (_ticket == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon İptal', style: TextStyle(fontSize: 22, color: Colors.red)),
        content: const Text('Adisyon iptal edilecek. Bu işlem geri alınamaz. Emin misiniz?', style: TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('Vazgeç', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), child: const Text('İptal Et', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
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
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Ürün İptal', style: TextStyle(fontSize: 22, color: Colors.red)),
        content: const Text('Bu ürün iptal edilecek. Emin misiniz?', style: TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('Vazgeç', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), child: const Text('İptal Et', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
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

  /// Ürün ekle ekranını aç (full-screen)
  Future<void> _openAddItemScreen() async {
    if (_ticket == null) {
      _showError('Lütfen önce adisyon açın');
      return;
    }

    final ticketId = _safeInt(_ticket!['id']) ?? _safeInt(_ticket!['local_id']);
    if (ticketId == null) {
      _showError('Ticket ID bulunamadi');
      return;
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AddItemModal(
        apiService: widget.apiService,
        printerService: widget.printerService,
        ticketId: ticketId,
        waiterId: _waiterId,
        onItemAdded: () => _loadTicket(),
        onClose: () {
          Navigator.pop(context); // AddItemModal'ı kapat
          widget.onClose(); // TicketModal'ı da kapat
        },
        showProductImages: widget.showProductImages,
        tableId: _tableId,
        table: widget.table,
        waiter: widget.waiter,
        section: widget.section,
      ),
    );
  }

  // Eski uyumluluk
  Future<void> _openAddItemModal() async => _openAddItemScreen();

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

      // Race condition guard: garson son urunu ekleyip hemen mutfak'a basarsa,
      // optimistic UI'daki item henuz DB'ye INSERT olmamis olabilir → printKitchen
      // o item'i atlar. 500ms beklemek pending addItem'larin commit olmasini saglar.
      await Future.delayed(const Duration(milliseconds: 500));

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

      final List<String> failReasons = [];
      int successCount = 0;
      int failCount = 0;
      final List<int> successJobIds = [];
      final List<int> failJobIds = [];

      for (final group in printerGroups) {
        final printerIp = group['printer_ip'] as String?;
        final printerPort = group['printer_port'] as int? ?? 9100;
        final groupItems = group['items'] as List? ?? [];
        final printerName = group['printer_name'] as String? ?? 'Varsayilan';
        final jobId = _safeInt(group['job_id']);

        if (groupItems.isEmpty) continue;

        bool success = false;

        if (printerIp != null && printerIp.isNotEmpty) {
          success = await widget.printerService.printKitchenReceiptToIp(
            ticket: ticketInfo,
            items: groupItems,
            ip: printerIp,
            port: printerPort,
          );
        } else {
          success = await widget.printerService.printKitchenReceipt(
            ticket: ticketInfo,
            items: groupItems,
          );
        }

        if (success) {
          successCount += groupItems.length;
          if (jobId != null) successJobIds.add(jobId);
          print('[TicketModal] $printerName -> ${groupItems.length} urun BASILDI');
        } else {
          failCount += groupItems.length;
          if (jobId != null) failJobIds.add(jobId);
          failReasons.add(printerName);
          print('[TicketModal] $printerName -> BASAMADI');
        }
      }

      // Telemetri: panel_print_jobs lifecycle'i tamamla (dashboard "stuck" yaniltma fix).
      // Hata gizle — telemetri kritik degil, asil is yapildi.
      if (successJobIds.isNotEmpty) {
        widget.apiService.markItemsPrinted(
          ticketId: ticketId,
          itemIds: const [],
          jobIds: successJobIds,
        ).catchError((_) => false);
      }
      if (failJobIds.isNotEmpty) {
        widget.apiService.unmarkItemsPrinted(
          ticketId: ticketId,
          itemIds: const [],
          jobIds: failJobIds,
          error: 'TCP unreachable',
        ).catchError((_) => false);
      }

      // Admin panel POS Loglari icin ozet (manuel buton)
      final tableLabel = widget.table['table_number']?.toString() ?? 'Masa ${widget.table['id']}';
      if (failCount > 0) {
        LogService().error(
          LogType.error,
          'Mutfak fisi yazici hatasi: $tableLabel — $failCount urun yaziciya gitmedi (printed=1 DB; manuel reprint gerek)',
          details: {
            'ticket_id': ticketId,
            'table': tableLabel,
            'printed_count': successCount,
            'failed_count': failCount,
            'failed_printers': failReasons,
          },
        );
      } else if (successCount > 0) {
        LogService().logAction(
          'Mutfak fisi basildi: $tableLabel — $successCount urun',
          details: {
            'ticket_id': ticketId,
            'table': tableLabel,
            'printed_count': successCount,
          },
        );
      }

      // Kullaniciya net feedback — yazici hatasinda DB printed=1, manuel reprint gerek
      if (failCount > 0 && successCount == 0) {
        _showError('YAZICI HATASI: ${failReasons.join(", ")} basamadi. Yazicilari kontrol edin; gerekirse "Yazdirma Gecmisi -> Tekrar Yazdir" kullanin.');
        // Modal kapali kalsin — kullanici durumu gormeli
      } else if (failCount > 0) {
        _showError('Kismen basarili: $successCount basildi, $failCount basamadi (${failReasons.join(", ")}). "Yazdirma Gecmisi -> Tekrar Yazdir" ile basamayanlari yazdirabilirsiniz.');
      } else {
        // Tam basarili
        widget.onClose();
      }
    } catch (e) {
      print('[TicketModal] Mutfaga gonderme hatasi: $e');
      LogService().error(
        LogType.error,
        'Mutfak fisi exception: $e',
        details: {'ticket_id': _safeInt(_ticket?['id'])},
      );
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
    // Önce sunucudan gelen discount_amount'u kullan
    final serverDiscount = _ticket!['discount_amount'] ?? _ticket!['discount'];
    if (serverDiscount != null) {
      final val = serverDiscount is num ? serverDiscount.toDouble() : double.tryParse(serverDiscount.toString()) ?? 0;
      if (val > 0) return val;
    }
    // Yoksa local discount'u hesapla
    if (_localDiscount <= 0) return 0;
    final subtotal = (_ticket!['subtotal'] as num?)?.toDouble() ?? 0;
    if (_localDiscountType == 'percentage') {
      return subtotal * _localDiscount / 100;
    }
    return _localDiscount;
  }

  double get _calculatedTotal {
    if (_ticket == null) return 0;
    // Önce sunucudan gelen total_amount'u kullan
    final serverTotal = _ticket!['total_amount'] ?? _ticket!['total'];
    if (serverTotal != null) {
      final val = serverTotal is num ? serverTotal.toDouble() : double.tryParse(serverTotal.toString()) ?? 0;
      if (val > 0 && _calculatedDiscount > 0) return val;
    }
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
                      : _buildTicketHasContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyTicket() {
    final theme = Provider.of<ThemeProvider>(context, listen: false);

    Widget buildCountButton(int count) {
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _customerCount = count);
            if (_hasPermission('open_ticket')) _openTicket();
          },
          child: Container(
            height: 80,
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[300]!, width: 2),
            ),
            child: Center(
              child: Text('$count', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF1F2937))),
            ),
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text('Masa Boş', style: TextStyle(color: Colors.grey[800], fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Kişi sayısına dokunarak adisyon açın', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
          const SizedBox(height: 24),
          Container(
            width: 420,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Row(children: List.generate(5, (i) => buildCountButton(i + 1))),
                Row(children: List.generate(5, (i) => buildCountButton(i + 6))),
              ],
            ),
          ),
          if (!_hasPermission('open_ticket')) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.orange[200]!)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.warning_amber, color: Colors.orange[700], size: 20),
                const SizedBox(width: 8),
                Text('Adisyon açma yetkiniz yok', style: TextStyle(color: Colors.orange[700], fontWeight: FontWeight.w500)),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  /// Adisyon var — büyük "Ürün Ekle" butonu göster, tıklayınca AddItemModal açılır
  Widget _buildTicketHasContent() {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    final items = (_ticket!['items'] as List?) ?? [];
    final activeItems = items.where((i) => i['status'] != 'cancelled').toList();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Ticket bilgisi
          _buildTicketInfo(),
          const SizedBox(height: 24),

          // Ürün sayısı ve toplam
          if (activeItems.isNotEmpty) ...[
            Text(
              '${activeItems.length} urun - ${_calculatedTotal.toStringAsFixed(2)} TL',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.grey[700]),
            ),
            const SizedBox(height: 24),
          ],

          // Büyük "Ürün Ekle / Adisyon Yönet" butonu
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openAddItemScreen,
            child: Container(
              width: 400,
              height: 80,
              decoration: BoxDecoration(
                color: theme.primaryColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: theme.primaryColor.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(activeItems.isEmpty ? Icons.add_circle : Icons.restaurant_menu, color: Colors.white, size: 32),
                  const SizedBox(width: 12),
                  Text(
                    activeItems.isEmpty ? 'Urun Ekle' : 'Adisyon Yonet',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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

    // Bekleme sureci rengi — masalar ekranindaki ile ayni kural:
    // delivered_at NULL + status active + 10-20dk sari, 20+dk kirmizi
    final isDelivered = item['delivered_at'] != null;
    int waitSeconds = 0;
    if (!isCancelled && !isDelivered) {
      final createdRaw = item['created_at']?.toString();
      if (createdRaw != null) {
        final created = DateTime.tryParse(createdRaw);
        if (created != null) {
          waitSeconds = DateTime.now().toUtc().difference(created.toUtc()).inSeconds;
        }
      }
    }
    final waitMinutes = waitSeconds ~/ 60;
    final isLate = waitSeconds >= 1200; // 20dk
    final isWarning = !isLate && waitSeconds >= 600; // 10dk

    final Color bgColor;
    final Color borderColor;
    if (isCancelled) {
      bgColor = Colors.red[50]!;
      borderColor = Colors.red[200]!;
    } else if (isLate) {
      bgColor = const Color(0xFFFEE2E2);
      borderColor = const Color(0xFFDC2626);
    } else if (isWarning) {
      bgColor = const Color(0xFFFEF3C7);
      borderColor = const Color(0xFFF59E0B);
    } else {
      bgColor = Colors.grey[50]!;
      borderColor = Colors.grey[200]!;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: (isLate || isWarning) ? 2 : 1),
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
                if (!isCancelled && !isDelivered && waitMinutes > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      isLate
                          ? '$waitMinutes dk — gec kaldi'
                          : (isWarning ? '$waitMinutes dk bekliyor' : '$waitMinutes dk'),
                      style: TextStyle(
                        color: isLate
                            ? const Color(0xFFB91C1C)
                            : (isWarning ? const Color(0xFFD97706) : Colors.grey[500]),
                        fontSize: 11,
                        fontWeight: (isLate || isWarning) ? FontWeight.w600 : FontWeight.normal,
                      ),
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
              (_ticket?['discount_type'] == 'percentage' || _localDiscountType == 'percentage')
                  ? 'Indirim (%${(subtotal > 0 ? (discountAmount / subtotal * 100) : 0).toStringAsFixed(0)})'
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
