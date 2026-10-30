// 28 Eki 2026 — KALEM BOLME ("Bol") KURALLARI (saf, bagimliliksiz — testler DOGRUDAN bunu kullanir).
//
// Mustafa: "200 TL'lik 1 urunu iki kisi 100+100 (ya da elle tutar) odeyebilsin."
// Sunucu modeli (SOZLESME, project_pos_kalem_bolme_tasarim):
//  - Ana satir ILK payi tutar: split_seq=1, split_parts=N, split_parent_id NULL.
//  - N-1 parca satiri: split_parent_id=ana.id, split_seq=2..N, split_parts=N, quantity=1,
//    printed/delivered/created_at ANA satirdan kopya.
//  - "Bolunmus grup uyesi" = split_parts dolu.  "Parca satiri" = split_parent_id dolu.
//  - FIZIKSEL okuyucular (urun adedi, mutfak fisi, masa takip, ozet fisi) parca satirini SAYMAZ.
//  - PARA okuyuculari (tutar, kalan, odeme, kasa fisi toplami) parcayi DAHIL eder.
//  - Kurus artigi SON parcaya (sunucuyla AYNI kural; ekran ile sunucu farkli parca gostermesin).
//
// Bu dosya UI/ag/DB bilmez. add_item_modal (Bol dugmesi + pencere), local_db_service
// (fiziksel sorgular), printer_service (fis katlama) AYNI fonksiyonlari cagirir — tek kaynak.
import 'ikram_rules.dart';

class KalemBolme {
  KalemBolme._(); // instance yok — saf statik yardimcilar

  static const int enAzParca = 2;
  static const int enCokParca = 10; // sunucu siniri (SOZLESME: parts 2..10)

  /// int / num / '187' hepsi icin guvenli tam sayi. Bos/bozuk -> null.
  static int? tamSayi(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v == v.roundToDouble() ? v.toInt() : null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final i = int.tryParse(s);
    if (i != null) return i;
    final d = double.tryParse(s);
    return (d != null && d == d.roundToDouble()) ? d.toInt() : null;
  }

  /// num / '230.00' hepsi icin guvenli ondalik (backend fiyati String de dondurebilir).
  static double ondalik(dynamic v, [double varsayilan = 0]) {
    if (v == null) return varsayilan;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? varsayilan;
  }

  /// Satirin SUNUCU kimligi. Cevrimdisi yerel aynada `id` = yerel local_id, sunucu id'si
  /// `server_id`'de durur; parcalarin split_parent_id'si ise HER ZAMAN sunucu id'sidir.
  /// Bu yuzden grup eslesmesi once server_id'ye bakar (30 Eki 2026 Fable ORTA-1).
  static int? kimlik(dynamic item) {
    if (item is! Map) return null;
    // Yerel aynada server_id anahtari VAR: NULL ise (cevrimdisi eklenmis) eslesme adayi DEGIL —
    // yerel local_id bir sunucu id'siyle sayisal cakisamaz.
    if (item.containsKey('server_id')) return tamSayi(item['server_id']);
    return tamSayi(item['id']);
  }

  /// Parca satiri mi? (split_parent_id DOLU) — fiziksel sayimda SAYILMAZ.
  static bool parcaSatiriMi(dynamic item) =>
      item is Map && tamSayi(item['split_parent_id']) != null;

  /// Bolunmus grubun uyesi mi? (ana satir DAHIL; split_parts DOLU)
  static bool grupUyesiMi(dynamic item) =>
      item is Map && tamSayi(item['split_parts']) != null;

  /// Ekrandaki parca etiketi: "1/2", "2/2"... Grup uyesi degilse null (HICBIR SEY cizilmez).
  static String? parcaEtiketi(dynamic item) {
    if (!grupUyesiMi(item)) return null;
    final m = item as Map;
    final parts = tamSayi(m['split_parts'])!;
    final seq = tamSayi(m['split_seq']) ?? (parcaSatiriMi(m) ? 0 : 1);
    return '$seq/$parts';
  }

  /// "Bol" dugmesi bu satirda gosterilir mi? Sunucu kurallarinin ISTEMCI yansimasi
  /// (sunucu yine dogrular; buradaki amac kasiyere bosuna buton gostermemek):
  /// aktif, odenmemis, ikram degil, combo uyesi degil, PAVO'ya gitmemis, parca degil,
  /// zaten bolunmemis, quantity=1, tutar>0.
  static bool bolunebilirMi(dynamic item) {
    if (item is! Map) return false;
    if ((item['status'] ?? 'active').toString() == 'cancelled') return false;
    if ((item['payment_status'] ?? '').toString() == 'paid') return false;
    if (IkramRules.kalemIkramMi(item)) return false;
    if ((item['combo_group_id'] ?? '').toString().trim().isNotEmpty) return false;
    if ((item['pavo_tx_id'] ?? '').toString().trim().isNotEmpty) return false;
    if (parcaSatiriMi(item) || grupUyesiMi(item)) return false;
    final adet = tamSayi(item['quantity']) ?? 1;
    if (adet != 1) return false;
    return ondalik(item['unit_price']) > 0;
  }

