import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/printer_service.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../providers/theme_provider.dart';

class PrinterSettingsScreen extends StatefulWidget {
  final PrinterService printerService;
  final ApiService? apiService; // Opsiyonel - sunucudan yazıcı çekmek için

  const PrinterSettingsScreen({
    super.key,
    required this.printerService,
    this.apiService,
  });

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  bool _isScanning = false;
  bool _isLoadingFromServer = false;
  List<Map<String, dynamic>> _discoveredPrinters = [];
  List<Map<String, dynamic>> _serverPrinters = []; // Sunucudan gelen yazıcılar
  bool _variantOnTap = false; // POS davranisi: urune tiklayinca varyant secimi acilsin mi
  bool _failedPrintAutoPopup = true; // 24 Tem: cikmayan-fis uyarisi otomatik pop (DEFAULT ACIK)
  bool _showWaiterTimeCash = true; // 9 Agu: kasa fisinde kalem garson+saat (DEFAULT ACIK)
  bool _showWaiterTimeKitchen = true; // 9 Agu: mutfak fisinde kalem garson+saat (DEFAULT ACIK)
  bool _showGroupTitlesKitchen = true; // 10 Agu: mutfak fisinde gruplu varyant basliklari (DEFAULT ACIK)
  bool _showKitchenPrintTime = true; // 24 Agu: fiste 'Fis Basim' (baski ani) satiri (DEFAULT ACIK)
  List<String> _yazdirPrinterIds = []; // 24 Agu (P4): "Yazdir" butonu hedef yazicilari (server id)

  // Varsayılan yazıcı türleri (ikon ve renk için)
  final Map<String, Map<String, dynamic>> _defaultTypes = {
    'kitchen': {'name': 'Mutfak Yazicisi', 'icon': Icons.restaurant, 'color': Colors.orange},
    'kitchen2': {'name': 'Mutfak 2', 'icon': Icons.restaurant, 'color': Colors.deepOrange},
    'bar': {'name': 'Bar Yazicisi', 'icon': Icons.local_bar, 'color': Colors.purple},
    'cashier': {'name': 'Kasa Yazicisi', 'icon': Icons.point_of_sale, 'color': Colors.green},
  };

  // Renk paleti yeni yazıcılar için
  final List<Color> _colorPalette = [
    Colors.blue,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
    Colors.cyan,
    Colors.amber,
    Colors.lime,
    Colors.brown,
  ];

  @override
  void initState() {
    super.initState();
    _loadServerPrinters();
    _loadPosBehaviorPrefs();
  }

