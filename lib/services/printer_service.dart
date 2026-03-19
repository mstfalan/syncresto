import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';

/// Yazıcı türleri
enum PrinterType {
  kitchen,  // Mutfak
  bar,      // Bar
  cashier,  // Kasa/Adisyon
}

class PrinterService {
  static final PrinterService _instance = PrinterService._internal();
  factory PrinterService() => _instance;
  PrinterService._internal();

  final LogService _logService = LogService();

  // Çoklu yazıcı desteği - her tür için ayrı ayar
  Map<String, Map<String, dynamic>> _printers = {};

  // Sunucudan gelen yazıcılar (read-only cache)
  List<Map<String, dynamic>> _serverPrinters = [];

  // Eski tek yazıcı desteği (geriye uyumluluk)
  Map<String, dynamic>? _printerSettings;

  // Callback for print status
  Function(String message, bool isError)? onStatusChange;

  // Callback for discovered printers
  Function(List<Map<String, dynamic>>)? onPrintersFound;

  /// Sunucudan gelen yazıcılar (read-only)
  List<Map<String, dynamic>> get serverPrinters => List.unmodifiable(_serverPrinters);

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Yeni çoklu yazıcı ayarlarını yükle
      final printersJson = prefs.getString('printers_multi');
      if (printersJson != null) {
        final decoded = jsonDecode(printersJson) as Map<String, dynamic>;
        _printers = decoded.map((key, value) =>
          MapEntry(key, Map<String, dynamic>.from(value)));
        print('[Printer] Coklu yazici ayarlari yuklendi: ${_printers.keys.toList()}');
      }