  /// Grupta ODENMIS uye var mi? (varsa sunucu iptali 400 ile reddeder — istemci onceden soyler)
  static bool gruptaOdenmisVarMi(dynamic item, List<dynamic> tumKalemler) {
    return grupKalemleri(item, tumKalemler)
        .any((k) => (k['payment_status'] ?? '').toString() == 'paid');
  }

  /// Bir uyenin TUM grup kalemleri (ana + parcalar). Grup uyesi degilse yalniz kendisi.
  static List<Map> grupKalemleri(dynamic item, List<dynamic> tumKalemler) {
    if (item is! Map) return const [];
    if (!grupUyesiMi(item)) return [item];
    final anaId = tamSayi(item['split_parent_id']) ?? kimlik(item);
    if (anaId == null) return [item];
    final grup = tumKalemler.whereType<Map>().where((k) {
      if ((k['status'] ?? 'active').toString() == 'cancelled') return false;
      return kimlik(k) == anaId || tamSayi(k['split_parent_id']) == anaId;
    }).toList();
    return grup.isEmpty ? [item] : grup;
  }

  // ---------------------------------------------------------------------------
  // PARA HESABI — kurus duzeyinde (double toplamada 0.1+0.2 tuzagi yok)
  // ---------------------------------------------------------------------------

  /// TL -> kurus (2 ondalik yuvarlama).
  static int kurus(double tl) => (tl * 100).round();

  /// kurus -> TL
  static double tl(int kurus) => kurus / 100;

  /// ESIT BOLME (kurus): toplam / parca; artik SON parcaya. Sunucuyla AYNI kural.
  /// parca araligi [enAzParca, enCokParca] disinda ya da her parcaya 1 kurus dusmuyorsa null.
  static List<int>? esitBolKurus(int toplamKurus, int parca) {
    if (parca < enAzParca || parca > enCokParca) return null;
    if (toplamKurus < parca) return null;
    final pay = toplamKurus ~/ parca;
    final artik = toplamKurus - pay * parca;
    final l = List<int>.filled(parca, pay);
    l[parca - 1] += artik;
    return l;
  }

  /// ESIT BOLME (TL). Ornek: 200 -> [100.00, 100.00]; 100 / 3 -> [33.33, 33.33, 33.34].
  static List<double>? esitBol(double toplamTl, int parca) =>
      esitBolKurus(kurus(toplamTl), parca)?.map(tl).toList();

  /// "TUTAR YAZ": kasiyer ilk parcayi yazar, ikinci parca KALAN (otomatik). Gecersizse null:
  /// ilk < 0.01, kalan < 0.01 (ilk >= satir tutari), satir tutari < 0.02.
  /// Ornek: satir 200, ilk 120 -> [120.00, 80.00].
  static List<double>? tutarlaBol(double satirTutariTl, double ilkTl) {
    final t = kurus(satirTutariTl);
    final i = kurus(ilkTl);
    if (t < 2 || i < 1 || i >= t) return null;
    return [tl(i), tl(t - i)];
  }

  /// "TUTAR YAZ" (Web POS ile AYNI): kasiyer 1..N-1. parcalari yazar, SON parca KALAN.
  /// Gecersizse null: yazilan parca < 0.01, kalan < 0.01, toplam parca > [enCokParca].
  /// Ornek: satir 200, [100, 50] -> [100.00, 50.00, 50.00].
  static List<double>? tutarlarlaBol(double satirTutariTl, List<double> yazilanlar) {
    if (yazilanlar.isEmpty || yazilanlar.length + 1 > enCokParca) return null;
    final t = kurus(satirTutariTl);
    var top = 0;
    final l = <int>[];
    for (final y in yazilanlar) {
      final k = kurus(y);
      if (k < 1) return null;
      l.add(k);
      top += k;
    }
    final kalan = t - top;
    if (kalan < 1) return null;
    l.add(kalan);
    return l.map(tl).toList();
  }

  /// Parcalarin toplami satir tutarina KURUS duzeyinde esit mi? (sunucu esit degilse 400 der;
  /// istemci gondermeden once dogrular — yuvarlama/fallback YOK).
  static bool toplamTutuyorMu(double satirTutariTl, List<double> parcalar) {
    if (parcalar.isEmpty) return false;
    var toplam = 0;
    for (final p in parcalar) {
      final k = kurus(p);
      if (k < 1) return false;
      toplam += k;
    }
    return toplam == kurus(satirTutariTl);
  }

