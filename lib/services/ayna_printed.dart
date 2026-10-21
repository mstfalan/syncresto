/// 21 Eki 2026 — AYNA printed birleştirme kuralı. TEK YÖNLÜ:
/// bir kalem bir kez "basıldı" sayıldıysa ayna onu 0'a GERİ ÇEKEMEZ.
///  - lokal satır yok  → sunucu değeri
///  - lokal 1 (çevrimdışı basıldı, mark_printed bekliyor) → 1 (sunucu 0 dese de)
///  - sunucu 1 (başka kasa/WebPOS bastı) → 1
/// Sunucu alanı int/bool/'1' gelebilir (kiracı sürümüne göre).
int printedBirlestir({required int? lokal, required Object? sunucu}) {
  final s = (sunucu == 1 || sunucu == true || sunucu == '1') ? 1 : 0;
  if (lokal == null) return s;
  return (lokal == 1 || s == 1) ? 1 : 0;
}
