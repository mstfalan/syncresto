// 8 Eyl 2026 — HIZLI SATIŞ (perakende) saf kural katmanı.
//
// Mustafa: "salon adlarının başına HIZLI SATIŞ butonu; ayarlarda pasif gelsin; masa açma gibi
// ama ödeme alındığında ekran kapanmayacak; panelde salonda Hızlı Satış tiki; birden fazla
// hızlı salon varsa pop-up ile seç; salon adında otomatik gizli masa; çevrimdışına dikkat."
//
// Bu dosya UI/DB bağımsızdır (test edilebilir). Bayraklar SQLite'tan 0/1, sunucudan
// true/false/1 gelebilir → HER OKUMA `bayrak()` ile (feedback_sqlite_boolean_yok_int_tuzagi).
class QuickSaleRules {
  QuickSaleRules._();

  /// Gevşek bayrak okuma: true / 1 / '1' / 'true'. null ve diğer her şey → false.
  static bool bayrak(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  static bool salonHizli(dynamic s) => s is Map && bayrak(s['is_quick_sale']);
  static bool masaGizli(dynamic t) => t is Map && bayrak(t['is_quick_sale']);

  /// Panelde "Hızlı Satış" işaretli salonlar (sıra korunur).
  static List<Map<String, dynamic>> hizliSalonlar(List<dynamic> sections) => sections
      .where(salonHizli)
      .map((s) => Map<String, dynamic>.from(s as Map))
      .toList();

  /// Normal salon sekmeleri: hızlı salonlar ASLA sekmede görünmez (ayar açık/kapalı fark etmez —
  /// boş "Bu salonda masa yok" sekmesi olmasın).
  static List<dynamic> normalSalonlar(List<dynamic> sections) =>
      sections.where((s) => !salonHizli(s)).toList();

  /// Gridde/sayaçlarda görünen masalar: gizli hızlı-satış masaları HER ZAMAN elenir.
  static List<dynamic> gorunurMasalar(List<dynamic> tables) =>
      tables.where((t) => !masaGizli(t)).toList();

  /// Bir hızlı salonun gizli masası (backend salon adıyla otomatik üretir). Yoksa null.
  static Map<String, dynamic>? gizliMasa(List<dynamic> tables, int sectionId) {
    for (final t in tables) {
      if (t is! Map) continue;
      if (!masaGizli(t)) continue;
      final sid = _safeInt(t['section_id']);
      if (sid == sectionId) return Map<String, dynamic>.from(t);
    }
    return null;
  }

  /// tables_screen ile AYNI dolu-masa tanımı (status/current_ticket_id/active_ticket_id).
  static bool masaDolu(Map<String, dynamic> t) =>
      t['status'] == 'occupied' || t['current_ticket_id'] != null || t['active_ticket_id'] != null;

  /// Hızlı satış adisyonu YALNIZ açan kasada devam eder (Fable Y1: iki kasa aynı salonu
  /// kullanırsa sessizce aynı adisyona yazıyordu). Eski veri (opened_by_device null/boş) → devam.
  static bool baskaKasadaAcik({String? openedByDevice, String? buKasa}) {
    final a = (openedByDevice ?? '').trim();
    final b = (buKasa ?? '').trim();
    if (a.isEmpty || b.isEmpty) return false;
    return a.toLowerCase() != b.toLowerCase();
  }

  /// Hızlı masalardaki açık adisyonların toplam tutarı + adedi (buton rozeti).
  static ({int adet, double tutar}) acikOzet(List<dynamic> tables, Iterable<int> sectionIds) {
    final ids = sectionIds.toSet();
    var adet = 0;
    var tutar = 0.0;
    for (final t in tables) {
      if (t is! Map) continue;
      if (!masaGizli(t)) continue;
      final sid = _safeInt(t['section_id']);
      if (sid == null || !ids.contains(sid)) continue;
      final m = Map<String, dynamic>.from(t);
      if (!masaDolu(m)) continue;
      adet++;
      tutar += _para(m['current_total']);
    }
    return (adet: adet, tutar: tutar);
  }

  /// Çevrimdışı adisyon numarası masa parçası (Fable E1): sunucu `ticket_number` varchar(30);
  /// `OFFLINE-` (8) + parça + `-` (1) + uuid8 (8) = 30 → parça EN FAZLA 13 karakter, ASCII
  /// alfanümerik. "Hızlı Satış Kasa 2" → "HizliSatisKas". Boş kalırsa "MASA". ticket_number hiçbir
  /// yerde parse edilmez (Fable D6) — salt görüntü/kimlik.
  static String offlineMasaAnahtari(String? tableNumber) {
    final ascii = turkceToAscii(tableNumber ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final kirp = ascii.length > 13 ? ascii.substring(0, 13) : ascii;
    return kirp.isEmpty ? 'MASA' : kirp;
  }

  static const Map<String, String> _tr = {
    'ç': 'c', 'Ç': 'C', 'ğ': 'g', 'Ğ': 'G', 'ı': 'i', 'İ': 'I', 'ö': 'o', 'Ö': 'O',
    'ş': 's', 'Ş': 'S', 'ü': 'u', 'Ü': 'U', 'â': 'a', 'Â': 'A', 'î': 'i', 'Î': 'I',
    'û': 'u', 'Û': 'U', 'ô': 'o', 'Ô': 'O', 'ê': 'e', 'Ê': 'E',
  };

  static String turkceToAscii(String s) {
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      sb.write(_tr[ch] ?? ch);
    }
    return sb.toString();
  }

  static int? _safeInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static double _para(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(',', '.')) ?? 0;
  }
}
