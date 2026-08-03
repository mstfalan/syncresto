// 3 Agu 2026 — IKRAM KURALLARI (saf, bagimliliksiz — testler DOGRUDAN bunu kullanir).
//
// Neden ayri dosya: yetki katiligi + sebep zorunlulugu + SQLite 0/1 bayrak okumasi
// para/mal kaybina acik kurallardir; UI icinde gomulu kalirsa test edilemez.
// add_item_modal / api_service / local_db_service AYNI fonksiyonlari cagirir
// (tek kaynak) — testler de birebir ayni kodu dogrular.
//
// ⚠️ SQLite'ta BOOLEAN YOK: is_ikram / is_active INTEGER 0/1 saklanir. Dart'ta
//    `0 == false` FALSE dondugu icin ham karsilastirma YASAK — esnek guard sart.
//    (Bu tuzak daha once combo_repeat'te 250 TL'lik para hatasina yol acti.)
class IkramRules {
  IkramRules._(); // instance yok — saf statik yardimcilar

  /// KATI YETKI KURALI (Mustafa, 2 Agu guvenlik fix'i ile ayni cizgi):
  /// yetki verisi YOKSA veya Map DEGILSE ikram REDDEDILIR. Sadece
  /// permissions Map'inde `ikram: true` acikca varsa izin verilir.
  static bool yetkiVarMi(dynamic rawPermissions) {
    if (rawPermissions is! Map) return false;
    return rawPermissions['ikram'] == true;
  }

  /// SQLite int (0/1), backend bool, eski API string ('1'/'true'/'t') — hepsi
  /// icin esnek dogruluk guard'i. Bilinmeyen deger = false (guvenli taraf).
  static bool bayrak(dynamic v) =>
      v == true || v == 1 || v == '1' || v == 'true' || v == 't';

  /// Bir adisyon kalemi ikram mi? (is_ikram alani esnek guard ile okunur)
  static bool kalemIkramMi(dynamic item) {
    if (item is! Map) return false;
    return bayrak(item['is_ikram']);
  }

  /// `ikram_reason_required` ayari: deger BILINMIYORSA ZORUNLU kabul edilir
  /// (guvenli taraf — sebepsiz bedava urun dagitimi varsayilanla ACILMAZ).
  /// cached_settings TEXT saklar: 'true'/'false'/'1'/'0' hepsi desteklenir.
  static bool sebepZorunluMu(dynamic v) {
    if (v == null) return true;
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return true;
    return !(s == '0' || s == 'false');
  }

  /// Sebep onay butonu aktif mi? Zorunluysa sebepsiz onay PASIF; opsiyonelse
  /// sebepsiz de onaylanabilir (secilirse yine kaydedilir). _IkramDialog._sebepSor
  /// bu fonksiyonu kullanir — testler ayni kodu dogrular.
  static bool onaylanabilirMi({required String girilen, required bool zorunlu}) =>
      girilen.trim().isNotEmpty || !zorunlu;

  /// Sebep listesi satirlarini filtrele (is_active esnek guard; alan HIC yoksa
  /// aktif kabul — server zaten filtrelemis olabilir) + sort_order'a gore sirala.
  static List<Map<String, dynamic>> aktifSebepler(List<dynamic> rows) {
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final reason = (m['reason'] ?? '').toString().trim();
      if (reason.isEmpty) continue;
      if (m.containsKey('is_active') && m['is_active'] != null && !bayrak(m['is_active'])) {
        continue; // pasif sebep gosterilmez
      }
      out.add(m);
    }
    int siraNo(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? 0}') ?? 0;
    out.sort((a, b) => siraNo(a['sort_order']).compareTo(siraNo(b['sort_order'])));
    return out;
  }

  static double _sayi(dynamic v, [double varsayilan = 0]) {
    if (v == null) return varsayilan;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? varsayilan;
  }

  /// Aktif (iptal olmayan) kalemlerin IKRAM toplami — tahsil edilecek tutardan
  /// dusulecek miktar. Online'da backend close() ayni dusumu authoritative yapar;
  /// bu deger POS onizlemesi + OFFLINE kapanis icindir.
  static double ikramToplami(List<dynamic> items) {
    double toplam = 0;
    for (final i in items) {
      if (i is! Map) continue;
      if ((i['status'] ?? '').toString() == 'cancelled') continue;
      if (!kalemIkramMi(i)) continue;
      toplam += _sayi(i['unit_price']) * _sayi(i['quantity'], 1);
    }
    return toplam;
  }
}
