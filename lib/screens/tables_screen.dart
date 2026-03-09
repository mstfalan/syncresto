import 'package:flutter/material.dart';
import 'dart:async';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/printer_service.dart';
import '../services/websocket_service.dart';
import '../services/connectivity_service.dart';
import 'pin_login_screen.dart';
import 'printer_settings_screen.dart';
import '../widgets/ticket_modal.dart';

class TablesScreen extends StatefulWidget {
  final StorageService storageService;
  final ApiService apiService;
  final PrinterService printerService;
  final WebSocketService webSocketService;
  final Map<String, dynamic> waiter;

  const TablesScreen({
    super.key,
    required this.storageService,
    required this.apiService,
    required this.printerService,
    required this.webSocketService,
    required this.waiter,
  });

  @override
  State<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends State<TablesScreen> {
  List<dynamic> _sections = [];
  List<dynamic> _tables = [];
  bool _isLoading = true;
  int? _selectedSectionId;
  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  // Offline monitoring
  final ConnectivityService _connectivity = ConnectivityService();
  bool _isOnline = true;
  StreamSubscription<bool>? _connectivitySubscription;

  int? _safeInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    _startClock();
    _setupConnectivity();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _setupConnectivity() {
    _isOnline = _connectivity.isOnline;
    _connectivitySubscription = _connectivity.connectionStream.listen((isOnline) {
      setState(() => _isOnline = isOnline);
      if (isOnline) {
        // Online olunca verileri yenile ve sync et
        _loadData();
        widget.apiService.syncPendingItems();
        // Masa durumlarını server'dan yenile
        widget.apiService.refreshTablesFromServer();
      }
    });
  }

  void _startClock() {
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
  }

  void _updateClock() {
    final now = DateTime.now();
    setState(() {
      _currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      _currentDate = '${now.day} ${_getMonthName(now.month)} ${now.year}';
    });
  }

  String _getMonthName(int month) {
    const months = ['Ocak', 'Subat', 'Mart', 'Nisan', 'Mayis', 'Haziran',
                    'Temmuz', 'Agustos', 'Eylul', 'Ekim', 'Kasim', 'Aralik'];
    return months[month - 1];
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final sections = await widget.apiService.getSections();
      final tables = await widget.apiService.getTables();

      setState(() {
        _sections = sections;
        _tables = tables;
        if (sections.isNotEmpty && _selectedSectionId == null) {
          _selectedSectionId = _safeInt(sections[0]['id']);
        }
      });
    } catch (e) {
      _showError('Veri yuklenemedi: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  List<dynamic> get _filteredTables {
    return _tables.where((t) => t['section_id'] == _selectedSectionId).toList();
  }

  int get _emptyCount => _filteredTables.where((t) => t['status'] != 'occupied' && t['current_ticket_id'] == null).length;
  int get _occupiedCount => _filteredTables.where((t) => t['status'] == 'occupied' || t['current_ticket_id'] != null).length;

  Future<void> _openTable(Map<String, dynamic> table) async {
    final tableId = table['id'] as int;

    // Online ise önce server'dan güncel masa durumunu al
    if (widget.apiService.isOnline) {
      try {
        // Server'dan bu masa için ticket var mı kontrol et
        final ticketData = await widget.apiService.getTableTicket(tableId);

        // Eğer server'da ticket yoksa ama local'de dolu görünüyorsa, table'ı güncelle
        if (ticketData == null && (table['status'] == 'occupied' || table['current_ticket_id'] != null)) {
          print('[Tables] Server\'da ticket yok, masa durumu güncelleniyor...');
          table['status'] = 'empty';
          table['current_ticket_id'] = null;
          // Tabloyu yeniden yükle
          await _loadData();
          // Güncellenmiş tabloyu bul
          final updatedTable = _tables.firstWhere(
            (t) => t['id'] == tableId,
            orElse: () => table,
          );
          table = Map<String, dynamic>.from(updatedTable);
        }
      } catch (e) {
        print('[Tables] Masa durumu kontrol hatası: $e');
      }
    }

    // Show ticket modal
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => TicketModal(
        table: table,
        apiService: widget.apiService,
        printerService: widget.printerService,
        waiter: widget.waiter,
        onClose: () {
          Navigator.of(context).pop();
          _loadData(); // Refresh tables
        },
      ),
    );
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
                      webSocketService: widget.webSocketService,
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
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Column(
        children: [
          // Header
          _buildHeader(),

          // Section Tabs
          _buildSectionTabs(),

          // Tables Grid
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF16A34A)))
                : _buildTablesGrid(),
          ),

