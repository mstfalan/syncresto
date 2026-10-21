/// 21 Eki 2026 (F): 'table_status' push payload'ından aynalanacak masa id'lerini seçer.
/// table_ids yoksa (eski sunucu) boş → 90 sn döngü yeter. Payload'da satır varsa ve masa
/// BOŞ görünüyorsa çekilmez (kapanan masanın prune'u mevcut döngüde).
Set<int> pushAynaMasalariSec(Map<String, dynamic> raw) {
  final ids = raw['table_ids'];
  if (ids is! List || ids.isEmpty) return const {};
  final satir = <int, Map>{};
  final tl = raw['tables'];
  if (tl is List) {
    for (final e in tl) {
      if (e is Map) {
        final id = _tam(e['id']);
        if (id != null) satir[id] = e;
      }
    }
  }
  final out = <int>{};
  for (final x in ids) {
    final id = _tam(x);
    if (id == null) continue;
    final s = satir[id];
    if (s != null && s['status'] != 'occupied' && s['current_ticket_id'] == null) continue;
    out.add(id);
  }
  return out;
}

int? _tam(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