  Future<void> _loadPosBehaviorPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _variantOnTap = prefs.getBool(StorageService.variantOnTapKey) ?? false;
      _failedPrintAutoPopup = prefs.getBool(StorageService.failedPrintAutoPopupKey) ?? true; // DEFAULT ACIK
      _showWaiterTimeCash = prefs.getBool(StorageService.showWaiterTimeCashKey) ?? true; // DEFAULT ACIK
      _showWaiterTimeKitchen = prefs.getBool(StorageService.showWaiterTimeKitchenKey) ?? true; // DEFAULT ACIK
      _showGroupTitlesKitchen = prefs.getBool(StorageService.showGroupTitlesKitchenKey) ?? true; // DEFAULT ACIK
      _showKitchenPrintTime = prefs.getBool(StorageService.showKitchenPrintTimeKey) ?? true; // DEFAULT ACIK
      _yazdirPrinterIds = prefs.getStringList(StorageService.yazdirPrinterIdsKey) ?? <String>[]; // P4
    });
  }

  Future<void> _setVariantOnTap(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.variantOnTapKey, value);
    if (mounted) setState(() => _variantOnTap = value);
  }

  Future<void> _setFailedPrintAutoPopup(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.failedPrintAutoPopupKey, value);
    if (mounted) setState(() => _failedPrintAutoPopup = value);
  }

  Future<void> _setShowWaiterTimeCash(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.showWaiterTimeCashKey, value);
    if (mounted) setState(() => _showWaiterTimeCash = value);
  }

  Future<void> _setShowWaiterTimeKitchen(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.showWaiterTimeKitchenKey, value);
    if (mounted) setState(() => _showWaiterTimeKitchen = value);
  }

  Future<void> _setShowGroupTitlesKitchen(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.showGroupTitlesKitchenKey, value);
    if (mounted) setState(() => _showGroupTitlesKitchen = value);
  }

  Future<void> _setShowKitchenPrintTime(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageService.showKitchenPrintTimeKey, value);
    if (mounted) setState(() => _showKitchenPrintTime = value);
  }

  // 24 Agu 2026 (P4): "Yazdir" hedef yazicisini ekle/cikar.
  Future<void> _toggleYazdirPrinter(String id, bool selected) async {
    final list = List<String>.from(_yazdirPrinterIds);
    if (selected) {
      if (!list.contains(id)) list.add(id);
    } else {
      list.remove(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(StorageService.yazdirPrinterIdsKey, list);
    if (mounted) setState(() => _yazdirPrinterIds = list);
  }

  /// Sunucudan yazıcıları yükle (admin panelden eklenenler)
  Future<void> _loadServerPrinters() async {
    if (widget.apiService == null) return;

    setState(() => _isLoadingFromServer = true);

    try {
      final printers = await widget.apiService!.getPrinters();
      setState(() => _serverPrinters = printers);

      // PrinterService'e de yükle
      if (printers.isNotEmpty) {
        await widget.printerService.loadFromServer(() async => printers);
        setState(() {}); // UI güncelle
      }
    } catch (e) {
      print('[PrinterSettings] Sunucudan yazıcı yüklenemedi: $e');
    } finally {
      setState(() => _isLoadingFromServer = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mevcut yazıcıları al
    final configuredPrinters = widget.printerService.allPrinters;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        backgroundColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
        foregroundColor: Colors.white,
        actions: [
          // Sunucudan yenile butonu
          IconButton(
            onPressed: _isLoadingFromServer ? null : _loadServerPrinters,
            icon: _isLoadingFromServer
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download),
            tooltip: 'Sunucudan Yukle',
          ),
          // Ağ tarama butonu
          IconButton(
            onPressed: _isScanning ? null : _scanPrinters,
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find),
            tooltip: 'Ag Tara',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // POS davranış ayarları (cihaz bazlı)
            _buildPosBehaviorSection(),
            const SizedBox(height: 16),

            // Sunucudan gelen yazıcılar (admin panelden eklenenler)
            if (_serverPrinters.isNotEmpty) ...[
              _buildServerPrintersSection(),
              const SizedBox(height: 16),
            ],

            // Ağda bulunan yazıcılar
            if (_discoveredPrinters.isNotEmpty) ...[
              _buildDiscoveredPrintersSection(),
              const SizedBox(height: 16),
            ],

            // Mevcut yazıcı kartları
            if (configuredPrinters.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Kayitli Yazicilar',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              ...configuredPrinters.map((printer) => _buildConfiguredPrinterCard(printer)),
            ],

            // Yeni yazıcı ekle butonu
            const SizedBox(height: 8),
            _buildAddPrinterButton(),

            // Bilgi notu
            if (widget.apiService != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Admin panelden eklenen yazicilar otomatik yuklenir. Urun-yazici eslestirmesi admin panelden yapilir.',
                        style: TextStyle(color: Colors.blue[700], fontSize: 12),
                      ),
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

  /// POS davranış ayarları — cihaz bazlı toggle'lar (varyant açılış davranışı vb).
  Widget _buildPosBehaviorSection() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Row(children: [
                Icon(Icons.tune, size: 18, color: Colors.grey[700]),
                const SizedBox(width: 8),
                Text('POS Davranışı',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[700])),
              ]),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ürüne tıklayınca varyant seçimi açılsın'),
              subtitle: const Text(
                  'Açık: varyantlı ürüne tıklayınca varyant penceresi açılır. '
                  'Kapalı: ürün direkt sepete eklenir, varyant sağdaki "Varyant" butonundan seçilir.'),
              value: _variantOnTap,
              onChanged: _setVariantOnTap,
            ),
            const Divider(height: 1),
            // 24 Tem 2026: Çıkmayan-fiş otomatik uyarı toggle (DEFAULT AÇIK).
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Çıkmayan fiş uyarısı otomatik açılsın'),
              subtitle: const Text(
                  'Açık: yazıcı denemeleri tükenip mutfak fişi çıkmazsa bu kasada uyarı '
                  'penceresi otomatik açılır (tekrar yazdırabilirsiniz). '
                  'Kapalı: sadece sağ üstteki uyarı simgesinden görülür.'),
              value: _failedPrintAutoPopup,
              onChanged: _setFailedPrintAutoPopup,
            ),
            const Divider(height: 1),
            // 9 Agu 2026: fiste kalem garson adi + giris saati (kasa AYRI / mutfak AYRI, DEFAULT ACIK).
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kasa fişinde garson + saat göster'),
              subtitle: const Text(
                  'Açık: adisyon ve hesap kapanış fişinde her kalemin yanında (fiyattan önce, '
                  'küçük yazı) o kalemi giren garson ve giriş saati yazar. Kapalı: eskisi gibi.'),
              value: _showWaiterTimeCash,
              onChanged: _setShowWaiterTimeCash,
            ),
            const Divider(height: 1),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mutfak fişinde garson + saat göster'),
              subtitle: const Text(
                  'Açık: mutfak fişinde her kalemin en sağında (küçük yazı) o kalemi giren garson '
                  've giriş saati yazar. Hangi siparişi kim ne zaman girdi görürsünüz. Kapalı: eskisi gibi.'),
              value: _showWaiterTimeKitchen,
              onChanged: _setShowWaiterTimeKitchen,
            ),
            const Divider(height: 1),
            // 10 Agu 2026: mutfak fişinde gruplu varyant başlıkları (DEFAULT AÇIK).
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mutfak fişinde grup başlıklarını göster'),
              subtitle: const Text(
                  'Açık: çoklu seçimli üründe seçimler grup adının (ör. "1. Yan Ürün", "2. Yan Ürün") '
                  'altında yazılır. Sadece 2. grubu seçtiğinizde mutfak 1. grubu sanmaz. Kapalı: eskisi gibi düz liste.'),
              value: _showGroupTitlesKitchen,
              onChanged: _setShowGroupTitlesKitchen,
            ),
            const Divider(height: 1),
            // 24 Agu 2026: fişte "Fiş Basım" (baskı anı) satırı (DEFAULT AÇIK).
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fişte basım zamanını göster'),
              subtitle: const Text(
                  'Açık: mutfak fişinde "Ürün Girişi" (ürünün girildiği saat) altına "Fiş Basım" '
                  '(fişin çıktığı an) ayrı satır yazar. Ürün 10\'da girilip fiş 12\'de basıldıysa '
                  'ikisi net ayrılır. Kapalı: sadece Ürün Girişi yazar.'),
              value: _showKitchenPrintTime,
              onChanged: _setShowKitchenPrintTime,
            ),
            const Divider(height: 1),
            // 24 Agu 2026 (P4): "Yazdir" butonu hedef yazicilari (coklu). Bos = bugunku (kasa) yol.
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 2),
              child: Text('Yazdır Butonu Yazıcıları',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey[800])),
            ),
            Text(
              'Adisyon "Yazdır" butonu hangi yazıcı(lar)a bassın? Hiçbiri seçili değilse: bugünkü '
              'gibi kasa yazıcısı. 1 seçili: doğrudan ona. Birden fazla: "Yazdır"a basınca yazıcı '
              'seçim penceresi açılır.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.3),
            ),
            ..._serverPrinters.map((p) {
              final id = '${p['id']}';
              return CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(p['name']?.toString() ?? 'Yazıcı'),
                subtitle: Text('${p['ip'] ?? p['ip_address'] ?? ''}',
                    style: const TextStyle(fontSize: 12)),
                value: _yazdirPrinterIds.contains(id),
                onChanged: (v) => _toggleYazdirPrinter(id, v ?? false),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildAddPrinterButton() {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: _showAddPrinterDialog,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.add, color: Colors.grey[600], size: 28),
              ),
              const SizedBox(width: 16),
              Text(
                'Yeni Yazici Ekle',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddPrinterDialog() {
    final nameController = TextEditingController();
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '9100');
    String selectedType = 'custom';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Yeni Yazici Ekle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Yazıcı türü seçimi
                DropdownButtonFormField<String>(
                  value: selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Yazici Turu',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: 'kitchen', child: Text('🍳 Mutfak')),
                    const DropdownMenuItem(value: 'kitchen2', child: Text('🍳 Mutfak 2')),
                    const DropdownMenuItem(value: 'bar', child: Text('🍺 Bar')),
                    const DropdownMenuItem(value: 'cashier', child: Text('💵 Kasa')),
                    const DropdownMenuItem(value: 'custom', child: Text('⚙️ Ozel')),
                  ],
                  onChanged: (value) {
                    setDialogState(() => selectedType = value!);
                    if (value != 'custom' && _defaultTypes.containsKey(value)) {
                      nameController.text = _defaultTypes[value]!['name'] ?? '';
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Yazici Adi',
                    hintText: 'Ornek: Ust Kat Mutfak',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    labelText: 'IP Adresi',
                    hintText: '192.168.1.100',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: portController,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: '9100',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Iptal'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (ipController.text.isEmpty) {
                  _showMessage('IP adresi giriniz', isError: true);
                  return;
                }

                final type = selectedType == 'custom'
                    ? 'printer_${DateTime.now().millisecondsSinceEpoch}'
                    : selectedType;

                final name = nameController.text.isNotEmpty
                    ? nameController.text
                    : 'Yazici (${ipController.text})';

                await widget.printerService.addPrinter(type, {
                  'ip': ipController.text,
                  'port': int.tryParse(portController.text) ?? 9100,
                  'name': name,
                });

                Navigator.pop(context);
                setState(() {});
                _showMessage('$name eklendi');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Provider.of<ThemeProvider>(context, listen: false).primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Ekle'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfiguredPrinterCard(Map<String, dynamic> printer) {
    final type = printer['type'] as String? ?? 'custom';
    final defaultInfo = _defaultTypes[type];

    final icon = defaultInfo?['icon'] as IconData? ?? Icons.print;
    final color = defaultInfo?['color'] as Color? ?? _getColorForType(type);
    final displayName = printer['name'] as String? ?? 'Yazici';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            '${printer['ip']}:${printer['port'] ?? 9100}',
                            style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              PrinterService.getPrinterTypeName(type),
                              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Test butonu
                IconButton(
                  onPressed: () => _testPrinter(type, printer),
                  icon: const Icon(Icons.print),
                  color: color,
                  tooltip: 'Test Yazdir',
                ),
                // Sil butonu
                IconButton(
                  onPressed: () => _removePrinter(type),
                  icon: const Icon(Icons.delete_outline),
                  color: Colors.red,
                  tooltip: 'Kaldir',
                ),
              ],
            ),

            const Divider(height: 24),

            // 15 Tem 2026: Sesli bildirim toggle — açıkken bu yazıcıya fiş gidince ESC/POS beep
            // komutu gönderilir (yazıcının dahili buzzer'ı öter). IP bazlı saklanır (printer_beep_ips),
            // sunucudan yazıcı çekimi (loadFromServer) beep ayarını EZMEZ.
            Builder(builder: (_) {
              final pIp = (printer['ip'] ?? '').toString();
              final beepOn = widget.printerService.isBeepEnabledForIp(pIp);
              return SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                secondary: Icon(
                  beepOn ? Icons.volume_up : Icons.volume_off,
                  color: beepOn ? color : Colors.grey,
                ),
                title: const Text('Sesli bildirim', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text('Fiş basılınca yazıcı sesli uyarı verir (buzzer)', style: TextStyle(fontSize: 12)),
                value: beepOn,
                onChanged: pIp.isEmpty ? null : (v) => _setPrinterBeep(pIp, v),
              );
            }),

            const Divider(height: 24),

            // Düzenleme alanları
            _buildPrinterForm(type, printer, color),
          ],
        ),
      ),
    );
  }

  /// Yazıcı sesli bildirim (beep) ayarını IP bazlı kaydet (printer_beep_ips).
  /// printers_multi'ye YAZMAZ -> loadFromServer ezmesinden bağımsız (Fable fix).
  Future<void> _setPrinterBeep(String ip, bool value) async {
    await widget.printerService.setBeepForIp(ip, value);
    if (mounted) setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value ? 'Sesli bildirim açıldı' : 'Sesli bildirim kapatıldı'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Color _getColorForType(String type) {
    final hash = type.hashCode.abs();
    return _colorPalette[hash % _colorPalette.length];
  }

  /// Sunucudan gelen yazıcılar (admin panelden eklenenler)
  Widget _buildServerPrintersSection() {
    return Card(
      color: Colors.green[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_done, color: Colors.green[700]),
                const SizedBox(width: 8),
                Text(
                  'Admin Panelden Eklenen (${_serverPrinters.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green[700],
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _loadServerPrinters,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Yenile'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.green[700],
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._serverPrinters.map((printer) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green[200]!),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.green[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.print, color: Colors.green[700], size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          printer['name'] ?? 'Yazici',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${printer['ip']}:${printer['port'] ?? 9100}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  // Durum
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: printer['is_active'] == true ? Colors.green[100] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      printer['is_active'] == true ? 'Aktif' : 'Pasif',
                      style: TextStyle(
                        color: printer['is_active'] == true ? Colors.green[700] : Colors.grey[600],
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Test butonu
                  IconButton(
                    onPressed: () => _testConnection(printer['ip'], printer['port'] ?? 9100),
                    icon: const Icon(Icons.wifi_find, size: 20),
                    color: Colors.green[700],
                    tooltip: 'Baglanti Test',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredPrintersSection() {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'Agda Bulunan Yazicilar (${_discoveredPrinters.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[700],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._discoveredPrinters.map((printer) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.print, color: Colors.blue),
                  title: Text(printer['name'] ?? 'Yazici'),
                  subtitle: Text('${printer['ip']}:${printer['port']}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (type) => _assignPrinterToType(printer, type),
                    itemBuilder: (context) => _defaultTypes.entries
                        .map((e) => PopupMenuItem<String>(
                              value: e.key,
                              child: Row(
                                children: [
                                  Icon(e.value['icon'] as IconData, color: e.value['color'] as Color, size: 20),
                                  const SizedBox(width: 8),
                                  Text(e.value['name'] as String),
                                ],
                              ),
                            ))
                        .toList(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Ata',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildPrinterForm(String type, Map<String, dynamic>? printer, Color color) {
    final nameController = TextEditingController(text: printer?['name'] ?? '');
    final ipController = TextEditingController(text: printer?['ip'] ?? '');
    final portController = TextEditingController(text: (printer?['port'] ?? 9100).toString());

    return Column(
      children: [
        // Yazıcı adı
        TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Yazici Adi',
            hintText: '${PrinterService.getPrinterTypeName(type)} Yazicisi',
            prefixIcon: const Icon(Icons.label),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: 'IP Adresi',
                  hintText: '192.168.1.100',
                  prefixIcon: Icon(Icons.lan),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 1,
              child: TextField(
                controller: portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '9100',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _testConnection(ipController.text, int.tryParse(portController.text) ?? 9100),
                icon: const Icon(Icons.wifi_find, size: 18),
                label: const Text('Test'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _savePrinter(
                  type,
                  ipController.text,
                  int.tryParse(portController.text) ?? 9100,
                  name: nameController.text,
                ),
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Kaydet'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            if (printer != null) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _removePrinter(type),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                tooltip: 'Kaldir',
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _scanPrinters() async {
    setState(() {
      _isScanning = true;
      _discoveredPrinters = [];
    });

    try {
      final printers = await widget.printerService.discoverPrinters();
      setState(() => _discoveredPrinters = printers);

      if (printers.isEmpty) {
        _showMessage('Yazici bulunamadi', isError: true);
      } else {
        _showMessage('${printers.length} yazici bulundu');
      }
    } catch (e) {
      _showMessage('Tarama hatasi: $e', isError: true);
    } finally {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _testConnection(String ip, int port) async {
    if (ip.isEmpty) {
      _showMessage('IP adresi giriniz', isError: true);
      return;
    }

    _showMessage('Test ediliyor...');

    try {
      final success = await widget.printerService.testConnection(ip, port);
      if (success) {
        _showMessage('Baglanti basarili!');
      } else {
        _showMessage('Baglanti basarisiz', isError: true);
      }
    } catch (e) {
      _showMessage('Test hatasi: $e', isError: true);
    }
  }

  Future<void> _savePrinter(String type, String ip, int port, {String? name}) async {
    if (ip.isEmpty) {
      _showMessage('IP adresi giriniz', isError: true);
      return;
    }

    final printerName = (name != null && name.isNotEmpty)
        ? name
        : '${PrinterService.getPrinterTypeName(type)} ($ip)';

    await widget.printerService.addPrinter(type, {
      'ip': ip,
      'port': port,
      'name': printerName,
    });

    setState(() {});
    _showMessage('$printerName kaydedildi');
  }

  Future<void> _removePrinter(String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yaziciyi Kaldir'),
        content: Text('${PrinterService.getPrinterTypeName(type)} yazicisini kaldirmak istediginize emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Iptal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kaldir', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.printerService.removePrinter(type);
      setState(() {});
      _showMessage('Yazici kaldirildi');
    }
  }

  void _assignPrinterToType(Map<String, dynamic> printer, String type) {
    _savePrinter(type, printer['ip'], printer['port'] ?? 9100);
  }

  Future<void> _testPrinter(String type, Map<String, dynamic> printer) async {
    _showMessage('Test fisi gonderiliyor...');

    try {
      final success = await widget.printerService.printTicket({
        'ticket_number': 'TEST-001',
        'table_name': 'Test Masa',
        'waiter_name': 'Test Garson',
        'opened_at': DateTime.now().toIso8601String(),
        'items': [
          {'product_name': 'Test Urun', 'quantity': 1, 'unit_price': 10.0, 'status': 'active'},
        ],
        'subtotal': 10.0,
        'total': 10.0,
      }, printerType: type);

      if (success) {
        _showMessage('Test fisi yazdirildi');
      } else {
        _showMessage('Yazdirma hatasi', isError: true);
      }
    } catch (e) {
      _showMessage('Hata: $e', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
