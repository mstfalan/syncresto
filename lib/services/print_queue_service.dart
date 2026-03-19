import 'dart:async';
import 'printer_service.dart';
import 'local_db_service.dart';

/// Yazıcı kuyruğu otomatik retry servisi
/// Her 5 saniyede bekleyen yazdırma işlerini tekrar dener
class PrintQueueService {
  static final PrintQueueService _instance = PrintQueueService._internal();
  factory PrintQueueService() => _instance;
  PrintQueueService._internal();

  Timer? _retryTimer;
  final PrinterService _printerService = PrinterService();
  final LocalDbService _localDb = LocalDbService();

  bool _isProcessing = false;

  /// Otomatik retry'ı başlat
  void startAutoRetry() {
    print('[PrintQueue] Otomatik retry baslatildi (5 saniye aralik)');

    // Başlangıçta bir kez çalıştır
    _processQueue();

    // Timer'ı başlat
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _processQueue();
    });
  }

  /// Otomatik retry'ı durdur
  void stopAutoRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    print('[PrintQueue] Otomatik retry durduruldu');
  }

  /// Kuyruktaki bekleyen işleri işle
  Future<void> _processQueue() async {
    // Zaten işleniyorsa atla
    if (_isProcessing) {
      return;
    }

    _isProcessing = true;

    try {
      final pendingJobs = await _localDb.getPendingPrintJobs();

      if (pendingJobs.isEmpty) {
        return;
      }

      print('[PrintQueue] ${pendingJobs.length} bekleyen is isleniyor...');

      for (final job in pendingJobs) {
        final id = job['id'] as int;
        final retryCount = job['retry_count'] as int;
        final maxRetries = job['max_retries'] as int;

        // Max denemeye ulaştıysa atla
        if (retryCount >= maxRetries) {
          print('[PrintQueue] Job $id max denemeye ulasti, atlaniyor');
          continue;
        }

        // Yazdırmayı dene
        final success = await _printerService.retryPrintJob(id);

        if (success) {
          print('[PrintQueue] Job $id basarili');
        } else {
          print('[PrintQueue] Job $id basarisiz (${retryCount + 1}/$maxRetries)');
        }

        // Her iş arasında kısa bekleme (yazıcıyı boğmamak için)
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Tamamlanmış eski işleri temizle
      await _localDb.cleanupCompletedPrintJobs();

    } catch (e) {
      print('[PrintQueue] Kuyruk islenirken hata: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Manuel olarak tüm bekleyen işleri tekrar dene
  Future<int> retryAllPending() async {
    final pendingJobs = await _localDb.getPendingPrintJobs();
    int successCount = 0;

    for (final job in pendingJobs) {
      final id = job['id'] as int;
      final success = await _printerService.retryPrintJob(id);
      if (success) {
        successCount++;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    return successCount;
  }

  /// Tek bir işi manuel olarak tekrar dene
  Future<bool> retryJob(int jobId) async {
    // Önce job'u sıfırla (retry_count = 0, status = pending)
    await _localDb.resetPrintJob(jobId);
    // Sonra tekrar dene
    return await _printerService.retryPrintJob(jobId);
  }

  /// Kuyruk durumu
  Future<Map<String, int>> getQueueSummary() async {
    return await _localDb.getPrintQueueSummary();
  }

  /// Servis çalışıyor mu?
  bool get isRunning => _retryTimer != null;
}
