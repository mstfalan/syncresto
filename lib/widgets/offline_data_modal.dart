import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/print_queue_service.dart';
import '../providers/theme_provider.dart';

class OfflineDataModal extends StatefulWidget {
  final ApiService apiService;
  final VoidCallback? onSyncComplete;

  const OfflineDataModal({
    super.key,
    required this.apiService,
    this.onSyncComplete,
  });

  @override
  State<OfflineDataModal> createState() => _OfflineDataModalState();
}

class _OfflineDataModalState extends State<OfflineDataModal> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _syncData;
  List<Map<String, dynamic>> _printJobs = [];
  Map<String, int> _printSummary = {};
  bool _isLoading = true;
  bool _isSyncing = false;

  late TabController _tabController;
  final PrinterService _printerService = PrinterService();
  final PrintQueueService _printQueueService = PrintQueueService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final syncData = await widget.apiService.getOfflineDataSummary();
      final printJobs = await _printerService.getAllPrintJobs();
      final printSummary = await _printerService.getPrintQueueSummary();

      if (mounted) {
        setState(() {
          _syncData = syncData;
          _printJobs = printJobs;
          _printSummary = printSummary;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ==================== SYNC QUEUE METHODS ====================

  Future<void> _syncAll() async {
    setState(() => _isSyncing = true);
    try {
      await widget.apiService.syncPendingItems();
      await _loadData();
      widget.onSyncComplete?.call();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _retryItem(int syncId) async {
    await widget.apiService.retrySyncItem(syncId);
    await _loadData();
    widget.onSyncComplete?.call();
  }

  Future<void> _deleteItem(int syncId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Islemi Sil'),
        content: const Text('Bu islemi silmek istediginize emin misiniz? Bu islem geri alinamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.apiService.deleteSyncItem(syncId);
      await _loadData();
      widget.onSyncComplete?.call();
    }
  }

  Future<void> _clearAllFailed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tum Hatali Islemleri Temizle'),
        content: const Text('Tum hatali islemler silinecek. Bu islem geri alinamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Temizle', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.apiService.clearFailedSyncItems();
      await _loadData();
      widget.onSyncComplete?.call();
    }
  }

  // ==================== PRINT QUEUE METHODS ====================

  Future<void> _retryPrintJob(int jobId) async {
    setState(() => _isSyncing = true);
    try {
      await _printQueueService.retryJob(jobId);
      await _loadData();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _retryAllPrintJobs() async {
    setState(() => _isSyncing = true);
    try {
      await _printQueueService.retryAllPending();
      await _loadData();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _deletePrintJob(int jobId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fisi Sil'),
        content: const Text('Bu fisi kuyruktan silmek istediginize emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _printerService.deletePrintJob(jobId);
      await _loadData();
    }
  }

  Future<void> _clearFailedPrintJobs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Basarisiz Fisleri Temizle'),
        content: const Text('Tum basarisiz fisler silinecek. Bu islem geri alinamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Iptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Temizle', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _printerService.clearFailedPrintJobs();
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);

    // Tab badge'leri için sayılar
    final syncPending = (_syncData?['pending'] as List?)?.length ?? 0;
    final syncFailed = (_syncData?['failed'] as List?)?.length ?? 0;
    final printPending = _printSummary['pending_count'] ?? 0;
    final printFailed = _printSummary['failed_count'] ?? 0;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 550,
        constraints: const BoxConstraints(maxHeight: 650),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.primaryColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cloud_sync, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Cevrimdisi Veriler',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Tab Bar
            Container(
              color: Colors.grey[100],
              child: TabBar(
                controller: _tabController,
                labelColor: theme.primaryColor,
                unselectedLabelColor: Colors.grey[600],
                indicatorColor: theme.primaryColor,
                tabs: [
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sync, size: 18),
                        const SizedBox(width: 6),
                        const Text('Sync Kuyrugu'),
                        if (syncPending + syncFailed > 0) ...[
                          const SizedBox(width: 6),
                          _buildBadge(syncPending + syncFailed, syncFailed > 0),
                        ],
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.print, size: 18),
                        const SizedBox(width: 6),
                        const Text('Yazici Kuyrugu'),
                        if (printPending + printFailed > 0) ...[
                          const SizedBox(width: 6),
                          _buildBadge(printPending + printFailed, printFailed > 0),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Content
            Flexible(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildSyncContent(theme),
                        _buildPrintContent(theme),
                      ],
                    ),
            ),

            // Actions (dinamik)
            AnimatedBuilder(
              animation: _tabController,
              builder: (context, child) {
                if (_tabController.index == 0) {
                  return _buildSyncActions(theme);
                } else {
                  return _buildPrintActions(theme);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(int count, bool isError) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isError ? Colors.red : Colors.orange,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // ==================== SYNC QUEUE UI ====================

  Widget _buildSyncContent(ThemeProvider theme) {
    if (_syncData == null) {
      return const Center(child: Text('Veri yuklenemedi'));
    }

    final pending = _syncData!['pending'] as List? ?? [];
    final failed = _syncData!['failed'] as List? ?? [];
    final completedCount = _syncData!['completed_count'] as int? ?? 0;

    if (pending.isEmpty && failed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_done, size: 64, color: Colors.green[300]),
            const SizedBox(height: 16),
            const Text(
              'Tum veriler senkronize',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1F2937),
              ),
            ),
            if (completedCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Son 24 saatte $completedCount islem tamamlandi',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
          ],
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(16),
      children: [
        if (pending.isNotEmpty) ...[
          _buildSectionHeader(
            icon: Icons.schedule,
            title: 'Bekleyen Islemler',
            count: pending.length,
            color: Colors.orange,
          ),
          const SizedBox(height: 8),
          ...pending.map((item) => _buildSyncItem(item, isPending: true, theme: theme)),
          const SizedBox(height: 16),
        ],
        if (failed.isNotEmpty) ...[
          _buildSectionHeader(
            icon: Icons.error_outline,
            title: 'Hatali Islemler',
            count: failed.length,
            color: Colors.red,
          ),
          const SizedBox(height: 8),
          ...failed.map((item) => _buildSyncItem(item, isPending: false, theme: theme)),
          const SizedBox(height: 16),
        ],
        if (completedCount > 0)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[600], size: 20),
                const SizedBox(width: 8),
                Text(
                  'Son 24 saatte $completedCount islem basariyla tamamlandi',
                  style: TextStyle(color: Colors.green[800]),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSyncActions(ThemeProvider theme) {
    final pending = _syncData?['pending'] as List? ?? [];
    final failed = _syncData?['failed'] as List? ?? [];
    final hasPending = pending.isNotEmpty;
    final hasFailed = failed.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Row(
        children: [
          if (hasFailed)
            TextButton.icon(
              onPressed: _clearAllFailed,
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Hatalari Temizle'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          const Spacer(),
          if (hasPending)
            ElevatedButton.icon(
              onPressed: _isSyncing ? null : _syncAll,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: Text(_isSyncing ? 'Senkronize Ediliyor...' : 'Tumunu Sync Et'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
              ),
            ),
          if (!hasPending && !hasFailed)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Kapat'),
            ),
        ],
      ),
    );
  }

  // ==================== PRINT QUEUE UI ====================

  Widget _buildPrintContent(ThemeProvider theme) {
    final pendingJobs = _printJobs.where((j) => j['status'] == 'pending').toList();
    final failedJobs = _printJobs.where((j) => j['status'] == 'failed').toList();

    if (pendingJobs.isEmpty && failedJobs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.print, size: 64, color: Colors.green[300]),
            const SizedBox(height: 16),
            const Text(
              'Yazici kuyrugu bos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tum fisler basariyla yazdirildi',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(16),
      children: [
        if (pendingJobs.isNotEmpty) ...[
          _buildSectionHeader(
            icon: Icons.schedule,
            title: 'Bekleyen Fisler',
            count: pendingJobs.length,
            color: Colors.orange,
          ),
          const SizedBox(height: 8),
          ...pendingJobs.map((job) => _buildPrintItem(job, theme: theme)),
          const SizedBox(height: 16),
        ],
        if (failedJobs.isNotEmpty) ...[
          _buildSectionHeader(
            icon: Icons.error_outline,
            title: 'Basarisiz Fisler',
            count: failedJobs.length,
            color: Colors.red,
          ),
          const SizedBox(height: 8),
          ...failedJobs.map((job) => _buildPrintItem(job, theme: theme)),
        ],
      ],
    );
  }

  Widget _buildPrintItem(Map<String, dynamic> job, {required ThemeProvider theme}) {
    final id = job['id'] as int;
    final printType = job['print_type'] as String;
    final printerName = job['printer_name'] as String? ?? 'Yazici';
    final printerIp = job['printer_ip'] as String;
    final status = job['status'] as String;
    final retryCount = job['retry_count'] as int? ?? 0;
    final maxRetries = job['max_retries'] as int? ?? 5;
    final errorMessage = job['error_message'] as String?;
    final createdAt = job['created_at'] as String?;

    final isPending = status == 'pending';

    // Print type label
    String typeLabel;
    IconData typeIcon;
    switch (printType) {
      case 'ticket':
        typeLabel = 'Adisyon Fisi';
        typeIcon = Icons.receipt;
        break;
      case 'kitchen':
        typeLabel = 'Mutfak Fisi';
        typeIcon = Icons.restaurant;
        break;
      case 'order':
        typeLabel = 'Siparis Fisi';
        typeIcon = Icons.shopping_bag;
        break;
      case 'closing':
        typeLabel = 'Kapama Fisi';
        typeIcon = Icons.point_of_sale;
        break;
      default:
        typeLabel = 'Fis';
        typeIcon = Icons.print;
    }

    String timeAgo = '';
    if (createdAt != null) {
      try {
        final dt = DateTime.parse(createdAt);
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 1) {
          timeAgo = 'Az once';
        } else if (diff.inMinutes < 60) {
          timeAgo = '${diff.inMinutes} dk once';
        } else if (diff.inHours < 24) {
          timeAgo = '${diff.inHours} saat once';
        } else {
          timeAgo = '${diff.inDays} gun once';
        }
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isPending ? Colors.orange[50] : Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isPending ? Colors.orange[200]! : Colors.red[200]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                typeIcon,
                color: isPending ? Colors.orange[700] : Colors.red[700],
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  typeLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: isPending ? Colors.orange[900] : Colors.red[900],
                  ),
                ),
              ),
              IconButton(
                onPressed: _isSyncing ? null : () => _retryPrintJob(id),
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Tekrar Gonder',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: theme.primaryColor,
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _deletePrintJob(id),
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Sil',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: Colors.red,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$printerName ($printerIp)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (timeAgo.isNotEmpty) timeAgo,
                    'Deneme: $retryCount/$maxRetries',
                  ].join(' - '),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                if (errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      errorMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red[700],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintActions(ThemeProvider theme) {
    final pendingJobs = _printJobs.where((j) => j['status'] == 'pending').toList();
    final failedJobs = _printJobs.where((j) => j['status'] == 'failed').toList();
    final hasPending = pendingJobs.isNotEmpty;
    final hasFailed = failedJobs.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Row(
        children: [
          if (hasFailed)
            TextButton.icon(
              onPressed: _clearFailedPrintJobs,
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Basarisizlari Sil'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          const Spacer(),
          if (hasPending)
            ElevatedButton.icon(
              onPressed: _isSyncing ? null : _retryAllPrintJobs,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.print, size: 18),
              label: Text(_isSyncing ? 'Gonderiliyor...' : 'Tumunu Gonder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
              ),
            ),
          if (!hasPending && !hasFailed)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Kapat'),
            ),
        ],
      ),
    );
  }

  // ==================== SHARED WIDGETS ====================

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required int count,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncItem(Map<String, dynamic> item, {required bool isPending, required ThemeProvider theme}) {
    final syncId = item['id'] as int;
    final description = item['description'] as String? ?? 'Islem';
    final createdAt = item['created_at'] as String?;
    final retryCount = item['retry_count'] as int? ?? 0;
    final errorMessage = item['error_message'] as String?;

    String timeAgo = '';
    if (createdAt != null) {
      try {
        final dt = DateTime.parse(createdAt);
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 1) {
          timeAgo = 'Az once';
        } else if (diff.inMinutes < 60) {
          timeAgo = '${diff.inMinutes} dk once';
        } else if (diff.inHours < 24) {
          timeAgo = '${diff.inHours} saat once';
        } else {
          timeAgo = '${diff.inDays} gun once';
        }
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isPending ? Colors.orange[50] : Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isPending ? Colors.orange[200]! : Colors.red[200]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPending ? Icons.schedule : Icons.error_outline,
                color: isPending ? Colors.orange[700] : Colors.red[700],
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  description,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: isPending ? Colors.orange[900] : Colors.red[900],
                  ),
                ),
              ),
              if (!isPending) ...[
                IconButton(
                  onPressed: () => _retryItem(syncId),
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Tekrar Dene',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: theme.primaryColor,
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _deleteItem(syncId),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Sil',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: Colors.red,
                ),
              ],
            ],
          ),
          if (timeAgo.isNotEmpty || retryCount > 0 || errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (timeAgo.isNotEmpty || retryCount > 0)
                    Text(
                      [
                        if (timeAgo.isNotEmpty) timeAgo,
                        if (retryCount > 0) '$retryCount deneme',
                      ].join(' - '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  if (errorMessage != null)
                    Text(
                      errorMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red[700],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
