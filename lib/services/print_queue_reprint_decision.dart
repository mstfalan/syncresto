/// 6 Eyl 2026 — KUYRUK × POPUP YARIŞI (Green Chef çift fiş denetimi).
///
/// Mutfak fişi TCP'de düşünce iki aktör aynı işi basmaya çalışır:
///  (a) PrintQueueService 5 sn'de bir `retryPrintJob` (arka plan, sessiz),
///  (b) KitchenPrintRetryModal "Tekrar Yazdır" (kullanıcı, koşulsuz basıyordu).
/// (a) başarılı olup (b) hâlâ açıkken kullanıcı basınca fiş İKİ KEZ çıkıyordu (pos_logs: manuel tekrar
/// hatadan 2–30 sn sonra; 30 sn = 6 otomatik deneme penceresi).
///
/// Çözüm: print_queue.status'a geçici 'printing' değeri (ATOMİK `UPDATE … WHERE status='pending'`
/// sahiplenme). Bu dosya SAF karar mantığıdır (birim test edilir); SQLite tarafı LocalDbService.
enum ManualReprintAction {
  /// Kuyruk kaydı 'pending' → önce sahiplen (claim), sonra bas.
  printWithClaim,

  /// Kuyruk kaydı 'failed' (retry tükendi, arka plan dokunmaz) veya kuyrukta yok → claim'siz bas.
  printWithoutClaim,

  /// Kuyruk kaydı 'completed' → arka plan zaten bastı, TEKRAR BASMA.
  skipAlreadyPrinted,

  /// Kuyruk kaydı 'printing' → arka plan şu an basıyor, bekle ve yeniden bak.
  waitInProgress,
}

class PrintQueueReprintDecision {
  /// Uygulama 'printing' ortasında kapanırsa iş takılı kalmasın: bu süreden eski claim → pending.
  static const Duration staleClaimAfter = Duration(minutes: 2);

  static ManualReprintAction decide(String? queueStatus) {
    switch (queueStatus) {
      case 'completed':
        return ManualReprintAction.skipAlreadyPrinted;
      case 'printing':
        return ManualReprintAction.waitInProgress;
      case 'pending':
        return ManualReprintAction.printWithClaim;
      default:
        // 'failed' (tükenmiş) / null (kayıt yok veya okunamadı) → eski davranış: bas.
        return ManualReprintAction.printWithoutClaim;
    }
  }

  static bool isStaleClaim(DateTime? lastAttemptAt, DateTime now) =>
      lastAttemptAt == null || now.difference(lastAttemptAt) > staleClaimAfter;
}