          // Status Legend
          _buildStatusLegend(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          // Logo
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.restaurant, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          const Text(
            'GreenChef POS',
            style: TextStyle(
              color: Color(0xFF1F2937),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const Spacer(),

          // Offline indicator
          if (!_isOnline)
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange[100],
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.orange),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, color: Colors.orange[800], size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Offline Mod',
                    style: TextStyle(
                      color: Colors.orange[800],
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

          // Clock
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _currentTime,
                style: const TextStyle(
                  color: Color(0xFF1F2937),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                _currentDate,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ],
          ),

          const Spacer(),

          // Waiter info
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF16A34A),
                  radius: 18,
                  child: Text(
                    (widget.waiter['name'] ?? 'G')[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.waiter['name'] ?? 'Garson',
                      style: const TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Garson',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 16),

          // Printer settings button
          IconButton(
            onPressed: _openPrinterSettings,
            icon: Icon(
              Icons.print,
              color: widget.printerService.isConfigured ? const Color(0xFF16A34A) : Colors.grey[700],
            ),
            tooltip: 'Yazici Ayarlari',
          ),

          // Logout button
          IconButton(
            onPressed: _logout,
            icon: Icon(Icons.logout, color: Colors.grey[700]),
            tooltip: 'Cikis Yap',
          ),
        ],
      ),
    );
  }

  void _openPrinterSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PrinterSettingsScreen(
          printerService: widget.printerService,
          apiService: widget.apiService, // Sunucudan yazıcı çekmek için
        ),
      ),
    ).then((_) {
      // Ayarlar değiştiğinde UI'ı güncelle
      setState(() {});
    });
  }

  Widget _buildSectionTabs() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      color: Colors.white,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: _sections.map((section) {
            final sectionId = _safeInt(section['id']);
            final isSelected = sectionId == _selectedSectionId;
            final color = _parseColor(section['color'] ?? '#16A34A');

            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => setState(() => _selectedSectionId = sectionId),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? color : Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? color : Colors.grey[300]!,
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          section['name'],
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.grey[700],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white.withValues(alpha: 0.2) : Colors.grey[200],
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${section['table_count'] ?? 0}',
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.grey[600],
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildTablesGrid() {
    final tables = _filteredTables;

    if (tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_restaurant, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'Bu salonda masa yok',
              style: TextStyle(color: Colors.grey[500], fontSize: 18),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        childAspectRatio: 1,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: tables.length,
      itemBuilder: (context, index) {
        final table = tables[index];
        return _buildTableCard(table);
      },
    );
  }

  Widget _buildTableCard(Map<String, dynamic> table) {
    final isOccupied = table['status'] == 'occupied' || table['current_ticket_id'] != null;
    final tableNumber = (table['table_number'] ?? 'M${table['id']}').toString().replaceAll('Masa ', '');
    final total = table['current_total'];
    final openedAt = table['ticket_opened_at'];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openTable(table),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            gradient: isOccupied
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF16A34A), Color(0xFF059669)],
                  )
                : null,
            color: isOccupied ? null : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isOccupied ? const Color(0xFF16A34A) : Colors.grey[300]!,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Table number
              Text(
                tableNumber,
                style: TextStyle(
                  color: isOccupied ? Colors.white : const Color(0xFF1F2937),
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              // Status
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: isOccupied
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isOccupied ? 'Dolu' : 'Bos',
                  style: TextStyle(
                    color: isOccupied ? Colors.white : Colors.grey[600],
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              // Total (if occupied)
              if (isOccupied && total != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${total.toStringAsFixed(2)} TL',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],

              // Duration (if occupied)
              if (isOccupied && openedAt != null) ...[
                const SizedBox(height: 4),
                Text(
                  _formatDuration(openedAt),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildLegendItem('Bos', _emptyCount, Colors.grey[300]!),
          const SizedBox(width: 32),
          _buildLegendItem('Dolu', _occupiedCount, const Color(0xFF16A34A)),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$label: $count',
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  String _formatDuration(String openedAt) {
    try {
      final opened = DateTime.parse(openedAt);
      final now = DateTime.now();
      final diff = now.difference(opened);

      if (diff.inMinutes < 60) {
        return '${diff.inMinutes} dk';
      } else {
        final hours = diff.inHours;
        final mins = diff.inMinutes % 60;
        return '${hours}s ${mins}dk';
      }
    } catch (e) {
      return '';
    }
  }

  Color _parseColor(String colorStr) {
    try {
      return Color(int.parse(colorStr.replaceFirst('#', '0xFF')));
    } catch (e) {
      return const Color(0xFF16A34A);
    }
  }
}