      // Eski tek yazıcı ayarlarını da yükle (geriye uyumluluk)
      final settingsJson = prefs.getString('printer_settings');
      if (settingsJson != null) {
        _printerSettings = jsonDecode(settingsJson);
        print('[Printer] Eski ayarlar yuklendi: $_printerSettings');

        // Eski ayarı kasa yazıcısı olarak migrate et
        if (_printers.isEmpty && _printerSettings != null) {
          _printers['cashier'] = Map<String, dynamic>.from(_printerSettings!);
          _printers['cashier']!['type'] = 'cashier';
          _printers['cashier']!['name'] = _printerSettings!['name'] ?? 'Kasa Yazicisi';
          await _savePrinters();
        }
      }
    } catch (e) {
      print('[Printer] Ayarlar yuklenemedi: $e');
    }
  }

  /// Sunucudan yazıcı listesini yükle (ApiService üzerinden)
  /// Bu metod admin panelden eklenen yazıcıları getirir
  Future<void> loadFromServer(Future<List<Map<String, dynamic>>> Function() fetchPrinters) async {
    try {
      final printers = await fetchPrinters();

      if (printers.isNotEmpty) {
        _serverPrinters = printers;
        print('[Printer] Sunucudan ${printers.length} yazici yuklendi');

        // Önce sunucudan gelen yazıcıları temizle (yeniden yükle)
        _printers.removeWhere((key, value) => value['fromServer'] == true);

        // Sunucu yazıcılarını local cache'e ekle - HER YAZICI AYRI KEY İLE
        for (final p in printers) {
          // Sadece aktif yazıcıları ekle
          if (p['is_active'] != true && p['is_active'] != 1) continue;

          final departments = p['departments'] as List? ?? [];
          final printerId = p['id'];

          // Her yazıcı kendi ID'siyle kaydedilir: printer_1, printer_2, ...
          final key = 'printer_$printerId';

          // Departman bilgisini de sakla
          String department = 'other';
          if (departments.contains('kitchen')) {
            department = 'kitchen';
          } else if (departments.contains('bar')) {
            department = 'bar';
          } else if (departments.contains('cashier')) {
            department = 'cashier';
          }

          _printers[key] = {
            'id': printerId,
            'name': p['name'],
            'ip': p['ip_address'] ?? p['ip'],
            'port': p['port'] ?? 9100,
            'type': key,
            'department': department,
            'departments': departments,
            'fromServer': true,
          };
          print('[Printer] Yazici eklendi: ${p['name']} (${p['ip_address'] ?? p['ip']}) -> $key');
        }
        await _savePrinters();
        print('[Printer] Toplam ${_printers.length} yazici kayitli');
      }
    } catch (e) {
      print('[Printer] Sunucudan yazici yuklenemedi: $e');
    }
  }

  /// Sunucudan gelen yazıcı var mı?
  bool get hasServerPrinters => _serverPrinters.isNotEmpty;

  Future<void> _savePrinters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printers_multi', jsonEncode(_printers));
      print('[Printer] Coklu yazici ayarlari kaydedildi');
    } catch (e) {
      print('[Printer] Ayarlar kaydedilemedi: $e');
    }
  }

  /// Yeni yazıcı ekle veya güncelle
  Future<void> addPrinter(String type, Map<String, dynamic> settings) async {
    settings['type'] = type;
    _printers[type] = settings;
    await _savePrinters();

    // Geriye uyumluluk için eski ayarı da güncelle (ilk yazıcı)
    if (_printerSettings == null) {
      _printerSettings = settings;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printer_settings', jsonEncode(settings));
    }
  }

  /// Yazıcı sil
  Future<void> removePrinter(String type) async {
    _printers.remove(type);
    await _savePrinters();
  }

  /// Tüm yazıcıları getir
  List<Map<String, dynamic>> get allPrinters {
    return _printers.entries.map((e) => {
      ...e.value,
      'type': e.key,
    }).toList();
  }

  /// Belirli türdeki yazıcıyı getir
  Map<String, dynamic>? getPrinter(String type) {
    return _printers[type];
  }

  /// Eski API - geriye uyumluluk için
  Future<void> saveSettings(Map<String, dynamic> settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printer_settings', jsonEncode(settings));
      _printerSettings = settings;

      // Yeni sisteme de ekle (kasa yazıcısı olarak)
      final type = settings['type'] ?? 'cashier';
      _printers[type] = settings;
      await _savePrinters();

      print('[Printer] Ayarlar kaydedildi');
    } catch (e) {
      print('[Printer] Ayarlar kaydedilemedi: $e');
    }
  }

  Map<String, dynamic>? get settings => _printerSettings;

  bool get isConfigured {
    // En az bir yazıcı ayarlı mı?
    if (_printers.isNotEmpty) {
      return _printers.values.any((p) =>
        p['ip'] != null && p['ip'].toString().isNotEmpty);
    }
    // Eski tek yazıcı kontrolü
    return _printerSettings != null &&
        _printerSettings!['ip'] != null &&
        _printerSettings!['ip'].toString().isNotEmpty;
  }

  /// Belirli tür yazıcı ayarlı mı?
  bool isPrinterConfigured(String type) {
    final printer = _printers[type];
    return printer != null &&
        printer['ip'] != null &&
        printer['ip'].toString().isNotEmpty;
  }

  /// Yazıcı türü için Türkçe isim
  static String getPrinterTypeName(String type) {
    switch (type) {
      case 'kitchen': return 'Mutfak';
      case 'kitchen2': return 'Mutfak 2';
      case 'bar': return 'Bar';
      case 'cashier': return 'Kasa';
      default:
        if (type.startsWith('printer_')) return 'Ozel';
        return type;
    }
  }

  /// Yazıcı IP ve port bilgisini al (tür veya varsayılan)
  Map<String, dynamic>? _getPrinterConfig(String? type) {
    if (type != null && _printers.containsKey(type)) {
      return _printers[type];
    }
    // Varsayılan: kasa yazıcısı veya ilk bulunan
    if (_printers.containsKey('cashier')) {
      return _printers['cashier'];
    }
    if (_printers.isNotEmpty) {
      return _printers.values.first;
    }
    return _printerSettings;
  }

  /// Prints a ticket receipt
  Future<bool> printTicket(Map<String, dynamic> ticket, {String? printerType}) async {
    final config = _getPrinterConfig(printerType ?? 'cashier');
    if (config == null || config['ip'] == null) {
      onStatusChange?.call('Yazici ayarlanmamis', true);
      _logService.warning(LogType.action, 'Fis yazdirma basarisiz: yazici ayarlanmamis', details: {
        'ticket_number': ticket['ticket_number'],
        'printer_type': printerType ?? 'cashier',
      });
      return false;
    }

    try {
      onStatusChange?.call('Yazici baglaniyor...', false);

      final ip = config['ip'] as String;
      final port = config['port'] as int? ?? 9100;

      // Generate receipt bytes
      final bytes = await _generateTicketReceipt(ticket);

      // Send to printer
      final success = await _sendToPrinter(ip, port, bytes);

      if (success) {
        onStatusChange?.call('Fis yazdirildi', false);
        _logService.logAction('Fis yazdirildi', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
          'printer_type': printerType ?? 'cashier',
        });
      } else {
        onStatusChange?.call('Yazdirma hatasi', true);
        _logService.error(LogType.error, 'Fis yazdirma hatasi', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
        });
      }

      return success;
    } catch (e) {
      print('[Printer] Ticket yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
      _logService.error(LogType.error, 'Fis yazdirma hatasi', error: e, details: {
        'ticket_number': ticket['ticket_number'],
      });
      return false;
    }
  }

  /// Prints an order receipt (for kitchen/bar)
  /// targetPrinter: Sunucudan gelen hedef yazıcı bilgisi (online siparişler için)
  Future<bool> printOrderReceipt(
    Map<String, dynamic> order,
    String department,
    {String? printerType, Map<String, dynamic>? targetPrinter}
  ) async {
    String ip;
    int port;
    String type;

    // Hedef yazıcı belirtilmişse onu kullan (online sipariş)
    final printerIp = targetPrinter?['ip_address'] ?? targetPrinter?['ip'];
    if (targetPrinter != null && printerIp != null) {
      ip = printerIp as String;
      port = (targetPrinter['port'] as num?)?.toInt() ?? 9100;
      type = targetPrinter['name'] ?? 'online';
      print('[Printer] Hedef yazici kullaniliyor: $ip:$port (${targetPrinter['name']})');
    } else {
      // Eski davranış: departmana göre yazıcı türünü belirle
      type = printerType ?? _departmentToPrinterType(department);
      final config = _getPrinterConfig(type);

      if (config == null || config['ip'] == null) {
        onStatusChange?.call('${PrinterService.getPrinterTypeName(type)} yazicisi ayarlanmamis', true);
        _logService.warning(LogType.action, 'Siparis fisi yazdirma basarisiz: yazici ayarlanmamis', details: {
          'order_number': order['order_number'],
          'department': department,
          'printer_type': type,
        });
        return false;
      }

      ip = config['ip'] as String;
      port = config['port'] as int? ?? 9100;
    }

    try {
      onStatusChange?.call('Siparis fisi yazdirilyor...', false);

      // Generate order receipt bytes
      final bytes = await _generateOrderReceipt(order, department);

      // Send to printer
      final success = await _sendToPrinter(ip, port, bytes);

      if (success) {
        final printerName = targetPrinter?['name'] ?? PrinterService.getPrinterTypeName(type);
        onStatusChange?.call('Siparis fisi yazdirildi ($printerName)', false);
        _logService.logAction('Siparis fisi yazdirildi', details: {
          'order_number': order['order_number'],
          'department': department,
          'printer_ip': ip,
          'printer_name': printerName,
          'is_online_order': targetPrinter != null,
        });
      } else {
        _logService.error(LogType.error, 'Siparis fisi yazdirma hatasi', details: {
          'order_number': order['order_number'],
          'department': department,
          'printer_ip': ip,
        });
      }

      return success;
    } catch (e) {
      print('[Printer] Order yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
      _logService.error(LogType.error, 'Siparis fisi yazdirma hatasi', error: e, details: {
        'order_number': order['order_number'],
        'department': department,
      });
      return false;
    }
  }

  /// Departman adından yazıcı türünü belirle
  String _departmentToPrinterType(String department) {
    final dept = department.toLowerCase();
    if (dept.contains('mutfak') || dept.contains('kitchen')) {
      return 'kitchen';
    } else if (dept.contains('bar')) {
      return 'bar';
    }
    return 'kitchen'; // Varsayılan mutfak
  }

  /// Test printer connection
  Future<bool> testConnection(String ip, int port) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );
      await socket.close();
      return true;
    } catch (e) {
      print('[Printer] Baglanti testi basarisiz: $e');
      return false;
    }
  }

  /// Discover network printers by scanning local network
  Future<List<Map<String, dynamic>>> discoverPrinters({
    int port = 9100,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    try {
      print('[Printer] Ag yazicilari taraniyor...');
      onStatusChange?.call('Yazicilar araniyor...', false);

      final List<Map<String, dynamic>> foundPrinters = [];

      // Get local IP to determine subnet
      final interfaces = await NetworkInterface.list();
      String? localIp;

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            localIp = addr.address;
            break;
          }
        }
        if (localIp != null) break;
      }

      if (localIp == null) {
        onStatusChange?.call('Yerel IP bulunamadi', true);
        return [];
      }

      // Get subnet (e.g., 192.168.1.)
      final parts = localIp.split('.');
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}.';

      print('[Printer] Subnet taraniyor: $subnet*:$port');

      // Scan common IP ranges in parallel
      final futures = <Future<Map<String, dynamic>?>>[];

      for (int i = 1; i <= 254; i++) {
        final ip = '$subnet$i';
        futures.add(_checkPrinter(ip, port, timeout));
      }

      final results = await Future.wait(futures);

      for (final result in results) {
        if (result != null) {
          foundPrinters.add(result);
        }
      }

      if (foundPrinters.isEmpty) {
        onStatusChange?.call('Yazici bulunamadi', true);
      } else {
        onStatusChange?.call('${foundPrinters.length} yazici bulundu', false);
      }

      onPrintersFound?.call(foundPrinters);
      return foundPrinters;
    } catch (e) {
      print('[Printer] Yazici tarama hatasi: $e');
      onStatusChange?.call('Tarama hatasi: $e', true);
      return [];
    }
  }

  Future<Map<String, dynamic>?> _checkPrinter(String ip, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      await socket.close();
      print('[Printer] Yazici bulundu: $ip:$port');
      return {
        'ip': ip,
        'port': port,
        'name': 'Yazici ($ip)',
      };
    } catch (e) {
      // Not a printer or not reachable
      return null;
    }
  }

  /// Send bytes to printer via TCP
  Future<bool> _sendToPrinter(String ip, int port, List<int> bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 10),
      );

      socket.add(bytes);
      await socket.flush();
      await socket.close();

      return true;
    } catch (e) {
      print('[Printer] TCP gonderim hatasi: $e');
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Generate ticket receipt bytes
  Future<List<int>> _generateTicketReceipt(Map<String, dynamic> ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // Header
    bytes += generator.text(
      'GREEN CHEF',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    bytes += generator.text(
      'Restoran & Cafe',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();

    // Ticket info
    final ticketNumber = ticket['ticket_number'] ?? '';
    final tableName = _turkishToAscii(ticket['table_name'] ?? ticket['table_number'] ?? 'Masa ${ticket['table_id']}');
    final sectionName = _turkishToAscii(ticket['section_name'] ?? '');
    final waiterName = _turkishToAscii(ticket['waiter_name'] ?? '');
    final createdAt = ticket['created_at'] ?? ticket['opened_at'] ?? '';

    bytes += generator.text('Adisyon: $ticketNumber');
    bytes += generator.text('Masa: ${sectionName.isNotEmpty ? "$sectionName - " : ""}$tableName');
    if (waiterName.isNotEmpty) {
      bytes += generator.text('Garson: $waiterName');
    }
    bytes += generator.text('Tarih: ${_formatDate(createdAt)}');
    bytes += generator.hr();

    // Items
    final items = ticket['items'] as List? ?? [];
    for (final item in items) {
      final name = _turkishToAscii(item['product_name'] ?? '');
      final qty = item['quantity'] ?? 1;
      final price = (item['unit_price'] ?? 0).toDouble() * qty;

      bytes += generator.row([
        PosColumn(
          text: '$qty x $name',
          width: 8,
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          text: '${price.toStringAsFixed(2)} TL',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      // Notes
      if (item['notes'] != null && item['notes'].toString().isNotEmpty) {
        bytes += generator.text(
          '  * ${_turkishToAscii(item['notes'])}',
        );
      }
    }

    bytes += generator.hr();

    // Totals
    final subtotal = (ticket['subtotal'] ?? ticket['total_amount'] ?? 0).toDouble();
    final discount = (ticket['discount_amount'] ?? 0).toDouble();
    final total = subtotal - discount;

    if (discount > 0) {
      bytes += generator.row([
        PosColumn(text: 'Ara Toplam:', width: 8),
        PosColumn(
          text: '${subtotal.toStringAsFixed(2)} TL',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Indirim:', width: 8),
        PosColumn(
          text: '-${discount.toStringAsFixed(2)} TL',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
    }

    bytes += generator.row([
      PosColumn(
        text: 'TOPLAM:',
        width: 8,
        styles: const PosStyles(bold: true, height: PosTextSize.size2),
      ),
      PosColumn(
        text: '${total.toStringAsFixed(2)} TL',
        width: 4,
        styles: const PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size2,
        ),
      ),
    ]);

    // Payment method
    final paymentMethod = ticket['payment_method'];
    if (paymentMethod != null) {
      bytes += generator.hr();
      bytes += generator.text(
        'Odeme: ${_paymentMethodLabel(paymentMethod)}',
        styles: const PosStyles(align: PosAlign.center),
      );
    }

    // Footer
    bytes += generator.hr();
    bytes += generator.text(
      'Afiyet olsun!',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'SyncResto POS',
      styles: const PosStyles(align: PosAlign.center),
    );

    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }

  /// Generate web order receipt (same format as server)
  Future<List<int>> _generateOrderReceipt(Map<String, dynamic> order, String department) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // ===== HEADER =====
    final settings = order['_settings'] as Map<String, dynamic>?;
    final brandName = _turkishToAscii(settings?['brand_name'] ?? 'GREEN CHEF');
    final contactPhone = settings?['contact_phone'] ?? '';

    bytes += generator.text(
      brandName.toUpperCase(),
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    if (contactPhone.isNotEmpty) {
      bytes += generator.text(
        'Tel: $contactPhone',
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    bytes += generator.hr(ch: '=');

    // ===== ORDER INFO =====
    final orderNumber = order['order_number'] ?? order['ticket_number'] ?? '';
    bytes += generator.text(
      'SIPARIS: #$orderNumber',
      styles: const PosStyles(bold: true),
    );
    bytes += generator.text('Tarih: ${_formatDate(order['created_at']?.toString())}');
    bytes += generator.hr();

    // ===== CUSTOMER INFO =====
    bytes += generator.text(
      'MUSTERI BILGILERI',
      styles: const PosStyles(bold: true),
    );

    final customerName = _turkishToAscii(order['customer_name'] ?? 'Misafir');
    bytes += generator.text(customerName);

    if (order['customer_phone'] != null && order['customer_phone'].toString().isNotEmpty) {
      bytes += generator.text('Tel: ${order['customer_phone']}');
    }

    if (order['customer_address'] != null && order['customer_address'].toString().isNotEmpty) {
      bytes += generator.text(_turkishToAscii(order['customer_address']));
    }

    if (order['courier_notes'] != null && order['courier_notes'].toString().isNotEmpty) {
      bytes += generator.text('Not: ${_turkishToAscii(order['courier_notes'])}');
    }

    if (order['notes'] != null && order['notes'].toString().isNotEmpty) {
      bytes += generator.text('Siparis Notu: ${_turkishToAscii(order['notes'])}');
    }
    bytes += generator.hr();

    // ===== PRODUCTS =====
    bytes += generator.text(
      'URUNLER',
      styles: const PosStyles(bold: true),
    );

    final items = order['items'] as List? ?? [];
    for (final item in items) {
      final name = _turkishToAscii(item['product_name'] ?? item['name'] ?? '');
      final qty = item['quantity'] ?? 1;

      // Ürün adı kalın ve büyük (fiyat yok)
      bytes += generator.text(
        '$qty x $name',
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
        ),
      );

      // Extras
      if (item['extras'] != null && (item['extras'] as List).isNotEmpty) {
        for (final extra in item['extras']) {
          bytes += generator.text('  + ${_turkishToAscii(extra.toString())}');
        }
      }

      // Notes
      if (item['notes'] != null && item['notes'].toString().isNotEmpty) {
        bytes += generator.text(
          '  >>> ${_turkishToAscii(item['notes'])} <<<',
          styles: const PosStyles(bold: true),
        );
      }

      bytes += generator.text(''); // Boşluk
    }
    bytes += generator.hr();

    // ===== TOTALS (sadece KASA fişinde) =====
    final isKasa = department.toUpperCase() == 'KASA';
    if (isKasa) {
      final subtotal = ((order['subtotal'] ?? 0) as num).toDouble();
      final deliveryFee = ((order['delivery_fee'] ?? 0) as num).toDouble();
      final discountAmount = ((order['discount_amount'] ?? order['discount'] ?? 0) as num).toDouble();
      final total = ((order['total'] ?? subtotal) as num).toDouble();

      bytes += generator.row([
        PosColumn(text: 'Ara Toplam:', width: 8),
        PosColumn(
          text: '${subtotal.toStringAsFixed(2)} TL',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      if (deliveryFee > 0) {
        bytes += generator.row([
          PosColumn(text: 'Teslimat:', width: 8),
          PosColumn(
            text: '${deliveryFee.toStringAsFixed(2)} TL',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      if (discountAmount > 0) {
        bytes += generator.row([
          PosColumn(text: 'Indirim:', width: 8),
          PosColumn(
            text: '-${discountAmount.toStringAsFixed(2)} TL',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      bytes += generator.hr();
      bytes += generator.row([
        PosColumn(
          text: 'TOPLAM:',
          width: 6,
          styles: const PosStyles(bold: true, height: PosTextSize.size2),
        ),
        PosColumn(
          text: '${total.toStringAsFixed(2)} TL',
          width: 6,
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
          ),
        ),
      ]);

      // Ödeme yöntemi
      final paymentMethod = order['payment_method'];
      if (paymentMethod != null) {
        bytes += generator.hr();
        bytes += generator.text(
          'Odeme: ${_paymentMethodLabel(paymentMethod)}',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        );
      }
    }

    // ===== FOOTER =====
    bytes += generator.hr(ch: '=');
    bytes += generator.text(
      'Afiyet olsun!',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'SyncResto POS',
      styles: const PosStyles(align: PosAlign.center),
    );

    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }

  String _turkishToAscii(String text) {
    const turkishChars = 'ÇçĞğİıÖöŞşÜü';
    const asciiChars = 'CcGgIiOoSsUu';

    String result = text;
    for (int i = 0; i < turkishChars.length; i++) {
      result = result.replaceAll(turkishChars[i], asciiChars[i]);
    }
    return result;
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return '';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }

  String _formatTime(String? isoDate) {
    if (isoDate == null) return '';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }

  String _paymentMethodLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Nakit';
      case 'card':
        return 'Kredi Karti';
      case 'multinet':
        return 'Multinet';
      case 'sodexo':
        return 'Sodexo';
      case 'setcard':
        return 'Setcard';
      default:
        return method;
    }
  }

  /// Mutfak fişi yazdır (sadece yazdırılmamış ürünler)
  Future<bool> printKitchenReceipt({
    required Map<String, dynamic> ticket,
    required List<dynamic> items,
    String printerType = 'kitchen',
  }) async {
    final config = _getPrinterConfig(printerType);

    if (config == null || config['ip'] == null) {
      onStatusChange?.call('${PrinterService.getPrinterTypeName(printerType)} yazicisi ayarlanmamis', true);
      _logService.warning(LogType.action, 'Mutfak fisi yazdirma basarisiz: yazici ayarlanmamis', details: {
        'ticket_number': ticket['ticket_number'],
        'printer_type': printerType,
        'item_count': items.length,
      });
      return false;
    }

    if (items.isEmpty) {
      onStatusChange?.call('Yazdirilacak urun yok', false);
      return true;
    }

    try {
      onStatusChange?.call('Mutfak fisi yazdirilyor...', false);

      final ip = config['ip'] as String;
      final port = config['port'] as int? ?? 9100;

      final bytes = await _generateKitchenReceipt(ticket, items);
      final success = await _sendToPrinter(ip, port, bytes);

      if (success) {
        onStatusChange?.call('Mutfak fisi yazdirildi (${items.length} urun)', false);
        _logService.logAction('Mutfak fisi yazdirildi', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
          'printer_type': printerType,
          'item_count': items.length,
        });
      } else {
        onStatusChange?.call('Mutfak fisi yazdirilamadi', true);
        _logService.error(LogType.error, 'Mutfak fisi yazdirma hatasi', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
          'item_count': items.length,
        });
      }

      return success;
    } catch (e) {
      print('[Printer] Mutfak fisi yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
      _logService.error(LogType.error, 'Mutfak fisi yazdirma hatasi', error: e, details: {
        'ticket_number': ticket['ticket_number'],
        'item_count': items.length,
      });
      return false;
    }
  }

  /// Belirli IP'ye mutfak fişi yazdır (sunucudan gelen yazıcı bilgileriyle)
  Future<bool> printKitchenReceiptToIp({
    required Map<String, dynamic> ticket,
    required List<dynamic> items,
    required String ip,
    int port = 9100,
  }) async {
    if (items.isEmpty) {
      onStatusChange?.call('Yazdirilacak urun yok', false);
      return true;
    }

    try {
      onStatusChange?.call('Mutfak fisi yazdirilyor ($ip)...', false);

      final bytes = await _generateKitchenReceipt(ticket, items);
      final success = await _sendToPrinter(ip, port, bytes);

      if (success) {
        onStatusChange?.call('Mutfak fisi yazdirildi ($ip)', false);
        _logService.logAction('Mutfak fisi yazdirildi (IP)', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
          'printer_port': port,
          'item_count': items.length,
        });
      } else {
        onStatusChange?.call('Mutfak fisi yazdirilamadi ($ip)', true);
        _logService.error(LogType.error, 'Mutfak fisi yazdirma hatasi (IP)', details: {
          'ticket_number': ticket['ticket_number'],
          'printer_ip': ip,
          'item_count': items.length,
        });
      }

      return success;
    } catch (e) {
      print('[Printer] Mutfak fisi yazdirilirken hata ($ip): $e');
      onStatusChange?.call('Hata: $e', true);
      _logService.error(LogType.error, 'Mutfak fisi yazdirma hatasi (IP)', error: e, details: {
        'ticket_number': ticket['ticket_number'],
        'printer_ip': ip,
        'item_count': items.length,
      });
      return false;
    }
  }

  /// Mutfak fişi formatı oluştur
  Future<List<int>> _generateKitchenReceipt(
    Map<String, dynamic> ticket,
    List<dynamic> items,
  ) async {
    print('[Printer] ============================================');
    print('[Printer] _generateKitchenReceipt CAGRILDI - V2');
    print('[Printer] ticket: $ticket');
    print('[Printer] items: ${items.length} adet');
    print('[Printer] ============================================');

    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // ===== ÜST BOŞLUK (70px ~ 10 satır) =====
    bytes += generator.feed(10);

    // ===== MASA BİLGİSİ (EN BÜYÜK) =====
    final ticketNumber = ticket['ticket_number'] ?? '';
    final tableName = _turkishToAscii(ticket['table_number']?.toString() ?? 'Masa');
    final sectionName = _turkishToAscii(ticket['section_name'] ?? '');
    final waiterName = _turkishToAscii(ticket['waiter_name'] ?? '');

    // Masa numarası çok büyük ve belirgin
    bytes += generator.text(
      'MASA: $tableName',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );

    // Salon adı (varsa)
    if (sectionName.isNotEmpty) {
      bytes += generator.text(
        sectionName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
        ),
      );
    }

    bytes += generator.hr(ch: '=');
    // Adisyon, garson ve saat
    bytes += generator.text('Adisyon: $ticketNumber', styles: const PosStyles(bold: true));
    if (waiterName.isNotEmpty) {
      bytes += generator.text('Garson: $waiterName', styles: const PosStyles(bold: true));
    }
    bytes += generator.text('Saat: ${_formatTime(DateTime.now().toIso8601String())}');
    bytes += generator.hr(ch: '=');

    // ===== ÜRÜNLER =====
    for (final item in items) {
      final name = _turkishToAscii(item['product_name'] ?? '');
      final qty = item['quantity'] ?? 1;
      final portion = item['portion'];
      final notes = item['notes'];

      // Ürün adı ve miktarı büyük fontla
      bytes += generator.text(
        '$qty x $name',
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
        ),
      );

      // Porsiyon bilgisi
      if (portion != null && portion.toString().isNotEmpty) {
        bytes += generator.text('   Porsiyon: ${_turkishToAscii(portion)}');
      }

      // Not varsa belirgin şekilde göster
      if (notes != null && notes.toString().isNotEmpty) {
        bytes += generator.text(
          '   >>> ${_turkishToAscii(notes)} <<<',
          styles: const PosStyles(bold: true),
        );
      }

      bytes += generator.text(''); // Boşluk
    }

    bytes += generator.hr(ch: '=');
    bytes += generator.text(
      'Toplam ${items.length} urun',
      styles: const PosStyles(align: PosAlign.center),
    );

    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }

  /// Hesap kapama özet fişi yazdır (salon bazlı yazıcıya)
  Future<bool> printClosingReceipt({
    required Map<String, dynamic> ticket,
    required Map<String, dynamic> table,
    required String waiterName,
    required String paymentMethod,
    required String targetIp,
    required int targetPort,
    String? brandName,
  }) async {
    try {
      onStatusChange?.call('Ozet fis yazdiriliyor...', false);

      // Generate closing receipt bytes
      final bytes = await _generateClosingReceipt(
        ticket: ticket,
        table: table,
        waiterName: waiterName,
        paymentMethod: paymentMethod,
        brandName: brandName,
      );

      // Send to printer
      final success = await _sendToPrinter(targetIp, targetPort, bytes);

      if (success) {
        onStatusChange?.call('Ozet fis yazdirildi', false);
        _logService.logAction('Ozet fis yazdirildi', details: {
          'ticket_number': ticket['ticket_number'],
          'table': table['table_number'],
          'printer_ip': targetIp,
        });
      } else {
        onStatusChange?.call('Ozet fis yazdirilamadi', true);
      }

      return success;
    } catch (e) {
      print('[Printer] Ozet fis yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
      return false;
    }
  }

  /// Sipariş özeti fişi oluştur (fiyatlı - paket/kasa için)
  Future<List<int>> _generateClosingReceipt({
    required Map<String, dynamic> ticket,
    required Map<String, dynamic> table,
    required String waiterName,
    required String paymentMethod,
    String? brandName,
  }) async {
    print('[Printer] _generateClosingReceipt cagrildi');
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    bytes += generator.reset();

    // Marka adı (dinamik)
    final brand = _turkishToAscii(brandName ?? 'SyncResto');
    bytes += generator.text(
      brand.toUpperCase(),
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    bytes += generator.hr(ch: '=');

    // Başlık
    bytes += generator.text(
      'SIPARIS OZETI',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
      ),
    );
    bytes += generator.hr();

    // Masa bilgisi
    final sectionName = _turkishToAscii(table['section_name'] ?? '');
    final tableNumber = table['table_number'] ?? '-';
    bytes += generator.text(
      'Masa: ${sectionName.isNotEmpty ? "$sectionName - " : ""}$tableNumber',
      styles: const PosStyles(bold: true, height: PosTextSize.size2),
    );

    // Garson bilgisi
    bytes += generator.text(
      'Garson: ${_turkishToAscii(waiterName)}',
      styles: const PosStyles(bold: true),
    );

    // Tarih ve saat
    final now = DateTime.now();
    bytes += generator.text(
      'Tarih: ${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}',
    );
    bytes += generator.text(
      'Saat: ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );

    bytes += generator.hr(ch: '=');

    // Ürünler - fiyatlı
    final items = ticket['items'] as List? ?? [];
    double calculatedTotal = 0;

    for (final item in items) {
      final name = _turkishToAscii(item['product_name'] ?? item['name'] ?? '?');
      final qty = (item['quantity'] ?? 1) as num;
      final unitPrice = (item['unit_price'] ?? item['price'] ?? 0) as num;
      final lineTotal = qty * unitPrice;
      calculatedTotal += lineTotal;
      final notes = item['notes'] as String? ?? '';

      // Ürün adı ve miktarı büyük kalın fontla
      bytes += generator.text(
        '$qty x $name',
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
        ),
      );

      // Fiyat
      bytes += generator.text(
        '${lineTotal.toStringAsFixed(2)} TL',
        styles: const PosStyles(align: PosAlign.right),
      );

      // Ürün notu varsa ekle
      if (notes.isNotEmpty) {
        bytes += generator.text(
          '   NOT: ${_turkishToAscii(notes)}',
          styles: const PosStyles(fontType: PosFontType.fontB),
        );
      }
    }

    bytes += generator.hr();

    // Ara toplam
    final ticketSubtotal = (ticket['subtotal'] as num?)?.toDouble() ?? 0;
    final subtotal = ticketSubtotal > 0 ? ticketSubtotal : calculatedTotal;

    bytes += generator.row([
      PosColumn(text: 'Ara Toplam:', width: 6, styles: const PosStyles(bold: true)),
      PosColumn(text: '${subtotal.toStringAsFixed(2)} TL', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
    ]);

    // İndirim varsa göster
    final discount = (ticket['discount'] ?? ticket['discount_amount'] ?? 0) as num;
    if (discount > 0) {
      bytes += generator.row([
        PosColumn(text: 'Indirim:', width: 6),
        PosColumn(text: '-${discount.toStringAsFixed(2)} TL', width: 6, styles: const PosStyles(align: PosAlign.right)),
      ]);
    }

    bytes += generator.hr(ch: '=');

    // Toplam
    final ticketTotal = (ticket['total'] as num?)?.toDouble() ?? 0;
    final total = ticketTotal > 0 ? ticketTotal : (calculatedTotal - discount.toDouble());

    bytes += generator.row([
      PosColumn(text: 'TOPLAM:', width: 6, styles: const PosStyles(bold: true, height: PosTextSize.size2)),
      PosColumn(text: '${total.toStringAsFixed(2)} TL', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true, height: PosTextSize.size2)),
    ]);

    bytes += generator.hr(ch: '=');

    // Ödeme yöntemi
    final paymentText = paymentMethod == 'cash' ? 'NAKIT' : 'KREDI KARTI';
    bytes += generator.text(
      'Odeme: $paymentText',
      styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2),
    );

    // SyncResto imzası
    bytes += generator.feed(1);
    bytes += generator.text(
      'SyncResto POS',
      styles: const PosStyles(align: PosAlign.center),
    );

    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }
}