  /// Kasiyerin yazdigi metni TL'ye cevir: "120", "120,50", "120.5", " 99 ". Binlik ayraci YOK
  /// (dokunmatik sayisal giris). Bos/bozuk/sifir/negatif/2'den fazla ondalik -> null
  /// (Web POS ile AYNI kural: ^\d+(\.\d{1,2})?$ — sessiz yuvarlama YOK).
  static double? tutarAyristir(String ham) {
    var s = ham.trim().replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
    if (s.isEmpty) return null;
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(s)) return null;
    final v = double.tryParse(s);
    if (v == null || v.isNaN || v.isInfinite || v <= 0) return null;
    return v;
  }

  // ---------------------------------------------------------------------------
  // LISTE DONUSUMLERI — kanit yoksa AYNI liste doner (fis sozlesmesi: 0 regresyon)
  // ---------------------------------------------------------------------------

  /// FIZIKSEL liste: parca satirlari dusurulur (mutfak fisi, ozet fisi, masa takip).
  /// Hic parca yoksa AYNI nesne doner (listeyi kopyalamaz bile).
  static List<T> parcasiz<T>(List<T> items) {
    if (!items.any(parcaSatiriMi)) return items;
    return items.where((i) => !parcaSatiriMi(i)).toList();
  }

  /// Katlanmis satirda parcalar FARKLI yontem/durumla odendiyse yazilan isaret (tek yontem
  /// rozeti YALAN soylemesin). Kasa fisi satir basina yontem basmaz; bu deger yalniz
  /// birlestirme anahtarina (ve ileride okuyacak bir yuzeye) gider.
  static const String karisikOdemeDurumu = 'partial';
  static const String karisikOdemeYontemi = 'PARÇALI';

  /// KASA/HESAP FISI: parca tutarlari ANA satira KATLANIR -> musteri 1 urun gorur
  /// (tek satir, tutar = grup toplami). Hic parca yoksa AYNI liste (ayni nesneler, ayni sira)
  /// -> fis BIREBIR eski. Ana satir listede YOKSA parca kendi satirinda kalir (fail-safe:
  /// tutar kaybolmaz). Iptal parca katlanmaz (grup zaten birlikte iptal olur).
  /// Katlanan ana satir KOPYALANIR (unit_price = grup toplami, quantity=1); diger nesneler aynen.
  /// Parcalar farkli yontem/durumla odendiyse (nakit+kart, odenmis+odenmemis) kopyada
  /// payment_status='partial', payment_method='PARÇALI' -> ana satirin tek yontemi grubun
  /// tamamiymis gibi gorunmez; birlestirme anahtari da baska satirla yanlis birlesmez.
  static List<dynamic> parcalariAnaSatiraKatla(List<dynamic> items) {
    if (!items.any(parcaSatiriMi)) return items;
    final anaIdler = <int>{};
    for (final i in items) {
      if (i is Map && !parcaSatiriMi(i)) {
        final id = kimlik(i);
        if (id != null) anaIdler.add(id);
      }
    }
    String odemeImzasi(Map m) =>
        '${(m['payment_status'] ?? '').toString()}|${(m['payment_method'] ?? '').toString()}';
    final ek = <int, int>{}; // ana id -> katlanan kurus
    final odemeler = <int, Set<String>>{}; // ana id -> parcalarin odeme imzalari
    final sonuc = <dynamic>[];
    for (final i in items) {
      if (parcaSatiriMi(i)) {
        final m = i as Map;
        final anaId = tamSayi(m['split_parent_id'])!;
        final iptal = (m['status'] ?? 'active').toString() == 'cancelled';
        if (anaIdler.contains(anaId) && !iptal) {
          final adet = tamSayi(m['quantity']) ?? 1;
          ek[anaId] = (ek[anaId] ?? 0) + kurus(ondalik(m['unit_price']) * adet);
          (odemeler[anaId] ??= <String>{}).add(odemeImzasi(m));
          continue; // parca satiri fiste gorunmez
        }
      }
      sonuc.add(i);
    }
    for (var k = 0; k < sonuc.length; k++) {
      final i = sonuc[k];
      if (i is! Map) continue;
      final id = kimlik(i);
      if (id == null || !ek.containsKey(id)) continue;
      final adet = tamSayi(i['quantity']) ?? 1;
      final yeni = Map<String, dynamic>.from(i);
      final toplamKurus = kurus(ondalik(i['unit_price']) * adet) + ek[id]!;
      yeni['unit_price'] = tl(toplamKurus);
      yeni['quantity'] = 1;
      final imzalar = {...?odemeler[id], odemeImzasi(i)};
      if (imzalar.length > 1) {
        yeni['payment_status'] = karisikOdemeDurumu;
        yeni['payment_method'] = karisikOdemeYontemi;
      }
      sonuc[k] = yeni;
    }
    return sonuc;
  }
}
