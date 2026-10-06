// 6 Eki 2026 (Mustafa) — MUTFAK FISINDE AYNI KALEMLERI BIRLESTIR.
// "10 kofte girdim, mutfak fisinde 10 ayri satir cikiyor. Notu/varyasyonu olan ayri
// gorunmeli; ayni olanlar '10 x Kofte' diye yazmali."
//
// FIS SOZLESMESI (feedback_fis_akisi_bozulamaz):
//  - Yalniz BIREBIR AYNI 'tek' kalemler birlesir: urun, ad, porsiyon, not, secimler ve
//    fisin sagindaki garson·saat metni AYNI olmali. Farkli garson/dakika ayri satirda kalir.
//  - Combo gruplarina ('grup') DOKUNULMAZ.
//  - Birlesecek kalem yoksa liste AYNEN (ayni nesneler, ayni sira) doner -> fis BIREBIR eski.
//  - Birlesen satir ILK kalemin yerinde durur; adet = toplam. Cagiran try/catch ile sarar.

/// [satirlar]: `_comboGrupla` ciktisi ({tip:'tek', kalem} | {tip:'grup', ...}).
/// [anahtar]: bir kalemin birlesme anahtari; null donerse o kalem ASLA birlesmez.
List<Map<String, dynamic>> ayniKalemleriBirlestir(
  List<Map<String, dynamic>> satirlar,
  String? Function(Map kalem) anahtar,
) {
  final ilkYer = <String, int>{};          // anahtar -> sonuc listesindeki indeks
  final toplam = <String, num>{};          // anahtar -> toplam adet
  final sayi = <String, int>{};            // anahtar -> kac kalem birlesti
  final sonuc = <Map<String, dynamic>>[];
  for (final s in satirlar) {
    final k = s['kalem'];
    if (s['tip'] != 'tek' || k is! Map) { sonuc.add(s); continue; }
    final a = anahtar(k);
    final adet = _adet(k['quantity']);
    if (a == null || adet == null) { sonuc.add(s); continue; }
    final yer = ilkYer[a];
    if (yer == null) {
      ilkYer[a] = sonuc.length;
      toplam[a] = adet;
      sayi[a] = 1;
      sonuc.add(s);
    } else {
      toplam[a] = toplam[a]! + adet;
      sayi[a] = sayi[a]! + 1;
    }
  }
  // Yalniz GERCEKTEN birlesen satirlarin kalemi kopyalanip adedi guncellenir;
  // digerleri ayni nesne olarak kalir (cikti birebir).
  ilkYer.forEach((a, yer) {
    if ((sayi[a] ?? 1) < 2) return;
    final eski = sonuc[yer]['kalem'] as Map;
    final yeni = Map<String, dynamic>.from(eski);
    final t = toplam[a]!;
    yeni['quantity'] = (t == t.roundToDouble()) ? t.toInt() : t;
    sonuc[yer] = {'tip': 'tek', 'kalem': yeni};
  });
  return sonuc;
}

num? _adet(dynamic v) {
  if (v == null) return 1;               // fis de null'i 1 basiyor (item['quantity'] ?? 1)
  if (v is num) return v > 0 ? v : null;
  final n = num.tryParse(v.toString().trim());
  return (n != null && n > 0) ? n : null;
}
