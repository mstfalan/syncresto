import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

        // Sunucu yazıcılarını local cache'e de ekle (yazdırma için)
        for (final p in printers) {
          final departments = p['departments'] as List? ?? [];
          String type = 'printer_${p['id']}'; // Varsayılan: printer_1, printer_2...

          // Departmana göre tür belirle
          if (departments.contains('kitchen')) {
            type = 'kitchen';
          } else if (departments.contains('bar')) {
            type = 'bar';
          } else if (departments.contains('cashier')) {
            type = 'cashier';
          }

          // Sadece aktif yazıcıları ekle
          if (p['is_active'] == true) {
            _printers[type] = {
              'id': p['id'],
              'name': p['name'],
              'ip': p['ip'],
              'port': p['port'] ?? 9100,
              'type': type,
              'fromServer': true, // Sunucudan geldiğini işaretle
            };
          }
        }
        await _savePrinters();
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
      } else {
        onStatusChange?.call('Yazdirma hatasi', true);
      }

      return success;
    } catch (e) {
      print('[Printer] Ticket yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
      return false;
    }
  }

  /// Prints an order receipt (for kitchen/bar)
  Future<bool> printOrderReceipt(Map<String, dynamic> order, String department, {String? printerType}) async {
    // Departmana göre yazıcı türünü belirle
    final type = printerType ?? _departmentToPrinterType(department);
    final config = _getPrinterConfig(type);

    if (config == null || config['ip'] == null) {
      onStatusChange?.call('${PrinterService.getPrinterTypeName(type)} yazicisi ayarlanmamis', true);
      return false;
    }

    try {
      onStatusChange?.call('Siparis fisi yazdirilyor...', false);

      final ip = config['ip'] as String;
      final port = config['port'] as int? ?? 9100;

      // Generate order receipt bytes
      final bytes = await _generateOrderReceipt(order, department);

      // Send to printer
      final success = await _sendToPrinter(ip, port, bytes);

      if (success) {
        onStatusChange?.call('Siparis fisi yazdirildi (${PrinterService.getPrinterTypeName(type)})', false);
      }

      return success;
    } catch (e) {
      print('[Printer] Order yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
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
      final price = ((item['price'] ?? item['unit_price'] ?? 0) as num).toDouble() * qty;

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

      // Extras
      if (item['extras'] != null && (item['extras'] as List).isNotEmpty) {
        for (final extra in item['extras']) {
          bytes += generator.text('  + ${_turkishToAscii(extra.toString())}');
        }
      }

      // Notes
      if (item['notes'] != null && item['notes'].toString().isNotEmpty) {
        bytes += generator.text('  > ${_turkishToAscii(item['notes'])}');
      }
    }
    bytes += generator.hr();

    // ===== TOTALS =====
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

    // ===== PAYMENT METHOD =====
    final paymentMethod = order['payment_method'];
    if (paymentMethod != null) {
      bytes += generator.hr();
      bytes += generator.text(
        'Odeme: ${_paymentMethodLabel(paymentMethod)}',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
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
      } else {
        onStatusChange?.call('Mutfak fisi yazdirilamadi', true);
      }

      return success;
    } catch (e) {
      print('[Printer] Mutfak fisi yazdirilirken hata: $e');
      onStatusChange?.call('Hata: $e', true);
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
      } else {
        onStatusChange?.call('Mutfak fisi yazdirilamadi ($ip)', true);
      }

      return success;
    } catch (e) {
      print('[Printer] Mutfak fisi yazdirilirken hata ($ip): $e');
      onStatusChange?.call('Hata: $e', true);
      return false;
    }
  }

  /// Mutfak fişi formatı oluştur
  Future<List<int>> _generateKitchenReceipt(
    Map<String, dynamic> ticket,
    List<dynamic> items,
  ) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // ===== HEADER =====
    bytes += generator.text(
      '*** MUTFAK ***',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    bytes += generator.hr(ch: '=');

    // ===== MASA & ADISYON BİLGİSİ =====
    final ticketNumber = ticket['ticket_number'] ?? '';
    final tableName = _turkishToAscii(ticket['table_number']?.toString() ?? 'Masa');
    final sectionName = _turkishToAscii(ticket['section_name'] ?? '');
    final waiterName = _turkishToAscii(ticket['waiter_name'] ?? '');

    bytes += generator.text(
      'MASA: ${sectionName.isNotEmpty ? "$sectionName - " : ""}$tableName',
      styles: const PosStyles(bold: true, height: PosTextSize.size2),
    );
    bytes += generator.text('Adisyon: $ticketNumber');
    if (waiterName.isNotEmpty) {
      bytes += generator.text('Garson: $waiterName');
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
}
