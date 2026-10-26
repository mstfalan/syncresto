/// 26 Eki 2026 (POS 1.7.11): sunucu yoklamasinin (GET /health) sonucunu online/offline kararina cevirir.
/// Eski davranis: TEK basarisiz yoklama (2,5 sn cevap yok) butun uygulamayi ~10 sn offline'a atiyordu;
/// Green Chef'te kasa basina gunde 50-180 gecis, %93'u 6-11 sn — gercek kesinti degil, anlik gecikme.
/// O pencerede acilan masa sonra 404 veriyor, lisans kontrolune denk gelirse kasa girise atiliyordu.
/// Yeni: online iken ust uste [esik] yoklama basarisiz olmadan offline'a GECILMEZ; ilk hatadan sonra
/// kisa surede teyit yoklamasi yapilir. Ag karti (NIC) kopmasi bu karardan bagimsiz, yine aninda offline.
class YoklamaKarari {
  static const int esik = 2;

  int _ardisikHata = 0;
  int get ardisikHata => _ardisikHata;

  /// Ilk hatadan sonra teyit yoklamasi bekleniyor mu (online kalindi ama bir hata goruldu).
  bool get teyitBekliyor => _ardisikHata > 0 && _ardisikHata < esik;

  /// [basarili]: yoklamanin sonucu. [erisilebilir]: su anki backend durumu. Doner: yeni durum.
  bool uygula({required bool basarili, required bool erisilebilir}) {
    if (basarili) {
      _ardisikHata = 0;
      return true;
    }
    _ardisikHata++;
    if (!erisilebilir) return false; // zaten offline: tek hata da offline tutar
    return _ardisikHata < esik;
  }

  /// NIC koptugunda sayac sifirlanir (offline karari NIC'ten geldi, yoklamadan degil).
  void sifirla() => _ardisikHata = 0;
}
