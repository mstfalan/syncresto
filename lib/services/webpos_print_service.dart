import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'log_service.dart';
import 'printer_service.dart';

/// 12 Haz 2026 — Web POS fis isleri: DB-polling + atomic claim istemcisi.
///
/// AMAC: Web POS'tan dusen fisler icin socket'e GUVENMEYEN, DB tabanli
/// teslimat. 5 sn'de bir GET /api/pos/print-jobs/pending cekilir; her job
/// icin ONCE POST /claim yapilir ve SADECE claim true donerse yazdirilir.
/// Tek-basim garantisi BU CLAIM'den gelir (DB'de atomik) — 2 POS acik olsa
/// bile fis TEK cihazdan cikar. Yazdirma sonucu /result ile raporlanir.
///
/// - Socket 'webpos_jobs_hint' event'i sadece poll'u one ceker (triggerNow);
///   basim yetkisi tasimaz.
/// - Yazdirma MEVCUT mutfak fisi ureticisiyle yapilir
///   (PrinterService.printKitchenReceiptToIp) — yeni ESC/POS formati YOK.
/// - Kill-switch: SharedPreferences 'webpos_poll_enabled' (default true).
///   false ise start() no-op, ayrica her poll oncesi kontrol edilir.
class WebposPrintService {
  static final WebposPrintService _instance = WebposPrintService._internal();
  factory WebposPrintService() => _instance;
  WebposPrintService._internal();

  /// Feature kill-switch anahtari (SharedPreferences, default: true)
  static const String enabledPrefKey = 'webpos_poll_enabled';
  static const Duration _pollInterval = Duration(seconds: 5);

  ApiService? _apiService;
  PrinterService? _printerService;
  final LogService _logService = LogService();

  Timer? _pollTimer;
  bool _isPolling = false; // ust uste binme korumasi (try/finally ile birakilir)

  bool get isRunning => _pollTimer != null;

  /// main.dart'ta servis kurulurken cagirilir (singleton'lara referans baglar).
  void configure({
    required ApiService apiService,
    required PrinterService printerService,
  }) {
    _apiService = apiService;
    _printerService = printerService;
  }

  Future<bool> _isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(enabledPrefKey) ?? true; // default ACIK
    } catch (_) {
      return true;
    }
  }

  /// Periyodik polling'i baslatir. Kill-switch kapaliysa no-op.
  Future<void> start() async {
    if (!await _isEnabled()) {
      if (kDebugMode) {
        print('[WebposPrint] kill-switch kapali ($enabledPrefKey=false), start no-op');
      }
      return;
    }
    if (_pollTimer != null) return; // zaten calisiyor
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_poll());
    });
    if (kDebugMode) print('[WebposPrint] polling basladi (${_pollInterval.inSeconds}sn)');
    // Ilk turu timer'i beklemeden at
    unawaited(_poll());
  }

  /// Timer'i beklemeden hemen poll tetikler (socket webpos_jobs_hint icin).
  /// _isPolling guard'i sayesinde calisan tur varsa ust uste binmez.
  void triggerNow() {
    unawaited(_poll());
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      final api = _apiService;
      final printer = _printerService;
      if (api == null || printer == null) return; // configure() henuz cagrilmadi
      if (!api.isOnline || !api.hasApiKey) return; // online-only akis
      if (!await _isEnabled()) return; // kill-switch calisirken de gecerli

      final jobs = await api.getWebposPendingPrintJobs();
      if (jobs.isEmpty) return;

      for (final raw in jobs) {
        if (raw is! Map) continue;
        final job = Map<String, dynamic>.from(raw);
        final jobId = job['id'] is int ? job['id'] as int : int.tryParse('${job['id']}');
        if (jobId == null) continue;

        // TEK-BASIM GARANTISI: yazdirma yetkisi SADECE claim'den gelir.
        // false (409 = baska POS kapti, hata, claimed!=true) → bu job atlanir.
        final claimed = await api.claimPrintJob(jobId);
        if (!claimed) continue;

        String? errorMsg;
        try {
          errorMsg = await _printJob(printer, job);
        } catch (e) {
          errorMsg = e.toString();
        }
        final ok = errorMsg == null;

        _logService.logAction(
          ok ? 'Webpos fis basildi (claim)' : 'Webpos fis basilamadi (claim)',
          details: {
            'job_id': jobId,
            'job_type': job['job_type'],
            if (errorMsg != null) 'error': errorMsg,
          },
        );

        // Claim sonrasi sonuc raporu ZORUNLU — backend status'u buna gore set eder.
        // Faz 2 (22 Tem 2026): ilk deneme basarisizsa 2sn+5sn backoff (max 2 tekrar),
        // fire-and-forget — poll dongusunu BLOKLAMAZ (<10sn). Rapor telemetridir;
        // tek-basim garantisi atomik claim'den gelir, tekrar basim riski YOKTUR.
        final reported = await api.reportPrintJobResult(jobId, ok: ok, error: errorMsg);
        if (!reported) {
          unawaited(PrinterService.retryReportWithBackoff(
            () => api.reportPrintJobResult(jobId, ok: ok, error: errorMsg),
            tag: 'webpos result #$jobId',
          ));
        }
      }
    } catch (e) {
      if (kDebugMode) print('[WebposPrint] poll hata: $e');
    } finally {
      _isPolling = false;
    }
  }

  /// Tek job'i MEVCUT mutfak fisi ureticisiyle basar.
  /// Donus: null = basarili, String = hata mesaji (reportPrintJobResult'a gider).
  Future<String?> _printJob(PrinterService printer, Map<String, dynamic> job) async {
    final printerRaw = job['printer'];
    final printerInfo =
        printerRaw is Map ? Map<String, dynamic>.from(printerRaw) : null;
    final ip = printerInfo?['ip']?.toString() ?? '';
    final port = (printerInfo?['port'] as num?)?.toInt() ?? 9100;
    if (ip.isEmpty) {
      return 'Yazici IP bilgisi eksik (job.printer.ip bos)';
    }

    final items = (job['items'] as List?) ?? [];
    if (items.isEmpty) {
      return 'Yazdirilacak urun yok (job.items bos)';
    }

    // Ticket bilgisi: job.ticket map'i esas, top-level alanlar fallback
    final ticketRaw = job['ticket'];
    final ticket = ticketRaw is Map
        ? Map<String, dynamic>.from(ticketRaw)
        : <String, dynamic>{};
    ticket['ticket_number'] ??= job['ticket_number'];
    ticket['table_number'] ??= job['table_number'];
    ticket['section_name'] ??= job['section_name'];
    ticket['waiter_name'] ??= job['waiter_name'];

    final printed = await printer.printKitchenReceiptToIp(
      ticket: ticket,
      items: items,
      ip: ip,
      port: port,
    );
    if (!printed) {
      return 'Yazici cevap vermedi ($ip:$port)';
    }
    return null;
  }
}
