/// 21 Eki 2026: senkron turunun sonunda AYNI turda yeniden denenecek mark_printed kayitlarini secer.
/// mark_printed bagimsiz oldugu icin kalemlerden ONCE islenir ve kalemler henuz sunucuda yoksa
/// "bekliyor" der; bu turda kalem eklendiyse ayni turda bir kez daha denenir.
///  - bu turda hic add_item tamamlanmadiysa -> bos (yeniden denemenin anlami yok)
///  - zaten tamamlanan -> elenir
///  - ilk denemede retry_count'u ARTAN (HTTP hatasi) -> elenir; ayni turda ikinci retry harcanmasin
///  - tur basindaki listede olmayan (tur sirasinda eklenen) -> secilir (hic denenmedi; sunucu ucu idempotent)
List<Map<String, dynamic>> markPrintedTekrarSec({
  required List<Map<String, dynamic>> turBasi,
  required List<Map<String, dynamic>> yenidenOkunan,
  required Set<int> tamamlanan,
}) {
  final kalemEklendi = turBasi.any((r) =>
      r['action'] == 'add_item' && tamamlanan.contains(r['id'] as int));
  if (!kalemEklendi) return const [];
  final ilkRetry = <int, int>{
    for (final r in turBasi)
      if (r['action'] == 'mark_printed') r['id'] as int: (r['retry_count'] as int?) ?? 0,
  };
  return yenidenOkunan.where((r) {
    if (r['action'] != 'mark_printed') return false;
    final id = r['id'] as int;
    if (tamamlanan.contains(id)) return false;
    final once = ilkRetry[id];
    return once == null || ((r['retry_count'] as int?) ?? 0) == once;
  }).toList();
}
