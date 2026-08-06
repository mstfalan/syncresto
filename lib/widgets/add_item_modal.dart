import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';   // 6 Agu 2026 — icerik kilidi (400) hatasini kullaniciya anlamli gostermek icin
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/ikram_rules.dart';
import '../services/printer_service.dart';
import '../services/log_service.dart';
import '../services/image_cache_service.dart';
import '../services/storage_service.dart';
import '../services/combo_calculator.dart';
import '../providers/theme_provider.dart';
import 'kitchen_print_retry_modal.dart';

/// 3 Agu 2026 — YENI KALEM OTO-SECIM kurallari (saf; test/pos_oto_secim_test.dart dogrular).
/// Mustafa: liste ters sirali (en yeni ustte) — o kalem ayni anda SECILI de gelsin.
class PosOtoSecim {
  PosOtoSecim._(); // instance yok

  /// Ekleme aninda secim: [secilsin]=true ise yeni kalemin (gecici, negatif) id'si
  /// secilir — kullanici baska kalem secmis olsa bile secim yeni urune gecer (beklenen).
  /// false ise mevcut secim korunur (combo paketinin 2..N kalemleri: ILK kalem secili).
  static int? eklemede({required int? mevcut, required int tempId, required bool secilsin}) =>
      secilsin ? tempId : mevcut;

  /// Sync sonrasi gecici id gercek id'ye donusur: secim gecici id'deyse KAYBOLMADAN
  /// gercek id'ye tasinir; kullanici bu arada BASKA kalem sectiyse dokunulmaz.
  static int? syncSonrasi({required int? mevcut, required int tempId, required int realId}) =>
      mevcut == tempId ? realId : mevcut;
}

class AddItemModal extends StatefulWidget {
  final ApiService apiService;
  final PrinterService? printerService;
  final int ticketId;
  final int waiterId;
  final VoidCallback onItemAdded;
  final VoidCallback onClose;
  final bool showProductImages;
  final int tableId;
  final Map<String, dynamic>? table;
  final Map<String, dynamic>? waiter;
  final Map<String, dynamic>? section;

  const AddItemModal({
    super.key,
    required this.apiService,
    required this.ticketId,
    required this.waiterId,
    required this.onItemAdded,
    required this.onClose,
    this.showProductImages = true,
    this.tableId = 0,
    this.printerService,
    this.table,
    this.waiter,
    this.section,
  });

  @override
  State<AddItemModal> createState() => _AddItemModalState();
}

class _AddItemModalState extends State<AddItemModal> {
  List<dynamic> _categories = [];
  List<dynamic> _products = [];
  List<dynamic> _filteredProducts = [];
  List<dynamic> _ticketItems = [];
  Map<String, dynamic>? _ticketInfo;
  /// 15 Tem 2026: Panelden gelen EK ödeme yöntemleri (show_pos=true, nakit/kart HARİÇ).
  /// Nakit/Kart butonları HER ZAMAN built-in gösterilir; bu liste onlara ek dinamik butonlardır.
  /// Boş/offline -> sadece built-in görünür (geriye tam uyum).
  List<Map<String, dynamic>> _dynamicPaymentMethods = [];
  bool _isLoading = true;
  int? _selectedCategoryId;
  String _searchQuery = '';
  /// Seçili ticket item'in ID'si (server tarafındaki id).
  /// Index yerine ID kullanıyoruz çünkü _ticketItems sırası API refresh sonrası
  /// değişebiliyordu ve eski index yanlış item'ı işaret ediyordu (notları başka
  /// ürünlere uyguluyordu). ID ile her zaman doğru item bulunur.
  int? _selectedItemId;
  /// Helper — ID ile item bul (cancelled olmayanlar arasından)
  Map<String, dynamic>? _findSelectedItem() {
    if (_selectedItemId == null) return null;
    for (final it in _ticketItems) {
      if (it['status'] == 'cancelled') continue;
      if (_safeInt(it['id']) == _selectedItemId) return it;
    }
    return null;
  }

  final TextEditingController _searchController = TextEditingController();
  final ImageCacheService _imageCache = ImageCacheService();
  bool _imageCacheReady = false;
  bool _variantOnTap = false; // ayar: urune tiklayinca varyant secimi acilsin mi

  int? _safeInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _safeDouble(dynamic value, [double defaultValue = 0]) {
    if (value == null) return defaultValue;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? defaultValue;
  }

  /// Bir urunun POS (RESTORAN kanali) baz fiyati: restaurant_price (varsa/≠0) yoksa price.
  /// Varyantin kendi kanal fiyati yoksa bu baz kullanilir (Mustafa: "varyant fiyati yoksa ana
  /// karttaki restoran fiyatini al").
  double _restaurantBasePrice(Map<String, dynamic> product) {
    final rp = product['restaurant_price'];
    if (rp != null && _safeDouble(rp) != 0) return _safeDouble(rp);
    return _safeDouble(product['price']);
  }

  /// Bir varyantin POS (RESTORAN kanali) modifier'i: restaurant_modifier (varsa) ?? genel price_modifier.
  /// POS restoran kanali oldugundan once restaurant_modifier'a bakar; o kanalda ozel deger yoksa (null)
  /// genel price_modifier'a duser. Boylece panelde "Res -940" girilince POS varyant fiyati = baz-940.
  double _variantModifier(Map<String, dynamic> variant) {
    final rm = variant['restaurant_modifier'];
    if (rm != null) return _safeDouble(rm);
    return _safeDouble(variant['price_modifier']);
  }

  /// 12 Haz 2026 — MUTLAK FIYAT modeli: notes icindeki '(+N TL)' / '(+NTL)'
  /// fiyat token'larini toplar (ondalik virgul/nokta destekli).
  /// Tek kullanim yeri: varyant uygulamasinda mevcut ucretli ekstra toplamini
  /// bulmak (eski varyant etiketleri temizlendikten SONRA cagrilir).
  double _sumExtraPriceTokens(String notes) {
    if (notes.isEmpty) return 0;
    double total = 0;
    for (final m in RegExp(r'\(\+\s*(\d+(?:[.,]\d+)?)\s*TL\)', caseSensitive: false).allMatches(notes)) {
      total += double.tryParse((m.group(1) ?? '0').replaceAll(',', '.')) ?? 0;
    }
    return total;
  }

  /// 🔴 6 Agu 2026 — KALEMIN `extras` FIYAT TOPLAMI.
  ///
  /// Varyant/coklu secim farklari SADECE `extras`'ta durur, notlara ASLA fiyat
  /// yazilmaz (bkz. satir 868-869 ve 889-890: backend'in unit_price safety-net'i
  /// nottaki '+NTL' desenine bakar, oraya fiyat yazmak cift sayim yaratir).
  /// Bu yuzden `_sumExtraPriceTokens` (nottaki tokenlar) ile bu fonksiyon
  /// (extras'taki fiyatlar) BIRBIRINDEN AYRIK kumeleri toplar — ikisini birden
  /// eklemek cift sayim DEGILDIR.
  ///
  /// Bicim toleransi: online jsonb dizi, cevrimdisi SQLite'ta JSON metin.
  ///
  /// `amount` anahtari UYDURMA DEGIL: fis tarafindaki `_extraSatiri`
  /// (printer_service.dart) 31 Tem 2026'dan beri `e['price'] ?? e['amount']`
  /// okuyor — ayni veriyi iki yerde farkli toleransla okumamak icin birebir
  /// esleniyor. Canlida bugun `amount` kullanan kayit YOK (6 Agu taramasi);
  /// fis kodu degisirse burasi da degismeli.
  double _sumExtrasPrices(dynamic extrasRaw) {
    if (extrasRaw == null) return 0;
    dynamic veri = extrasRaw;
    if (veri is String) {
      final s = veri.trim();
      if (s.isEmpty) return 0;
      try {
        veri = jsonDecode(s);
      } catch (_) {
        return 0;
      }
    }
    if (veri is! List) return 0;
    double t = 0;
    for (final e in veri) {
      if (e is Map) t += _safeDouble(e['price'] ?? e['amount']);
    }
    return t;
  }

  bool _hasPermission(String permission) {
    if (!widget.apiService.isOnline) {
      // 8 Tem 2026: 'print_receipt' EKLENDI. Offline'da mutfak yazicisi TCP ile dogrudan basar
      // (printKitchen backend'i beklemez, printed=1 lokal set + printerService.printKitchenReceipt),
      // "Yazdir"/"Yaz+Nakit/Kart" da lokal ESC/POS. Eksikligi butonlari PASIF birakiyordu (sikayet).
      const offlineAllowed = ['open_ticket', 'add_item', 'close_ticket', 'void_ticket', 'print_receipt'];
      return offlineAllowed.contains(permission);
    }
    // permissions Map beklenir ama offline cache'te List ([]) gelebilir (crash koruması).
    final raw = widget.waiter?['permissions'];
    // 🔴 2 Agu 2026 — GUVENLIK ACIGI KAPATILDI (Mustafa: "su acigi duzelt").
    // ESKIDEN: yetki verisi Map degilse (List/null) TUM yetkilere izin veriliyordu.
    // Rutin islemler icin bu bilincli bir kolayliktı (veri gelmezse kasa kilitlenmesin),
    // AMA para/mal kaybina yol acan yetkiler icin KABUL EDILEMEZ: yetki verisi eksik gelen
    // bir kasa bedava urun dagitabilir, fiyat degistirebilirdi.
    // ARTIK: asagidaki yetkiler ASLA varsayilan olarak ACILMAZ — veri yoksa REDDEDILIR.
    const katiYetkiler = ['ikram', 'edit_prices'];
    if (raw is! Map) return !katiYetkiler.contains(permission);
    // 3 Agu 2026: ikram karari TEK KAYNAK IkramRules.yetkiVarMi (dogrudan testli).
    // Ayni katilik: Map degilse yukarida zaten RED; Map ise SADECE ikram==true kabul.
    if (permission == 'ikram') return IkramRules.yetkiVarMi(raw);
    return raw[permission] == true;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _imageCache.init();
      if (mounted) setState(() => _imageCacheReady = true);
    } catch (e) {
      print('[AddItemModal] ImageCache init hatası: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(StorageService.variantOnTapKey) ?? false;
      if (mounted) setState(() => _variantOnTap = v);
    } catch (_) {}
    // EK ödeme yöntemleri (dinamik). Hata olursa boş kalır -> built-in nakit/kart devam eder.
    try {
      final pms = await widget.apiService.getPaymentMethods();
      // Nakit/kart zaten built-in buton -> dinamik listeden çıkar (çift olmasın).
      const builtinCodes = {'cash', 'card', 'credit_card', 'nakit', 'kart'};
      final extras = pms.where((m) => !builtinCodes.contains((m['code'] ?? '').toString().toLowerCase())).toList();
      if (mounted) setState(() => _dynamicPaymentMethods = extras);
    } catch (e) {
      print('[AddItemModal] Ödeme yöntemleri yüklenemedi: $e');
    }
    await _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      // Önce cache'ten yükle (anında), sonra API'den güncelle (arka plan)
      final cachedCats = await widget.apiService.getCachedCategories();
      final cachedProds = await widget.apiService.getCachedProducts();
      if (mounted && cachedCats.isNotEmpty) {
        setState(() {
          _categories = cachedCats;
          _products = cachedProds;
          _filteredProducts = cachedProds;
          _isLoading = false;
        });
      }
      // Ticket items yükle
      await _loadTicketItems();
      // API'den taze veri (arka planda)
      widget.apiService.getCategories().then((cats) {
        if (mounted && cats.isNotEmpty) setState(() => _categories = cats);
      }).catchError((_) {});
      widget.apiService.getProducts().then((prods) {
        // Taze veri (combo_* dahil güncel) gelince _products'i tazele + AKTIF FILTREYI KORU.
        // Eski: _filteredProducts=prods -> filtre kaybolur + combo kural degisikligi ekranda ESKI
        // kalabilirdi. _filterProducts kendi setState'i ile kategori/arama uygular -> taze combo yansir.
        if (mounted && prods.isNotEmpty) { _products = prods; _filterProducts(); }
      }).catchError((_) {});
    } catch (e) {
      // Cache de yoksa API'den dene
      try {
        final categories = await widget.apiService.getCategories();
        final products = await widget.apiService.getProducts();
        if (!mounted) return;
        setState(() { _categories = categories; _products = products; _filteredProducts = products; });
        await _loadTicketItems();
      } catch (e2) {
        if (mounted) _showError('Veri yuklenemedi: $e2');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTicketItems() async {
    try {
      if (widget.tableId > 0) {
        print('[AddItemModal] _loadTicketItems: tableId=${widget.tableId}');
        final ticketData = await widget.apiService.getTableTicket(widget.tableId);
        print('[AddItemModal] ticketData: $ticketData');
        if (ticketData != null && mounted) {
          final ticket = ticketData['ticket'] as Map<String, dynamic>?;
          if (ticket != null) {
            final items = (ticket['items'] as List?) ?? [];
            print('[AddItemModal] items loaded: ${items.length}, discount: ${ticket['discount']}, discount_type: ${ticket['discount_type']}');
            setState(() {
              _ticketItems = items;
              _ticketInfo = ticket;
            });
          } else {
            // ticket null ama ticketData var — belki doğrudan ticket objesi
            if (ticketData['items'] != null) {
              final items = (ticketData['items'] as List?) ?? [];
              print('[AddItemModal] items from direct ticketData: ${items.length}');
              setState(() {
                _ticketItems = items;
              });
            } else {
              print('[AddItemModal] ticket is null, no items found');
            }
          }
        }
      } else {
        print('[AddItemModal] tableId is 0, skipping _loadTicketItems');
      }
    } catch (e) {
      print('[AddItemModal] Ticket items yüklenemedi: $e');
    }
  }

  void _filterProducts() {
    setState(() {
      _filteredProducts = _products.where((p) {
        if (_selectedCategoryId != null) {
          if (_safeInt(p['category_id']) != _selectedCategoryId) return false;
        }
        if (_searchQuery.isNotEmpty) {
          final name = (p['name'] ?? '').toString().toLowerCase();
          final desc = (p['description'] ?? '').toString().toLowerCase();
          if (!name.contains(_searchQuery) && !desc.contains(_searchQuery)) return false;
        }
        final isActive = p['is_active'] == 1 || p['is_active'] == true;
        if (!isActive) return false;
        return true;
      }).toList();
    });
  }

  void _selectCategory(int? categoryId) {
    setState(() => _selectedCategoryId = categoryId);
    _filterProducts();
  }

  void _onSearch(String query) {
    _searchQuery = query.toLowerCase().trim();
    _filterProducts();
  }

  /// Ürüne tıkla → varsayilan: direkt sepete ekle (varyant secimi sepetten "Varyant" butonu ile).
  /// COMBO: urun combo_enabled + gecerli kural ise combo secim ekrani (kurala gore N/N+G varyant sec).
  /// Ayar 'variantOnTap' ACIK + urun VARYANTLI ise: once varyant dialogu ac, secilen varyantla ekle.
  Future<void> _addProductDirectly(Map<String, dynamic> product) async {
    // GUNCEL kopya: kart eski render edilmis olabilir; _products taze combo_* tasir (arka plan sync).
    // Tiklama aninda id ile en guncel urunu al -> combo kurali GUNCEL uygulanir (eski kural kalmaz).
    final pid = _safeInt(product['id']);
    if (pid != null) {
      final fresh = _products.where((p) => _safeInt(p['id']) == pid).firstOrNull;
      if (fresh != null) product = fresh;
    }
    // COMBO SECIM (Fable denetimli): combo_enabled + gecerli kural -> combo secim ekrani.
    // Karar: extra hediye BACKEND uretir (panel/web birebir) — POS N odenen kalem ekler, hediyeyi
    // close handler'i giftLines ile olusturur. Boylece cifte-hediye/reload sorunu YOK.
    if (_comboIsActive(product)) {
      // 31 Tem 2026 (Mustafa) — CAKISMA COZUMU: bir urunde HEM combo HEM "POS varyant coklu
      // secim" acikken eskiden combo KOSULSUZ kazaniyor, varyant yoluna hic gelinmiyordu
      // (iki ozellik birbirini eziyordu). Artik ikisi de aktifse ONCE kucuk bir secim ekrani
      // cikar: "Varyant" mi "Combo" mu. Tek ozellik aciksa ekran CIKMAZ — eski akis aynen.
      final _varyantlar = (product['variants'] is List) ? product['variants'] as List : const [];

      // 1 Agu 2026 (Mustafa: "varyant ve combo icinde de gecerli olmali o ozellik") —
      // "SORAYIM MI?" ile "NASIL SORAYIM?" AYRI iki sorudur:
      //   SORAYIM MI  -> urun ZORUNLU isaretliyse EVET; degilse GLOBAL toggle
      //                  (Yazici Ayarlari > POS Davranisi) ne diyorsa.
      //   NASIL       -> combo+coklu ikisi de aciksa secim ekrani, biri aciksa o ekran.
      // Onceki halimde "coklu secim" acik olmak ekrani ZORLA aciyordu; bu yanlisti —
      // coklu secim bir BICIM ayaridir, "sor" emri degil. Toggle'in islevsiz gorunmesinin
      // sebebi buydu.
      // ⚠️ combo_pos_selection_required VARSAYILANI true -> combo urunlerde davranis
      //    ESKISIYLE AYNI kalir (her zaman sorar). Regresyon yok.
      final _comboZorunlu = ComboCalculator.posSecimZorunlu(product); // TEK KAYNAK
      if (!_comboZorunlu && !_variantOnTap) {
        // Ne urun zorunlu kiliyor ne de global tercih "sor" diyor -> DOGRUDAN EKLE
        _addProductWithPrice(product, product['name']?.toString() ?? '',
          _restaurantBasePrice(product));
        return;
      }
      // 1 Agu 2026 — TEK PENCERE, SEKMELI. Combo urununde varyant ve/veya icerik de
      // varsa hepsi AYNI pencerede sekme olur (Varyant / Ekle-Cikar / Combo).
      // Hicbiri yoksa (sadece combo) dogrudan combo ekrani acilir — gereksiz sekme olmaz.
      final _icerikVar = _urunIcerikleri(product).isNotEmpty;
      final _varyantVar = _varyantlar.isNotEmpty;
      if (_varyantVar || _icerikVar) {
        // 1 Agu 2026 (Mustafa: "combo urunu de oraya ekle... ekstra varyant butonu combo
        // butonu da olmaz") — ARA SECIM EKRANI TAMAMEN KALKTI. Tek pencere acilir;
        // ustte hangi ozellik doluysa o sekme cikar: Varyant / Ekle-Cikar / Combo.
        // Combo sekmesinden "devam" denirse pencere kapanir ve combo secim ekrani acilir.
        await _openIcerikVaryantDialog(product, _varyantlar, mod: 'hepsi');
        return;
      }
      // 31 Tem 2026 — SECIM ZORUNLU DEGILSE ekran ACILMAZ, urun DOGRUDAN sepete eklenir.
      // Panel > combo pop > "Sadece POS" > "Secim zorunlu" kapatilinca gelir
      // (panel_products.combo_pos_selection_required=false). Varyant dialogu da ACILMAZ
      // (Mustafa: "zorunlu secili degilse direkt urun eklenecek, varyant secenegi cikmayacak").
      // Fiyat: ana kartin restoran fiyati (_restaurantBasePrice) — varyantsiz ekleme kurali.
      // ⚠️ SADECE POS. Web ve telefon bu alani OKUMAZ, orada secim her zaman zorunlu.
      // 31 Tem 2026: cevrimdisi cache 0/1 doner -> hem false hem 0 kabul edilmeli,
      // yoksa internet gidince "opsiyonel" ayari yok sayilip dialog yine acilirdi.
      if (!ComboCalculator.posSecimZorunlu(product)) { // TEK KAYNAK
        _addProductWithPrice(product, product['name']?.toString() ?? '',
          _restaurantBasePrice(product));
        return;
      }
      await _openComboSelectionDialog(product);
      return;
    }
    final variants = (product['variants'] is List) ? product['variants'] as List : const [];
    // 1 Agu 2026 — ICERIK / GRUPLU VARYANT EKRANI.
    // Urunde icerik (cikarilabilir/eklenebilir) VEYA gruplu varyant varsa web'deki gibi
    // bolumlu ekran acilir. IKISI DE YOKSA asagidaki eski akis AYNEN calisir.
    // "Sorayim mi" kurali burada da gecerli: zorunlu bir grup varsa HER ZAMAN sorar,
    // yoksa global toggle'a uyar (Yazici Ayarlari > POS Davranisi).
    if (variants.isNotEmpty || _urunIcerikleri(product).isNotEmpty) {
      // 1 Agu 2026 — "SORAYIM MI" / "NASIL SORAYIM" ayrimi.
      //   SORAYIM MI : urunde ZORUNLU bir grup varsa VEYA variants_required_pos aciksa EVET;
      //                degilse GLOBAL toggle (Yazici Ayarlari > POS Davranisi).
      //   NASIL      : _varyantEkraniAc karar verir (icerik/gruplu > coklu > tekli).
      // ⚠️ "coklu secim" bir BICIM ayaridir, "sor" emri DEGIL (31 Tem'de bunu karistirmistim,
      //    global toggle islevsiz kalmisti).
      final _zorunluGrup = variants.any((v) =>
          v is Map &&
          (v['group_name'] ?? '').toString().trim().isNotEmpty &&
          v['group_required'] == true);
      final _sorulacak = _zorunluGrup || _posVaryantZorunlu(product) || _variantOnTap;
      if (_sorulacak) {
        await _varyantEkraniAc(product, variants);
        return;
      }
    }
    _addProductWithPrice(product, product['name']?.toString() ?? '',
      _restaurantBasePrice(product));
  }

  /// Combo kurali AKTIF mi: combo_enabled + gecerli indirim (hediye VEYA yuzde VEYA sabit).
  /// combo_enabled ama indirim tanimsizsa (calculator eligible=false) combo ekrani ACILMAZ.
  /// Combo AKTIF mi: combo_enabled=true YETER. Indirim tipi (hediye/yuzde/sabit) ZORUNLU DEGIL —
  /// isletme indirimi urun FIYATINA gomebilir ("2 al" combo urun zaten indirimli fiyatli girilmis).
  /// O durumda combo ekrani yine acilir (N urun sec), ekstra indirim comboCalculator'dan GELMEZ
  /// (eligible=false, dogru — indirim fiyatta). Indirim tipi VARSA calcCartCombos ayrica duser.
  // 1 Agu 2026 — TEK KAYNAK: ComboCalculator. Eskiden burada `== true || == 1`
  // yaziyordu ve '1'/'true' METNINI kaciriyordu (hesaplayici ise kabul ediyordu)
  // -> ayni urun bir yerde combo, digerinde degil sayilabiliyordu.
  bool _comboIsActive(Map<String, dynamic> product) =>
      ComboCalculator.comboAktif(product);

  /// Combo kural ozeti: N (secilecek), G (hediye), mod, repeat, stepPerSet (bir set icin secilecek adet),
  /// label. within/percent/amount -> N sec; extra -> N+G sec (G'si hediye, BACKEND uretir).
  Map<String, dynamic> _comboTargetFor(Map<String, dynamic> product) {
    final n = (_safeInt(product['combo_required_qty']) ?? 2).clamp(1, 10);
    final g = (_safeInt(product['combo_gift_qty']) ?? 0);
    final giftMode = product['combo_gift_mode'] == 'extra' ? 'extra' : 'within';
    // 1 Agu 2026 — TEK KAYNAK (SQLite INTEGER tuzagi burada cozulur).
    final repeat = ComboCalculator.katlanmaAcik(product);
    final pct = _safeDouble(product['combo_discount_percent']);
    final amt = _safeDouble(product['combo_discount_amount']);
    // Bir set icin secilecek adet: extra -> N+G (G hediye slotu), digerleri -> N.
    final stepPerSet = (g > 0 && giftMode == 'extra') ? n + g : n;
    String label;
    if (g > 0) {
      label = giftMode == 'extra' ? '$n al $g hediye' : '$n al ${(n - g) < 1 ? 1 : (n - g)} öde';
    } else if (pct > 0) {
      label = '%${pct % 1 == 0 ? pct.toInt() : pct} indirim';
    } else if (amt > 0) {
      label = '₺${amt % 1 == 0 ? amt.toInt() : amt} indirim';
    } else {
      // Indirim tipi yok — indirim urun FIYATINA gomulu. Sadece N urun sec (ekstra indirim yok).
      label = '$n ürün seç';
    }
    return {'N': n, 'G': g, 'giftMode': giftMode, 'repeat': repeat, 'stepPerSet': stepPerSet, 'label': label};
  }

  /// Ayar ACIK iken: urune tiklaninca varyant sec, secilen varyantla sepete EKLE (mevcut item'i
  /// guncellemez — yeni kalem ekler). Ekleme sonrasi mevcut _addProductWithPrice yolunu kullanir
  /// (fiyat = baz + varyant modifier), varyant adi note olarak yazilir.
  /// Urunde HEM combo HEM POS coklu varyant acikken hangisiyle devam edilecegini sorar.
  /// Doner: 'varyant' | 'combo' | null (iptal). Sadece IKISI DE aktifken cagrilir.
  /// 1 Agu 2026 — DINAMIK SECIM EKRANI (Mustafa: "hepsi dolu oldugunda pop penceresinde
  /// secenek ciksin COMBO - VARYANT - EKLE/CIKAR").
  /// Sadece GECERLI olan secenekler cizilir: 2 tanesi varsa 2 kart, 3'u varsa 3 kart.
  /// Doner: 'combo' | 'varyant' | 'icerik' | null (iptal).
  Future<String?> _openAkisSecimDialog(Map<String, dynamic> product,
      {bool comboVar = true, bool varyantVar = true, bool icerikVar = false}) async {
    final productName = product['name']?.toString() ?? '';
    final t = _comboTargetFor(product);
    final comboLabel = (t['label'] as String?)?.trim();
    final varyantSayisi = (product['variants'] is List) ? (product['variants'] as List).length : 0;
    final _icerikSayisi = _urunIcerikleri(product).length;

    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: (varyantVar ? 1 : 0) + (icerikVar ? 1 : 0) + (comboVar ? 1 : 0) >= 3 ? 580 : 420,
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text(productName,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx, null)),
            ]),
            Text('Nasıl eklensin?',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 16),
            Row(children: [
              if (varyantVar) ...[
                Expanded(
                  child: _akisSecimKarti(
                    ctx: ctx,
                    deger: 'varyant',
                    ikon: Icons.checklist_rounded,
                    baslik: 'Varyant',
                    altYazi: '$varyantSayisi seçenek\nfiyatlar toplanır',
                    renk: Colors.orange[700]!,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (icerikVar) ...[
                Expanded(
                  child: _akisSecimKarti(
                    ctx: ctx,
                    deger: 'icerik',
                    ikon: Icons.tune_rounded,
                    baslik: 'Ekle / Çıkar',
                    altYazi: '$_icerikSayisi malzeme\nekle veya çıkar',
                    renk: Colors.blue[700]!,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (comboVar)
                Expanded(
                  child: _akisSecimKarti(
                    ctx: ctx,
                    deger: 'combo',
                    ikon: Icons.card_giftcard_rounded,
                    baslik: 'Combo',
                    altYazi: (comboLabel != null && comboLabel.isNotEmpty)
                        ? comboLabel
                        : 'paket seçimi',
                    renk: Colors.green[700]!,
                  ),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _akisSecimKarti({
    required BuildContext ctx,
    required String deger,
    required IconData ikon,
    required String baslik,
    required String altYazi,
    required Color renk,
  }) {
    return Material(
      color: renk.withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(ctx, deger),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: renk.withOpacity(0.45), width: 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(ikon, size: 30, color: renk),
            const SizedBox(height: 8),
            Text(baslik,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: renk)),
            const SizedBox(height: 4),
            Text(altYazi,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Colors.grey[700], height: 1.25)),
          ]),
        ),
      ),
    );
  }

  /// Coklu varyant secimi: birden fazla varyant birlikte secilir, TEK adisyon kalemi eklenir.
  /// Fiyat = ana restoran fiyati + Secilen varyant farklari (web ile BIREBIR ayni kural).
  /// Secimler `extras` alaninda yapilandirilmis gider (backend tickets.js addItem ZATEN kabul
  /// ediyor ve getByTable geri donduruyor) -> adisyon/fis urun adinin ALTINDA satir satir gosterir.
  /// Urun adi TEMIZ kalir (web deseni) — isim icine parantez YAZILMAZ.
  /// [guncellenecekKalem] verilirse YENI KALEM EKLEMEZ, o kalemi GUNCELLER.
  /// 1 Agu 2026 (Mustafa: "bu pencere ayni koddan beslenmeli, sen ayri tasarim mi yaptin") —
  /// Varyant BUTONU (adisyondaki secili kaleme) ayri bir dialog kullaniyordu ve yeni POS
  /// ayarlarini (coklu secim / secim zorunlu) HIC OKUMUYORDU. Artik iki giris noktasi da
  /// BU fonksiyondan besleniyor; tek kod, tek davranis.
  // ==========================================================================
  // 3 Agu 2026 (Mustafa: "hazir varyant popda not ekleme alani da koysana, tek
  // yerde cozelim isi. menude yine kalsin ama. AYNI KAPIYI kullansinlar.")
  //
  // TEK KAPI: not metni her yerde ayni kanaldan gider —
  //   • yeni kalem  -> _addProductWithPrice(variantNote:) -> addTicketItem(notes:)
  //   • mevcut kalem-> updateTicketItem(notes:)
  // Hazir notlar da menudeki "Not Ekle" ile AYNI kaynaktan: apiService.getProductNotes()
  // (cevrimdisinda cached_lookups 'product_notes' fallback'i var).
  // Menudeki buton KALDIRILMADI — Mustafa "menude yine kalsin" dedi.
  // ==========================================================================

  /// Iki varyant penceresinin de kullandigi not alani. `ctrl` cagiranin
  /// controller'i; hazir not cipine basmak metne ekler/cikarir.
  Widget _notAlani(TextEditingController ctrl, void Function(void Function()) setSt) {
    // Cache bossa arka planda cek — pencere BEKLEMEZ, cipler gelince belirir.
    _notlariYukle(setSt);
    final List hazirNotlar = _hazirNotCache;
    // Metinde hazir notun secili olup olmadigini, virgullu listeyi parcalayarak anlar
    // (serbest metin kullanicinin kendi yazdigi seydir, dokunulmaz).
    List<String> parcala() => ctrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    void degistir(String not) {
      final list = parcala();
      final i = list.indexWhere((e) => e.toLowerCase() == not.toLowerCase());
      if (i >= 0) {
        list.removeAt(i);
      } else {
        list.add(not);
      }
      final yeni = list.join(', ');
      setSt(() {
        ctrl.text = yeni;
        ctrl.selection = TextSelection.collapsed(offset: yeni.length);
      });
    }

    final secilenler = parcala().map((e) => e.toLowerCase()).toSet();

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.sticky_note_2_outlined, size: 15, color: Colors.grey[600]),
        const SizedBox(width: 5),
        Text('Not', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[700])),
      ]),
      const SizedBox(height: 6),
      if (hazirNotlar.isNotEmpty) ...[
        Wrap(spacing: 5, runSpacing: 5, children: [
          for (final n in hazirNotlar)
            if ((n['note']?.toString() ?? '').trim().isNotEmpty)
              _notCipi(n['note'].toString().trim(),
                  secilenler.contains(n['note'].toString().trim().toLowerCase()),
                  () => degistir(n['note'].toString().trim())),
        ]),
        const SizedBox(height: 6),
      ],
      TextField(
        controller: ctrl,
        style: const TextStyle(fontSize: 13),
        minLines: 1,
        maxLines: 2,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Serbest not (az pisisin, sogansiz...)',
          hintStyle: TextStyle(fontSize: 12, color: Colors.grey[500]),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ]);
  }

  Widget _notCipi(String etiket, bool secili, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: secili ? Colors.indigo[600] : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: secili ? Colors.indigo[700]! : Colors.grey[300]!),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (secili) ...[const Icon(Icons.check, size: 12, color: Colors.white), const SizedBox(width: 3)],
          Text(etiket,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: secili ? Colors.white : Colors.grey[800])),
        ]),
      ),
    );
  }

  // 🔴 3 Agu 2026 PERFORMANS (Mustafa: "flutter biraz yavasladi, ust uste urun
  // ekledim butona hizli bastim geriden geldi") — SEBEP BUYDU: hazir notlar
  // varyant penceresi acilmadan ONCE await ediliyordu. Olculen: /product-notes
  // ~250 ms; yani HER varyant acilisinda 250 ms bekleme, ust uste eklemede birikti.
  //
  // COZUM: agdan cekme SICAK YOLDAN CIKTI.
  //  • Notlar bir kez cekilip _hazirNotCache'te tutulur (her acilista tekrar YOK).
  //  • Pencere ANINDA acilir; cache bossa yukleme ARKA PLANDA baslar ve veri
  //    gelince pencerenin kendi setSt'i ile cipler belirir.
  //  • Cevrimdisinda getProductNotes zaten SQLite cache'ine duser (yine engellemez).
  List _hazirNotCache = const [];
  bool _notlarYukleniyor = false;
  // 3 Agu 2026 (dogrulama denetimi B3): ACIK pencerenin tazeleyicisi. Yukleme
  // pencereden ONCE basladigi icin dialog'un setSt'i kaydedilemiyordu; parent
  // setState ayri route'taki StatefulBuilder'i CIZMEZ -> cipler ilk acilista
  // ancak kullanici bir seye dokununca beliriyordu. Artik son acik pencerenin
  // tazeleyicisi burada tutulur ve veri gelince o cagrilir.
  void Function(void Function())? _notYenileyici;

  /// Engellemeyen yukleyici. `setSt` verilirse (acik pencere) veri gelince tazeler.
  void _notlariYukle([void Function(void Function())? setSt]) {
    // Yukleme SURSE BILE en son pencerenin tazeleyicisini kaydet (B3).
    if (setSt != null) _notYenileyici = setSt;
    if (_hazirNotCache.isNotEmpty || _notlarYukleniyor) return;
    _notlarYukleniyor = true;
    widget.apiService.getProductNotes().then((liste) {
      _hazirNotCache = liste;
      _notlarYukleniyor = false;
      if (!mounted) return;
      final yenile = _notYenileyici ?? setSt;
      if (yenile != null) {
        // Pencere bu arada kapandiysa setSt disposed element'e dokunabilir —
        // yut, cache zaten dolu, bir sonraki acilista aninda gorunur.
        try { yenile(() {}); } catch (_) { setState(() {}); }
      } else {
        setState(() {});
      }
    }).catchError((_) {
      // 3 Agu 2026 (dogrulama denetimi B2): burada DEGER DONULMEZ. Zincir Future<void>;
      // List donmek hata yolunda TypeError uretip "unhandled async error" gurultusu
      // yapiyordu (analyzer: invalid_return_type_for_catch_error).
      _notlarYukleniyor = false;
    });
  }

  Future<void> _openMultiVariantDialog(Map<String, dynamic> product, List variants,
      {Map<String, dynamic>? guncellenecekKalem}) async {
    final basePrice = _restaurantBasePrice(product);
    final productName = product['name']?.toString() ?? '';
    final zorunlu = _posVaryantZorunlu(product);
    final secili = <Map<String, dynamic>>[];

    // 🔴 3 Agu 2026 (denetim bulgusu) — GUNCELLEME MODUNDA ON-SECIM.
    // Pencere mevcut kalemi duzenlemek icin acildiginda secimler BOS geliyordu.
    // Zorunlu degilse "Ekle" bos secimle AKTIF oldugu icin, kullanici hicbir seye
    // dokunmadan Ekle'ye basinca extras=[] + fiyat=baz gonderiliyor ve kalemin
    // VARYANTI, FIYAT FARKI ve nottaki varyant adi SESSIZCE SILINIYORDU.
    // Artik kalemin mevcut secimleri (extras) varyant listesiyle ADIYLA eslestirilip
    // isaretli gelir; kullanici dokunmazsa hicbir sey degismez.
    if (guncellenecekKalem != null) {
      dynamic _ex = guncellenecekKalem['extras'];
      // extras iki sekilde gelir: backend jsonb -> List, cevrimdisi mirror -> JSON METIN.
      if (_ex is String && _ex.trim().isNotEmpty) {
        try { _ex = jsonDecode(_ex); } catch (_) { _ex = null; }
      }
      if (_ex is List) {
        for (final e in _ex) {
          if (e is! Map) continue;
          final ad = (e['name']?.toString() ?? '').trim().toLowerCase();
          if (ad.isEmpty || ad.startsWith('-')) continue; // '-' onekli = CIKARILAN malzeme
          for (final raw in variants) {
            if (raw is! Map) continue;
            final v = Map<String, dynamic>.from(raw);
            if ((v['name']?.toString() ?? '').trim().toLowerCase() != ad) continue;
            final zatenVar = secili.any((x) => x['id'] == v['id'] && x['name'] == v['name']);
            if (!zatenVar) secili.add(v);
            break;
          }
        }
      }
    }

    // 3 Agu 2026 — not alani (menudeki "Not Ekle" ile AYNI kaynak/kanal).
    final notCtrl = TextEditingController(
        text: guncellenecekKalem == null ? '' : _mevcutSerbestNot(guncellenecekKalem));
    _notlariYukle(); // engellemez: pencere ANINDA acilir

    final onay = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        final toplamFark = secili.fold<double>(0, (t, v) => t + _variantModifier(v));
        final toplam = basePrice + toplamFark;
        final eklenebilir = zorunlu ? secili.isNotEmpty : true;
        final tiles = <Widget>[
          // 1 Agu 2026 (Mustafa: "secim yapmadan ekleyebilecegim ana urun yok?") —
          // ZORUNLU DEGILSE ana urunun KENDISI de secilebilir olmali. Tekli varyant
          // ekraninda "1 Porsiyon" kutucugu vardi, coklu ekranda eksikti: buton
          // "secim yapmadan da eklenebilir" diyor ama tiklanacak bir sey yoktu.
          // Bu kutucuk = SIFIR secimle onayla (fiyat = ana restoran fiyati).
          // Zorunlu ise GOSTERILMEZ — orada zaten en az bir secim sart.
          if (!zorunlu)
              // 1 Agu 2026 (Mustafa: "1 porsiyon yazmasi hatali, ana urunun adi yazmali,
              // web sitesinde de yanlis anlasiliyor") — bu kutucuk ANA URUNUN KENDISI;
              // varyantsiz, ana fiyattan. Sabit "1 Porsiyon" yerine urun adi yazilir.
            _variantOptionTile(
              label: productName,
              price: basePrice,
              selected: secili.isEmpty,
              onTap: () {
                secili.clear();
                Navigator.pop(ctx, true);
              },
              color: Colors.blue[600]!,
            ),
          ...variants.map((raw) {
          final v = Map<String, dynamic>.from(raw as Map);
          final mod = _variantModifier(v);
          final vname = v['name']?.toString() ?? '';
          final isSecili = secili.any((x) => x['id'] == v['id'] && x['name'] == v['name']);
          return _variantOptionTile(
            label: vname,
            price: basePrice + mod,
            modifier: mod,
            selected: isSecili,
            onTap: () => setSt(() {
              if (isSecili) {
                secili.removeWhere((x) => x['id'] == v['id'] && x['name'] == v['name']);
              } else {
                secili.add(v);
              }
            }),
            color: isSecili ? Colors.green[700]! : Colors.orange[600]!,
          );
          }),
        ];

        return _buildResponsiveVariantDialog(
          ctx: ctx,
          title: productName,
          tiles: tiles,
          altBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (secili.isNotEmpty) ...[
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (int i = 0; i < secili.length; i++)
                  InputChip(
                    label: Text(secili[i]['name']?.toString() ?? '', style: const TextStyle(fontSize: 12)),
                    onDeleted: () => setSt(() => secili.removeAt(i)),
                    deleteIcon: const Icon(Icons.close, size: 15),
                  ),
              ]),
              const SizedBox(height: 8),
            ],
            _notAlani(notCtrl, setSt),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(
                  secili.isEmpty
                      ? (zorunlu
                          ? 'En az bir seçim yapın'
                          : '"1 Porsiyon" ile seçimsiz de eklenebilir')
                      : '${secili.length} seçim  •  ${toplam.toStringAsFixed(2)} TL',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: secili.isEmpty ? Colors.grey[600] : Colors.green[800],
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: eklenebilir ? () => Navigator.pop(ctx, true) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: eklenebilir ? Colors.green[700] : Colors.grey[300],
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                ),
                child: Text(secili.isEmpty ? 'Ekle' : 'Ekle (${toplam.toStringAsFixed(2)} TL)'),
              ),
            ]),
          ]),
        );
      }),
    );

    if (onay != true) return; // iptal
    final toplamFark = secili.fold<double>(0, (t, v) => t + _variantModifier(v));

    // GUNCELLEME MODU: mevcut kalemin fiyatini/secimlerini degistir, YENI KALEM EKLEME.
    if (guncellenecekKalem != null) {
      final gItemId = _safeInt(guncellenecekKalem['id']);
      if (gItemId == null) return;
      final gExtras = secili
          .map((v) => {'name': v['name']?.toString() ?? '', 'price': _variantModifier(v)})
          .toList();
      // 3 Agu 2026 — varyant adlari + kullanicinin serbest notu AYNI alanda.
      final gNotlar = _notuBirlestir(
          secili.map((v) => v['name']?.toString() ?? '').toList(), notCtrl.text);
      // 🔴 6 Agu 2026 — NOTTAKI FIYAT TOKEN'I FIYATTAN DUSUYORDU.
      // `_notuBirlestir` kullanicinin serbest notunu AYNEN korur; o notta eski
      // genel-varyant doneminden kalma "(+10TL)" gibi tokenlar olabilir (canlida
      // 6.512 not tasiyor). Eskiden burada SADECE `basePrice + toplamFark`
      // yaziliyordu -> not hala "+10TL" derken fiyattan 10 TL DUSUYORDU
      // (iz birakmayan eksik tahsilat). Tekli varyant yolu (asagida ~2098)
      // bunu `existingExtrasTotal` ile ZATEN ekliyordu; iki yol tutarsizdi.
      // Yeni secimlerin farki `toplamFark`ta, nottaki tokenlar ayrik kume.
      final gNotTokenlari = _sumExtraPriceTokens(gNotlar ?? '');
      try {
        final res = await widget.apiService.updateTicketItem(
          ticketId: widget.ticketId,
          itemId: gItemId,
          // Not alanina fiyat YAZILMAZ (backend unit_price safety-net'i notlardaki
          // '+NTL' desenine bakiyor — cift sayim riski). Secimler extras'ta.
          notes: gNotlar,
          unitPrice: basePrice + toplamFark + gNotTokenlari,
          waiterId: widget.waiterId,
          extras: gExtras,
        );
        if (res['success'] == true) {
          await _loadTicketItems();
        } else {
          _showError(res['error']?.toString() ?? 'Varyant uygulanamadi');
        }
      } catch (e) {
        _showError('Varyant hatasi: $e');
      }
      return;
    }

    // extras: [{name, price}] — backend JSON.stringify ile panel_pos_ticket_items.extras'a yazar.
    // DIKKAT: notes'a "+50TL" YAZILMAZ; backend'in unit_price safety-net'i notes'taki fiyat
    // desenine bakiyor, buraya fiyat yazarsak cift sayim riski dogar (tickets.js:199-236).
    final extras = secili
        .map((v) => {'name': v['name']?.toString() ?? '', 'price': _variantModifier(v)})
        .toList();
    final _not = notCtrl.text.trim();
    await _addProductWithPrice(product, productName, basePrice + toplamFark,
        extras: extras, variantNote: _not.isEmpty ? null : _not);
  }

  // ============================================================================
  // 1 Agu 2026 — URUN ICERIKLERI + VARYANT SECIM GRUPLARI
  // Mustafa: "bizim aslinda icerikler kismini da eklememiz lazim. onu webde
  // gosteriyoruz ama POS'ta gostermiyoruz. keza coklu secimi de?"
  //
  // Backend (panel-direct/products.js, 1 Agu) artik gonderiyor:
  //   ingredients[] : {id, name, role:'removable'|'addon', is_default, price}
  //   variants[]    : + group_name / group_required / group_multi
  //
  // 🔴 GERI UYUMLULUK: ikisi de YOKSA (bos dizi / group_name null) hicbir sey degismez —
  //    urun eski akisla eklenir, ekranda ek bolum CIZILMEZ.
  // ============================================================================

  /// Urunun icerikleri var mi (cikarilabilir veya eklenebilir)
  List<Map<String, dynamic>> _urunIcerikleri(Map<String, dynamic> product) {
    final raw = product['ingredients'];
    List list;
    if (raw is List) {
      list = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try { final d = jsonDecode(raw); list = d is List ? d : const []; } catch (_) { return const []; }
    } else {
      return const [];
    }
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['name'] ?? '').toString().trim().isNotEmpty)
        .toList();
  }

  /// Varyantlari SECIM GRUPLARINA ayirir. group_name olmayanlar '' anahtarinda toplanir
  /// (duz liste = eski davranis). Sira korunur.
  Map<String, List<Map<String, dynamic>>> _varyantGruplari(List variants) {
    final gruplar = <String, List<Map<String, dynamic>>>{};
    for (final raw in variants) {
      if (raw is! Map) continue;
      final v = Map<String, dynamic>.from(raw);
      final g = (v['group_name'] ?? '').toString().trim();
      (gruplar[g] ??= []).add(v);
    }
    return gruplar;
  }

  /// İÇERİK + GRUPLU VARYANT SEÇİM EKRANI (1 Agu 2026)
  /// Web'deki urun modalinin POS karsiligi. Uc bolum:
  ///   1. Gruplu varyantlar — her grup ayri baslik, group_multi ? cok secim : tek secim
  ///   2. Cikarilabilir icerikler (role='removable') — isaretlenirse CIKARILIR
  ///   3. Eklenebilir icerikler (role='addon')     — isaretlenirse EKLENIR
  /// Fiyat = ana fiyat + Σ(varyant farki) + Σ(eklenen) + Σ(cikarilan fiyat etkisi)
  /// Secimler `extras` alaninda yapilandirilmis gider -> adisyon/fis alt satirlarinda gorunur.
  /// [mod] hangi bolumlerin cizilecegini belirler (1 Agu 2026, Mustafa: "eklenebilir
  /// cikartilabilir varyanti eziyor"):
  ///   'hepsi'   -> varyant gruplari + icerikler (tek ozellik varsa bu yeterli)
  ///   'varyant' -> SADECE varyant gruplari (icerikler ayri ekranda)
  ///   'icerik'  -> SADECE ekle/cikar (varyantlar ayri ekranda)
  Future<void> _openIcerikVaryantDialog(Map<String, dynamic> product, List variants,
      {String mod = 'hepsi'}) async {
    final basePrice = _restaurantBasePrice(product);
    final productName = product['name']?.toString() ?? '';
    final _icerikGoster = mod == 'hepsi' || mod == 'icerik';
    final _varyantGoster = mod == 'hepsi' || mod == 'varyant';
    final icerikler = _icerikGoster ? _urunIcerikleri(product) : <Map<String, dynamic>>[];
    final cikarilabilir = icerikler.where((i) => i['role'] == 'removable').toList();
    final eklenebilir = icerikler.where((i) => i['role'] == 'addon').toList();
    final gruplar = _varyantGoster
        ? _varyantGruplari(variants)
        : <String, List<Map<String, dynamic>>>{};

    // 1 Agu 2026 (Mustafa: "ekle cikari da mevcut pencerede TAB olarak eklesene,
    // bosa tik yapmasin sonucta ayni urune ait") — ayri secim ekrani yerine AYNI pencerede
    // sekme. Secimler sekme degisince KAYBOLMAZ (ayni StatefulBuilder durumu).
    // 3 Agu 2026 — not alani (AYNI kapi: _notAlani + variantNote kanali).
    final notCtrl = TextEditingController();
    _notlariYukle(); // engellemez: pencere ANINDA acilir

    int sekme = 0; // 0 = Varyant, 1 = Ekle/Cikar, 2 = Combo
    // 1 Agu 2026: Combo sekmesinden cikilirsa bu bayrak dolar ve pencere kapandiktan
    // SONRA combo secim ekrani acilir (combo'nun kendi N-secim/paket-bolme mantigi var).
    bool comboyaGec = false;

    // Secim durumu
    final secVaryant = <String, List<Map<String, dynamic>>>{}; // grup -> secilenler
    final cikarilan = <Map<String, dynamic>>[];
    final eklenen = <Map<String, dynamic>>[];

    double toplamHesapla() {
      double t = basePrice;
      secVaryant.forEach((_, list) {
        for (final v in list) t += _variantModifier(v);
      });
      for (final c in cikarilan) t += _icerikFiyati(c);   // genelde negatif
      for (final e in eklenen) t += _icerikFiyati(e);
      return t;
    }

    bool zorunluTamam() {
      for (final g in gruplar.keys) {
        if (g.isEmpty) continue;
        final ilk = gruplar[g]!.first;
        if (ilk['group_required'] == true && (secVaryant[g]?.isEmpty ?? true)) return false;
      }
      return true;
    }

    final onay = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        final toplam = toplamHesapla();
        // 1 Agu 2026 (Mustafa: "coklu varyant secimi sagda, solda normal varyantlar
        // yan urun 1 yan urun 2 yazan") —
        //   SOL : GRUPLU varyantlar (Yan urun secimi 1/2, Acili-Acisiz ...)
        //   SAG : COKLU/duz varyant secimi
        //   ALT : ekle/cikar malzemeler — tam genislik, iki sutunun ALTINDA
        // Tek taraf doluysa TEK sutun cizilir (bos yarim ekran olmasin).
        final solBolumler = <Widget>[];   // gruplu varyantlar
        final sagBolumler = <Widget>[];   // coklu/duz varyant
        final altBolumler = <Widget>[];   // icerikler (ekle/cikar)

        Widget baslik(String metin, {String? alt}) => Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Row(children: [
                Text(metin,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                if (alt != null) ...[
                  const SizedBox(width: 6),
                  Text(alt, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ],
              ]),
            );

        // ---- 1) GRUPLU VARYANTLAR ----
        gruplar.forEach((grupAdi, secenekler) {
          if (grupAdi.isEmpty) return; // duz varyantlar asagida
          final ilk = secenekler.first;
          final coklu = ilk['group_multi'] == true;
          final zorunlu = ilk['group_required'] == true;
          solBolumler.add(baslik(grupAdi,
              alt: (zorunlu ? 'zorunlu' : 'opsiyonel') + (coklu ? ' · çoklu' : '')));
          solBolumler.add(Wrap(spacing: 8, runSpacing: 8, children: secenekler.map((v) {
            final secili = (secVaryant[grupAdi] ?? []).any((x) => x['id'] == v['id']);
            final mod = _variantModifier(v);
            return SizedBox(
              width: _variantTileWidth,
              child: _variantOptionTile(
                label: v['name']?.toString() ?? '',
                price: basePrice + mod,
                modifier: mod,
                selected: secili,
                onTap: () => setSt(() {
                  final liste = secVaryant[grupAdi] ??= [];
                  if (secili) {
                    liste.removeWhere((x) => x['id'] == v['id']);
                  } else {
                    if (!coklu) liste.clear(); // tekli grup: oncekini degistir
                    liste.add(v);
                  }
                }),
                color: secili ? Colors.green[700]! : Colors.orange[600]!,
              ),
            );
          }).toList()));
        });

        // ---- 1b) GRUPSUZ (DUZ) VARYANTLAR ----
        // 🔴 1 Agu 2026 (Mustafa: "coklu secim yok, onu eklememissin") — ILK YAZIMDA
        // `if (grupAdi.isEmpty) return;` ile grupsuz varyantlar ATLANIYORDU ve "duz varyantlar
        // asagida" diye not dusulmustu ama ASAGIDA BOYLE BIR BOLUM YOKTU. Sonuc: gruplu +
        // duz varyanti olan urunde DUZ OLANLAR KAYBOLUYORDU, coklu secim de hic devreye
        // girmiyordu. Artik bu bolum ciziliyor ve variants_allow_multiple_pos'a UYUYOR:
        //   coklu ACIK  -> birden fazla secilebilir (fiyatlar toplanir)
        //   coklu KAPALI-> tek secim (yeni secim oncekini degistirir)
        if (_varyantGoster && (gruplar[''] ?? const []).isNotEmpty) {
          final duzler = gruplar['']!;
          final cokluDuz = _posCokluVaryant(product);
          sagBolumler.add(baslik('Varyant', alt: cokluDuz ? 'çoklu seçilebilir' : 'tek seçim'));
          sagBolumler.add(Wrap(spacing: 8, runSpacing: 8, children: duzler.map((v) {
            final secili = (secVaryant[''] ?? []).any((x) => x['id'] == v['id']);
            final mod = _variantModifier(v);
            return SizedBox(
              width: _variantTileWidth,
              child: _variantOptionTile(
                label: v['name']?.toString() ?? '',
                price: basePrice + mod,
                modifier: mod,
                selected: secili,
                onTap: () => setSt(() {
                  final liste = secVaryant[''] ??= [];
                  if (secili) {
                    liste.removeWhere((x) => x['id'] == v['id']);
                  } else {
                    if (!cokluDuz) liste.clear();
                    liste.add(v);
                  }
                }),
                color: secili ? Colors.green[700]! : Colors.orange[600]!,
              ),
            );
          }).toList()));
        }

        // ---- 2) CIKARILABILIR ICERIKLER ----
        if (cikarilabilir.isNotEmpty) {
          altBolumler.add(baslik('Çıkartılacak Malzemeler', alt: 'işaretlenen çıkarılır'));
          altBolumler.add(Wrap(spacing: 8, runSpacing: 8, children: cikarilabilir.map((i) {
            final secili = cikarilan.any((x) => x['id'] == i['id']);
            final f = _icerikFiyati(i);
            return _icerikCipi(
              ad: i['name']?.toString() ?? '',
              fiyat: f,
              secili: secili,
              renk: Colors.red[600]!,
              onTap: () => setSt(() {
                if (secili) {
                  cikarilan.removeWhere((x) => x['id'] == i['id']);
                } else {
                  cikarilan.add(i);
                }
              }),
            );
          }).toList()));
        }

        // ---- 3) EKLENEBILIR ICERIKLER ----
        if (eklenebilir.isNotEmpty) {
          altBolumler.add(baslik('Eklenecek Malzemeler', alt: 'işaretlenen eklenir'));
          altBolumler.add(Wrap(spacing: 8, runSpacing: 8, children: eklenebilir.map((i) {
            final secili = eklenen.any((x) => x['id'] == i['id']);
            final f = _icerikFiyati(i);
            return _icerikCipi(
              ad: i['name']?.toString() ?? '',
              fiyat: f,
              secili: secili,
              renk: Colors.green[700]!,
              onTap: () => setSt(() {
                if (secili) {
                  eklenen.removeWhere((x) => x['id'] == i['id']);
                } else {
                  eklenen.add(i);
                }
              }),
            );
          }).toList()));
        }

        final hazir = zorunluTamam();
        // Ekran genisligine gore: iki taraf da doluysa VE yer varsa 2 sutun.
        final _ekranG = MediaQuery.of(ctx).size.width;
        final _ikiSutun =
            solBolumler.isNotEmpty && sagBolumler.isNotEmpty && _ekranG >= 900;
        // Sekme SADECE hem varyant hem icerik varsa anlamli
        final _comboVar = _comboIsActive(product);
        // Sekme cubugu: varyant+icerik ikisi de varsa VEYA combo varsa
        final _sekmeVar = ((solBolumler.isNotEmpty || sagBolumler.isNotEmpty) &&
                altBolumler.isNotEmpty) ||
            _comboVar;
        final _genislik = (_ikiSutun ? 1040.0 : 660.0).clamp(360.0, _ekranG * 0.95);

        Widget _sutun(List<Widget> ler) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: ler,
            );

        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            width: _genislik,
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(productName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx, false)),
              ]),
              // SEKME CUBUGU — sadece IKI taraf da doluysa cizilir.
              // Tek taraf varsa sekme yok, dogrudan o icerik gosterilir (gereksiz tik olmasin).
              if (_sekmeVar) ...[
                const SizedBox(height: 4),
                Row(children: [
                  _sekmeButonu(
                    secili: sekme == 0,
                    ikon: Icons.checklist_rounded,
                    metin: 'Varyant',
                    onTap: () => setSt(() => sekme = 0),
                  ),
                  const SizedBox(width: 8),
                  _sekmeButonu(
                    secili: sekme == 1,
                    ikon: Icons.tune_rounded,
                    metin: 'Ekle / Çıkar',
                    rozet: (cikarilan.length + eklenen.length),
                    onTap: () => setSt(() => sekme = 1),
                  ),
                  if (_comboVar) ...[
                    const SizedBox(width: 8),
                    _sekmeButonu(
                      secili: sekme == 2,
                      ikon: Icons.card_giftcard_rounded,
                      metin: 'Combo',
                      onTap: () => setSt(() => sekme = 2),
                    ),
                  ],
                ]),
                const SizedBox(height: 10),
              ],
              Flexible(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // VARYANT SEKMESI (veya sekme yoksa varyantlar)
                    if (!_sekmeVar || sekme == 0) ...[
                      if (_ikiSutun)
                        // SOL: gruplu varyantlar · SAG: coklu varyant secimi
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 1, child: _sutun(solBolumler)),
                              Container(
                                width: 1,
                                margin: const EdgeInsets.symmetric(horizontal: 20),
                                color: Colors.grey[300],
                              ),
                              Expanded(flex: 1, child: _sutun(sagBolumler)),
                            ],
                          ),
                        )
                      else
                        _sutun([...solBolumler, ...sagBolumler]),
                    ],
                    // EKLE/CIKAR SEKMESI (veya sekme yoksa altta)
                    if (!_sekmeVar || sekme == 1) ..._sutunListesi(altBolumler),

                    // ---- COMBO SEKMESI ----
                    // 1 Agu 2026 (Mustafa): "combo urunlerde varyant secimi secilmemeli".
                    // Combo paketi KENDI fiyatlandirmasini kullanir (paket fiyati N kaleme
                    // bolunur); ustune varyant/icerik farki eklenirse tutar YANLIS olur.
                    // Bu yuzden secim varsa combo'ya GECIRMEYIZ — ama kullaniciyi "git
                    // temizle" diye ugrastirmak yerine TEK TIKLA cozeriz.
                    if (sekme == 2) _comboSekmesi(
                      ctx: ctx,
                      secimVar: secVaryant.values.any((l) => l.isNotEmpty) ||
                          cikarilan.isNotEmpty || eklenen.isNotEmpty,
                      comboEtiket: (_comboTargetFor(product)['label'] as String?) ?? '',
                      temizle: () => setSt(() {
                        secVaryant.clear();
                        cikarilan.clear();
                        eklenen.clear();
                      }),
                      devam: () {
                        comboyaGec = true;
                        Navigator.pop(ctx, false);
                      },
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // 3 Agu 2026 — not alani (Combo sekmesinde GIZLI: orada kalem
              // combo ekraninda olusur, not oraya ait degil).
              if (sekme != 2) ...[
                _notAlani(notCtrl, setSt),
                const SizedBox(height: 12),
              ],
              Row(children: [
                Expanded(child: Text(
                  hazir ? '${toplam.toStringAsFixed(2)} TL' : 'Zorunlu seçim bekleniyor',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                      color: hazir ? Colors.green[800] : Colors.grey[600]),
                )),
                ElevatedButton(
                  onPressed: hazir ? () => Navigator.pop(ctx, true) : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: hazir ? Colors.green[700] : Colors.grey[300],
                    foregroundColor: Colors.white, minimumSize: const Size(0, 48),
                  ),
                  child: Text('Ekle (${toplam.toStringAsFixed(2)} TL)'),
                ),
              ]),
            ]),
          ),
        );
      }),
    );

    // Combo sekmesinden "devam" denmisse bu pencere kapandi, simdi combo ekrani acilir.
    if (comboyaGec) {
      await _openComboSelectionDialog(product);
      return;
    }
    if (onay != true) return;

    // extras: varyant secimleri + eklenen + cikarilan (hepsi tek yapida, fis zaten basiyor)
    final extras = <Map<String, dynamic>>[];
    secVaryant.forEach((_, list) {
      for (final v in list) {
        extras.add({'name': v['name']?.toString() ?? '', 'price': _variantModifier(v)});
      }
    });
    for (final e in eklenen) {
      extras.add({'name': e['name']?.toString() ?? '', 'price': _icerikFiyati(e)});
    }
    for (final c in cikarilan) {
      // '-' onekli ad -> fis zincirinde "Cikartilacak Malzemeler" basligina duser
      extras.add({'name': '-' + (c['name']?.toString() ?? ''), 'price': _icerikFiyati(c)});
    }

    double toplam = basePrice;
    secVaryant.forEach((_, list) { for (final v in list) toplam += _variantModifier(v); });
    for (final c in cikarilan) toplam += _icerikFiyati(c);
    for (final e in eklenen) toplam += _icerikFiyati(e);

    final _not2 = notCtrl.text.trim();
    await _addProductWithPrice(product, productName, toplam,
        extras: extras, variantNote: _not2.isEmpty ? null : _not2);
  }

  /// Varyant adlari + serbest not -> tek `notes` metni. Bos ise null
  /// (backend'de notes NULL kalir, eski davranisla ayni).
  String? _notuBirlestir(List<String> varyantAdlari, String serbest) {
    final parts = <String>[];
    for (final v in varyantAdlari) {
      if (v.trim().isNotEmpty) parts.add(v.trim());
    }
    final sn = serbest.trim();
    if (sn.isNotEmpty) parts.add(sn);
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Guncelleme modunda kalemin notundan VARYANT ADLARINI ayiklayip geriye
  /// kalan serbest metni dondurur — pencere acilinca kullanicinin kendi notu
  /// kutuda durur, varyant adlari tekrar yazilmaz (cift yazim olmaz).
  String _mevcutSerbestNot(Map<String, dynamic> kalem) {
    final ham = kalem['notes']?.toString().trim() ?? '';
    if (ham.isEmpty) return '';
    // 🔴 3 Agu 2026 — extras IKI SEKILDE gelir: backend jsonb -> List,
    // cevrimdisi SQLite mirror -> JSON METIN. Sadece List islenirse mirror'dan
    // yuklenen kalemde varyant adlari ayiklanamaz ve her duzenlemede NOTA TEKRAR
    // eklenir ("Buyuk Boy, Buyuk Boy, az pissin") — birikir, mutfak fisine basar.
    // Dosyanin kendi deseni (_secimAltSatirlari) ikisini de cozuyor; ayni kural.
    dynamic extras = kalem['extras'];
    if (extras is String && extras.trim().isNotEmpty) {
      try { extras = jsonDecode(extras); } catch (_) { extras = null; }
    }
    final adlar = <String>{};
    if (extras is List) {
      for (final e in extras) {
        if (e is Map) {
          final n = e['name']?.toString().trim() ?? '';
          if (n.isNotEmpty) adlar.add(n.toLowerCase());
        }
      }
    }
    if (adlar.isEmpty) return ham;
    final kalan = ham
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !adlar.contains(e.toLowerCase()))
        .toList();
    return kalan.join(', ');
  }

  /// Kalem alt satiri: secilen varyant / eklenen malzeme / CIKARILAN malzeme.
  /// 1 Agu 2026 (Mustafa: "eklenecek urun cikarilacak urun veya varyantlar adisyonda
  /// gozukmeli") — CIKARILAN malzemeler '-' onekiyle geliyor; burada ONEK TEMIZLENIR,
  /// satir KIRMIZI ve ustu cizili gosterilir (web sepetiyle ayni desen).
  /// ⚠️ FIYAT ISARETI FIX: onceden sabit '+' yaziliyordu -> negatif fiyatta "+-20.00"
  ///    gibi bozuk metin cikiyordu. Artik isaret degere gore.
  Widget _secimAltSatiri(Map e) {
    final hamAd = (e['name'] ?? '').toString();
    final cikarilan = hamAd.startsWith('-');
    final ad = cikarilan ? hamAd.substring(1).trim() : hamAd;
    final fiyat = _safeDouble(e['price']) ?? 0;
    final renk = cikarilan ? Colors.red[700]! : Colors.grey[800]!;
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Row(children: [
        Text(cikarilan ? '−  ' : '•  ',
            style: TextStyle(fontSize: 12, color: cikarilan ? Colors.red[400] : Colors.grey[500])),
        Expanded(
          child: Text(
            ad,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: renk,
              decoration: cikarilan ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        if (fiyat != 0)
          Text(
            '${fiyat > 0 ? '+' : '−'}${fiyat.abs().toStringAsFixed(2)}',
            style: TextStyle(
                fontSize: 12,
                color: fiyat > 0 ? Colors.grey[600] : Colors.red[600],
                fontWeight: FontWeight.w600),
          ),
      ]),
    );
  }

  /// COMBO SEKMESI icerigi (1 Agu 2026).
  /// [secimVar] ise combo'ya GECILMEZ: combo paketi kendi fiyatlandirmasini kullanir
  /// (paket fiyati N kaleme bolunur), ustune varyant/icerik farki binerse tutar yanlis olur.
  /// Kullaniciyi "git temizle" diye ugrastirmak yerine TEK BUTONLA cozuyoruz.
  Widget _comboSekmesi({
    required BuildContext ctx,
    required bool secimVar,
    required String comboEtiket,
    required VoidCallback temizle,
    required VoidCallback devam,
  }) {
    if (secimVar) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.amber[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber[300]!),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 20, color: Colors.amber[800]),
            const SizedBox(width: 8),
            Text('Combo paketi ayrı fiyatlandırılır',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                    color: Colors.amber[900])),
          ]),
          const SizedBox(height: 8),
          Text(
            'Combo\'da paket fiyatı seçilen ürünlere bölünür. Şu an yaptığınız varyant '
            've malzeme seçimleri bu hesaba dahil edilemez — birlikte kullanılırsa tutar '
            'yanlış çıkar.\n\nComboya geçmek için mevcut seçimleri kaldırmanız gerekiyor.',
            style: TextStyle(fontSize: 13.5, color: Colors.grey[800], height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(children: [
            ElevatedButton.icon(
              onPressed: temizle,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Seçimleri kaldır ve devam et'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber[800], foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
              ),
            ),
          ]),
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green[200]!),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.card_giftcard_rounded, size: 22, color: Colors.green[700]),
          const SizedBox(width: 8),
          Text(comboEtiket.isNotEmpty ? comboEtiket : 'Combo paketi',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                  color: Colors.green[800])),
        ]),
        const SizedBox(height: 8),
        Text('Paket içeriğini seçmek için devam edin. Paket fiyatı seçilen ürünlere '
            'otomatik bölünür.',
            style: TextStyle(fontSize: 13.5, color: Colors.grey[800], height: 1.4)),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          onPressed: devam,
          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
          label: const Text('Combo seçimine geç'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green[700], foregroundColor: Colors.white,
            minimumSize: const Size(0, 46),
          ),
        ),
      ]),
    );
  }

  /// Sekme butonu (Varyant / Ekle-Cikar). Rozet = o sekmede kac secim yapildi.
  Widget _sekmeButonu({
    required bool secili,
    required IconData ikon,
    required String metin,
    required VoidCallback onTap,
    int rozet = 0,
  }) {
    // 2 Agu 2026: SADECE GORSEL — secili sekme hafif golgeli koyu hap, secili
    // olmayan beyaz + ince cerceve (eski duz gri dolgudan daha net hiyerarsi).
    return Material(
      color: secili ? const Color(0xFF1F2937) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      elevation: secili ? 2 : 0,
      shadowColor: Colors.black26,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: secili ? Colors.transparent : const Color(0xFFE2E8F0),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(ikon, size: 16, color: secili ? Colors.white : Colors.grey[700]),
            const SizedBox(width: 6),
            Text(metin, style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: secili ? Colors.white : Colors.grey[800])),
            if (rozet > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: secili ? Colors.white24 : Colors.blue[600],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$rozet', style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  List<Widget> _sutunListesi(List<Widget> ler) => ler;

  Widget _icerikCipi({
    required String ad,
    required double fiyat,
    required bool secili,
    required Color renk,
    required VoidCallback onTap,
  }) {
    final fiyatMetni = fiyat == 0
        ? ''
        : '  ${fiyat > 0 ? '+' : '-'}${fiyat.abs().toStringAsFixed(0)}₺';
    return Material(
      color: secili ? renk.withOpacity(0.12) : Colors.grey[100],
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: secili ? renk : Colors.grey[300]!, width: secili ? 1.6 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(secili ? Icons.check_circle : Icons.circle_outlined,
                size: 16, color: secili ? renk : Colors.grey[400]),
            const SizedBox(width: 6),
            Text(ad, style: TextStyle(
                fontSize: 13.5,
                fontWeight: secili ? FontWeight.w600 : FontWeight.normal,
                color: secili ? renk : const Color(0xFF374151))),
            if (fiyatMetni.isNotEmpty)
              Text(fiyatMetni, style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[700])),
          ]),
        ),
      ),
    );
  }

  /// 1 Agu 2026 — VARYANT EKRANI SECICI (TEK KARAR NOKTASI).
  /// Mustafa: "combo ve varyant ayni anda aciksa POS'ta secim ekrani gosteriyorduk,
  /// bunda nasil yapabiliriz?"
  ///
  /// Artik UC farkli varyant ekrani var. Hangisinin acilacagi TEK yerden belirlenir ki
  /// hem urune tiklama, hem varyant butonu, hem de combo secim ekraninin "Varyant" dali
  /// AYNI karari versin (kod tekrari ve davranis farki olmasin).
  ///
  /// Oncelik (en zengin ekran once):
  ///   1. Icerik VEYA gruplu varyant varsa -> _openIcerikVaryantDialog (web muadili, bolumlu)
  ///   2. variants_allow_multiple_pos      -> _openMultiVariantDialog  (coklu, fiyat toplanir)
  ///   3. digerleri                        -> _openVariantDialogForProduct (tekli, eski akis)
  Future<void> _varyantEkraniAc(Map<String, dynamic> product, List variants) async {
    final _icerik = _urunIcerikleri(product).isNotEmpty;
    final _gruplu = _urunGrupluVaryantli(product);
    final _varyant = variants.isNotEmpty;

    // 1 Agu 2026 (Mustafa: "ekle cikari da mevcut pencerede TAB olarak eklesene, bosa tik
    // yapmasin sonucta ayni urune ait") — HEM varyant HEM icerik varsa ARTIK ARA SECIM
    // EKRANI YOK. Tek pencere acilir, ust tarafta "Varyant | Ekle/Cikar" sekmeleri olur.
    // Secimler sekme degisince korunur, tek "Ekle" butonu hepsini birlikte uygular.
    if (_icerik && _varyant) {
      await _openIcerikVaryantDialog(product, variants, mod: 'hepsi');
      return;
    }

    // Tek ozellik varsa dogrudan o ekran
    if (_icerik && !_varyant) {
      await _openIcerikVaryantDialog(product, variants, mod: 'icerik');
      return;
    }
    if (_gruplu) {
      await _openIcerikVaryantDialog(product, variants, mod: 'varyant');
      return;
    }
    if (_posCokluVaryant(product)) {
      await _openMultiVariantDialog(product, variants);
      return;
    }
    await _openVariantDialogForProduct(product, variants);
  }

  bool _urunGrupluVaryantli(Map<String, dynamic> product) {
    final variants = (product['variants'] is List) ? product['variants'] as List : const [];
    return variants.any((v) =>
        v is Map && (v['group_name'] ?? '').toString().trim().isNotEmpty);
  }

  double _icerikFiyati(Map<String, dynamic> i) {
    final p = i['price'];
    if (p is num) return p.toDouble();
    return double.tryParse('${p ?? ''}') ?? 0;
  }

  /// 31 Tem 2026 — POS VARYANT COKLU SECIM (panel > Urun Duzenle > Varyant Ayarlari).
  /// Web'deki variants_allow_multiple'in POS karsiligi; AYRI kolon okur, web davranisi degismez.
  /// COMBO ILE ILGISI YOK: combo = paket/set mantigi (N kalem, indirim); bu = TEK kalemin
  /// uzerine birden fazla varyant farkinin eklenmesi. Kapaliyken (varsayilan) eski tekli akis.
  // 1 Agu 2026 — TEK KAYNAK: bayrak okuma kurali ComboCalculator'da.
  bool _posCokluVaryant(Map<String, dynamic> product) =>
      ComboCalculator.posCokluVaryant(product);

  bool _posVaryantZorunlu(Map<String, dynamic> product) =>
      ComboCalculator.posVaryantZorunlu(product);

  Future<void> _openVariantDialogForProduct(Map<String, dynamic> product, List variants) async {
    if (_posCokluVaryant(product)) {
      await _openMultiVariantDialog(product, variants);
      return;
    }
    final basePrice = _restaurantBasePrice(product);
    final productName = product['name']?.toString() ?? '';
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) {
        final tiles = <Widget>[
          // 1 Agu 2026: sabit "1 Porsiyon" yerine URUN ADI (bkz. coklu ekrandaki not).
          _variantOptionTile(
            label: productName,
            price: basePrice,
            selected: false,
            onTap: () => Navigator.pop(ctx, {'variant': null}),
            color: Colors.blue[600]!,
          ),
          ...variants.map((v) {
            final modifier = _variantModifier(Map<String, dynamic>.from(v as Map));
            final vname = v['name']?.toString() ?? '';
            return _variantOptionTile(
              label: vname,
              price: basePrice + modifier,
              modifier: modifier,
              selected: false,
              onTap: () => Navigator.pop(ctx, {'variant': v}),
              color: Colors.orange[600]!,
            );
          }),
        ];
        return _buildResponsiveVariantDialog(ctx: ctx, title: productName, tiles: tiles);
      },
    );
    if (result == null) return; // iptal
    final selectedVariant = result['variant'];
    if (selectedVariant == null) {
      // 1 Porsiyon (varyantsiz) secildi -> normal ekle
      _addProductWithPrice(product, productName, basePrice);
      return;
    }
    final mod = _variantModifier(Map<String, dynamic>.from(selectedVariant as Map));
    final vname = selectedVariant['name']?.toString() ?? '';
    final label = mod != 0
        ? '$vname (${mod > 0 ? '+' : ''}${mod.toStringAsFixed(0)}TL)'
        : vname;
    // Varyant adi displayName'e -> _addProductWithPrice note olarak yazar (mevcut kalip)
    _addProductWithPrice(product, '$productName ($label)', basePrice + mod, variantNote: label);
  }

  /// COMBO SECIM EKRANI (Fable denetimli). Kurala gore stepPerSet adet varyant sec (dinamik N/N+G).
  /// Secilen ODENEN kalemler sepete eklenir (extra hediye BACKEND uretir — POS eklemez, cifte-hediye YOK).
  /// comboCalculator indirimini _comboResult ile otomatik hesaplar (bu ekran indirim HESAPLAMAZ).
  Future<void> _openComboSelectionDialog(Map<String, dynamic> product) async {
    final t = _comboTargetFor(product);
    final int stepPerSet = t['stepPerSet'] as int;
    final bool repeat = t['repeat'] as bool;
    final String label = t['label'] as String;
    final String giftMode = t['giftMode'] as String;
    final int giftPerSet = t['G'] as int;
    final productName = product['name']?.toString() ?? '';
    // 31 Tem 2026 — LIMITSIZ SECIM (panel > combo pop > "Sadece POS").
    // Acikken N adedin tamami secilmeden de "Sepete Ekle" CALISIR; indirim backend'de
    // secilen adede ORANLANIR (panel-direct/comboCalculator kismiSet). Kapaliyken eski
    // davranis: tam sayi secilmeden buton pasif. ⚠️ SADECE POS — web/telefon okumaz.
    // 31 Tem 2026: cevrimdisi cache 0/1 doner (bkz. combo_calculator._truthy).
    final bool posUnlimited = ComboCalculator.posLimitsiz(product); // TEK KAYNAK
    final basePrice = _restaurantBasePrice(product);
    final variants = (product['variants'] is List) ? product['variants'] as List : const [];

    // Secim opsiyonlari: "1 Porsiyon" (baz) + her varyant. 'mod' = kanal modifier (paket bolmede
    // kullanilir). ETIKET (Mustafa): combo'da NEGATIF modifier (-940 = baz-sifirla niyeti) parantez
    // GOSTERMEZ (saçma "(-940TL)" olmasin) — sadece varyant adi. POZITIF modifier (+100 gercek ek
    // ucret) parantez gosterir. Kart fiyati: paketten payi gosterilir (0 saçma). Odenen adet bilinmedigi
    // icin kart onizlemesinde baz+pozitif-mod gosterilir (kesin bolme eklemede).
    // 'price' = kart onizleme (bedava ₺0, +mod). 'mod' = kanal modifier (paket bolme). 'realValue' =
    // GERCEK combo degeri (baz+mod) — extra hediye "en ucuz" secimi BUNA gore (B1 fix: POS+telefon
    // ayni, gercek fiyata gore en ucuz musteri lehine hediye).
    final options = <Map<String, dynamic>>[
      // 1 Agu 2026: combo secim ekraninda da sabit metin yerine URUN ADI.
      {'name': productName, 'price': basePrice, 'note': null, 'mod': 0.0, 'realValue': basePrice},
      ...variants.map((v) {
        final mod = _variantModifier(Map<String, dynamic>.from(v as Map));
        final vname = v['name']?.toString() ?? '';
        final lbl = mod > 0 ? '$vname (+${mod.toStringAsFixed(0)}TL)' : vname;
        final previewPrice = mod > 0 ? mod : 0.0;
        return {'name': vname, 'price': previewPrice, 'note': lbl, 'mod': mod, 'realValue': basePrice + mod};
      }),
    ];

    // Secilen kalemler (her secim bir opsiyon kopyasi). picks = [{name,price,note}].
    final picks = <Map<String, dynamic>>[];
    int setCount = 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final screen = MediaQuery.of(ctx).size;
        final maxCols = ((screen.width * 0.92 - 40) / (_variantTileWidth + 10)).floor().clamp(1, 4);
        final cols = maxCols.clamp(1, options.isEmpty ? 1 : options.length);
        final dialogWidth = (cols * (_variantTileWidth + 10) + 40).clamp(360.0, screen.width * 0.92);
        return StatefulBuilder(builder: (ctx, setSt) {
          final target = stepPerSet * setCount;
          final selected = picks.length;
          // 31 Tem 2026: limitsiz secimde EKSIK adetle de eklenebilir (en az 1).
          final canAdd = posUnlimited ? (selected > 0) : (selected == target && selected > 0);
          final kismiSecim = posUnlimited && selected > 0 && selected < target;
          // extra modda hediye vurgusu: secilen en ucuz (giftPerSet*setCount) tane bilgi amacli isaretlenir.
          final giftCount = giftMode == 'extra' ? giftPerSet * setCount : 0;
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: dialogWidth,
              constraints: BoxConstraints(maxHeight: screen.height * 0.88),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(child: Text(productName,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx, false)),
                  ]),
                  // Kural rozeti
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    margin: const EdgeInsets.only(top: 2, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange[50], borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange[300]!),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.local_offer, size: 15, color: Colors.orange[800]),
                      const SizedBox(width: 6),
                      Flexible(child: Text('COMBO: $label${repeat ? '  ·  Katlanabilir' : ''}',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.orange[900]))),
                    ]),
                  ),
                  // Ilerleme
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('$selected / $target seçildi',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                            color: canAdd ? Colors.green[700] : Colors.grey[700])),
                    if (giftCount > 0)
                      Text('$giftCount hediye (en ucuz)', style: TextStyle(fontSize: 12, color: Colors.green[700])),
                  ]),
                  const SizedBox(height: 10),
                  // Varyant/opsiyon kartlari — tikla, secim listesine ekle (hedefe kadar)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 10, runSpacing: 10,
                        children: options.map((opt) {
                          final cnt = picks.where((p) => p['name'] == opt['name'] && p['price'] == opt['price']).length;
                          final optMod = (opt['mod'] as double?) ?? 0.0;
                          // Combo kart fiyat metni (Mustafa): +modifier -> "+₺100" goster (baz+mod DEGIL);
                          // bedava/0 -> "₺0". Gercek fiyat eklemede paket bolmesiyle yazilir.
                          final priceLabel = optMod > 0 ? '+₺${optMod.toStringAsFixed(0)}' : '₺0';
                          return SizedBox(
                            width: _variantTileWidth,
                            child: _variantOptionTile(
                              label: cnt > 0 ? '${opt['name']}  ×$cnt' : opt['name'] as String,
                              price: opt['price'] as double,
                              priceLabel: priceLabel,
                              selected: cnt > 0,
                              onTap: () {
                                // Limitsizde de hedefi ASMA — eksik secime izin var, fazlaya degil
                                // (fazla secim set mantigini bozar; kullanici "Set daha" ile artirir).
                                if (picks.length >= target) return; // hedefe ulasti -> ekleme yok
                                setSt(() => picks.add(Map<String, dynamic>.from(opt)));
                              },
                              color: cnt > 0 ? Colors.green[700]! : Colors.orange[600]!,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Secilenler ozeti (tek satir + geri al)
                  if (picks.isNotEmpty) ...[
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (int i = 0; i < picks.length; i++)
                        InputChip(
                          label: Text('${picks[i]['name']}', style: const TextStyle(fontSize: 12)),
                          onDeleted: () => setSt(() => picks.removeAt(i)),
                          deleteIcon: const Icon(Icons.close, size: 15),
                        ),
                    ]),
                    const SizedBox(height: 8),
                  ],
                  // Alt bar
                  Row(children: [
                    if (repeat && canAdd) ...[
                      OutlinedButton.icon(
                        onPressed: () => setSt(() => setCount++),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Set daha'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: ElevatedButton(
                        onPressed: canAdd ? () => Navigator.pop(ctx, true) : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: canAdd ? Colors.green[700] : Colors.grey[300],
                          foregroundColor: Colors.white, minimumSize: const Size(0, 48),
                        ),
                        child: Text(!canAdd
                            ? 'Kalan: ${target - selected}'
                            : (kismiSecim
                                ? 'Sepete Ekle ($selected/$target)'   // eksik set — indirim oranlanacak
                                : 'Sepete Ekle ($selected)')),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          );
        });
      },
    );

    if (confirmed != true || picks.isEmpty) return; // iptal -> HIC kalem eklenmez
    // KRITIK (Fable C + panel/web birebir): extra modda kullanici N+G secer ama sepete SADECE N ODENEN
    // kalem eklenir; en ucuz G hediye slotu EKLENMEZ. Hediyeyi backend close calcCartCombos.giftLines ile
    // uretir (₺0 __combo_gift satir). Aksi halde backend Q=N+G gorup sets'i yanlis hesaplar (cifte-hediye).
    // within/percent/amount: hediye slotu yok, tum secilenler odenen -> hepsi eklenir.
    // extra modda en ucuz (giftPerSet*setCount) tane HEDIYE slotu EKLENMEZ (backend uretir).
    // within/percent/amount'ta giftCount=0 -> hepsi eklenir. Statik+test edilebilir yardimci.
    final giftCount = (giftMode == 'extra') ? giftPerSet * setCount : 0;
    // paidPicks ARTIK SADECE PAKET TUTARINI hesaplamak icin: hediye BEDAVA oldugu icin onun
    // varyant sursarji pakete eklenmez (en ucuz giftCount kalem cikarilir).
    final paidPicks = ComboCalculator.paidPicksAfterGift(picks, giftCount);
    // FIYAT BOLME (Mustafa kesin kural): combo=PAKET. Bolunecek toplam = ana restoran fiyati +
    // secilen odenen kalemlerin POZITIF modifier toplami. N odenen kaleme ESIT bolunur (kurus son
    // kaleme). Negatif modifier (-940 = baz-sifirla niyeti) toplama katilmaz. Or N=2 baz 940:
    // iki normal -> 470+470; bir +100 -> 1040/2=520+520. ₺0 kalem/ciro kaybi YOK.
    final paidMods = paidPicks.map((p) => (p['mod'] as double?) ?? 0.0).toList();
    // 🔴 1 Agu 2026 (Mustafa: "mutfak gormesi lazim olur mu canim") — EXTRA MODU DEGISTI.
    // ESKI: hediye kalemi adisyona HIC eklenmiyordu; backend kapanista ₺0 satir uretiyordu.
    //       Ama o satir printed=1 ile ve KAPANISTA yaziliyordu -> MUTFAK HIC GORMUYORDU.
    //       Musteri 3 urun seciyor, mutfak 2 yapiyordu.
    // YENI: secilen TUM kalemler (N+G) adisyona girer -> kasiyer gorur, mutfak fisine duser.
    // PARA DEGISMEDI: bolunecek paket tutari YINE SADECE odenen kalemlerin modifier'i +
    // baz fiyat (hediyenin sursarji dahil edilmez); sadece daha cok kaleme bolunur.
    // Backend kapanista bu paket icin IKINCI bir hediye satiri URETMEZ (combo_group_id tespiti).
    final splitPrices = ComboCalculator.splitComboPackagePrice(paidMods, basePrice,
        satirSayisi: picks.length);
    // 31 Tem 2026 — BU SECIM ICIN TEK PAKET KIMLIGI.
    // Karar (Mustafa): bir secim ekrani = bir grup. "Set daha" ile artirilan setler AYNI gruba
    // girer (web davranisiyla ayni); kasiyer combo urune TEKRAR tiklayip yeni secim yaparsa
    // bu fonksiyon yeniden calisir ve YENI kimlik uretilir → fiste ayri paket gorunur.
    // Format web ile ayni ailede ('cg' + zaman) ama POS'ta ayni milisaniyede iki ekleme
    // olabildigi icin sonuna MIKROSANIYE eki konur (cakisma = iki farkli paket birlesir).
    // Ayni milisaniyedeki iki cagri farkli mikrosaniye alir → kimlik ayrisir.
    final comboGid = 'cg${DateTime.now().millisecondsSinceEpoch}'
        '${(DateTime.now().microsecondsSinceEpoch % 100000).toString().padLeft(5, '0')}';
    for (int i = 0; i < picks.length; i++) {
      final p = picks[i];
      final note = p['note'] as String?;
      final display = note != null ? '$productName ($note)' : productName;
      _addProductWithPrice(product, display, splitPrices[i],
        variantNote: note,
        comboGroupId: comboGid,
        comboGroupName: productName,          // ANA urun adi → fiste ust satir
        comboPickName: note ?? productName,   // secilen varyant → fiste alt satir
        // 3 Agu 2026: combo paketinde SADECE ILK kalem secili gelir (hepsi degil)
        selectItem: i == 0);
    }
  }

  /// Secili sepet item'inin urunu icin varyant kayitlari var mi?
  List _variantsForSelectedItem() {
    final item = _findSelectedItem();
    if (item == null) return const [];
    final productId = item['product_id'];
    if (productId == null) return const [];
    final prod = _products.where((p) => p['id'] == productId).firstOrNull;
    if (prod == null) return const [];
    final raw = prod['variants'];
    return raw is List ? raw : const [];
  }

  /// Sepetteki secili item icin varyant secim dialog'u
  Future<void> _openVariantDialogForSelected() async {
    final item = _findSelectedItem();
    if (item == null) return;
    final productId = item['product_id'];
    if (productId == null) return;
    // 12 May 2026 debug: yanlis ürüne not yazma bug'i tracker
    LogService().logAction('Varyant dialog acildi', details: {
      'selected_item_id': _selectedItemId,
      'item_id': item['id'],
      'item_product_id': productId,
      'item_product_name': item['product_name'],
      'ticket_items_count': _ticketItems.length,
      'all_items': _ticketItems.map((i) => '${i['id']}:${i['product_name']}').toList(),
    });
    final prod = _products.where((p) => p['id'] == productId).firstOrNull;
    if (prod == null) return;

    // =========================================================================
    // 1 Agu 2026 (Mustafa) — VARYANT BUTONU İKİ KİLİT
    // "varyant seçiyorum kaydetmiyor, bu doğru bir davranış ama ... seçtirmemesi
    //  lazım. bir de fiş çıktıysa da düzenlemeye izin de vermemesi lazım"
    // Eskiden pencere açılıp seçim yaptırıyor, sonra sessizce kaydetmiyordu —
    // kasiyer seçtim sanıyordu. Artık HİÇ AÇILMIYOR, sebebi yazıyor.
    //
    // ⚠️ KAPSAM: bu kilit SADECE yazdırılmış kalemin varyantla İÇERİĞİNİN
    //    değiştirilmesini engeller. Ürün İPTAL akışı DEĞİŞMEDİ — yetkisi olan
    //    (cancel_item / cancel_item_unprinted) eskisi gibi sebep seçip iptal eder.
    // =========================================================================
    // KİLİT 1 — FİŞ MUTFAĞA GİTTİYSE İÇERİK DEĞİŞMEZ.
    // 'printed' SQLite'ta INTEGER (1) / API'de bool → iki şekil de kabul
    // (dosyadaki mevcut idiom, satır ~2389 ile aynı).
    final bool _fisCikti = item['printed'] == 1 || item['printed'] == true;
    if (_fisCikti) {
      _showError('Bu ürünün fişi mutfağa gitti — varyantı değiştirilemez. '
          'Değişmesi gerekiyorsa ürünü iptal edip yeniden ekleyin.');
      return;
    }

    // KİLİT 2 — COMBO ÜRÜNDE VARYANT SONRADAN DEĞİŞTİRİLEMEZ.
    // Combo paketinin fiyatı seçilen N kaleme BÖLÜNEREK yazılır
    // (splitComboPackagePrice). Kalem tek başına varyantla değiştirilirse bölünmüş
    // fiyat ile yeni varyant modifier'ı tutmaz → adisyon tutarı YANLIŞ olur.
    // 2 Agu 2026 DUZELTME (Mustafa yakaladi): kilit ARTIK KALEM SEVIYESINDE.
    // ESKI: urun combo_enabled ise TUM kalemleri kilitliyordu -> ayni urunu combo DISI,
    // duz varyantla eklediginde onun da varyanti degistirilemiyordu (yanlis engelleme).
    // DOGRUSU: sadece bir combo PAKETINE ait kalem korunur (combo_group_id DOLU), cunku
    // paket fiyati uyelere bolunmustur; tek uye degisirse tutar bozulur. Duz eklenen
    // kalemin bolunmus fiyati YOKTUR, serbestce degistirilebilir.
    final _kalemGid = (item['combo_group_id'] ?? '').toString().trim();
    if (_kalemGid.isNotEmpty) {
      final ad = (item['combo_group_name'] ?? prod['name'] ?? 'Bu ürün').toString();
      _showError('$ad combo paketinin parçası — varyant sonradan değiştirilemez. '
          'Paketin fiyatı ürünlere bölündüğü için kalemi iptal edip combo seçimini '
          'yeniden yapmanız gerekir.');
      return;
    }

    final variants = (prod['variants'] is List) ? prod['variants'] as List : const [];
    if (variants.isEmpty) return;

    // 1 Agu 2026 — VARYANT BUTONU ARTIK AYNI KODDAN BESLENIYOR.
    // Urunde "Varyantlarda Coklu Secim (POS)" acikas coklu ekran acilir ve secili kalem
    // GUNCELLENIR (yeni kalem eklenmez). Kapaliysa asagidaki TEKLI akis aynen calisir —
    // yani mevcut davranis bozulmaz.
    final _p = Map<String, dynamic>.from(prod);
    if (_urunIcerikleri(_p).isNotEmpty || _urunGrupluVaryantli(_p)) {
      // Icerik/gruplu varyant ekrani YENI KALEM ekler (guncelleme modu yok) — kasiyer
      // eski kalemi silip yenisini ekler. Coklu ekranin guncelleme modu korunuyor.
      await _openIcerikVaryantDialog(_p, variants);
      return;
    }
    if (_posCokluVaryant(_p)) {
      await _openMultiVariantDialog(_p, variants, guncellenecekKalem: item);
      return;
    }

    final basePrice = _restaurantBasePrice(Map<String, dynamic>.from(prod));
    final productName = prod['name']?.toString() ?? '';
    final currentNotes = item['notes']?.toString() ?? '';

    // Hangi varyant secili (notes icinden parse — basit eslestirme)
    int? currentSelectedId;
    for (final v in variants) {
      final vname = v['name']?.toString() ?? '';
      if (vname.isNotEmpty && currentNotes.contains(vname)) {
        currentSelectedId = _safeInt(v['id']);
        break;
      }
    }

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) {
        final tiles = <Widget>[
          // 1 Agu 2026: sabit "1 Porsiyon" yerine URUN ADI (bkz. coklu ekrandaki not).
          _variantOptionTile(
            label: productName,
            price: basePrice,
            selected: currentSelectedId == null,
            onTap: () => Navigator.pop(ctx, {'variant': null}),
            color: Colors.blue[600]!,
          ),
          ...variants.map((v) {
            final id = _safeInt(v['id']);
            final modifier = _variantModifier(Map<String, dynamic>.from(v as Map));
            final variantPrice = basePrice + modifier;
            final vname = v['name']?.toString() ?? '';
            return _variantOptionTile(
              label: vname,
              price: variantPrice,
              modifier: modifier,
              selected: currentSelectedId == id,
              onTap: () => Navigator.pop(ctx, {'variant': v}),
              color: Colors.orange[600]!,
            );
          }),
        ];
        return _buildResponsiveVariantDialog(ctx: ctx, title: productName, tiles: tiles);
      },
    );

    if (result == null) return; // Iptal (X butonu)
    final selectedVariant = result['variant'];

    // Eski varyant adlarini notes'tan temizle, yeni varyant adini ekle
    String newNotes = currentNotes;
    for (final v in variants) {
      final vname = v['name']?.toString() ?? '';
      if (vname.isEmpty) continue;
      newNotes = newNotes
          .replaceAll(RegExp(',\\s*' + RegExp.escape(vname) + '(\\s*\\(\\+[0-9.]+TL\\))?'), '')
          .replaceAll(RegExp('^' + RegExp.escape(vname) + '(\\s*\\(\\+[0-9.]+TL\\))?,?\\s*'), '')
          .replaceAll(vname, '')
          .trim();
    }
    newNotes = newNotes.replaceAll(RegExp(',\\s*,'), ',').replaceAll(RegExp('^,|,\$'), '').trim();

    // 12 Haz 2026 — MUTLAK FIYAT modeli (F4 fix): eski varyant etiketleri
    // temizlendikten sonra notes'ta kalan '(+N TL)' token'lari = mevcut ucretli
    // ekstra toplami. unit_price'a eklenir ki varyant degisince ekstra ucreti
    // fiyattan ucmasin. (Yeni varyant etiketi henuz eklenmeden hesaplanmali.)
    final existingExtrasTotal = _sumExtraPriceTokens(newNotes);

    if (selectedVariant != null) {
      final vname = selectedVariant['name']?.toString() ?? '';
      final mod = _variantModifier(Map<String, dynamic>.from(selectedVariant as Map));
      final label = mod != 0
          ? '$vname (${mod > 0 ? '+' : ''}${mod.toStringAsFixed(0)}TL)'
          : vname;
      newNotes = newNotes.isEmpty ? label : '$newNotes, $label';
    }

    final variantModifier = selectedVariant != null ? _variantModifier(Map<String, dynamic>.from(selectedVariant as Map)) : 0.0;

    final itemId = _safeInt(item['id']);
    if (itemId == null) return;

    try {
      final res = await widget.apiService.updateTicketItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        notes: newNotes.isEmpty ? null : newNotes,
        // MUTLAK FIYAT: baz + yeni varyant modifier + mevcut ekstra toplami
        unitPrice: basePrice + variantModifier + existingExtrasTotal,
        waiterId: widget.waiterId,
      );
      if (res['success'] == true) {
        await _loadTicketItems();
      } else {
        _showError(res['error']?.toString() ?? 'Varyant uygulanamadi');
      }
    } catch (e) {
      _showError('Varyant hatasi: $e');
    }
  }

  /// Responsive varyant dialog govdesi (iki varyant akisi da kullanir). Cok varyantta ekrana sigmayip
  /// asagi tasma sorununu cozer: tile'lar Wrap ile ENLEMESINE dizilir (sigmayinca alt satir), dialog
  /// genisligi varyant sayisina gore artar (max ekran %92), yukseklik ekran %85 + scroll.
  /// tiles: hazir _variantOptionTile listesi. Her tile sabit genislik (_variantTileWidth) ister.
  static const double _variantTileWidth = 300;
  Widget _buildResponsiveVariantDialog({
    required BuildContext ctx,
    required String title,
    String subtitle = 'Varyant secin',
    required List<Widget> tiles,
    // 31 Tem 2026: coklu secimde alt bar (secim ozeti + toplam + Ekle). Tekli akista null
    // -> dialog eskisiyle BIREBIR ayni kalir (tile'a tiklayinca kapanir, buton yok).
    Widget? altBar,
  }) {
    final screen = MediaQuery.of(ctx).size;
    // Kac sutun sigar (tile genisligi + 10 bosluk), 1..4 arasi; varyant sayisini gecmesin.
    final maxCols = ((screen.width * 0.92 - 40) / (_variantTileWidth + 10)).floor().clamp(1, 4);
    final cols = maxCols.clamp(1, tiles.isEmpty ? 1 : tiles.length);
    final dialogWidth = (cols * (_variantTileWidth + 10) + 40).clamp(360.0, screen.width * 0.92);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: dialogWidth,
        constraints: BoxConstraints(maxHeight: screen.height * 0.85),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx, null)),
            ]),
            Text(subtitle, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: tiles
                      .map((t) => SizedBox(width: _variantTileWidth, child: t))
                      .toList(),
                ),
              ),
            ),
            if (altBar != null) ...[
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              altBar,
            ],
          ],
        ),
      ),
    );
  }

  Widget _variantOptionTile({
    required String label,
    required double price,
    double? modifier,
    required bool selected,
    required VoidCallback onTap,
    required Color color,
    String? priceLabel, // combo: hazir fiyat metni (or "+₺100" veya "₺0"); verilirse price yerine gecer
  }) {
    final modText = (modifier != null && modifier != 0)
        ? ' (${modifier > 0 ? '+' : ''}${modifier.toStringAsFixed(0)} TL)'
        : '';
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color : Colors.white,
          foregroundColor: selected ? Colors.white : color,
          side: BorderSide(color: color, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text('$label$modText', overflow: TextOverflow.ellipsis)),
            Text(priceLabel ?? '₺${price.toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  /// 31 Tem 2026 — COMBO PAKET KIMLIGI (comboGroupId/comboGroupName/comboPickName)
  /// Ayni combo seciminden gelen kalemler AYNI comboGroupId'yi tasir → fis, mutfak ekrani ve
  /// adisyon ekrani bunlari ANA URUN altinda gruplayabilir. Alan adlari panel_orders.items[]
  /// icindeki WEB STANDARDIYLA AYNI (api/kitchen.js + admin/kitchen.html gruplama UI'i HAZIR).
  /// Combo DISI eklemelerde null gecilir → hicbir davranis degismez (geri uyumlu).
  /// 3 Agu 2026 (Mustafa): yeni eklenen kalem OTOMATIK SECILI gelsin (liste ters sirali,
  /// en yeni ustte — o kalem ayni anda secili de olur). [selectItem]=false SADECE combo
  /// paketinin 2..N kalemlerinde kullanilir (paketin ILK kalemi secili gelir, hepsi degil).
  /// Gecici id secimi guvenli: asagida `if (_selectedItemId == tempId) _selectedItemId = realId`
  /// eslemesi sync sonrasi secimi gercek id'ye tasir (kaybolmaz).
  Future<void> _addProductWithPrice(Map<String, dynamic> product, String displayName, double price,
      {String? variantNote, String? comboGroupId, String? comboGroupName, String? comboPickName,
      List<Map<String, dynamic>>? extras, bool selectItem = true}) async {
    try {
      final productId = _safeInt(product['id']);
      if (productId == null) return;

      final name = displayName;

      final tempId = -DateTime.now().millisecondsSinceEpoch;
      // Optimistic add — product cache'inden skip_pos_print kopyala ki badge YAZDIRILMADI cikmasin
      final skipPosPrint = product['skip_pos_print'] == true
          || product['skip_pos_print'] == 1
          || product['skip_pos_print'] == '1'
          || product['skip_pos_print'] == 'true';
      setState(() {
        _ticketItems.add({
          'id': tempId,
          'product_id': productId,
          'product_name': name,
          'unit_price': price,
          'quantity': 1,
          'status': 'active',
          'printed': 0,
          'notes': variantNote,
          // 31 Tem 2026: POS coklu varyant secimleri — sunucu cevabi beklenmeden alt satirlar cikar.
          'extras': extras ?? const [],
          'skip_pos_print': skipPosPrint,
          // 31 Tem 2026: optimistic satirda da tasi → sunucu cevabi gelmeden gruplu gorunur
          'combo_group_id': comboGroupId,
          'combo_group_name': comboGroupName,
          'combo_pick_name': comboPickName,
        });
        // 3 Agu 2026: yeni kalem otomatik secili (kullanici baska kalem secmis olsa bile
        // secim yeni urune gecer — beklenen davranis). Sync olunca tempId->realId eslemesi
        // asagida secimi korur. Kural saf ve testli: PosOtoSecim.eklemede.
        _selectedItemId = PosOtoSecim.eklemede(
            mevcut: _selectedItemId, tempId: tempId, secilsin: selectItem);
      });

      double basePrice = 0;
      final prodLookup = _products.where((p) => _safeInt(p['id']) == productId).firstOrNull;
      if (prodLookup != null) {
        basePrice = _safeDouble((prodLookup['restaurant_price'] != null && prodLookup['restaurant_price'] != 0)
            ? prodLookup['restaurant_price']
            : prodLookup['price']);
      }
      final extrasAmount = (basePrice > 0 && price > basePrice) ? (price - basePrice) : 0.0;

      widget.apiService.addTicketItem(
        ticketId: widget.ticketId,
        productId: productId,
        productName: name,
        unitPrice: price,
        extrasAmount: extrasAmount,
        quantity: 1,
        notes: variantNote,
        waiterId: widget.waiterId,
        clientTempId: tempId,
        comboGroupId: comboGroupId,
        comboGroupName: comboGroupName,
        comboPickName: comboPickName,
        extras: extras,
      ).then((response) {
        widget.onItemAdded();
        if (!mounted) return;
        int? realId = _safeInt(response['item_id'])
            ?? _safeInt(response['new_item_id'])
            ?? _safeInt(response['id']);
        if (realId == null && response['item'] is Map) {
          realId = _safeInt((response['item'] as Map)['id']);
        }
        if (realId == null && response['items'] is List) {
          for (final it in (response['items'] as List).reversed) {
            if (it is Map && _safeInt(it['client_temp_id']) == tempId) {
              realId = _safeInt(it['id']);
              break;
            }
          }
        }
        if (realId == null || realId <= 0) return;
        final rid = realId; // closure icinde null-promotion kaybolmasin
        setState(() {
          final idx = _ticketItems.indexWhere((i) => _safeInt(i['id']) == tempId);
          if (idx >= 0) {
            _ticketItems[idx] = Map<String, dynamic>.from(_ticketItems[idx])..['id'] = realId;
          }
          // 3 Agu 2026: gecici id seciliyken sync olursa secim KAYBOLMAZ (PosOtoSecim, testli)
          _selectedItemId = PosOtoSecim.syncSonrasi(
              mevcut: _selectedItemId, tempId: tempId, realId: rid);
        });
      }).catchError((e) {
        _showError('Sunucu hatasi: $e');
        _loadTicketItems();
      });
    } catch (e) {
      _showError('Urun eklenemedi: $e');
    }
  }

  /// Seçili ürüne not ekle popup — hazır notlar + serbest yazı
  Future<void> _openNoteDialog() async {
    var item = _findSelectedItem();
    // 🔴 3 Agu 2026 (Mustafa: "not ekle calismiyor varyant ekledigim uründe").
    // SEBEP: buton `_selectedItemId != null` ile aktif oluyordu ama varyant/icerik ekrani
    // YENI KALEM ekliyor; secim eski ya da gecici (client_temp_id) kimlikte kalirsa
    // _findSelectedItem() null doner ve fonksiyon SESSIZCE return ederdi -> buton
    // tiklaniyor, hicbir sey olmuyordu. Artik: bir kez tazele, yine bulunamazsa SOYLE.
    if (item == null && _selectedItemId != null) {
      await _loadTicketItems();
      if (!mounted) return;
      item = _findSelectedItem();
    }
    if (item == null) {
      if (_selectedItemId != null) {
        _showError('Seçili ürün bulunamadı — lütfen ürüne tekrar dokunup deneyin.');
        if (mounted) setState(() => _selectedItemId = null);
      }
      return;
    }
    // Buradan sonrasi null OLAMAZ; asagidaki mevcut kod non-null bekliyor (tip daraltma).
    final Map<String, dynamic> secili = item;
    // 12 May 2026 debug: yanlis ürüne not yazma bug'i tracker
    LogService().logAction('Not dialog acildi', details: {
      'selected_item_id': _selectedItemId,
      'item_id': secili['id'],
      'item_product_id': secili['product_id'],
      'item_product_name': secili['product_name'],
      'ticket_items_count': _ticketItems.length,
      'all_items': _ticketItems.map((i) => '${i['id']}:${i['product_name']}').toList(),
    });
    final currentNote = secili['notes']?.toString() ?? '';
    final controller = TextEditingController(text: currentNote);

    // Ürünün category_id'sini bul + MUTLAK FIYAT modeli icin urun kaydini sakla
    // (kayitta baz fiyat urun kaydindan okunur: restaurant_price ?? price —
    // item.unit_price'tan TURETILMEZ, o eski ekstralarla kirlenmis olabilir)
    final productId = secili['product_id'];
    dynamic dialogProd;
    if (productId != null) {
      final allProducts = await widget.apiService.getProducts();
      dialogProd = (allProducts as List).where((p) => p['id'] == productId).firstOrNull;
    }

    // Hazir notlar (tek cagri — genel varyant/ekstra cagrilari kaldirildi, asagiya bak)
    final List predefinedNotes = await widget.apiService.getProductNotes();

    // 🔴 6 Agu 2026 — GENEL VARYANT / GENEL EKSTRA HER YERDE GIZLENDI.
    // Mustafa: "genel varyant diye bir sey olmasin artik, sadece varyantlardan
    // ilerleyecegiz. Notlara tiklandiginda sadece notlar gorunecek."
    // Gerekce: varyantlar artik URUN BAZLI gosteriliyor (varyant + coklu secim +
    // icerik ekle/cikar), notun icindeki ikinci varyant sistemi gereksiz kaldi.
    // Panel (store-hub karti) ve Web POS (ticket.js) ayni gun ayni sekilde gizlendi.
    //
    // SILME YOK: API ucu, tablo, lisans modulu ve panel sayfasi yerinde duruyor.
    // Listeler bos oldugu icin sekme butonlari cizilmez, chip secilemez, nota
    // hicbir sey eklenmez. ESKI NOTLAR KAYBOLMAZ: chip'e eslenmeyen tokenlar
    // computeFreeText() ile serbest metne duser ve aynen geri yazilir.
    //
    // ISTEK TASARRUFU: iki /active cagrisi da kaldirildi (Flutter gunde ~461 istek
    // atiyordu) — [[feedback_istek_tasariminda_minimum_is]].
    // GERI ALMA: asagidaki iki const listeyi silip Future.wait'e
    // getGlobalVariants(categoryId: ...) / getGlobalExtras(categoryId: ...)
    // cagrilarini geri ekle (categoryId = dialogProd['category_id']).
    final List globalVariants = const [];
    final List globalExtras = const [];

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final theme = Provider.of<ThemeProvider>(ctx, listen: false);
        final Set<String> selectedNotes = {};
        final Set<int> selectedVariantIds = {};
        final Set<int> selectedExtraIds = {};
        int activeTab = 0; // 0=Notlar, 1=Varyantlar, 2=Ekstralar
        double extraPrice = 0;

        if (currentNote.isNotEmpty) {
          for (var n in predefinedNotes) {
            final noteText = n['note']?.toString() ?? '';
            if (currentNote.contains(noteText)) selectedNotes.add(noteText);
          }
          for (var v in globalVariants) {
            if (currentNote.contains(v['name']?.toString() ?? '')) selectedVariantIds.add(v['id']);
          }
          for (var e in globalExtras) {
            if (currentNote.contains(e['name']?.toString() ?? '')) selectedExtraIds.add(e['id']);
          }
        }

        // 12 Haz 2026 — MUTLAK FIYAT modeli: token normalize. Flutter
        // product_detail '+Ad (+NTL)' yazar, chip etiketi 'Ad (+NTL)' —
        // bastaki '+' strip edilmezse ayni ekstra hem serbest-metin hem chip
        // olarak NOT'U CIFTLER (Web POS ticket.js normTok esleniği).
        String normTok(String s) {
          var t = s.trim();
          if (t.startsWith('+')) t = t.substring(1).trim();
          return t;
        }

        bool isChipToken(String raw) {
          final t = normTok(raw);
          if (t.isEmpty) return false;
          if (predefinedNotes.any((p) => p['note'] == t)) return true;
          if (globalVariants.any((v) => v['name'] == t || '${v['name']} (+${_safeDouble(v['price']).toStringAsFixed(0)}TL)' == t)) return true;
          if (globalExtras.any((e) => e['name'] == t || '${e['name']} (+${_safeDouble(e['price']).toStringAsFixed(0)}TL)' == t)) return true;
          return false;
        }

        // Chip'e eslenmeyen serbest-metin tokenlari (fiyat etiketleri korunur)
        String computeFreeText() => controller.text
            .split(',')
            .where((t) => t.trim().isNotEmpty && !isChipToken(t))
            .map((t) => t.trim())
            .join(', ');

        // Acilis durumu — priceDirty karsilastirmasi icin (Web POS pattern'i):
        // chip setleri + chip'e eslenmeyen serbest '(+N TL)' token toplami.
        final initialVariantIds = Set<int>.from(selectedVariantIds);
        final initialExtraIds = Set<int>.from(selectedExtraIds);
        final initialFreeSum = _sumExtraPriceTokens(computeFreeText());

        void rebuildNote(void Function(void Function()) setState) {
          final parts = <String>[];
          final freeText = computeFreeText();
          if (freeText.isNotEmpty) parts.add(freeText);
          parts.addAll(selectedNotes);
          for (var vid in selectedVariantIds) {
            final v = globalVariants.firstWhere((x) => x['id'] == vid, orElse: () => null);
            if (v != null) {
              final p = _safeDouble(v['price']);
              parts.add(p > 0 ? '${v['name']} (+${p.toStringAsFixed(0)}TL)' : v['name']);
            }
          }
          for (var eid in selectedExtraIds) {
            final e = globalExtras.firstWhere((x) => x['id'] == eid, orElse: () => null);
            if (e != null) {
              final p = _safeDouble(e['price']);
              parts.add(p > 0 ? '${e['name']} (+${p.toStringAsFixed(0)}TL)' : e['name']);
            }
          }
          controller.text = parts.join(', ');
          controller.selection = TextSelection.fromPosition(TextPosition(offset: controller.text.length));

          extraPrice = 0;
          for (var vid in selectedVariantIds) {
            final v = globalVariants.firstWhere((x) => x['id'] == vid, orElse: () => null);
            if (v != null) extraPrice += _safeDouble(v['price']);
          }
          for (var eid in selectedExtraIds) {
            final e = globalExtras.firstWhere((x) => x['id'] == eid, orElse: () => null);
            if (e != null) extraPrice += _safeDouble(e['price']);
          }
        }

        // 12 Haz 2026 — MUTLAK FIYAT modeli (F1 fix): pre-select edilmis fiyatli
        // chip'lerden extraPrice'i acilista BIR KEZ hesapla (Web POS updateUI()
        // init pattern'i). Eskiden 0 basliyordu → chip'e dokunulmadan kaydedilince
        // additive safety-net regex'i devreye girip her kayitta cift sayim yapiyordu.
        if (selectedVariantIds.isNotEmpty || selectedExtraIds.isNotEmpty) {
          rebuildNote((fn) => fn());
        }
        // Acilistaki chip toplami (baz fiyat turetme fallback'i icin)
        final initialChipsPrice = extraPrice;

        Widget buildChips(List items, Set<int> selectedIds, String nameKey, void Function(void Function()) setState) {
          return Wrap(
            spacing: 8, runSpacing: 8,
            children: items.map<Widget>((item) {
              // 🔴 6 Agu 2026 HATA DUZELTMESI (Mustafa: "genel ekstralar ve genel
              // varyantlar nota tiklandiginda ICERIKLERIYLE BERABER gozukmuyor").
              // SEBEP: 3 Agu'daki `item` -> `secili` yeniden adlandirmasi bu lambdanin
              // ICINE de sizmisti. `secili` = SECILI ADISYON KALEMI, `item` = cizilen
              // chip. Sonuc: her chip kalemin id'siyle ciziliyordu -> ad bos (kalemde
              // 'name' yok, 'product_name' var), fiyat 0, hepsi ayni id oldugu icin
              // biri secilince HEPSI isaretli gorunuyordu. Para kaybi YOK: rebuildNote
              // bu id'yi globalVariants'ta bulamadigi icin nota/fiyata hicbir sey
              // yazilmiyordu — sadece sekme kullanilamaz haldeydi.
              // Sekmeler artik gizli (asagiya bak); bu duzeltme, ozellik geri gelirse
              // kodun calisir halde olmasi icin.
              final id = item['id'] as int;
              final name = item[nameKey]?.toString() ?? '';
              final price = _safeDouble(item['price']);
              final isSelected = selectedIds.contains(id);
              // 22 May 2026: Dokunmatik POS — InkWell + min 52
              return Material(
                color: isSelected ? theme.primaryColor : Colors.grey[100],
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      if (isSelected) { selectedIds.remove(id); } else { selectedIds.add(id); }
                      rebuildNote(setState);
                    });
                  },
                  borderRadius: BorderRadius.circular(10),
                  splashColor: theme.primaryColor.withOpacity(0.3),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSelected ? theme.primaryColor : Colors.grey[300]!, width: isSelected ? 2 : 1),
                    ),
                    child: Text(
                      price > 0 ? '$name +${price.toStringAsFixed(0)}₺' : name,
                      style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        }

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Material(
              type: MaterialType.transparency,
              child: Center(
                child: Container(
                  width: 600,
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20)],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('${secili['product_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                          if (extraPrice > 0) Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                            child: Text('+${extraPrice.toStringAsFixed(0)} TL', style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Serbest not girin...',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primaryColor, width: 2)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Tab butonları
                      Row(
                        children: [
                          _buildNoteTab('Notlar (${predefinedNotes.length})', 0, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                          const SizedBox(width: 6),
                          if (globalVariants.isNotEmpty) _buildNoteTab('Varyantlar (${globalVariants.length})', 1, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                          if (globalVariants.isNotEmpty) const SizedBox(width: 6),
                          if (globalExtras.isNotEmpty) _buildNoteTab('Ekstralar (${globalExtras.length})', 2, activeTab, theme, (i) => setDialogState(() => activeTab = i)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Tab içeriği
                      Flexible(
                        child: SingleChildScrollView(
                          child: activeTab == 0
                            ? Wrap(
                                spacing: 8, runSpacing: 8,
                                children: predefinedNotes.map<Widget>((n) {
                                  final noteText = n['note']?.toString() ?? '';
                                  final isSelected = selectedNotes.contains(noteText);
                                  // 22 May 2026: Dokunmatik POS — InkWell + min 52
                                  return Material(
                                    color: isSelected ? theme.primaryColor : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(10),
                                    child: InkWell(
                                      onTap: () {
                                        setDialogState(() {
                                          if (isSelected) { selectedNotes.remove(noteText); } else { selectedNotes.add(noteText); }
                                          rebuildNote(setDialogState);
                                        });
                                      },
                                      borderRadius: BorderRadius.circular(10),
                                      splashColor: theme.primaryColor.withOpacity(0.3),
                                      child: Container(
                                        constraints: const BoxConstraints(minHeight: 52),
                                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: isSelected ? theme.primaryColor : Colors.grey[300]!, width: isSelected ? 2 : 1),
                                        ),
                                        child: Text(noteText, style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              )
                            : activeTab == 1
                              ? buildChips(globalVariants, selectedVariantIds, 'name', setDialogState)
                              : buildChips(globalExtras, selectedExtraIds, 'name', setDialogState),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox(width: 120, height: 48, child: ElevatedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
                            child: const Text('İptal', style: TextStyle(fontSize: 16)),
                          )),
                          const SizedBox(width: 8),
                          SizedBox(width: 150, height: 48, child: ElevatedButton(
                            onPressed: () {
                              // 12 Haz 2026 MUTLAK FIYAT: fiyat ogeleri degisti mi?
                              // Degismediyse kaydetmede unit_price GONDERILMEZ
                              // (backend COALESCE eski fiyati korur).
                              final freeSum = _sumExtraPriceTokens(computeFreeText());
                              final varSame = selectedVariantIds.length == initialVariantIds.length &&
                                  selectedVariantIds.containsAll(initialVariantIds);
                              final extSame = selectedExtraIds.length == initialExtraIds.length &&
                                  selectedExtraIds.containsAll(initialExtraIds);
                              final priceDirty = !(varSame && extSame && (freeSum - initialFreeSum).abs() < 0.001);
                              Navigator.pop(ctx, {
                                'note': controller.text,
                                'extraPrice': extraPrice,
                                'freeSum': freeSum,
                                'priceDirty': priceDirty,
                                'initialChipsPrice': initialChipsPrice,
                                'initialFreeSum': initialFreeSum,
                              });
                            },
                            style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, foregroundColor: Colors.white),
                            child: Text(extraPrice > 0 ? 'Kaydet (+${extraPrice.toStringAsFixed(0)}₺)' : 'Kaydet', style: const TextStyle(fontSize: 16)),
                          )),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null) return;

    try {
      final itemId = _safeInt(secili['id']);
      final ticketId = widget.ticketId;
      if (itemId == null) return;

      final note = result['note'] as String? ?? '';
      final chipsPrice = result['extraPrice'] as double? ?? 0;
      final freeSum = result['freeSum'] as double? ?? 0;
      final priceDirty = result['priceDirty'] as bool? ?? true;

      final currentUnitPrice = _safeDouble(secili['unit_price']);

      // 12 Haz 2026 — MUTLAK FIYAT modeli (F1/F2 fix, Web POS ticket.js ile ayni):
      // - Fiyat ogesi DEGISMEDIYSE unit_price gonderilmez → backend COALESCE
      //   eski fiyati korur (manuel ozel fiyat + mevcut ekstra ucreti bozulmaz).
      // - DEGISTIYSE fiyat SIFIRDAN kurulur: baz (urun kaydi restaurant_price
      //   ?? price) + secili chip toplami + chip'e eslenmeyen serbest '(+N TL)'
      //   token toplami. Eski ADDITIVE model (currentUnitPrice + delta) her
      //   kayitta cift sayim yapiyordu (350→360→370) — kaldirildi. Ekstra
      //   kaldirilinca da fiyat artik DUSER (eskiden COALESCE eski fiyati
      //   tutuyordu, iz birakmayan fazla tahsilat).
      // 🔴 6 Agu 2026 — VARYANT FARKI YUTULUYORDU (para kaybi, iz birakmayan).
      // `base` urun kaydinin HAM fiyati; kalemin varyant/coklu secim farki ise
      // `extras`'ta durur ve unit_price'in icindedir. Eskiden fiyat sifirdan
      // kurulurken extras HIC eklenmiyordu:
      //   baz 200 + "Buyuk" +50 = 250 TL kalem. Kasiyer nota "(+20TL)" yazinca
      //   -> 200 + 0 + 20 = 220 TL. Varyantin 50 TL'si UCUYORDU.
      // Not: extras fiyatlari ile nottaki '(+N TL)' tokenlari AYRIK kumeler
      // (varyant akisi nota fiyat yazmaz) — ikisini toplamak cift sayim degil.
      double? newUnitPrice;
      if (priceDirty) {
        final kalemExtras = _sumExtrasPrices(secili['extras']);
        double base = 0;
        if (dialogProd != null) {
          base = _safeDouble(dialogProd['restaurant_price'] ?? dialogProd['price']);
        }
        if (base > 0) {
          newUnitPrice = base + kalemExtras + chipsPrice + freeSum;
        } else {
          // Urun kaydi bulunamadiysa baz'i mevcut fiyattan turet:
          // acilista bilinen fiyat ogelerini (chip + serbest token) dus.
          // ⚠️ Bu dalda `extras` EKLENMEZ: currentUnitPrice zaten iceriyor,
          // tekrar eklemek cift sayim olurdu.
          final initialChipsPrice = result['initialChipsPrice'] as double? ?? 0;
          final initialFreeSum = result['initialFreeSum'] as double? ?? 0;
          base = currentUnitPrice - initialChipsPrice - initialFreeSum;
          if (base < 0) base = currentUnitPrice;
          newUnitPrice = base + chipsPrice + freeSum;
        }
      }

      // 12 May 2026 debug: hangi item'a not yazildi
      LogService().logAction('Not API cagirildi', details: {
        'ticket_id': ticketId,
        'item_id': itemId,
        'item_product_name': item['product_name'],
        'note': note,
        'chips_price': chipsPrice,
        'free_sum': freeSum,
        'price_dirty': priceDirty,
        'new_unit_price': newUnitPrice,
      });

      // 🔴 3 Agu 2026 — YAZDIRILMIS / COMBO KALEMDE FIYAT GONDERILMEZ.
      // Denetim bulgusu: varyant butonuna koydugumuz kilit BURADA YOKTU; "Not Ekle"
      // penceresindeki global varyant/ekstra cipleri fiyati degistirip gonderiyordu,
      // yani mutfaga GITMIS urunun fiyati bu yoldan degistirilebiliyordu.
      // Mustafa kurali: "bir kanaldaki bugi TUM kanallarda ara."
      //
      // KAPSAM (6 Agu 2026 GUNCELLENDI): eskiden "not yazma serbest, sadece fiyat
      // engellenir" idi. Mustafa yeni kural koydu — yazdirilmis kalemde NOT DA
      // degistirilemez (asagidaki bloga bak). Fiyat farki hesabina artik gerek yok:
      // fis ciktiysa istek zaten hic gonderilmiyor.
      final _kalemK = _findSelectedItem() ?? _ticketItems.where((i) => _safeInt(i['id']) == itemId).firstOrNull;
      final bool _fisCiktiK = _kalemK != null && (_kalemK['printed'] == 1 || _kalemK['printed'] == true);
      final bool _comboK = _kalemK != null &&
          (_kalemK['combo_group_id']?.toString().trim().isNotEmpty ?? false);

      // 🔴 6 Agu 2026 — YAZDIRILMIS KALEMDE HICBIR DEGISIKLIK KABUL EDILMEZ (NOT DAHIL).
      // Mustafa kurali: "notu degistirirsen 'ben bunu girdim baska cikti' derler."
      // Mutfaga BASILI fis gitti; kayittaki not ile mutfagin elindeki fis AYNI kalmali.
      // Notu sonradan degistirmek kaydi fisten AYIRIR -> tartisma cikar.
      // Bu yuzden istek HIC GONDERILMEZ; kullaniciya ne yapacagi soylenir.
      //
      // ⚠️ Onceki hali sadece FIYATI engelliyordu, notu kaydediyordu. Ayrica sunucu
      // (panel-direct/tickets.js:424) not-only degisikligi HALA kabul ediyor — burasi
      // kullanici kapisi. Baska bir istemci ayni seyi yaparsa sunucu izin verir;
      // istenirse orasi da kapatilmali (ayri karar).
      if (_fisCiktiK || _comboK) {
        _showError(_fisCiktiK
            ? 'Yazdırılan ürünün içeriği düzeltilemez. Ürünü iptal ederek tekrar girebilirsiniz.'
            : 'Bu ürün bir combo paketinin parçası — içeriği tek başına düzeltilemez. '
              'Paketi iptal ederek tekrar oluşturabilirsiniz.');
        return;
      }

      await widget.apiService.updateTicketItem(
        ticketId: ticketId,
        itemId: itemId,
        notes: note,
        unitPrice: newUnitPrice,
      );

      await _loadTicketItems();
      widget.onItemAdded();
    } catch (e) {
      // 6 Agu 2026 — SON SAVUNMA: sunucunun icerik kilidi (400) kullaniciya HAM
      // DioException olarak yansiyordu ("Not eklenemedi: DioException [bad response]...").
      // Yukaridaki on kapi bu durumu artik onluyor ama bir yol daha acilirsa (baska
      // ekran, eski surum, yaris) kullanici anlamli uyari gormeli — teknik cop degil.
      final bool _icerikKilidi = e is DioException &&
          e.response?.statusCode == 400 &&
          (e.response?.data is Map) &&
          ((e.response!.data as Map)['kilit'] == 'printed' ||
           (e.response!.data as Map)['kilit'] == 'combo');
      if (_icerikKilidi) {
        final bool _printed = (e as DioException).response!.data['kilit'] == 'printed';
        _showError(_printed
            ? 'Yazdırılan ürünün içeriği düzeltilemez. Ürünü iptal ederek tekrar girebilirsiniz.'
            : 'Bu ürün bir combo paketinin parçası — içeriği tek başına düzeltilemez. '
              'Paketi iptal ederek tekrar oluşturabilirsiniz.');
      } else {
        _showError('Not eklenemedi: $e');
      }
    }
  }

  Widget _buildNoteTab(String label, int index, int activeTab, ThemeProvider theme, void Function(int) onTap) {
    // 22 May 2026: Dokunmatik POS — Material+InkWell (ripple)
    final isActive = activeTab == index;
    return Expanded(
      child: Material(
        color: isActive ? theme.primaryColor : Colors.grey[100],
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => onTap(index),
          borderRadius: BorderRadius.circular(10),
          splashColor: theme.primaryColor.withOpacity(0.25),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: isActive ? null : Border.all(color: Colors.grey[300]!),
            ),
            child: Center(child: Text(label, style: TextStyle(color: isActive ? Colors.white : Colors.grey[700], fontSize: 14, fontWeight: FontWeight.w600))),
          ),
        ),
      ),
    );
  }

  /// Ürün iptal — sebep seçimi zorunlu
  Future<void> _cancelSelectedItem() async {
    final item = _findSelectedItem();
    if (item == null) return;
    final itemId = _safeInt(item['id']);
    if (itemId == null) return;

    // 23 May 2026: Iki kademeli iptal yetkisi
    //  - cancel_item: HER turlu urun iptal (mutfaga gitmis dahil)
    //  - cancel_item_unprinted: SADECE mutfaga gitmemis (printed=0)
    // Mutfaga gitmis urun iptal etmek icin cancel_item GEREKLI.
    final isPrinted = item['printed'] == 1 || item['printed'] == true;
    final hasFullCancel = _hasPermission('cancel_item');
    final hasUnprintedCancel = _hasPermission('cancel_item_unprinted');
    if (isPrinted && !hasFullCancel) {
      _showError('Mutfağa gitmiş bir fişi iptal etme yetkiniz bulunmamaktadır.');
      return;
    }
    if (!isPrinted && !hasFullCancel && !hasUnprintedCancel) {
      _showError('Ürün iptal etme yetkiniz bulunmamaktadır.');
      return;
    }

    // =========================================================================
    // 1 Agu 2026 — COMBO PAKETI PARCALI IPTAL EDILEMEZ (Fable denetimi, bulgu ①)
    // Combo paketinin fiyati uyelere BOLUNEREK yazilir (splitComboPackagePrice).
    // Tek uye iptal edilirse kalan uyeler bolunmus fiyatta kalir -> paket bedeli
    // orantisiz duser. Ozellikle `extra` modda artik hediye de FIZIKSEL satir ve
    // mutfaga gidiyor: mutfak 3 urunu yaptiktan sonra bir satir iptal edilirse
    // musteri 3 urun alip 2 urun parasi oder (ciro kaybi).
    // KURAL: paketin bir uyesi iptal edilecekse PAKETIN TAMAMI iptal edilir.
    // ⚠️ YETKI KONTROLLERI YUKARIDA, DEGISMEDI. Grup yoksa akis BIREBIR eskisi gibi.
    // =========================================================================
    final gid = (item['combo_group_id'] ?? '').toString().trim();
    var iptalKalemleri = <Map<String, dynamic>>[item];
    if (gid.isNotEmpty) {
      iptalKalemleri = _ticketItems
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) =>
              (e['combo_group_id'] ?? '').toString().trim() == gid &&
              (e['status'] ?? 'active').toString() != 'cancelled')
          .toList();
      if (iptalKalemleri.isEmpty) iptalKalemleri = [item];
      if (iptalKalemleri.length > 1) {
        final paketAdi = (item['combo_group_name'] ?? item['product_name'] ?? 'Combo')
            .toString();
        final onay = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: Row(children: [
              Icon(Icons.card_giftcard_rounded, color: Colors.orange[800]),
              const SizedBox(width: 8),
              const Expanded(child: Text('Combo Paketi', style: TextStyle(fontSize: 17))),
            ]),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('"$paketAdi" combo paketinin parçası (${iptalKalemleri.length} ürün).',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                'Paketin fiyatı ürünlere bölünerek yazıldığı için tek ürün iptal edilemez — '
                'kalan ürünler eksik fiyatta kalır. Devam ederseniz PAKETİN TAMAMI iptal edilir.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                    color: Colors.orange[50], borderRadius: BorderRadius.circular(8)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final k in iptalKalemleri)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text('• ${(k['product_name'] ?? '').toString()}',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                ]),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Paketin tamamını iptal et',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (onay != true) return;
      }
    }

    // 1 Haz 2026 (v1.5.6): Mutfağa GİTMEMİŞ ürün iptalinde uyarı YOK.
    //  - printed=0 → direkt sil, reason='Mutfağa gönderilmedi' otomatik
    //  - printed=1 → mevcut sebep seçme dialog'u (panel_pos_cancel_reasons)
    String? selectedReason;
    if (!isPrinted) {
      selectedReason = 'Mutfağa gönderilmedi';
    } else {
      // İptal sebeplerini API'den çek (mutfağa gitmiş ürün)
      final reasons = await widget.apiService.getCancelReasons();

      if (!mounted) return;

      selectedReason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Provider.of<ThemeProvider>(ctx, listen: false);
        String? picked;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Material(
              type: MaterialType.transparency,
              child: Center(
                child: Container(
                  width: 450,
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20)],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.cancel, color: Colors.red, size: 24),
                          const SizedBox(width: 8),
                          Expanded(child: Text('${item['product_name']} - İptal Sebebi', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Lütfen iptal sebebini seçin', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                      const SizedBox(height: 16),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: reasons.map<Widget>((r) {
                              final reason = r['reason']?.toString() ?? '';
                              final isSelected = picked == reason;
                              // 22 May 2026: Dokunmatik POS — InkWell + min 48
                              return Material(
                                color: isSelected ? Colors.red : Colors.grey[100],
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  onTap: () => setDialogState(() => picked = reason),
                                  borderRadius: BorderRadius.circular(8),
                                  splashColor: Colors.red.withOpacity(0.3),
                                  child: Container(
                                    constraints: const BoxConstraints(minHeight: 48),
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: isSelected ? Colors.red : Colors.grey[300]!, width: isSelected ? 2 : 1),
                                    ),
                                    child: Text(reason, style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                          const SizedBox(width: 8),
                          // 22 May 2026: Dokunmatik POS — GestureDetector → ElevatedButton (tema'dan otomatik 56 yukseklik + ripple)
                          ElevatedButton(
                            onPressed: picked != null ? () => Navigator.pop(ctx, picked) : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey[300],
                              disabledForegroundColor: Colors.grey[500],
                            ),
                            child: const Text('İptal Et', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    } // else: printed=1 sebep seçme bloğu sonu

    if (selectedReason == null) return;

    // 1 Agu 2026: combo paketinde BIRDEN COK kalem iptal edilir; tek kalemde liste
    // 1 elemanlidir ve akis BIREBIR eskisi gibi calisir (0 regresyon).
    final idler = <int>[];
    for (final k in iptalKalemleri) {
      final kid = _safeInt(k['id']);
      if (kid != null && !idler.contains(kid)) idler.add(kid);
    }
    if (idler.isEmpty) idler.add(itemId);

    var basarili = 0;
    var fisBasildi = 0;
    var fisGerekti = 0;
    Object? ilkHata;

    for (final kid in idler) {
      try {
        // 16 May 2026: Backend cancel_print payload'u döner (printed=1 + printer_ip varsa)
        // Mevcut mutfak fiş akışı bozulmadı, sadece response'a ek field eklendi.
        final cancelResponse = await widget.apiService.deleteTicketItem(
          ticketId: widget.ticketId,
          itemId: kid,
          cancelReason: selectedReason,
          waiterId: widget.waiterId,
        );
        basarili++;

        // Backend "cancel_print" payload döndüyse → mutfağa iptal fişi bas
        final cancelPrint = (cancelResponse is Map) ? cancelResponse['cancel_print'] : null;
        if (cancelPrint != null) {
          fisGerekti++;
          if (widget.printerService != null) {
            try {
              final now = DateTime.now();
              final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
              final ok = await widget.printerService!.printCancelItem(
                productName: (cancelPrint['product_name'] ?? '').toString(),
                quantity: _safeInt(cancelPrint['quantity']) ?? 1,
                notes: (cancelPrint['notes'] ?? '').toString(),
                tableName: (cancelPrint['table_name'] ?? '').toString(),
                waiterName: (cancelPrint['waiter_name'] ?? widget.waiter?['name'] ?? 'Garson').toString(),
                reason: selectedReason,
                timeStr: timeStr,
                printerIp: cancelPrint['printer_ip']?.toString(),
                printerPort: _safeInt(cancelPrint['printer_port']),
              );
              if (ok) fisBasildi++;
            } catch (e) {
              print('[Cancel] İptal fişi yazılamadı: $e');
            }
          }
        }
      } catch (e) {
        ilkHata ??= e;
        // Paketin kalan kalemlerini denemeye DEVAM et — yarim iptal birakma.
      }
    }

    setState(() => _selectedItemId = null);
    await _loadTicketItems();
    widget.onItemAdded();

    if (basarili == 0) {
      _showError('Ürün iptal edilemedi: ${ilkHata ?? 'bilinmeyen hata'}');
      return;
    }
    if (ilkHata != null) {
      // Paketin bir kismi iptal EDILEMEDI — kasiyer MUTLAKA gormeli (tutar yanlis kalir).
      _showError('DİKKAT: paketin $basarili/${idler.length} ürünü iptal edildi, '
          'kalanı iptal EDİLEMEDİ. Adisyonu kontrol edin. Hata: $ilkHata');
      return;
    }
    final coklu = idler.length > 1;
    final onEk = coklu ? 'Combo paketi (${idler.length} ürün) iptal edildi' : 'Ürün iptal edildi';
    _showSuccess(fisGerekti == 0
        ? '$onEk: $selectedReason'
        : (fisBasildi == fisGerekti
            ? '$onEk + mutfağa iptal fişi gönderildi: $selectedReason'
            : '$onEk (iptal fişi yazıcıya ulaşamadı: $fisBasildi/$fisGerekti): $selectedReason'));
  }

  /// Mutfağa gönder — 12 May 2026: v1.2.0 atomik akisa GERI SARILDI.
  /// Backend printKitchen anlik printed=1 SET eder. Yazici fail olsa bile DB tutarli.
  /// (dry_run + mark/unmark 3-step flow: race condition + cift fis fix.)
  Future<void> _sendToKitchen() async {
    if (widget.printerService == null) return;

    try {
      // Race condition guard (pending addItem'lar commit olsun)
      await Future.delayed(const Duration(milliseconds: 500));

      final result = await widget.apiService.printKitchen(
        ticketId: widget.ticketId,
        waiterId: widget.waiterId,
        expectedTableId: widget.table?['id'] as int?, // 6 Tem 2026 DÜZELTME 1: yanlis-masa fis guard
      );
      if (result['success'] != true) {
        _showError(result['error'] ?? 'Mutfak fişi alınamadı');
        return;
      }
      final items = result['items'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};

      ticketInfo['table_number'] = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';
      ticketInfo['section_name'] = widget.table?['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter?['name'] ?? '';
      // 6 Tem 2026 (offline fix Adim 4b): table_id'yi de ekle -> print_queue'ya yazilir ->
      // offline'da masa kartinda "FIS CIKMADI" badge'i icin masa eslesmesi yapilabilir.
      if (widget.table?['id'] != null) ticketInfo['table_id'] = widget.table!['id'];

      // 21 May 2026: Yazıcı atanmamış ürünler için uyarı (backend response).
      // Backend printKitchen artık unassigned_items: [{id, product_name}] döner —
      // yönetici ürün ayarlarından düzeltir, garson görsel uyarı alır (4 sn turuncu snackbar).
      final unassigned = result['unassigned_items'] as List? ?? [];
      if (unassigned.isNotEmpty && mounted && context.mounted) {
        final names = unassigned.map((u) => u is Map ? (u['product_name'] ?? '?') : '?').join(', ');
        // 18 Tem 2026: ScaffoldMessenger.of(context) dispose olmuş context'te Flutter içindeki '!'
        // ile "Null check operator used on a null value" fırlatabilir → try/catch + overlay fallback
        // (_showError/_showSuccess ile aynı desen). context.mounted guard + izolasyon.
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠ ${unassigned.length} ürün yazıcısız basılmadı: $names'),
              backgroundColor: Colors.orange.shade700,
              duration: const Duration(seconds: 4),
            ),
          );
        } catch (_) {
          _showOverlayMessage('⚠ ${unassigned.length} ürün yazıcısız basılmadı: $names', Colors.orange.shade700);
        }
      }

      if (items.isEmpty) {
        _showSuccess('Yazdırılacak yeni ürün yok');
        return;
      }

      final List<String> failReasons = [];
      int successCount = 0;
      int failCount = 0;
      final List<int> successJobIds = [];
      final List<int> failJobIds = [];
      // 18 May 2026: Failed groups pop-up icin
      final List<Map<String, dynamic>> failedGroupsForRetry = [];

      final printerGroups = result['printerGroups'] as List? ?? [];
      final Map<String, List<Map<String, dynamic>>> byIpMap = {};
      for (final g in printerGroups) {
        final group = (g as Map).cast<String, dynamic>();
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty) continue;
        final ip = (group['printer_ip'] as String?)?.trim();
        final key = (ip == null || ip.isEmpty) ? '__default__' : ip;
        byIpMap.putIfAbsent(key, () => []).add(group);
      }

      final perBucket = await Future.wait(byIpMap.values.map((sameIpGroups) async {
        final out = <Map<String, dynamic>>[];
        for (final group in sameIpGroups) {
          final printerIp = group['printer_ip'] as String?;
          final printerPort = group['printer_port'] as int? ?? 9100;
          final groupItems = group['items'] as List? ?? [];
          bool ok = false;
          try {
            if (printerIp != null && printerIp.isNotEmpty) {
              ok = await widget.printerService!.printKitchenReceiptToIp(
                ticket: ticketInfo, items: groupItems, ip: printerIp, port: printerPort,
              );
            } else {
              ok = await widget.printerService!.printKitchenReceipt(
                ticket: ticketInfo, items: groupItems,
              );
            }
          } catch (_) {
            ok = false;
          }
          out.add({'group': group, 'ok': ok});
        }
        return out;
      }));

      for (final bucket in perBucket) {
        for (final r in bucket) {
          final group = r['group'] as Map<String, dynamic>;
          final ok = r['ok'] as bool;
          final printerIp = group['printer_ip'] as String?;
          final printerPort = group['printer_port'] as int? ?? 9100;
          final groupItems = group['items'] as List? ?? [];
          final printerName = group['printer_name'] as String? ?? 'Varsayilan';
          final jobId = _safeInt(group['job_id']);

          if (ok) {
            successCount += groupItems.length;
            if (jobId != null) successJobIds.add(jobId);
          } else {
            failCount += groupItems.length;
            if (jobId != null) failJobIds.add(jobId);
            failReasons.add(printerName);
            // Sag ust yazici kuyruguna ekle (arka plan auto-retry baslatir)
            int? queueJobId;
            // Retry kuyrugu icin IP cozumle. Grup IP'si varsa onu kullan; YOKSA (urun yazicisi
            // atanmamis -> default yaziciya basildi) default mutfak yazicisinin IP'sini kullan.
            String? retryIp = (printerIp != null && printerIp.isNotEmpty) ? printerIp : null;
            int retryPort = printerPort;
            if (retryIp == null) {
              // 6 Tem 2026 (offline fix Adim 4): SESSIZ FIS KAYBI onleme. Eskiden printer_ip=null
              // grubu fail olunca enqueue ATLANIYORDU -> item printed=1 kalir, hicbir kuyrukta
              // olmaz = sessiz kayip. Simdi default mutfak yazicisinin IP'siyle kuyruga alinir.
              final defCfg = widget.printerService!.getKitchenPrinterConfig();
              if (defCfg != null) {
                retryIp = defCfg['ip'] as String?;
                retryPort = defCfg['port'] as int? ?? printerPort;
              }
            }
            if (retryIp != null && retryIp.isNotEmpty) {
              queueJobId = await widget.printerService!.enqueueKitchenForRetry(
                ip: retryIp,
                port: retryPort,
                printerName: printerName,
                ticketInfo: ticketInfo,
                items: groupItems,
                serverJobId: jobId,             // Faz 2: basinca sunucuya rapor
                serverTicketId: widget.ticketId, // Faz 2
              );
            }
            failedGroupsForRetry.add({
              'printer_ip': printerIp,
              'printer_port': printerPort,
              'printer_name': printerName,
              'items': groupItems,
              'job_id': jobId,
              'queue_job_id': queueJobId,
            });
          }
        }
      }

      // Telemetri: print_jobs lifecycle (dashboard "stuck" fix)
      if (successJobIds.isNotEmpty) {
        widget.apiService.markItemsPrinted(
          ticketId: widget.ticketId, itemIds: const [], jobIds: successJobIds,
        ).catchError((_) => false);
      }
      if (failJobIds.isNotEmpty) {
        widget.apiService.unmarkItemsPrinted(
          ticketId: widget.ticketId, itemIds: const [], jobIds: failJobIds, error: 'TCP unreachable',
        ).catchError((_) => false);
      }

      // Admin panel POS Loglari icin ozet
      final tableLabel = widget.table?['table_number']?.toString() ?? 'Masa ${widget.table?['id'] ?? ''}';
      if (failCount > 0) {
        // 19 May 2026: Inline retry sonrasi hala fail → kuyruga aliniyor, retry edilecek.
        // Bu DOGRU bir error — manuel mudahale gerekebilir (ozellikle yazici fiziken kapaliysa).
        LogService().error(
          LogType.error,
          'Mutfak fisi $failCount yaziciya gonderilemedi (kuyrukta retry edilecek): Masa $tableLabel',
          details: {
            'ticket_id': widget.ticketId,
            'table': tableLabel,
            'printed_count': successCount,
            'failed_count': failCount,
            'failed_printers': failReasons,
            'action': 'queued_for_retry',
          },
        );
      } else if (successCount > 0) {
        LogService().logAction(
          'Mutfak fisi basildi (add): $tableLabel — $successCount urun',
          details: {
            'ticket_id': widget.ticketId,
            'table': tableLabel,
            'printed_count': successCount,
          },
        );
      }

      // 18 May 2026: Yazici fail varsa POP-UP ac (snackbar yerine). Backend printed=1
      // SET ettigi icin pop-up'taki "Tekrar Yazdir" SADECE TCP retry yapar — mukerrer fis riski yok.
      // 18 Tem 2026: context.mounted guard — race+dispose (aksam yogun: auto-refresh/WebSocket masa
      // guncellemesi modal'i kapatip widget'i dispose edince) showDialog/Navigator.of(context) dispose
      // olmus context'te Flutter icindeki '!' → "Null check operator" firlatiyordu → yanlis "Mutfaga
      // gonderilemedi" pop-up (fis aslinda basildi, printed=1). Basim karari DEGISMEZ, sadece dispose
      // aninda context erisimi atlanir (o modal zaten gorunemezdi). onClose da mounted-guard'landi.
      if (failedGroupsForRetry.isNotEmpty && mounted) {
        if (context.mounted) {
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => KitchenPrintRetryModal(
              printerService: widget.printerService!,
              apiService: widget.apiService,
              ticketId: widget.ticketId,
              ticketInfo: ticketInfo,
              failedGroups: failedGroupsForRetry,
            ),
          );
        }
        // Modal kapandiktan sonra ekrani da kapat — kullanici durumu gordu
        if (mounted) widget.onClose();
      } else {
        if (mounted) widget.onClose();
      }
    } catch (e, st) {
      _showError('Mutfağa gönderilemedi: $e');
      // 17 Tem 2026: stackTrace eklendi — "Null check operator used on a null value" seyrek (7g 16 kez)
      // ama tam satırı bilinmiyor; stack trace ilk 10 satır loglanır (LogService kırpıyor) → kök neden bulunur.
      LogService().error(
        LogType.error,
        'Mutfak fisi exception (add): $e',
        details: {'ticket_id': widget.ticketId},
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Yazdır
  Future<void> _printTicket() async {
    print('[AddItemModal] _printTicket: printerService=${widget.printerService != null}, tableId=${widget.tableId}');
    if (widget.printerService == null) return;
    try {
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      print('[AddItemModal] _printTicket ticketData: ${ticketData != null}');
      if (ticketData == null) return;
      final ticket = ticketData['ticket'] as Map<String, dynamic>?;
      print('[AddItemModal] _printTicket ticket: ${ticket != null}, items: ${ticket?['items']?.length}');
      if (ticket == null) return;

      final ticketToPrint = Map<String, dynamic>.from(ticket);
      final sectionName = widget.table?['section_name'] ?? '';
      final tableNumber = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';
      ticketToPrint['table_name'] = '$sectionName - $tableNumber';
      ticketToPrint['waiter_name'] = widget.waiter?['name'] ?? '';

      final success = await widget.printerService!.printTicket(ticketToPrint);
      if (success) {
        _showSuccess('Fiş yazdırıldı');
      } else {
        _showError('Yazıcı hatası');
      }
    } catch (e) {
      _showError('Yazdır hatası: $e');
    }
  }

  /// Hesap kapat — tüm ürünleri ödeyerek kapat.
  /// methodLabel: dinamik ödeme yönteminin görünen adı (nakit/kart dışı için doğru etiket).
  Future<void> _closeTicket(String paymentMethod, {String? methodLabel}) async {
    // Ödenmemiş ürünleri bul
    await _loadTicketItems();
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    // 3 Agu 2026 IKRAM: ikram kalemler payItems'a GONDERILMEZ (parasi alinmayacak) —
    // backend close() ikram dusumunu kendisi authoritative yapar. Ikram haric tum
    // kalemler odendiyse dogrudan close'a duser (asagidaki unpaidIds.isEmpty dali).
    final unpaidItems = activeItems
        .where((i) => i['payment_status'] != 'paid' && !IkramRules.kalemIkramMi(i))
        .toList();
    final unpaidIds = unpaidItems.map((i) => (i['id'] as num).toInt()).toList();

    if (unpaidIds.isEmpty) {
      // Tüm ürünler zaten ödendi, direkt kapat
      try {
        await widget.apiService.closeTicket(
          ticketId: widget.ticketId,
          paymentMethod: paymentMethod,
          waiterId: widget.waiterId,
        );
        _showSuccess('Hesap kapatıldı');
        widget.onItemAdded();
        widget.onClose();
      } catch (e) {
        _showError('Hesap kapatılamadı: $e');
      }
      return;
    }

    // methodLabel verilmişse onu kullan (dinamik yöntem); yoksa built-in nakit/kart etiketi.
    final label = methodLabel ?? (paymentMethod == 'cash' ? 'Nakit' : 'Kredi Kartı');
    double unpaidTotal = 0;
    for (var item in unpaidItems) {
      unpaidTotal += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesap Kapat', style: TextStyle(fontSize: 22)),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve hesap kapatılacak.\n\nDevam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            width: 150, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('İptal', style: TextStyle(fontSize: 18)),
            ),
          ),
          SizedBox(
            width: 200, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white),
              child: const Text('Öde ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // OFFLINE: parçalı ödeme (payItems) yok. Tüm ürünler tek ödeme yöntemiyle kapanır (closeTicket
    // offline'ı destekler). payItems'a düşersek "internet gerekli" der -> offline nakit/kart imkansız olurdu.
    if (!widget.apiService.isOnline) {
      try {
        // COMBO OFFLINE (Mustafa: offline'da combo UYGULANSIN): backend yok -> combo indirimini POS
        // uygula. calcCartCombos indirimi (yuzde/sabit/hediye-within) + mevcut manuel indirim toplanip
        // discountAmount olarak gecer. closeLocalTicket total=subtotal-discountAmount yazar. Online'da
        // backend close kendi hesaplar (bu dala GIRMEZ). Paket-bolme kalem fiyatinda; combo indirimi
        // AYRI (calcCartCombos paket-bolunmus kalemlerden yuzde/sabit hesaplar). Cift degil: bolme=fiyat,
        // indirim=yuzde/sabit ustune (panel/web birebir).
        final offlineDiscount = _ticketDiscount + _comboDiscount;
        await widget.apiService.closeTicket(
          ticketId: widget.ticketId,
          paymentMethod: paymentMethod,
          discountAmount: offlineDiscount,
          discountType: _comboDiscount > 0 ? 'amount' : _ticketDiscountType,
          waiterId: widget.waiterId,
        );
        _showSuccess('Hesap kapatıldı (çevrimdışı)');
        widget.onItemAdded();
        widget.onClose();
      } catch (e) {
        _showError('Hesap kapatılamadı: $e');
      }
      return;
    }

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: unpaidIds,
        paymentMethod: paymentMethod,
        waiterId: widget.waiterId,
      );

      if (result['success'] == true) {
        // Ödeme başarılı, şimdi ticket'ı kapat
        await widget.apiService.closeTicket(
          ticketId: widget.ticketId,
          paymentMethod: paymentMethod,
          waiterId: widget.waiterId,
        );
        _showSuccess('Hesap kapatıldı');
        widget.onItemAdded();
        widget.onClose();
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Hesap kapatılamadı: $e');
    }
  }

  /// Yazdır + kapat
  Future<void> _printAndCloseTicket(String paymentMethod) async {
    final label = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Karti';
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Yazdır ve Kapat', style: TextStyle(fontSize: 22)),
        content: Text('$label ile hesap kapatılacak ve fiş yazdırılacak. Devam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            width: 150, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87),
              child: const Text('İptal', style: TextStyle(fontSize: 18)),
            ),
          ),
          SizedBox(
            width: 200, height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white),
              child: const Text('Yazdır ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (widget.printerService != null) {
        // 1. Mutfağa gönder (yazdırılmamış ürünler varsa)
        try { await _sendToKitchenSilent(); } catch (_) {}
        // 2. Adisyon fişi yazdır (varsayılan yazıcıya)
        try { await _printTicket(); } catch (_) {}
        // 3. Salon özet fişi (salon yazıcısı tanımlıysa)
        try { await _printSummaryReceipt(paymentMethod); } catch (_) {}
      }

      // COMBO OFFLINE: offline kapanista combo+manuel indirimi gecir (backend yok). Online'da backend
      // close kendi hesaplar -> discount gecirme (cift olmasin). _closeTicket ile ayni mantik.
      final offline = !widget.apiService.isOnline;
      await widget.apiService.closeTicket(
        ticketId: widget.ticketId,
        paymentMethod: paymentMethod,
        discountAmount: offline ? (_ticketDiscount + _comboDiscount) : 0,
        discountType: offline ? (_comboDiscount > 0 ? 'amount' : _ticketDiscountType) : null,
        waiterId: widget.waiterId,
      );

      _showSuccess('Hesap kapatıldı');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Hesap kapatılamadı: $e');
    }
  }

  /// Sessiz mutfak gonderimi — 12 May 2026: v1.2.0 atomik akisa GERI SARILDI.
  /// Backend printKitchen anlik printed=1 SET eder. Yazici fail olsa bile DB tutarli.
  /// UI feedback yok (silent — orn. urun ekledikten sonra otomatik); LogService'e telemetri.
  Future<void> _sendToKitchenSilent() async {
    if (widget.printerService == null) return;
    try {
      // Race condition guard (pending addItem'lar commit olsun)
      await Future.delayed(const Duration(milliseconds: 500));

      final result = await widget.apiService.printKitchen(
        ticketId: widget.ticketId,
        waiterId: widget.waiterId,
        expectedTableId: widget.table?['id'] as int?, // 6 Tem 2026 DÜZELTME 1: yanlis-masa fis guard
      );
      if (result['success'] != true) return;
      final printerGroups = result['printerGroups'] as List? ?? [];
      final ticketInfo = result['ticket'] as Map<String, dynamic>? ?? {};
      ticketInfo['table_number'] = widget.table?['table_number'] ?? '';
      ticketInfo['section_name'] = widget.table?['section_name'] ?? '';
      ticketInfo['waiter_name'] = widget.waiter?['name'] ?? '';

      int successCount = 0;
      int failCount = 0;
      final List<String> failReasons = [];
      final List<int> successJobIds = [];
      final List<int> failJobIds = [];
      // 18 May 2026: Silent path da fail varsa pop-up acar
      final List<Map<String, dynamic>> failedGroupsForRetry = [];

      // 🟠 6 Tem 2026 FINAL-FIX C: null-IP grubu sessizce atlanmasin (kalici fis kaybi onleme —
      // ticket_modal silent yolu ile ayni duzeltme).
      final Map<String, List<Map<String, dynamic>>> byIpMap = {};
      for (final g in printerGroups) {
        final group = (g as Map).cast<String, dynamic>();
        final groupItems = group['items'] as List? ?? [];
        if (groupItems.isEmpty) continue;
        final ip = (group['printer_ip'] as String?)?.trim();
        final key = (ip == null || ip.isEmpty) ? '__default__' : ip;
        byIpMap.putIfAbsent(key, () => []).add(group);
      }

      final perBucket = await Future.wait(byIpMap.values.map((sameIpGroups) async {
        final out = <Map<String, dynamic>>[];
        for (final group in sameIpGroups) {
          final printerIp = group['printer_ip'] as String?;
          final printerPort = group['printer_port'] as int? ?? 9100;
          final groupItems = group['items'] as List? ?? [];
          bool ok = false;
          try {
            if (printerIp != null && printerIp.isNotEmpty) {
              ok = await widget.printerService!.printKitchenReceiptToIp(
                ticket: ticketInfo, items: groupItems, ip: printerIp, port: printerPort,
              );
            } else {
              ok = await widget.printerService!.printKitchenReceipt(
                ticket: ticketInfo, items: groupItems,
              );
            }
          } catch (_) {
            ok = false;
          }
          out.add({'group': group, 'ok': ok});
        }
        return out;
      }));

      for (final bucket in perBucket) {
        for (final r in bucket) {
          final group = r['group'] as Map<String, dynamic>;
          final ok = r['ok'] as bool;
          final printerIp = group['printer_ip'] as String?;
          final printerPort = group['printer_port'] as int? ?? 9100;
          final groupItems = group['items'] as List? ?? [];
          final printerName = group['printer_name'] as String? ?? 'Varsayilan';
          final jobId = _safeInt(group['job_id']);

          if (ok) {
            successCount += groupItems.length;
            if (jobId != null) successJobIds.add(jobId);
          } else {
            failCount += groupItems.length;
            if (jobId != null) failJobIds.add(jobId);
            failReasons.add(printerName);
            // Sag ust yazici kuyruguna ekle (null-IP grubunda default mutfak yazici IP'si)
            String? retryIp = (printerIp != null && printerIp.isNotEmpty) ? printerIp : null;
            int retryPort = printerPort;
            if (retryIp == null) {
              final defCfg = widget.printerService!.getKitchenPrinterConfig();
              if (defCfg != null) {
                retryIp = defCfg['ip'] as String?;
                retryPort = defCfg['port'] as int? ?? printerPort;
              }
            }
            int? queueJobId;
            if (retryIp != null && retryIp.isNotEmpty) {
              queueJobId = await widget.printerService!.enqueueKitchenForRetry(
                ip: retryIp,
                port: retryPort,
                printerName: printerName,
                ticketInfo: ticketInfo,
                items: groupItems,
                serverJobId: jobId,             // Faz 2: basinca sunucuya rapor
                serverTicketId: widget.ticketId, // Faz 2
              );
            }
            failedGroupsForRetry.add({
              'printer_ip': printerIp,
              'printer_port': printerPort,
              'printer_name': printerName,
              'items': groupItems,
              'job_id': jobId,
              'queue_job_id': queueJobId,
            });
          }
        }
      }

      // Telemetri: print_jobs lifecycle (dashboard "stuck" fix)
      if (successJobIds.isNotEmpty) {
        widget.apiService.markItemsPrinted(
          ticketId: widget.ticketId, itemIds: const [], jobIds: successJobIds,
        ).catchError((_) => false);
      }
      if (failJobIds.isNotEmpty) {
        widget.apiService.unmarkItemsPrinted(
          ticketId: widget.ticketId, itemIds: const [], jobIds: failJobIds, error: 'TCP unreachable',
        ).catchError((_) => false);
      }

      // Admin panel POS Loglari icin ozet
      final tableLabel = widget.table?['table_number']?.toString() ?? 'Masa ${widget.table?['id'] ?? ''}';
      if (failCount > 0) {
        LogService().error(
          LogType.error,
          'Mutfak fisi $failCount yaziciya gonderilemedi (sessiz mod, kuyrukta retry): Masa $tableLabel',
          details: {
            'ticket_id': widget.ticketId,
            'table': tableLabel,
            'printed_count': successCount,
            'failed_count': failCount,
            'failed_printers': failReasons,
            'action': 'queued_for_retry',
            'mode': 'silent',
          },
        );
      } else if (successCount > 0) {
        LogService().logAction(
          'Mutfak fisi basildi (add silent): $tableLabel — $successCount urun',
          details: {
            'ticket_id': widget.ticketId,
            'table': tableLabel,
            'printed_count': successCount,
          },
        );
      }

      // 18 May 2026: Silent path da fail varsa pop-up (operator hemen tekrar yazdirabilsin)
      if (failedGroupsForRetry.isNotEmpty && mounted) {
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => KitchenPrintRetryModal(
            printerService: widget.printerService!,
            apiService: widget.apiService,
            ticketId: widget.ticketId,
            ticketInfo: ticketInfo,
            failedGroups: failedGroupsForRetry,
          ),
        );
      }
    } catch (e, st) {
      // 17 Tem 2026: stackTrace eklendi — null-check kök nedeni için (add akışıyla aynı).
      LogService().error(
        LogType.error,
        'Mutfak fisi exception (add silent): $e',
        details: {'ticket_id': widget.ticketId},
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Modal X ile kapatılırken çağrılır.
  /// Otomatik mutfağa gönderme kaldırıldı — kullanıcı isteği üzerine.
  /// Yazdırma için garson açıkça "Mutfağa Gönder" butonuna basmalı.
  Future<void> _handleClose() async {
    if (mounted) widget.onClose();
  }

  Future<void> _printSummaryReceipt(String paymentMethod) async {
    print('[AddItemModal] _printSummaryReceipt: printerService=${widget.printerService != null}, section=${widget.section}');
    if (widget.printerService == null || widget.section == null) {
      print('[AddItemModal] SKIP: printerService veya section null');
      return;
    }
    final summaryPrinterId = widget.section!['summary_printer_id'];
    print('[AddItemModal] summaryPrinterId=$summaryPrinterId');
    if (summaryPrinterId == null) {
      print('[AddItemModal] SKIP: summaryPrinterId null');
      return;
    }
    try {
      final printers = await widget.apiService.getPrinters();
      final targetId = summaryPrinterId is String ? int.tryParse(summaryPrinterId) : summaryPrinterId;
      final printer = printers.firstWhere(
        (p) {
          final pid = p['id'] is String ? int.tryParse(p['id']) : p['id'];
          return pid == targetId;
        },
        orElse: () => <String, dynamic>{},
      );
      if (printer.isEmpty) return;
      final ip = (printer['ip'] ?? printer['ip_address']) as String?;
      final port = (printer['port'] as num?)?.toInt() ?? 9100;
      if (ip == null || ip.isEmpty) return;
      final brandName = Provider.of<ThemeProvider>(context, listen: false).brandName;

      // Ticket bilgisini çek
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      if (ticketData == null) return;
      final ticket = ticketData['ticket'] as Map<String, dynamic>?;
      if (ticket == null) return;

      await widget.printerService!.printClosingReceipt(
        ticket: ticket,
        table: widget.table ?? {},
        waiterName: widget.waiter?['name'] ?? '',
        paymentMethod: paymentMethod,
        targetIp: ip,
        targetPort: port,
        brandName: brandName,
      );
    } catch (_) {}
  }

  /// Parçalı ödeme popup
  Future<void> _openPartialPayment() async {
    // Ticket items'ı yenile
    await _loadTicketItems();
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (activeItems.isEmpty) return;

    // Ticket'in server'a sync olduğunu doğrula ve gerçek server ID'sini al
    int? serverTicketId;
    try {
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      final serverTicket = ticketData?['ticket'] as Map<String, dynamic>?;
      if (serverTicket != null && serverTicket['offline'] != true) {
        final id = serverTicket['id'];
        serverTicketId = id is int ? id : int.tryParse(id?.toString() ?? '');
      }
    } catch (_) {}

    if (serverTicketId == null) {
      _showError('Adisyon henuz sunucuya senkronize edilmedi. Lutfen birkac saniye bekleyip tekrar deneyin veya internet baglantinizi kontrol edin.');
      return;
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PartialPaymentDialog(
        items: activeItems,
        ticketId: serverTicketId!,
        waiterId: widget.waiterId,
        apiService: widget.apiService,
        onPaymentComplete: (allPaid) {
          if (allPaid) {
            // Tüm ürünler ödendi, adisyon kapanır - dialog ve modal kapanır
            Navigator.pop(ctx);
            widget.onItemAdded();
            widget.onClose();
          } else {
            // Kısmi ödeme - dialog açık kalır, sadece arkadaki listeyi tazele
            widget.onItemAdded();
          }
        },
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  // ==========================================================================
  // 3 Agu 2026 — IKRAM AKISI (Mustafa onayli): SADECE ISARETLEME, ayri odeme yolu YOK.
  // Kalem sec -> sebep (ikram_reason_required ayarina gore zorunlu/opsiyonel) -> onay.
  // Backend: PUT /tickets/:id/items/:itemId/ikram (iptal:true geri alir).
  // Kapanis MEVCUT odeme butonlariyla yapilir; backend close() ikram'i tahsilattan duser.
  // Yetki: _hasPermission('ikram') KATI (veri yoksa RED) — buton zaten pasif, burada
  // ikinci savunma hatti var. SADECE ONLINE (parcali odeme deseniyle ayni server-id sarti).
  // ==========================================================================
  Future<void> _openIkramFlow({Future<void> Function()? sonrasindaYenile}) async {
    if (!_hasPermission('ikram')) {
      _showError('İkram yetkiniz bulunmamaktadır.');
      return;
    }
    if (!widget.apiService.isOnline) {
      _showError('İkram için internet bağlantısı gerekli.');
      return;
    }

    await _loadTicketItems();
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    if (activeItems.isEmpty) return;

    // Parcali odeme kalibi: ticket'in server'a sync oldugunu dogrula, gercek server ID al.
    int? serverTicketId;
    try {
      final ticketData = await widget.apiService.getTableTicket(widget.tableId);
      final serverTicket = ticketData?['ticket'] as Map<String, dynamic>?;
      if (serverTicket != null && serverTicket['offline'] != true) {
        final id = serverTicket['id'];
        serverTicketId = id is int ? id : int.tryParse(id?.toString() ?? '');
      }
    } catch (_) {}
    if (serverTicketId == null) {
      _showError('Adisyon henuz sunucuya senkronize edilmedi. Lutfen birkac saniye bekleyip tekrar deneyin.');
      return;
    }

    // Sebep listesi (cache'li) + zorunluluk ayari (bilinmiyorsa ZORUNLU — guvenli taraf).
    List<Map<String, dynamic>> sebepler = const [];
    bool sebepZorunlu = true;
    try { sebepler = await widget.apiService.getIkramReasons(); } catch (_) {}
    try { sebepZorunlu = await widget.apiService.isIkramReasonRequired(); } catch (_) {}

    if (!mounted) return;
    final degisti = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _IkramDialog(
        items: activeItems,
        ticketId: serverTicketId!,
        waiterId: widget.waiterId,
        apiService: widget.apiService,
        sebepler: sebepler,
        sebepZorunlu: sebepZorunlu,
        onClose: () => Navigator.pop(ctx, false),
        onDone: () => Navigator.pop(ctx, true),
      ),
    );

    if (degisti == true) {
      await _loadTicketItems();
      widget.onItemAdded();
      // "Tumunu Gor" pop-up'i acik kaldi — icerigini tazele (Mustafa akis 3).
      if (sonrasindaYenile != null) await sonrasindaYenile();
    }
  }

  /// Adisyon iptal
  Future<void> _voidTicket() async {
    // Sebep seçtir — admin panelinde tanimlanan iptal sebepleri (panel_pos_cancel_reasons).
    // Ürün iptali pattern'i ile ayni davranis (line 759 _cancelSelectedItem)
    final reasons = await widget.apiService.getCancelReasons();
    if (!mounted) return;

    final selectedReason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? picked;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Material(
              type: MaterialType.transparency,
              child: Center(
                child: Container(
                  width: 480,
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20)],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.delete_forever, color: Colors.red, size: 26),
                          SizedBox(width: 8),
                          Expanded(child: Text('Adisyon İptal Sebebi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Adisyonun tamamı iptal edilecek. Lütfen sebep seçin.',
                          style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                      const SizedBox(height: 16),
                      if (reasons.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.amber[50], borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            'Tanımlı iptal sebebi yok. Panel > POS > İptal Sebepleri\'nden ekleyin.',
                            style: TextStyle(color: Colors.amber[900], fontSize: 13),
                          ),
                        )
                      else
                        Flexible(
                          child: SingleChildScrollView(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: reasons.map<Widget>((r) {
                                final reason = r['reason']?.toString() ?? '';
                                final isSelected = picked == reason;
                                // 22 May 2026: Dokunmatik POS — InkWell + min 48
                                return Material(
                                  color: isSelected ? Colors.red : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    onTap: () => setDialogState(() => picked = reason),
                                    borderRadius: BorderRadius.circular(8),
                                    splashColor: Colors.red.withOpacity(0.3),
                                    child: Container(
                                      constraints: const BoxConstraints(minHeight: 48),
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: isSelected ? Colors.red : Colors.grey[300]!, width: isSelected ? 2 : 1),
                                      ),
                                      child: Text(reason, style: TextStyle(color: isSelected ? Colors.white : Colors.grey[800], fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                            child: const Text('Vazgeç', style: TextStyle(fontSize: 15)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: picked != null ? () => Navigator.pop(ctx, picked) : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                            ),
                            child: const Text('Adisyonu İptal Et', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (selectedReason == null) return; // Kullanıcı vazgeçti

    try {
      await widget.apiService.voidTicket(
        ticketId: widget.ticketId,
        waiterId: widget.waiterId,
        reason: selectedReason,
      );
      _showSuccess('Adisyon iptal edildi: $selectedReason');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Adisyon iptal edilemedi: $e');
    }
  }

  /// Masa değiştir
  // 16 May 2026: Tek ürün taşıma — açık/kapalı tüm masaları listele
  Future<void> _moveSelectedItem() async {
    final selectedItem = _findSelectedItem();
    if (selectedItem == null) {
      _showError('Önce ürün seçin');
      return;
    }
    final itemId = _safeInt(selectedItem['id']);
    if (itemId == null) {
      _showError('Ürün ID alınamadı');
      return;
    }

    try {
      final tables = await widget.apiService.getTables();
      final candidateTables = (tables as List)
          .where((t) => (t['id'] as num).toInt() != widget.tableId)
          .toList();

      if (candidateTables.isEmpty) {
        _showError('Hedef masa yok');
        return;
      }

      // 22 May 2026: Numerik sirali (Masa 1, 2, 3 ... 10, 11) + salon gruplamali
      int tableNumKey(dynamic t) {
        final raw = t['table_number']?.toString() ?? '';
        return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 999999;
      }
      candidateTables.sort((a, b) {
        final aSec = (a['section_name'] ?? '').toString();
        final bSec = (b['section_name'] ?? '').toString();
        if (aSec != bSec) return aSec.compareTo(bSec);
        return tableNumKey(a).compareTo(tableNumKey(b));
      });

      // Salon listesi (TUMU + her unique section)
      final sectionMap = <int, Map<String, dynamic>>{};
      for (final t in candidateTables) {
        final sid = (t['section_id'] as num?)?.toInt();
        if (sid == null) continue;
        sectionMap.putIfAbsent(sid, () => {
          'id': sid,
          'name': t['section_name'] ?? '',
          'color': t['section_color'] ?? '#3b82f6',
        });
      }
      final sections = sectionMap.values.toList()
        ..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));

      final productName = selectedItem['product_name']?.toString() ?? 'Ürün';
      final qty = _safeInt(selectedItem['quantity']) ?? 1;
      // 22 May 2026: Urun Tasi — tenant tema secondary rengi (Masa Degistir primary'den ayrilsin)
      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      final headerColor = themeProvider.secondaryColor;
      final headerHsl = HSLColor.fromColor(headerColor);
      final headerDarker = headerHsl.withLightness((headerHsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
      final bannerBg = headerHsl.withLightness(0.93).toColor();
      final bannerText = headerHsl.withLightness(0.30).toColor();

      final selectedTable = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          int? selectedSectionId; // null = TUMU
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final filtered = selectedSectionId == null
                  ? candidateTables
                  : candidateTables.where((t) => (t['section_id'] as num?)?.toInt() == selectedSectionId).toList();

              return Dialog(
                insetPadding: const EdgeInsets.all(24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 780),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // HEADER (tenant tema secondary — Masa Degistir primary'den ayrilir)
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 18, 16, 18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [headerColor, headerDarker],
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                          ),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.drive_file_move, color: Colors.white, size: 28),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Ürünü Taşı',
                                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Text(
                                  '$qty × $productName',
                                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close, color: Colors.white, size: 26),
                          ),
                        ]),
                      ),
                      // BILGI BANDI (tema rengi acik tonu)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        color: bannerBg,
                        child: Row(children: [
                          Icon(Icons.info_outline, size: 18, color: headerColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'BOŞ masa seçerseniz YENİ ADİSYON açılır. DOLU masa seçerseniz mevcut adisyona EKLENİR.',
                              style: TextStyle(fontSize: 13, color: bannerText),
                            ),
                          ),
                        ]),
                      ),
                      // SALON FILTRE
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            _sectionChip(
                              label: 'TÜMÜ',
                              count: candidateTables.length,
                              color: const Color(0xFF6B7280),
                              selected: selectedSectionId == null,
                              onTap: () => setDialogState(() => selectedSectionId = null),
                            ),
                            const SizedBox(width: 10),
                            ...sections.map((s) {
                              final sid = s['id'] as int;
                              final secCount = candidateTables
                                  .where((t) => (t['section_id'] as num?)?.toInt() == sid).length;
                              return Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _sectionChip(
                                  label: s['name'].toString(),
                                  count: secCount,
                                  color: Color(int.parse((s['color'] as String).replaceAll('#', '0xFF'))),
                                  selected: selectedSectionId == sid,
                                  onTap: () => setDialogState(() => selectedSectionId = sid),
                                ),
                              );
                            }),
                          ]),
                        ),
                      ),
                      // MASA GRID
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.table_restaurant, size: 64, color: Colors.grey.shade300),
                                  const SizedBox(height: 12),
                                  Text('Bu salonda hedef masa yok',
                                      style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                                ]),
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.all(16),
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 160,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 1.0,
                                ),
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  final table = filtered[index];
                                  final isOccupied = table['status'] == 'occupied';
                                  final color = Color(int.parse(
                                      (table['section_color'] ?? '#3b82f6').replaceAll('#', '0xFF')));
                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => Navigator.pop(ctx, table),
                                      splashColor: (isOccupied ? Colors.orange : Colors.green).withValues(alpha: 0.2),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: isOccupied ? Colors.orange.shade50 : Colors.white,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isOccupied ? Colors.orange.shade300 : color,
                                            width: 2,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.05),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            // Ust durum seridi
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                              decoration: BoxDecoration(
                                                color: isOccupied ? Colors.orange.shade700 : Colors.green.shade600,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                Icon(isOccupied ? Icons.add_circle : Icons.note_add,
                                                    size: 12, color: Colors.white),
                                                const SizedBox(width: 4),
                                                Text(
                                                  isOccupied ? 'MEVCUTA EKLE' : 'YENİ ADİSYON',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ]),
                                            ),
                                            const SizedBox(height: 8),
                                            // Masa numarasi (buyuk)
                                            Text(
                                              '${table['table_number']}',
                                              style: TextStyle(
                                                fontSize: 36,
                                                fontWeight: FontWeight.w900,
                                                color: isOccupied ? Colors.orange.shade900 : Colors.grey.shade800,
                                                height: 1,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            // Salon adi
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8),
                                              child: Text(
                                                table['section_name']?.toString() ?? '',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey.shade600,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                textAlign: TextAlign.center,
                                                overflow: TextOverflow.ellipsis,
                                                maxLines: 1,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      // FOOTER
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: Colors.grey.shade200)),
                        ),
                        child: Row(children: [
                          _legendDot(Colors.green.shade600, 'BOŞ (yeni adisyon)'),
                          const SizedBox(width: 16),
                          _legendDot(Colors.orange.shade700, 'DOLU (mevcuta ekle)'),
                          const Spacer(),
                          SizedBox(
                            height: 44,
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close),
                              label: const Text('İptal', style: TextStyle(fontSize: 15)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey.shade200,
                                foregroundColor: Colors.black87,
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (selectedTable == null) return;

      final result = await widget.apiService.moveItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        newTableId: (selectedTable['id'] as num).toInt(),
        waiterId: widget.waiterId,
      );

      if (result['success'] == false || result['error'] != null) {
        _showError('Hata: ${result['error'] ?? 'Bilinmiyor'}');
        return;
      }
      final offline = result['offline'] == true;
      _showSuccess(
        (offline ? 'Ürün taşındı (offline, internet gelince senkron olacak): ' : 'Ürün taşındı: ') +
        '${selectedTable['section_name']} - Masa ${selectedTable['table_number']}',
      );
      setState(() => _selectedItemId = null);
      widget.onItemAdded();
    } catch (e) {
      _showError('Ürün taşınamadı: $e');
    }
  }

  Future<void> _transferTable() async {
    try {
      // 16 May 2026: Hem bos hem dolu masalari listele
      // - Bos masa secilirse → transfer
      // - Dolu masa secilirse → birlestirme onayi → backend ticket'lari birlestirir
      final tables = await widget.apiService.getTables();
      final candidateTables = (tables as List)
          .where((t) => (t['id'] as num).toInt() != widget.tableId) // Mevcut masa haric
          .toList();

      if (candidateTables.isEmpty) {
        _showError('Hedef masa yok');
        return;
      }

      // Numerik sırayla (Masa 1, 2, 3 ... 10, 11)
      int tableNumKey(dynamic t) {
        final raw = t['table_number']?.toString() ?? '';
        return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 999999;
      }
      candidateTables.sort((a, b) {
        final aSec = (a['section_name'] ?? '').toString();
        final bSec = (b['section_name'] ?? '').toString();
        if (aSec != bSec) return aSec.compareTo(bSec);
        return tableNumKey(a).compareTo(tableNumKey(b));
      });

      // Salon listesi (TÜMÜ + her unique section)
      final sectionMap = <int, Map<String, dynamic>>{};
      for (final t in candidateTables) {
        final sid = (t['section_id'] as num?)?.toInt();
        if (sid == null) continue;
        sectionMap.putIfAbsent(sid, () => {
          'id': sid,
          'name': t['section_name'] ?? '',
          'color': t['section_color'] ?? '#3b82f6',
        });
      }
      final sections = sectionMap.values.toList()
        ..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));

      // 22 May 2026: Masa Degistir — tenant tema primary rengi (Urun Tasi secondary'den ayrilir)
      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      final headerColor = themeProvider.primaryColor;
      final headerHsl = HSLColor.fromColor(headerColor);
      final headerDarker = headerHsl.withLightness((headerHsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();

      // 21 Tem 2026 FIX: Taşıma dialogu VARSAYILAN adisyonun KENDİ salonu seçili açılsın (eskiden
      // null=Tümü). Duplike masa isimli bayilerde (aynı "5" masası iki salonda) kasiyer alfabetik
      // ilk salonun masasını yanlışlıkla seçip adisyonu yanlış masaya taşıyordu. Kendi salonu seçili
      // gelince en olası hedef (aynı salondaki komşu masa) önde olur. GÜVENLİK: (a) section_id yok/0
      // ise Tümü fallback; (b) kendi salonunda başka aday masa YOKSA (tek masalı salon) Tümü'ye düş
      // (boş grid kafa karıştırmasın). _safeInt string/int normalize (legacy tenant güvenli).
      final int? ownSectionId = _safeInt(widget.table?['section_id']);
      final bool ownSectionHasCandidates = ownSectionId != null && ownSectionId != 0 &&
          candidateTables.any((t) => _safeInt(t['section_id']) == ownSectionId);
      final int? initialSectionId = ownSectionHasCandidates ? ownSectionId : null;

      final selectedTable = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          int? selectedSectionId = initialSectionId; // varsayılan: kendi salonu (yoksa null=TÜMÜ)
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final filtered = selectedSectionId == null
                  ? candidateTables
                  : candidateTables.where((t) => _safeInt(t['section_id']) == selectedSectionId).toList();

              return Dialog(
                insetPadding: const EdgeInsets.all(24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 780),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // HEADER (tenant tema primary)
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 18, 16, 18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [headerColor, headerDarker],
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                          ),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.swap_horiz, color: Colors.white, size: 28),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Masa Değiştir / Birleştir',
                                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Text(
                                  'Mevcut: ${widget.table?['section_name'] ?? ''} • Masa ${widget.table?['table_number'] ?? ''}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close, color: Colors.white, size: 26),
                          ),
                        ]),
                      ),
                      // BİLGİ BANDI
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        color: Colors.amber.shade50,
                        child: Row(children: [
                          Icon(Icons.info_outline, size: 18, color: Colors.amber.shade800),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Dolu masaya transfer ederseniz iki adisyon BİRLEŞTİRİLİR (ürünler tek adisyonda toplanır).',
                              style: TextStyle(fontSize: 13, color: Color(0xFF78350F)),
                            ),
                          ),
                        ]),
                      ),
                      // SALON FİLTRE
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            // TÜMÜ chip
                            _sectionChip(
                              label: 'TÜMÜ',
                              count: candidateTables.length,
                              color: const Color(0xFF6B7280),
                              selected: selectedSectionId == null,
                              onTap: () => setDialogState(() => selectedSectionId = null),
                            ),
                            const SizedBox(width: 10),
                            ...sections.map((s) {
                              final sid = s['id'] as int;
                              final secCount = candidateTables
                                  .where((t) => (t['section_id'] as num?)?.toInt() == sid).length;
                              return Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _sectionChip(
                                  label: s['name'].toString(),
                                  count: secCount,
                                  color: Color(int.parse((s['color'] as String).replaceAll('#', '0xFF'))),
                                  selected: selectedSectionId == sid,
                                  onTap: () => setDialogState(() => selectedSectionId = sid),
                                ),
                              );
                            }),
                          ]),
                        ),
                      ),
                      // MASA GRID
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.table_restaurant, size: 64, color: Colors.grey.shade300),
                                  const SizedBox(height: 12),
                                  Text('Bu salonda hedef masa yok',
                                      style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                                ]),
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.all(16),
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 160,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 1.0,
                                ),
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  final table = filtered[index];
                                  final isOccupied = table['status'] == 'occupied';
                                  final color = Color(int.parse(
                                      (table['section_color'] ?? '#3b82f6').replaceAll('#', '0xFF')));
                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => Navigator.pop(ctx, table),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: isOccupied ? Colors.red.shade50 : Colors.white,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isOccupied ? Colors.red.shade300 : color,
                                            width: 2,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.05),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            // Üst durum şeridi
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                              decoration: BoxDecoration(
                                                color: isOccupied ? Colors.red.shade600 : Colors.green.shade600,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                Icon(isOccupied ? Icons.merge_type : Icons.check_circle_outline,
                                                    size: 12, color: Colors.white),
                                                const SizedBox(width: 4),
                                                Text(
                                                  isOccupied ? 'BİRLEŞTİR' : 'BOŞ',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ]),
                                            ),
                                            const SizedBox(height: 8),
                                            // Masa numarası (büyük)
                                            Text(
                                              '${table['table_number']}',
                                              style: TextStyle(
                                                fontSize: 36,
                                                fontWeight: FontWeight.w900,
                                                color: isOccupied ? Colors.red.shade900 : Colors.grey.shade800,
                                                height: 1,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            // 21 Tem 2026 FIX: Salon adı BELİRGİN (chip + koyu renk).
                                            // Duplike masa isimli bayilerde kasiyer aynı numaralı iki
                                            // masayı ayırt edebilsin diye salon adı soluk gri yerine
                                            // vurgulu rozet oldu. Dolu masa arka planı red.shade50
                                            // olduğu için chip red.shade100 (karodan ayrışsın).
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 6),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: (isOccupied ? Colors.red.shade100 : Colors.grey.shade200),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  table['section_name']?.toString() ?? '',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: isOccupied ? Colors.red.shade800 : Colors.grey.shade800,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 0.2,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  overflow: TextOverflow.ellipsis,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      // FOOTER
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: Colors.grey.shade200)),
                        ),
                        child: Row(children: [
                          _legendDot(Colors.green.shade600, 'BOŞ (transfer)'),
                          const SizedBox(width: 16),
                          _legendDot(Colors.red.shade600, 'DOLU (birleştir)'),
                          const Spacer(),
                          SizedBox(
                            height: 44,
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close),
                              label: const Text('İptal', style: TextStyle(fontSize: 15)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey.shade200,
                                foregroundColor: Colors.black87,
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (selectedTable == null) return;

      final isMerge = selectedTable['status'] == 'occupied';
      if (isMerge) {
        // Birlestirme onayi
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.merge_type, color: Colors.orange),
              SizedBox(width: 8),
              Text('Adisyon Birleştir', style: TextStyle(fontSize: 20)),
            ]),
            content: Text(
              'Mevcut adisyondaki ürünler "Masa ${selectedTable['table_number']}" adisyonuna aktarılacak. '
              'İki adisyon birleşip TEK adisyon haline gelecek. Devam edilsin mi?',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                child: const Text('Evet, Birleştir'),
              ),
            ],
          ),
        );
        if (confirm != true) return;
      }

      final result = await widget.apiService.transferTable(
        ticketId: widget.ticketId,
        newTableId: (selectedTable['id'] as num).toInt(),
        waiterId: widget.waiterId,
      );
      if (result['success'] == false || result['error'] != null) {
        _showError('Hata: ${result['error'] ?? 'Bilinmiyor'}');
        return;
      }
      _showSuccess(isMerge
          ? 'Adisyonlar birleştirildi: ${selectedTable['section_name']} - Masa ${selectedTable['table_number']}'
          : 'Masa değiştirildi: ${selectedTable['section_name']} - Masa ${selectedTable['table_number']}');
      widget.onItemAdded();
      widget.onClose();
    } catch (e) {
      _showError('Masa değiştirilemedi: $e');
    }
  }

  /// İndirim dialog
  Future<void> _openDiscountDialog() async {
    double? discount;
    String type = 'percentage';

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        String localType = 'percentage';
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('İndirim Uygula', style: TextStyle(fontSize: 22)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // 22 May 2026: Dokunmatik POS — InkWell + min 56
                    Expanded(
                      child: Material(
                        color: localType == 'percentage' ? const Color(0xFFE11D48) : Colors.grey[200],
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () => setDialogState(() => localType = 'percentage'),
                          borderRadius: BorderRadius.circular(8),
                          splashColor: Colors.white.withOpacity(0.3),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 56),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Center(child: Text('% Yüzde', style: TextStyle(color: localType == 'percentage' ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold))),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Material(
                        color: localType == 'amount' ? const Color(0xFFE11D48) : Colors.grey[200],
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () => setDialogState(() => localType = 'amount'),
                          borderRadius: BorderRadius.circular(8),
                          splashColor: Colors.white.withOpacity(0.3),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 56),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Center(child: Text('₺ Tutar', style: TextStyle(color: localType == 'amount' ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold))),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: localType == 'percentage' ? '%' : '₺',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.spaceEvenly,
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              SizedBox(width: 140, height: 50, child: ElevatedButton(onPressed: () => Navigator.pop(ctx), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 16)))),
              SizedBox(width: 160, height: 50, child: ElevatedButton(
                onPressed: () {
                  final val = double.tryParse(controller.text);
                  if (val != null && val > 0) Navigator.pop(ctx, {'type': localType, 'value': val});
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE11D48), foregroundColor: Colors.white),
                child: const Text('Uygula', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )),
            ],
          ),
        );
      },
    );

    if (result == null) return;
    try {
      await widget.apiService.applyDiscount(
        ticketId: widget.ticketId,
        discountType: result['type'],
        discountValue: result['value'],
        waiterId: widget.waiterId,
      );
      _showSuccess('İndirim uygulandı');
      await _loadTicketItems();
    } catch (e) {
      _showError('İndirim uygulanamadı: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    print('[AddItemModal] ERROR: $message');
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (_) {
      // Dialog içinde Scaffold yoksa overlay ile göster
      _showOverlayMessage(message, Colors.red);
    }
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    print('[AddItemModal] SUCCESS: $message');
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
    } catch (_) {
      _showOverlayMessage(message, Colors.green);
    }
  }

  void _showOverlayMessage(String message, Color color) {
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 50,
        left: 50,
        right: 50,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 14), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () => entry.remove());
  }

  double get _paidTotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      if (item['payment_status'] == 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  double get _unpaidTotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      // 3 Agu 2026 IKRAM: ikram kalemin parasi ALINMAZ -> "Kalan"a girmez
      if (IkramRules.kalemIkramMi(item)) continue;
      if (item['payment_status'] != 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  /// 3 Agu 2026 IKRAM: aktif kalemlerdeki ikram toplami (tahsilattan dusulecek miktar).
  /// Online'da backend close() ayni dusumu authoritative yapar; bu POS onizlemesi +
  /// offline kapanis tutaridir. is_ikram esnek guard (SQLite 0/1) IkramRules'ta.
  double get _ikramTotal => IkramRules.ikramToplami(_ticketItems);

  double get _ticketSubtotal {
    double total = 0;
    for (var item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    }
    return total;
  }

  double get _ticketDiscount {
    if (_ticketInfo == null) return 0;
    final d = _ticketInfo!['discount_amount'] ?? _ticketInfo!['discount'];
    if (d == null) return 0;
    return d is num ? d.toDouble() : double.tryParse(d.toString()) ?? 0;
  }

  String? get _ticketDiscountType => _ticketInfo?['discount_type']?.toString();

  /// COMBO FAZ4: adisyondaki combo indirimini hesapla (offline dahil — comboCalculator.dart).
  /// _products'ta combo_enabled=1 urun yoksa (backend combo dondurmuyorsa) 0 doner (guvenli).
  /// Online'da backend kapanista kesin hesabi yapar; bu POS onizlemesi/offline uygulamasidir.
  ComboCartResult get _comboResult {
    // Aktif (iptal olmayan) kalemler; __combo_gift satirlari calcCartCombos zaten atlar.
    final cart = <Map<String, dynamic>>[];
    for (final item in _ticketItems) {
      if (item['status'] == 'cancelled') continue;
      cart.add(item);
    }
    // combo_enabled urunlerden productsById kur.
    final byId = <String, Map<String, dynamic>>{};
    for (final p in _products) {
      final id = _safeInt(p['id']);
      if (id == null) continue;
      final enabled = ComboCalculator.comboAktif(Map<String, dynamic>.from(p)); // TEK KAYNAK
      if (enabled) byId[id.toString()] = p;
    }
    if (byId.isEmpty) return ComboCartResult();
    return ComboCalculator.calcCartCombos(cart, byId);
  }

  double get _comboDiscount => _comboResult.totalDiscount;

  double get _ticketTotal {
    // Combo indirimi manuel indirimle CAKISMAZ: combo aktif urunlerde combo, digerlerinde manuel.
    // Basit ve guvenli: toplam = subtotal - manuel_indirim - combo_indirim (combo zaten sadece
    // combo urunlerin set tutarina uygulanir; backend authoritative kesin hesabi kapanista yapar).
    // 3 Agu 2026 IKRAM: ikram kalemler de tahsilattan duser (backend close() ile ayni kural).
    final t = _ticketSubtotal - _ticketDiscount - _comboDiscount - _ikramTotal;
    return t < 0 ? 0 : t;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);

    return PopScope(
      // Modal sistem geri tuşu/ESC ile kapatılırsa da otomatik mutfağa gönder
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _handleClose();
      },
      child: Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Scaffold(
        body: Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        color: Colors.white,
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: theme.primaryColor))
                  : Row(
                      children: [
                        // 1. SOL: Kategoriler
                        _buildCategoriesPanel(theme),
                        // 2. ORTA-SOL: Ürünler (geniş)
                        Expanded(flex: 4, child: _buildProductsPanel(theme)),
                        // 3. ORTA-SAĞ: Adisyon listesi (scroll)
                        _buildTicketPanel(theme),
                        // 4. SAĞ: Aksiyon butonları
                        _buildActionPanel(theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }

  Widget _buildHeader(ThemeProvider theme) {
    final sectionName = widget.table?['section_name'] ?? '';
    final tableNumber = widget.table?['table_number'] ?? 'Masa ${widget.table?['id'] ?? ''}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.primaryColor,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Text(
            '$sectionName - $tableNumber',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 16),
          // Arama
          Expanded(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearch,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Ürün ara...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.7), size: 20),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                // X ile kapatırken yazdırılmamış ürünler otomatik mutfağa gönderilsin
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(12),
                child: const SizedBox(
                  width: 64,
                  height: 64,
                  child: Icon(Icons.close, color: Colors.white, size: 36),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // SOL: Kategoriler - 2 sütun
  Widget _buildCategoriesPanel(ThemeProvider theme) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(right: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        children: [
          // "Tümü" butonu - tam genişlik
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: _buildCategoryButton(theme, null, 'Tümü', Icons.apps, yatay: true),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                return _buildCategoryButton(
                  theme,
                  _safeInt(cat['id']),
                  cat['name']?.toString() ?? '',
                  null,
                  emoji: cat['icon']?.toString() ?? '',
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 2 Agu 2026 (Mustafa: "solda tumu butonu asagi dogru cok uzun, genislemesine uzun olsun"):
  // [yatay]=true -> ikon ve etiket YAN YANA, alcak yukseklik. Tam genislikteki "Tumu"
  // butonu icin kullanilir; 2 sutunlu kategori izgarasi ESKISI GIBI dikey kalir.
  Widget _buildCategoryButton(ThemeProvider theme, int? categoryId, String label, IconData? icon, {String emoji = '', bool yatay = false}) {
    // 22 May 2026: Dokunmatik POS — InkWell ile ripple + min 64 yukseklik
    final isSelected = _selectedCategoryId == categoryId;
    return Material(
      color: isSelected ? theme.primaryColor : Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: isSelected ? 2 : 0.5,
      shadowColor: isSelected ? theme.primaryColor.withOpacity(0.4) : Colors.black26,
      child: InkWell(
        onTap: () => _selectCategory(categoryId),
        borderRadius: BorderRadius.circular(8),
        splashColor: theme.primaryColor.withOpacity(0.3),
        highlightColor: theme.primaryColor.withOpacity(0.15),
        child: Container(
          constraints: BoxConstraints(minHeight: yatay ? 44 : 68),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? theme.primaryColor : Colors.grey[300]!,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: yatay
            // YATAY: ikon solda, etiket saginda — dokunma hedefi 44px, genislik tam.
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (emoji.isNotEmpty)
                    Text(emoji, style: const TextStyle(fontSize: 18))
                  else if (icon != null)
                    Icon(icon, color: isSelected ? Colors.white : Colors.grey[700], size: 19),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.grey[800],
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (emoji.isNotEmpty)
                Text(emoji, style: const TextStyle(fontSize: 20))
              else if (icon != null)
                Icon(icon, color: isSelected ? Colors.white : Colors.grey[700], size: 20),
              const SizedBox(height: 2),
              // Flexible: 2 satir label parent yuksekligini asarsa taşma yerine sıkışır (0.385px overflow fix).
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey[800],
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ORTA: Ürünler grid
  Widget _buildProductsPanel(ThemeProvider theme) {
    if (_filteredProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Ürün bulunamadı', style: TextStyle(color: Colors.grey[500], fontSize: 18)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Min 3 sutun garanti: pencere kuculurse urunler o oranda kuculsun
        final crossAxisCount = (constraints.maxWidth / 160).floor().clamp(3, 6);
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: widget.showProductImages ? 0.85 : 1.5,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: _filteredProducts.length,
          itemBuilder: (context, index) => _buildProductCard(_filteredProducts[index], theme),
        );
      },
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product, ThemeProvider theme) {
    final isOutOfStock = product['is_out_of_stock'] == 1 || product['is_out_of_stock'] == true;
    final hasImage = product['image'] != null && product['image'].toString().isNotEmpty;

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        elevation: 1.5,
        shadowColor: Colors.black26,
        child: InkWell(
          onTap: isOutOfStock ? null : () => _addProductDirectly(product),
          borderRadius: BorderRadius.circular(10),
          splashColor: theme.primaryColor.withOpacity(0.2),
          highlightColor: theme.primaryColor.withOpacity(0.08),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              // Gorsel sadece varsa goster, yoksa hic yer kaplamasin
              if (widget.showProductImages && hasImage)
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10)),
                    child: _buildProductImage(product),
                  ),
                ),
              Expanded(
                flex: (widget.showProductImages && hasImage) ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: (widget.showProductImages && hasImage) ? MainAxisAlignment.start : MainAxisAlignment.center,
                    children: [
                      Text(
                        product['name']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Color(0xFF1f2937)),
                      ),
                      if (widget.showProductImages && hasImage) const Spacer(),
                      if (!(widget.showProductImages && hasImage)) const SizedBox(height: 2),
                      Text(
                        '${(product['restaurant_price'] != null && product['restaurant_price'] != 0) ? product['restaurant_price'] : product['price'] ?? 0} TL',
                        style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              if (isOutOfStock)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.only(bottomLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
                  ),
                  child: const Center(
                    child: Text('Tukendi', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // SAĞ: Adisyon paneli + aksiyon butonları
  Widget _buildTicketPanel(ThemeProvider theme) {
    // 2 Agu 2026 (Mustafa: "adisyonda en son eklenen urun en basa gelsin"):
    // SADECE EKRAN SIRASI ters cevrilir (en yeni ustte). Secim itemId uzerinden
    // yapildigi icin etkilenmez; odeme/yazdirma/fis akislarindaki DIGER activeItems
    // listelerine (satir ~2983 ve ~3395) DOKUNULMADI -> fis sirasi KRONOLOJIK kalir.
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList().reversed.toList();
    final hasItems = activeItems.isNotEmpty;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Colors.grey[300]!)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(-2, 0))],
      ),
      child: Column(
        children: [
          // Başlık
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long, size: 16, color: theme.primaryColor),
                const SizedBox(width: 6),
                Text('Adisyon', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                const SizedBox(width: 8),
                // 2 Agu 2026 (Mustafa): "Tumunu Gor" rozeti — masadaki TUM urunleri
                // ADETLERI BIRLESTIRILMIS halde gosterir (4 ayri "Cay" yerine "4x Cay").
                // SALT OKUNUR pop-up: hicbir kalem/tutar/akis degismez, garsona kolaylik.
                if (activeItems.isNotEmpty)
                  Material(
                    color: theme.primaryColor.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: () => _tumunuGorDialog(theme),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.list_alt_rounded, size: 13, color: theme.primaryColor),
                          const SizedBox(width: 4),
                          Text('Tümünü Gör',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                                  color: theme.primaryColor, letterSpacing: 0.2)),
                        ]),
                      ),
                    ),
                  ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('${activeItems.length}', style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),

          // Ürün listesi
          Expanded(
            child: activeItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.restaurant_menu, size: 36, color: Colors.grey[300]),
                        const SizedBox(height: 8),
                        Text('Henüz ürün eklenmedi', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: activeItems.length,
                    itemBuilder: (context, index) {
                      final item = activeItems[index];
                      final itemId = _safeInt(item['id']);
                      final isSelected = itemId != null && _selectedItemId == itemId;
                      return _buildTicketItemRow(item, theme, index, isSelected);
                    },
                  ),
          ),

          // Toplam + ödeme durumu
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(top: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Column(
              children: [
                if (_paidTotal > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Ödenen', style: TextStyle(fontSize: 11, color: Colors.green[700])),
                      Text('${_paidTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green[700])),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Kalan', style: TextStyle(fontSize: 11, color: Colors.orange[700])),
                      Text('${_unpaidTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                if (_ticketDiscount > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Ara Toplam', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      Text('${_ticketSubtotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _ticketDiscountType == 'percentage'
                            ? 'İndirim (%${(_ticketSubtotal > 0 ? (_ticketDiscount / _ticketSubtotal * 100) : 0).toStringAsFixed(0)})'
                            : 'İndirim',
                        style: TextStyle(fontSize: 11, color: Colors.red[700]),
                      ),
                      Text('-${_ticketDiscount.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red[700])),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                // COMBO FAZ4: combo indirim satiri (manuel indirim yoksa ara toplam da goster)
                if (_comboDiscount > 0) ...[
                  if (_ticketDiscount <= 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Ara Toplam', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                        Text('${_ticketSubtotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ],
                    ),
                  ..._comboResult.breakdown.where((b) => b.amount > 0).map((b) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Combo (${b.label})',
                              style: TextStyle(fontSize: 11, color: Colors.orange[800])),
                          Text('-${b.amount.toStringAsFixed(2)} TL',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange[800])),
                        ],
                      )),
                  const SizedBox(height: 4),
                ],
                // 3 Agu 2026 IKRAM: ikram dusumu satiri (indirim/combo yoksa Ara Toplam da goster)
                if (_ikramTotal > 0) ...[
                  if (_ticketDiscount <= 0 && _comboDiscount <= 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Ara Toplam', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                        Text('${_ticketSubtotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ],
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('İkram', style: TextStyle(fontSize: 11, color: const Color(0xFFEA580C))),
                      Text('-${_ikramTotal.toStringAsFixed(2)} TL',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFEA580C))),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('TOPLAM', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey[800])),
                    Text('${_ticketTotal.toStringAsFixed(2)} TL', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.primaryColor)),
                  ],
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }

  Widget _buildActionPanel(ThemeProvider theme) {
    // 22 May 2026: 2-sutun layout. Buton yuksekligi 60+ olunca tek sutun cok
    // asagi tasiyordu; 2 sutun + scroll ile daha kompakt. Genislik 130 → 240.
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    final hasItems = activeItems.isNotEmpty;

    // Buton liste yapisini bir kerede tanimla (group: 1-4)
    final btnGroup1 = <Widget>[
      _buildActionBtnVertical(icon: Icons.edit_note_rounded, label: 'Not Ekle', color: Colors.blueGrey, onTap: hasItems && _selectedItemId != null ? _openNoteDialog : null),
      _buildActionBtnVertical(
        icon: Icons.tune_rounded,
        label: 'Varyant',
        color: const Color(0xFFF59E0B),
        onTap: hasItems && _selectedItemId != null && _variantsForSelectedItem().isNotEmpty
            ? _openVariantDialogForSelected
            : null,
      ),
      _buildActionBtnVertical(icon: Icons.close_rounded, label: 'Ürün İptal', color: Colors.red[400]!, onTap: hasItems && _selectedItemId != null && (_hasPermission('cancel_item') || _hasPermission('cancel_item_unprinted')) ? _cancelSelectedItem : null),
      _buildActionBtnVertical(
        icon: Icons.drive_file_move_rounded,
        label: 'Ürün Taşı',
        color: const Color(0xFF7C3AED),
        onTap: hasItems && _selectedItemId != null && _hasPermission('move_item') ? _moveSelectedItem : null,
      ),
      _buildActionBtnVertical(icon: Icons.restaurant_rounded, label: 'Mutfak', color: const Color(0xFFF59E0B), onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null),
      _buildActionBtnVertical(icon: Icons.print_rounded, label: 'Yazdır', color: Colors.blueGrey, onTap: hasItems && _hasPermission('print_receipt') ? _printTicket : null),
    ];

    final btnGroup2 = <Widget>[
      if (_hasPermission('apply_discount'))
        _buildActionBtnVertical(icon: Icons.percent_rounded, label: 'İndirim', color: const Color(0xFFE11D48), onTap: hasItems ? _openDiscountDialog : null),
      if (_hasPermission('transfer_table'))
        _buildActionBtnVertical(icon: Icons.swap_horiz_rounded, label: 'Masa Değiştir', color: const Color(0xFF0EA5E9), onTap: hasItems ? _transferTable : null),
      _buildActionBtnVertical(icon: Icons.splitscreen_rounded, label: 'Parçalı Ödeme', color: const Color(0xFF7C3AED), onTap: hasItems && _hasPermission('close_ticket') ? _openPartialPayment : null),
      // 3 Agu 2026 (Mustafa: "parcali odeme yaninda yok buton halen") — IKRAM'i once
      // sadece "Tumunu Gor" pop-up'ina koymustum; Mustafa'nin baktigi yer SAGDAKI ANA
      // MENU. Parcali Odeme'nin HEMEN YANINA buraya da eklendi. Ayni akis, ayni
      // fonksiyon (_openIkramFlow) — AYRI bir odeme yolu DEGIL, sadece isaretleme.
      // Yetki yoksa GIZLI (komsulari Indirim/Masa Degistir ile ayni desen).
      // 3 Agu 2026 DUZELTME (yorum-kod uyumsuzlugu): _hasPermission('ikram')
      // cevrimdisinda da false doner, yani buton cevrimdisinda "pasif" DEGIL
      // TAMAMEN GIZLI olur. Asagidaki isOnline guard'i yalnizca "build online
      // yapildi, sonra baglanti koptu" yarisini korur (ikram server-authoritative).
      if (_hasPermission('ikram'))
        _buildActionBtnVertical(
          icon: Icons.card_giftcard_rounded,
          label: 'İkram',
          color: const Color(0xFFEA580C),
          onTap: hasItems && widget.apiService.isOnline ? () => _openIkramFlow() : null,
        ),
    ];

    final btnGroup3 = <Widget>[
      _buildActionBtnVertical(icon: Icons.payments_rounded, label: 'Nakit Kapat', color: theme.primaryColor, onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null),
      _buildActionBtnVertical(icon: Icons.credit_card_rounded, label: 'Kart Kapat', color: const Color(0xFF3B82F6), onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('credit_card') : null),
      _buildActionBtnVertical(icon: Icons.receipt_long_rounded, label: 'Yaz+Nakit', color: const Color(0xFF059669), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('cash') : null),
      _buildActionBtnVertical(icon: Icons.receipt_long_rounded, label: 'Yaz+Kart', color: const Color(0xFF2563EB), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('credit_card') : null),
      // 15 Tem 2026: Panelden gelen DİNAMİK ödeme yöntemleri (nakit/kart hariç). Her biri "X Kapat".
      // Kod (code) backend'e payment_method olarak gider; display_name fiş/dialog etiketinde kullanılır.
      for (final pm in _dynamicPaymentMethods)
        _buildActionBtnVertical(
          icon: Icons.account_balance_wallet_rounded,
          label: '${pm['display_name']} Kapat',
          color: const Color(0xFF7C3AED),
          onTap: hasItems && _hasPermission('close_ticket')
              ? () => _closeTicket(pm['code'] as String, methodLabel: pm['display_name'] as String?)
              : null,
        ),
    ];

    final btnGroup4 = <Widget>[
      if (_hasPermission('void_ticket'))
        _buildActionBtnVertical(icon: Icons.delete_outline_rounded, label: 'Adisyon İptal', color: const Color(0xFFDC2626), onTap: _voidTicket),
    ];

    // 2 Agu 2026: SADECE GORSEL — grup ayraci yerine kucuk baslikli boluculer
    // (URUN / ADISYON / ODEME). Buton listesi, kosullar ve onTap'ler BIREBIR aynidir.
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(left: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildActionGroupHeader('ÜRÜN İŞLEMLERİ'),
            _buildActionGrid(btnGroup1),
            if (btnGroup2.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildActionGroupHeader('ADİSYON'),
              _buildActionGrid(btnGroup2),
            ],
            const SizedBox(height: 12),
            _buildActionGroupHeader('ÖDEME'),
            _buildActionGrid(btnGroup3),
            if (btnGroup4.isNotEmpty) ...[
              const SizedBox(height: 14),
              Divider(color: Colors.grey[300], height: 1),
              const SizedBox(height: 10),
              _buildActionGrid(btnGroup4),
            ],
          ],
        ),
      ),
    );
  }

  /// 2 Agu 2026: Aksiyon paneli grup basligi (sadece gorsel ayrac; davranis yok).
  Widget _buildActionGroupHeader(String metin) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Row(
        children: [
          Text(
            metin,
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: Color(0xFF94A3B8),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: const Color(0xFFE2E8F0))),
        ],
      ),
    );
  }

  /// 2-sutun action button grid (responsive Wrap)
  Widget _buildActionGrid(List<Widget> buttons) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 2-sutun: her buton (toplamGenislik - aralarGap) / 2
        const spacing = 6.0;
        final cellW = (c.maxWidth - spacing) / 2;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: buttons.map((b) => SizedBox(width: cellW, child: b)).toList(),
        );
      },
    );
  }

  Widget _buildActionBtnVertical({required IconData icon, required String label, required Color color, VoidCallback? onTap}) {
    // 22 May 2026: Dokunmatik POS icin iyilestirme (InkWell ripple + min 60 yukseklik).
    // 2 Agu 2026: SADECE GORSEL yenileme (Mustafa: "daha pro"). Davranis AYNEN korundu.
    // - Beyaz kart yuzeyi + yumusak golge (derinlik) — eski %10 tint dolgu yerine
    // - Ikon, renk degradeli (color → koyusu) yuvarlatilmis rozet icinde beyaz cizilir
    //   (vektorel/SVG rozet gorunumu; ekstra paket YOK, Material ikonlar vektoreldir)
    // - Etiket notr koyu renkte (okunabilirlik); disabled durum mat gri + golgesiz = NET ayirt edilir
    final isDisabled = onTap == null;
    final Color koyu = Color.lerp(color, Colors.black, 0.22)!;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: isDisabled
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Material(
        color: isDisabled ? const Color(0xFFF1F5F9) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: isDisabled ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          splashColor: isDisabled ? null : color.withOpacity(0.22),
          highlightColor: isDisabled ? null : color.withOpacity(0.08),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 62),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDisabled ? const Color(0xFFE2E8F0) : color.withOpacity(0.30),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: isDisabled
                        ? null
                        : LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [color, koyu],
                          ),
                    color: isDisabled ? const Color(0xFFCBD5E1) : null,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: isDisabled
                        ? null
                        : [
                            BoxShadow(
                              color: color.withOpacity(0.32),
                              blurRadius: 5,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Icon(icon, size: 17, color: Colors.white),
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    letterSpacing: 0.1,
                    color: isDisabled ? const Color(0xFF94A3B8) : const Color(0xFF334155),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Kalemin `extras` alanindan alt satirlar uretir (POS coklu varyant secimleri).
  /// Backend jsonb doner (List), cevrimdisi cache JSON METIN saklar -> ikisini de coz.
  /// Hatali/eksik veride BOS liste -> satir eskisi gibi cizilir (gorunum bozulmaz).
  List<Widget> _secimAltSatirlari(Map<String, dynamic> item) {
    final raw = item['extras'];
    List list;
    if (raw is List) {
      list = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        list = d is List ? d : const [];
      } catch (_) {
        return const [];
      }
    } else {
      return const [];
    }
    if (list.isEmpty) return const [];
    return [
      for (final e in list)
        if (e is Map) _secimAltSatiri(e),
    ];
  }

  /// 1 Agu 2026 — ADISYONDA COMBO GRUPLU GORUNUM (Mustafa: "ana kartin altinda sonradan
  /// eklenenler yine TIKLANABILIR olacak, not girmek icin falan").
  ///
  /// TASARIM KARARI: liste YENIDEN YAPILANDIRILMADI. Her kalem kendi satiri olarak kalir —
  /// yani secim, not girme, silme, parcali odeme HEPSI aynen calisir. Sadece GORSEL olarak
  /// gruplanir: grubun ILK kaleminin ustune ana urun basligi cizilir, kalem adlari girintili
  /// secim adina doner.
  /// Kanit kurali fisle AYNI: combo_group_id dolu + ayni kimlikte >=2 kalem. Yoksa hicbir sey
  /// degismez (eski gorunum birebir).
  Map<String, dynamic> _comboGrupBilgi(Map<String, dynamic> item) {
    final gid = (item['combo_group_id'] ?? '').toString().trim();
    if (gid.isEmpty) return const {'grupluMu': false};
    final uyeler = _ticketItems
        .where((x) =>
            x['status'] != 'cancelled' &&
            (x['combo_group_id'] ?? '').toString().trim() == gid)
        .toList();
    if (uyeler.length < 2) return const {'grupluMu': false};
    final ilkId = _safeInt(uyeler.first['id']);
    final buId = _safeInt(item['id']);
    final ad = (item['combo_group_name'] ?? '').toString().trim();
    return {
      'grupluMu': true,
      'ilkMi': ilkId != null && buId != null && ilkId == buId,
      'ad': ad.isNotEmpty ? ad : (item['product_name'] ?? '').toString(),
      'adet': uyeler.length,
    };
  }

  /// 2 Ağu 2026 — ÖDEME SEÇENEKLERİ kısayolu (adisyon başlığındaki rozet).
  /// ⚠️ YENİ AKIŞ YOK: sağ paneldeki butonların çağırdığı AYNI fonksiyonlar ve AYNI
  /// yetki kontrolleri kullanılır (_closeTicket / _printAndCloseTicket / _openPartialPayment).
  /// Dinamik ödeme yöntemleri (_dynamicPaymentMethods) da panelden geldiği gibi listelenir.
  /// Odeme secenekleri LISTESI — "Tumunu Gor" pop-up'inin SAG sutununda gosterilir.
  /// [kapat] secenek calistirilmadan once pop-up'i kapatir.
  /// [ikramYenile] 3 Agu 2026: İkram akisi bittikten sonra "Tumunu Gor" pop-up'i
  /// KAPANMAZ — bu callback listeyi/toplami tazeler (StatefulBuilder setState).
  Widget _odemeSecenekleriListesi(ThemeProvider theme, VoidCallback kapat,
      {Future<void> Function()? ikramYenile}) {
    final aktif = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
    final hasItems = aktif.isNotEmpty;
    final kapatabilir = hasItems && _hasPermission('close_ticket');
    final yazdirabilir = kapatabilir && _hasPermission('print_receipt');

    // 2 Agu 2026 (Mustafa): "odeme seceneklerini 2'serli yap, dinamik oldugu icin
    // ilerde cok eklenebilir" -> tam genislik satir yerine KOMPAKT KART, 2 sutunlu izgara.
    Widget satir({required IconData ikon, required String etiket, required Color renk,
        String? altYazi, VoidCallback? onTap}) {
      final aktifMi = onTap != null;
      return Material(
        color: aktifMi ? Colors.white : Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        elevation: aktifMi ? 1.5 : 0,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 86),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: aktifMi ? Colors.grey[200]! : Colors.grey[300]!),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    gradient: aktifMi
                        ? LinearGradient(colors: [renk, Color.lerp(renk, Colors.black, 0.22)!],
                            begin: Alignment.topLeft, end: Alignment.bottomRight)
                        : null,
                    color: aktifMi ? null : Colors.grey[350],
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: aktifMi
                        ? [BoxShadow(color: renk.withOpacity(0.28), blurRadius: 5, offset: const Offset(0, 2))]
                        : null,
                  ),
                  child: Icon(ikon, color: Colors.white, size: 18),
                ),
                const SizedBox(height: 7),
                Text(etiket,
                    textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.15,
                        color: aktifMi ? const Color(0xFF334155) : Colors.grey[500])),
                if (altYazi != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(altYazi,
                        textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: Colors.grey[600])),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    VoidCallback? sar(VoidCallback? f) => f == null ? null : () { kapat(); f(); };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF059669), Color(0xFF047857)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.payments_rounded, color: Colors.white, size: 15),
        ),
        const SizedBox(width: 8),
        const Text('Ödeme Seçenekleri',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 12),
      Flexible(
        child: SingleChildScrollView(
          child: LayoutBuilder(builder: (_, kis) {
            // 2 sutun: bosluk 10px, kalan genislik ikiye bolunur.
            final w = (kis.maxWidth - 10) / 2;
            Widget k(Widget c) => SizedBox(width: w, child: c);
            return Wrap(spacing: 10, runSpacing: 10, children: [
              k(satir(ikon: Icons.payments_rounded, etiket: 'Nakit Kapat', renk: theme.primaryColor,
                  onTap: sar(kapatabilir ? () => _closeTicket('cash') : null))),
              k(satir(ikon: Icons.credit_card_rounded, etiket: 'Kart Kapat', renk: const Color(0xFF3B82F6),
                  onTap: sar(kapatabilir ? () => _closeTicket('credit_card') : null))),
              k(satir(ikon: Icons.receipt_long_rounded, etiket: 'Yazdır + Nakit',
                  altYazi: 'fiş bas', renk: const Color(0xFF059669),
                  onTap: sar(yazdirabilir ? () => _printAndCloseTicket('cash') : null))),
              k(satir(ikon: Icons.receipt_long_rounded, etiket: 'Yazdır + Kart',
                  altYazi: 'fiş bas', renk: const Color(0xFF2563EB),
                  onTap: sar(yazdirabilir ? () => _printAndCloseTicket('credit_card') : null))),
              // Panelden gelen DINAMIK yontemler — kac tane olursa olsun izgaraya akar.
              for (final pm in _dynamicPaymentMethods)
                k(satir(ikon: Icons.account_balance_wallet_rounded,
                    etiket: '${pm['display_name']} Kapat', renk: const Color(0xFF7C3AED),
                    onTap: sar(kapatabilir
                        ? () => _closeTicket(pm['code'] as String,
                            methodLabel: pm['display_name'] as String?)
                        : null))),
              // 3 Agu 2026 (Mustafa: "flutterda ikram butonu yok? parcali odemenin
              // YANINDA olmasi lazimdi") — sorun buton EKSIKLIGI degildi, IZGARA KAYMASIYDI:
              // dinamik odeme yontemi sayisi TEK olunca Wrap Parcali'yi bir satirin sonuna,
              // Ikram'i BIR ALT satira atiyordu. Artik ikisi Wrap'in icinde AYNI SATIRDA
              // sabit bir cift olarak duruyor — dinamik yontem kac tane olursa olsun.
              SizedBox(
                width: kis.maxWidth,
                child: Row(children: [
                  Expanded(
                      child: satir(ikon: Icons.splitscreen_rounded, etiket: 'Parçalı Ödeme',
                          altYazi: 'seçili ürünler', renk: const Color(0xFF7C3AED),
                          onTap: sar(kapatabilir ? _openPartialPayment : null))),
                  const SizedBox(width: 10),
                  // IKRAM: SADECE ISARETLEME — ayri odeme yolu YOK. Kalem sec -> sebep
                  // (ayara gore zorunlu) -> onay; pop-up KAPANMAZ, liste tazelenir. Kalan
                  // tutar MEVCUT odeme butonlariyla kapatilir (backend close ikram'i duser).
                  // Yetki KATI (_hasPermission('ikram')): veri yoksa/offline'da PASIF —
                  // pasifken alt yazi NEDENINI soyler, sessizce olu buton olarak durmaz.
                  Expanded(
                      child: satir(ikon: Icons.card_giftcard_rounded, etiket: 'İkram',
                          // 3 Agu 2026 DUZELTME: SIRA onemli. _hasPermission('ikram')
                          // cevrimdisinda ZATEN false doner (offline beyaz listesinde
                          // 'ikram' yok) — yetki kontrolu once yazilinca cevrimdisi
                          // YETKILI garsona da "yetki yok" diyordu, 'cevrimici gerekli'
                          // dali ULASILAMAZ olu koddu. Once baglantiyi soyle.
                          altYazi: !widget.apiService.isOnline
                              ? 'çevrimiçi gerekli'
                              : (!_hasPermission('ikram') ? 'yetki yok' : 'kalem seç'),
                          renk: const Color(0xFFEA580C),
                          onTap: (hasItems && _hasPermission('ikram') && widget.apiService.isOnline)
                              ? () => _openIkramFlow(sonrasindaYenile: ikramYenile)
                              : null)),
                ]),
              ),
            ]);
          }),
        ),
      ),
    ]);
  }

  /// 2 Ağu 2026 — "TÜMÜNÜ GÖR": masadaki aktif ürünleri ADET BAZLI BİRLEŞTİRİP gösterir.
  /// Aynı ürün + aynı not + aynı seçimler tek satırda "4x Çay" olarak toplanır.
  /// ⚠️ SALT OKUNUR — hiçbir kalem, tutar, sıra veya akış değişmez. Sadece görüntüleme.
  /// 3 Agu 2026 IKRAM: pop-up StatefulBuilder oldu — ikram akisi bitince KAPANMADAN
  /// tazelenir (Mustafa akis 3). Ikramli gruplar rozet + ustu cizili; TOPLAM ikram
  /// dusulmus gosterilir + vurgulu "Kalan" satiri. Ikramli ile ikramsiz AYNI urun
  /// BIRLESTIRILMEZ (anahtara ikram bayragi eklendi) — rozet yanlis satira yapismasin.
  void _tumunuGorDialog(ThemeProvider theme) {
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(builder: (ctx, setDialogState) {
        final aktif = _ticketItems.where((i) => i['status'] != 'cancelled').toList();

        // Birlestirme anahtari: urun adi + not + secimler + ikram bayragi
        // (varyant/ekstra farkli olan AYRI satir kalir)
        String anahtar(Map i) {
          final ad = (i['product_name'] ?? '').toString().trim();
          final not = (i['notes'] ?? '').toString().trim();
          var ex = i['extras'];
          if (ex is String) { try { ex = jsonDecode(ex); } catch (_) { ex = null; } }
          final exAd = (ex is List)
              ? ex.map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString()).join('|')
              : '';
          final ik = IkramRules.kalemIkramMi(i) ? '1' : '0';
          return '$ad##$not##$exAd##ik$ik';
        }

        final gruplar = <String, Map<String, dynamic>>{};
        for (final i in aktif) {
          final k = anahtar(i as Map);
          final adet = (_safeInt(i['quantity']) ?? 1);
          final tutar = _safeDouble(i['unit_price']) * adet;
          if (gruplar.containsKey(k)) {
            gruplar[k]!['adet'] = (gruplar[k]!['adet'] as int) + adet;
            gruplar[k]!['tutar'] = (gruplar[k]!['tutar'] as double) + tutar;
          } else {
            gruplar[k] = {
              'ad': (i['product_name'] ?? '').toString(),
              'not': (i['notes'] ?? '').toString().trim(),
              'adet': adet,
              'tutar': tutar,
              'ikram': IkramRules.kalemIkramMi(i),
            };
          }
        }
        final liste = gruplar.values.toList()
          ..sort((a, b) => (b['adet'] as int).compareTo(a['adet'] as int));
        final toplamAdet = liste.fold<int>(0, (t, g) => t + (g['adet'] as int));
        // TOPLAM = brut - ikram (Mustafa: "TOPLAM ikram dusulmus haliyle").
        final brutToplam = liste.fold<double>(0, (t, g) => t + (g['tutar'] as double));
        final ikramTutari = _ikramTotal;
        final toplamTutar = (brutToplam - ikramTutari) < 0 ? 0.0 : (brutToplam - ikramTutari);
        // Kalan = odenmemis + ikram olmayan kalemler (tahsil edilecek gercek miktar)
        final kalanTutar = _unpaidTotal;

        return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          // 2 Agu 2026 (Mustafa): "odeme secenekleri butonunu tumunu gor pop'una SAGINA ekle".
          // Ayri buton YOK; tek pop-up iki sutun: SOL birlesik urun listesi, SAG odeme.
          width: 930,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.86),
          padding: const EdgeInsets.all(18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [theme.primaryColor, theme.primaryColor.withOpacity(0.78)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.list_alt_rounded, color: Colors.white, size: 17),
              ),
              const SizedBox(width: 10),
              const Expanded(child: Text('Masadaki Ürünler',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(ctx)),
            ]),
            const SizedBox(height: 4),
            Text('$toplamAdet ürün · ${liste.length} çeşit',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const Divider(height: 18),
            Flexible(
              child: liste.isEmpty
                  ? Padding(padding: const EdgeInsets.all(24),
                      child: Text('Masada ürün yok', style: TextStyle(color: Colors.grey[500])))
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: liste.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey[200]),
                      itemBuilder: (_, idx) {
                        final g = liste[idx];
                        final not = (g['not'] as String);
                        // 3 Agu 2026 IKRAM: rozet + tutar ustu cizili (parasi alinmayacak)
                        final ikramMi = g['ikram'] == true;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              constraints: const BoxConstraints(minWidth: 38),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: ikramMi
                                    ? const Color(0xFFEA580C).withOpacity(0.12)
                                    : theme.primaryColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('${g['adet']}x',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: ikramMi ? const Color(0xFFEA580C) : theme.primaryColor,
                                      fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Flexible(
                                    child: Text(g['ad'] as String,
                                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                                  ),
                                  if (ikramMi) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEA580C),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text('İKRAM',
                                          style: TextStyle(color: Colors.white, fontSize: 9.5,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ]),
                                if (not.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(not,
                                        style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
                                  ),
                              ]),
                            ),
                            const SizedBox(width: 8),
                            Text('₺${(g['tutar'] as double).toStringAsFixed(2)}',
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600,
                                    color: ikramMi ? Colors.grey[500] : Colors.grey[800],
                                    decoration: ikramMi ? TextDecoration.lineThrough : null,
                                    decorationColor: Colors.grey[600])),
                          ]),
                        );
                      },
                    ),
            ),
            const Divider(height: 18),
            // 3 Agu 2026 IKRAM: ikram varsa dusum satiri, TOPLAM ikram dusulmus.
            if (ikramTutari > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('İkram', style: TextStyle(fontSize: 12, color: Color(0xFFEA580C))),
                  Text('-₺${ikramTutari.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                          color: Color(0xFFEA580C))),
                ]),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('TOPLAM', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              Text('₺${toplamTutar.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.primaryColor)),
            ]),
            // Vurgulu KALAN satiri (Mustafa: gorsel kolaylik — tahsil edilecek miktar)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF059669).withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF059669).withOpacity(0.35)),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Kalan',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF047857))),
                Text('₺${kalanTutar.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                        color: Color(0xFF047857))),
              ]),
            ),
            ]),
          ),
          // --- AYRAC ---
          Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 16),
              color: Colors.grey[200]),
          // --- SAG: odeme secenekleri (ayni fonksiyonlar, yeni akis YOK) ---
          SizedBox(
            width: 360,
            child: _odemeSecenekleriListesi(theme, () => Navigator.pop(ctx),
                // 3 Agu 2026: ikram sonrasi pop-up KAPANMAZ — liste/toplam tazelenir.
                ikramYenile: () async {
                  await _loadTicketItems();
                  if (ctx.mounted) setDialogState(() {});
                }),
          ),
          ]),
        ),
        );
      }),
    );
  }

  Widget _buildTicketItemRow(Map<String, dynamic> item, ThemeProvider theme, int index, bool isSelected) {
    final quantity = _safeInt(item['quantity']) ?? 1;
    final unitPrice = _safeDouble(item['unit_price']);
    final total = unitPrice * quantity;
    final notes = item['notes'] as String?;
    final isPaid = item['payment_status'] == 'paid';
    final payMethod = item['payment_method']?.toString().toUpperCase() ?? '';
    // Backend'den gelen ekleyen garson + saat (TR lokal)
    final addedBy = item['added_by_name']?.toString() ?? '';
    final addedTime = _formatItemTime(item['created_at']);
    // 19 May 2026: Mutfak'a yazdirilmis mi? Backend'den printed=1 veya true geliyor.
    final isPrinted = item['printed'] == 1 || item['printed'] == true;
    // 21 May 2026: skip_pos_print=true ürünlerde badge gösterilmez (içecek/su gibi
    // restoran yazıcısına gönderilmeyen, garson elden getiren ürünler).
    final skipRaw = item['skip_pos_print'];
    final isSkipPrint = skipRaw == true || skipRaw == 1 || skipRaw == '1' || skipRaw == 'true' || skipRaw == 't';
    // 3 Agu 2026 IKRAM (Mustafa: adisyona bakan HERKES gormeli, pop-up acmak zorunda kalmasin):
    // rozet + tutar ustu cizili/soluk. SADECE gorsel — tutar hesabi getter'larda (_ikramTotal).
    final isIkram = IkramRules.kalemIkramMi(item);
    final ikramReason = (item['ikram_reason'] ?? '').toString().trim();
    // Combo gruplu gorunum bilgisi (hata olursa gruplama YOK -> eski gorunum).
    Map<String, dynamic> _grupBilgi;
    try {
      _grupBilgi = _comboGrupBilgi(item);
    } catch (_) {
      _grupBilgi = const {'grupluMu': false};
    }

    // 22 May 2026: Dokunmatik POS — GestureDetector → InkWell (ripple)
    return Material(
      color: isPaid
          ? Colors.green[50]
          : (isSelected ? theme.primaryColor.withOpacity(0.08) : Colors.transparent),
      child: InkWell(
        onTap: () {
          final itemId = _safeInt(item['id']);
          setState(() => _selectedItemId = isSelected ? null : itemId);
        },
        splashColor: theme.primaryColor.withOpacity(0.18),
        highlightColor: theme.primaryColor.withOpacity(0.08),
        child: Container(
          // 31 Tem 2026 (Mustafa): "adisyon kalemleri cok buyuk, uzunlugu kisalsin, amac daha
          // COK URUN SIGMASI". Olculu kucultme: dikey bosluk 16->9, adet rozeti 40->34,
          // yazi 18->16.5. Satir ~105px -> ~80px (%25 daha fazla kalem). Dokunma alani
          // hala ~80px (44px esiginin cok ustunde) — dokunmatik kasada kayip yok.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[200]!),
              left: isSelected ? BorderSide(color: theme.primaryColor, width: 4) : BorderSide.none,
            ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: isPaid ? Colors.green : theme.primaryColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(child: Text('$quantity', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1 Agu 2026: combo grubunda ILK kalemin ustunde ANA URUN basligi.
                  if (_grupBilgi['grupluMu'] == true && _grupBilgi['ilkMi'] == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(children: [
                        Icon(Icons.card_giftcard_rounded, size: 14, color: Colors.green[700]),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _grupBilgi['ad']?.toString() ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.green[800],
                            ),
                          ),
                        ),
                        Text('${_grupBilgi['adet']} secim',
                            style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ]),
                    ),
                  Text(
                    // Grupluysa kalem adi yerine SECIM adi gosterilir (fisle ayni gorunum).
                    _grupBilgi['grupluMu'] == true
                        ? '• ' +
                            ((item['combo_pick_name'] ?? item['product_name'] ?? '').toString())
                        : (item['product_name']?.toString() ?? ''),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _grupBilgi['grupluMu'] == true ? 14.5 : 16.5,
                      fontWeight: _grupBilgi['grupluMu'] == true
                          ? FontWeight.w500
                          : FontWeight.w600,
                      color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
                    ),
                  ),
                  if (notes != null && notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(notes, style: TextStyle(fontSize: 12.5, color: Colors.grey[600], fontStyle: FontStyle.italic)),
                    ),
                  // 31 Tem 2026 — POS VARYANT COKLU SECIM: secimler urun adinin ALTINDA
                  // satir satir (web deseni). Urun adi TEMIZ kalir. extras yoksa (combo'suz,
                  // tekli varyantli, eski kayitlar) HICBIR SEY cizilmez -> gorunum aynen eskisi.
                  ..._secimAltSatirlari(item),
                  // Ekleyen garson + saat — Omer Bey istegi
                  if (addedBy.isNotEmpty || addedTime.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(children: [
                        Icon(Icons.person_outline, size: 12, color: Colors.grey[500]),
                        const SizedBox(width: 3),
                        // Flexible: uzun garson adi dar sepette tasmasin (1.1px overflow fix).
                        Flexible(
                          child: Text(
                            addedBy.isNotEmpty ? addedBy : 'Bilinmiyor',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: Colors.grey[700], fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (addedTime.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.access_time, size: 12, color: Colors.grey[500]),
                          const SizedBox(width: 3),
                          Text(addedTime, style: TextStyle(fontSize: 11, color: Colors.grey[700])),
                        ],
                      ]),
                    ),
                  // 3 Agu 2026 IKRAM rozeti — TESLIM (yesil) / IPTAL (kirmizi) / MUTFAKTA (amber)
                  // ile karismasin diye TURUNCU (0xFFEA580C). Sebep varsa kucuk punto ile yaninda.
                  if (isIkram)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEA580C),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'İKRAM',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (ikramReason.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              ikramReason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, color: Colors.orange[800], fontStyle: FontStyle.italic),
                            ),
                          ),
                        ],
                      ]),
                    ),
                  if (isPaid)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: payMethod == 'CASH' ? Colors.green : Colors.blue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        payMethod == 'CASH' ? 'NAKİT' : 'KART',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 19 May 2026: Mutfaga yazdirildi mi badge'i — Omer Bey istegi
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${total.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.bold,
                    // 3 Agu 2026 IKRAM: tutar ustu cizili + soluk — "parasi alinmayacak"
                    // bir bakista anlasilir. Hesap zaten getter'larda dusuluyor (gorsel).
                    color: isIkram
                        ? Colors.grey[500]
                        : (isPaid ? Colors.green[700] : const Color(0xFF1F2937)),
                    decoration: isIkram ? TextDecoration.lineThrough : null,
                    decorationColor: isIkram ? Colors.grey[600] : null,
                  ),
                ),
                const SizedBox(height: 2),
                if (!isSkipPrint)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isPrinted ? const Color(0xFF059669) : const Color(0xFFDC2626),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPrinted ? Icons.check_circle : Icons.error_outline,
                          size: 10,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          isPrinted ? 'YAZDIRILDI' : 'YAZDIRILMADI',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(ThemeProvider theme, bool hasItems) {
    print('[AddItemModal] _buildActionButtons: hasItems=$hasItems, _selectedItemId=$_selectedItemId, cancel_perm=${_hasPermission("cancel_item")}');
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Column(
        children: [
          // İlk satır: Not Ekle + Varyant + Urun Iptal
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.edit_note_rounded,
                  label: 'Not Ekle',
                  color: Colors.blueGrey,
                  onTap: hasItems && _selectedItemId != null ? _openNoteDialog : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.tune_rounded,
                  label: 'Varyant',
                  color: const Color(0xFFF59E0B),
                  onTap: hasItems && _selectedItemId != null && _variantsForSelectedItem().isNotEmpty
                      ? _openVariantDialogForSelected
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.close_rounded,
                  label: 'Ürün İptal',
                  color: Colors.red[400]!,
                  onTap: hasItems && _selectedItemId != null
                      ? () async {
                          print('[AddItemModal] Ürün İptal butonuna tıklandı! selectedItemId=$_selectedItemId');
                          // 23 May 2026: cancel_item VEYA cancel_item_unprinted yetki kontrolu
                          // (Detay mutfaga-gitmis kontrolu _cancelSelectedItem icinde)
                          if (!_hasPermission('cancel_item') && !_hasPermission('cancel_item_unprinted')) {
                            print('[AddItemModal] cancel yetkisi YOK');
                            await showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Yetki Hatası'),
                                content: const Text('Ürün iptal yetkiniz bulunmamaktadır'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam')),
                                ],
                              ),
                            );
                            return;
                          }
                          print('[AddItemModal] cancel_item yetkisi VAR, _cancelSelectedItem çağrılıyor');
                          _cancelSelectedItem();
                        }
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // İkinci satır: Mutfağa Gönder + Yazdır
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.restaurant_rounded,
                  label: 'Mutfak',
                  color: const Color(0xFFF59E0B),
                  onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.print_rounded,
                  label: 'Yazdır',
                  color: Colors.blueGrey,
                  onTap: hasItems && _hasPermission('print_receipt') ? _printTicket : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Parçalı Ödeme (tam genişlik)
          SizedBox(
            width: double.infinity,
            child: _buildActionBtn(
              icon: Icons.splitscreen_rounded,
              label: 'Parçalı Ödeme',
              color: const Color(0xFF7C3AED),
              onTap: hasItems && _hasPermission('close_ticket') ? _openPartialPayment : null,
            ),
          ),
          const SizedBox(height: 6),
          // Üçüncü satır: Nakit + Kredi Kartı
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.payments_rounded,
                  label: 'Nakit',
                  color: theme.primaryColor,
                  onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.credit_card_rounded,
                  label: 'Kredi Kartı',
                  color: const Color(0xFF3B82F6),
                  onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('credit_card') : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Dördüncü satır: Yazdır+Nakit + Yazdır+Kart
          Row(
            children: [
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.receipt_long_rounded,
                  label: 'Yaz+Nakit',
                  color: const Color(0xFF059669),
                  onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt')
                      ? () => _printAndCloseTicket('cash')
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.receipt_long_rounded,
                  label: 'Yaz+Kart',
                  color: const Color(0xFF2563EB),
                  onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt')
                      ? () => _printAndCloseTicket('credit_card')
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Masa Değiştir + İndirim
          Row(
            children: [
              if (_hasPermission('transfer_table'))
                Expanded(
                  child: _buildActionBtn(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Masa Değiştir',
                    color: const Color(0xFF0EA5E9),
                    onTap: hasItems ? _transferTable : null,
                  ),
                ),
              if (_hasPermission('transfer_table')) const SizedBox(width: 6),
              if (_hasPermission('apply_discount'))
                Expanded(
                  child: _buildActionBtn(
                    icon: Icons.percent_rounded,
                    label: 'İndirim',
                    color: const Color(0xFFE11D48),
                    onTap: hasItems ? _openDiscountDialog : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Son satır: Adisyon İptal
          if (_hasPermission('void_ticket'))
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                icon: Icons.delete_outline_rounded,
                label: 'Adisyon İptal',
                color: const Color(0xFFDC2626),
                onTap: _voidTicket,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    // 22 May 2026: Dokunmatik POS — InkWell + min 64 yukseklik + ripple feedback
    // 2 Agu 2026: SADECE GORSEL yenileme — dikey degrade dolgu (color → koyusu),
    // yumusak renkli golge, radius 12; disabled = mat gri, golgesiz (net ayrim).
    final isDisabled = onTap == null;
    final Color koyu = Color.lerp(color, Colors.black, 0.18)!;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: isDisabled
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color, koyu],
              ),
        color: isDisabled ? const Color(0xFFE2E8F0) : null,
        boxShadow: isDisabled
            ? null
            : [
                BoxShadow(
                  color: color.withOpacity(0.30),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: isDisabled ? null : () => onTap(),
          borderRadius: BorderRadius.circular(12),
          splashColor: Colors.white.withOpacity(0.35),
          highlightColor: Colors.white.withOpacity(0.18),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: isDisabled ? const Color(0xFF94A3B8) : Colors.white, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: isDisabled ? const Color(0xFF94A3B8) : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductImage(Map<String, dynamic> product) {
    final imagePath = product['image']?.toString() ?? '';
    if (imagePath.isEmpty) return _buildPlaceholder(product);
    final imageUrl = widget.apiService.getImageUrl(imagePath);

    if (_imageCacheReady) {
      try {
        final cachePath = _imageCache.getCachePath(imageUrl);
        if (cachePath.isNotEmpty) {
          final cacheFile = File(cachePath);
          if (cacheFile.existsSync()) {
            return Image.file(cacheFile, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildPlaceholder(product));
          }
        }
      } catch (_) {}
    }

    return FutureBuilder<String?>(
      future: _imageCache.downloadAndCache(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey[200],
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Provider.of<ThemeProvider>(context, listen: false).primaryColor)),
          );
        }
        if (snapshot.hasData && snapshot.data != null) {
          final cacheFile = File(snapshot.data!);
          if (cacheFile.existsSync()) {
            return Image.file(cacheFile, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildPlaceholder(product));
          }
        }
        return _buildPlaceholder(product);
      },
    );
  }

  Widget _buildPlaceholder(Map<String, dynamic> product) {
    final emoji = product['category_icon'] ?? '🍽️';
    return Container(
      color: Colors.grey[100],
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 32))),
    );
  }

  // ISO timestamp -> "HH:mm" Turkiye lokal saati. Backend UTC dondukten sonra .toLocal().
  String _formatItemTime(dynamic iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Widget _sectionChip({
    required String label,
    required int count,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? color : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? color : Colors.grey.shade300, width: 2),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.grey.shade700,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: selected ? Colors.white.withValues(alpha: 0.22) : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: selected ? Colors.white : Colors.grey.shade600,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 12, height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
    ]);
  }
}

/// Parçalı Ödeme Dialog
class _PartialPaymentDialog extends StatefulWidget {
  final List<dynamic> items;
  final int ticketId;
  final int? waiterId;
  final ApiService apiService;
  final Function(bool allPaid) onPaymentComplete;
  final VoidCallback onClose;

  const _PartialPaymentDialog({
    required this.items,
    required this.ticketId,
    required this.apiService,
    required this.onPaymentComplete,
    required this.onClose,
    this.waiterId,
  });

  @override
  State<_PartialPaymentDialog> createState() => _PartialPaymentDialogState();
}

class _PartialPaymentDialogState extends State<_PartialPaymentDialog> {
  late List<Map<String, dynamic>> _items;
  final Set<int> _selectedIds = {};
  bool _isProcessing = false;

  double _safeDouble(dynamic value, [double defaultValue = 0]) {
    if (value == null) return defaultValue;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? defaultValue;
  }

  @override
  void initState() {
    super.initState();
    _items = widget.items.map((i) => Map<String, dynamic>.from(i)).toList();
  }

  double get _selectedTotal {
    double total = 0;
    for (var item in _items) {
      final itemId = item['id'] as int?;
      if (itemId != null && _selectedIds.contains(itemId)) {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  double get _totalAmount {
    double total = 0;
    for (var item in _items) {
      // 3 Agu 2026 IKRAM: ikram kalemin parasi ALINMAZ -> "Kalan"a girmez
      if (IkramRules.kalemIkramMi(item)) continue;
      if (item['payment_status'] != 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

  void _toggleItem(int itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  void _selectAll() {
    setState(() {
      for (var item in _items) {
        // 3 Agu 2026 IKRAM: ikram kalem SECILEMEZ (parasi alinmayacak) — toplu secime girmez
        if (IkramRules.kalemIkramMi(item)) continue;
        if (item['payment_status'] != 'paid') {
          final id = item['id'] as int?;
          if (id != null) _selectedIds.add(id);
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  Future<void> _paySelected(String paymentMethod) async {
    if (_selectedIds.isEmpty || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: _selectedIds.toList(),
        paymentMethod: paymentMethod,
      );

      if (result['success'] == true) {
        // Ödenen ürünleri güncelle
        for (var item in _items) {
          if (_selectedIds.contains(item['id'])) {
            item['payment_status'] = 'paid';
            item['payment_method'] = paymentMethod;
          }
        }
        _selectedIds.clear();

        // Tüm ürünler ödendi mi? Evet ise ticket'i de kapat (masa bossun)
        // 3 Agu 2026 IKRAM: ikram kalemler odenmez ama adisyon kapanisini ENGELLEMEZ —
        // "odenmis VEYA ikram" ise tamam say (backend close ikram'i tahsilattan zaten duser).
        final allPaid = _items.every(
            (i) => i['payment_status'] == 'paid' || IkramRules.kalemIkramMi(i));
        if (allPaid) {
          try {
            await widget.apiService.closeTicket(
              ticketId: widget.ticketId,
              paymentMethod: paymentMethod,
              waiterId: widget.waiterId,
            );
          } catch (e) {
            _showError('Adisyon kapatilamadi: $e');
            return;
          }
        }
        widget.onPaymentComplete(allPaid);
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Ödeme hatası: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _closeAll(String paymentMethod) async {
    if (_isProcessing) return;

    // 3 Agu 2026 IKRAM: ikram kalemler payItems'a gitmez (parasi alinmayacak)
    final unpaidIds = _items
        .where((i) => i['payment_status'] != 'paid' && !IkramRules.kalemIkramMi(i))
        .map((i) => i['id'] as int)
        .toList();

    if (unpaidIds.isEmpty) return;

    // Toplam tutarı hesapla
    double unpaidTotal = 0;
    for (var item in _items) {
      if (IkramRules.kalemIkramMi(item)) continue;
      if (item['payment_status'] != 'paid') {
        unpaidTotal += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }

    final label = paymentMethod == 'cash' ? 'Nakit' : 'Kredi Kartı';
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Adisyon Kapat', style: TextStyle(fontSize: 22)),
        content: Text('${unpaidIds.length} ürün ${unpaidTotal.toStringAsFixed(2)} TL $label ile ödenecek ve adisyon kapatılacak.\n\nDevam edilsin mi?', style: const TextStyle(fontSize: 16)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(width: 150, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, false), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[300], foregroundColor: Colors.black87), child: const Text('İptal', style: TextStyle(fontSize: 18)))),
          SizedBox(width: 200, height: 56, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: paymentMethod == 'cash' ? Colors.green : Colors.blue, foregroundColor: Colors.white), child: const Text('Öde ve Kapat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isProcessing = true);

    try {
      final result = await widget.apiService.payItems(
        ticketId: widget.ticketId,
        itemIds: unpaidIds,
        paymentMethod: paymentMethod,
      );

      if (result['success'] == true) {
        // Tum urunler odendi - adisyonu kapat
        try {
          await widget.apiService.closeTicket(
            ticketId: widget.ticketId,
            paymentMethod: paymentMethod,
            waiterId: widget.waiterId,
          );
        } catch (e) {
          _showError('Adisyon kapatilamadi: $e');
          return;
        }
        widget.onPaymentComplete(true);
      } else {
        _showError(result['error'] ?? 'Ödeme başarısız');
      }
    } catch (e) {
      _showError('Ödeme hatası: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    // 3 Agu 2026 IKRAM KARARI: ikram kalemler listede GORUNUR ama SECILEMEZ (kilitli).
    // Gizlenirse kasiyer "urun kayboldu" sanir; kilitli+rozetli gosterim durumu anlatir
    // (odenmis kalemlerin kilitli gosterimiyle ayni desen).
    final ikramItems = _items
        .where((i) => i['payment_status'] != 'paid' && IkramRules.kalemIkramMi(i))
        .toList();
    final unpaidItems = _items
        .where((i) => i['payment_status'] != 'paid' && !IkramRules.kalemIkramMi(i))
        .toList();
    final paidItems = _items.where((i) => i['payment_status'] == 'paid').toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      // Scaffold yerine direkt Container kullan ki arkada beyaz Scaffold pencere çıkmasın
      // Center ile ekranın ortasına yerleştir
      child: Center(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.7,
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.splitscreen, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Text('Parçalı Ödeme', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    // Tümünü Seç / Seçimi Kaldır
                    // 22 May 2026: Dokunmatik POS — InkWell + min 44
                    Material(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () => _selectedIds.length == unpaidItems.length ? _clearSelection() : _selectAll(),
                        borderRadius: BorderRadius.circular(8),
                        splashColor: Colors.white.withOpacity(0.3),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: Center(
                            child: Text(
                              _selectedIds.length == unpaidItems.length ? 'Seçimi Kaldır' : 'Tümünü Seç',
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () => widget.onClose(),
                        borderRadius: BorderRadius.circular(8),
                        splashColor: Colors.white.withOpacity(0.3),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.close, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Ürün listesi
              Expanded(
                child: Row(
                  children: [
                    // Sol: Ürünler
                    Expanded(
                      flex: 3,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (unpaidItems.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Ödenmemiş Ürünler', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                            ),
                            ...unpaidItems.map((item) => _buildPaymentItem(item, theme, false)),
                          ],
                          // 3 Agu 2026 IKRAM: kilitli bolum — tahsil edilmez, secilemez
                          if (ikramItems.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('İkram Ürünler (tahsil edilmez)',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange[800])),
                            ),
                            ...ikramItems.map((item) => _buildPaymentItem(item, theme, false)),
                          ],
                          if (paidItems.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Ödenen Ürünler', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[700])),
                            ),
                            ...paidItems.map((item) => _buildPaymentItem(item, theme, true)),
                          ],
                        ],
                      ),
                    ),

                    // Sağ: Özet + butonlar
                    Container(
                      width: 220,
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        border: Border(left: BorderSide(color: Colors.grey[200]!)),
                      ),
                      child: Column(
                        children: [
                          // Seçili ürünler özeti
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Seçili: ${_selectedIds.length} ürün', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_selectedTotal.toStringAsFixed(2)} TL',
                                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.primaryColor),
                                  ),
                                  const Divider(),
                                  Text('Kalan: ${_totalAmount.toStringAsFixed(2)} TL', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                ],
                              ),
                            ),
                          ),

                          // Ödeme butonları
                          Container(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                // Seçilenleri öde
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildPayBtn(
                                        icon: Icons.payments,
                                        label: 'Nakit',
                                        color: theme.primaryColor,
                                        onTap: _selectedIds.isNotEmpty && !_isProcessing ? () => _paySelected('cash') : null,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _buildPayBtn(
                                        icon: Icons.credit_card,
                                        label: 'Kart',
                                        color: const Color(0xFF3B82F6),
                                        onTap: _selectedIds.isNotEmpty && !_isProcessing ? () => _paySelected('card') : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Loading bar
              if (_isProcessing)
                LinearProgressIndicator(color: const Color(0xFF7C3AED)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentItem(Map<String, dynamic> item, ThemeProvider theme, bool isPaid) {
    final itemId = item['id'] as int?;
    final isSelected = itemId != null && _selectedIds.contains(itemId);
    final qty = item['quantity'] ?? 1;
    final price = _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
    final paymentMethod = item['payment_method']?.toString().toUpperCase() ?? '';
    // 3 Agu 2026 IKRAM: kilitli gorunum — secilemez, tutari ustu cizili, turuncu rozet
    final isIkram = !isPaid && IkramRules.kalemIkramMi(item);

    // Renk şeması:
    //   Ödenmiş → yeşil
    //   İkram → turuncu (kilitli)
    //   Seçili (ödenmemiş) → mor (purple seçim rengi)
    //   Ödenmemiş (seçilmemiş) → kırmızı/uyarı
    final unpaidBg = const Color(0xFFFEE2E2);  // red-100
    final unpaidBorder = const Color(0xFFEF4444);  // red-500
    final unpaidText = const Color(0xFFB91C1C);  // red-700

    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final Color qtyBg;
    if (isPaid) {
      bgColor = Colors.green[50]!;
      borderColor = Colors.green[300]!;
      textColor = Colors.green[700]!;
      qtyBg = Colors.green;
    } else if (isIkram) {
      bgColor = const Color(0xFFFFF7ED);            // orange-50
      borderColor = const Color(0xFFFDBA74);        // orange-300
      textColor = const Color(0xFF9A3412);          // orange-800
      qtyBg = const Color(0xFFEA580C);              // orange-600
    } else if (isSelected) {
      bgColor = const Color(0xFF7C3AED).withOpacity(0.10);
      borderColor = const Color(0xFF7C3AED);
      textColor = const Color(0xFF1F2937);
      qtyBg = const Color(0xFF7C3AED);
    } else {
      bgColor = unpaidBg;
      borderColor = unpaidBorder;
      textColor = unpaidText;
      qtyBg = unpaidBorder;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        // 3 Agu 2026 IKRAM: kilitli — tiklanamaz (odenmis gibi)
        onTap: (isPaid || isIkram) ? null : () { if (itemId != null) _toggleItem(itemId); },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // Checkbox (ikram kaleminde checkbox YOK — secilemez)
              if (!isPaid && !isIkram)
                Container(
                  width: 24, height: 24,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF7C3AED) : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: isSelected ? const Color(0xFF7C3AED) : unpaidBorder, width: 2),
                  ),
                  child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                ),
              // Miktar
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: qtyBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(child: Text('$qty', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              ),
              const SizedBox(width: 10),
              // Ürün adı
              Expanded(
                child: Text(
                  item['product_name']?.toString() ?? '',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
              // Badge (ödenmişse — yeşil/mavi; ikramsa — turuncu İKRAM; ödenmemişse — kırmızı)
              if (isPaid)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: paymentMethod == 'CASH' ? Colors.green : Colors.blue,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    paymentMethod == 'CASH' ? 'NAKİT' : 'KART',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                )
              else if (isIkram)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEA580C),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'İKRAM',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                )
              else if (!isSelected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: unpaidBorder,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'ÖDENMEDİ',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              // Fiyat (ikramda ustu cizili — tahsil edilmez)
              Text(
                '${price.toStringAsFixed(2)} TL',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  decoration: isIkram ? TextDecoration.lineThrough : null,
                  decorationColor: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPayBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    // 22 May 2026: Dokunmatik POS — InkWell + min 56
    final isDisabled = onTap == null;
    return Material(
      color: isDisabled ? Colors.grey[200] : color,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: isDisabled ? null : () => onTap(),
        borderRadius: BorderRadius.circular(8),
        splashColor: Colors.white.withOpacity(0.35),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: isDisabled ? Colors.grey[400] : Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3 Agu 2026 — IKRAM Dialog (Parcali Odeme kalibiyla ayni iskelet: kalem sec -> onayla).
/// SADECE ISARETLEME yapar (PUT .../ikram) — odeme almaz. Basarida kapanir, cagiran
/// "Tumunu Gor" gorunumune doner ve tazelenir. Geri alma: ikramli kalem sec -> Geri Al
/// (iptal:true) -> rozet kalkar, tutar geri eklenir.
class _IkramDialog extends StatefulWidget {
  final List<dynamic> items;
  final int ticketId;
  final int? waiterId;
  final ApiService apiService;
  final List<Map<String, dynamic>> sebepler;
  final bool sebepZorunlu;
  final VoidCallback onClose;
  final VoidCallback onDone;

  const _IkramDialog({
    required this.items,
    required this.ticketId,
    required this.apiService,
    required this.sebepler,
    required this.sebepZorunlu,
    required this.onClose,
    required this.onDone,
    this.waiterId,
  });

  @override
  State<_IkramDialog> createState() => _IkramDialogState();
}

class _IkramDialogState extends State<_IkramDialog> {
  static const _turuncu = Color(0xFFEA580C);
  late List<Map<String, dynamic>> _items;
  final Set<int> _selectedIds = {};
  bool _isProcessing = false; // async guard — cift tiklama kilidi

  double _safeDouble(dynamic value, [double defaultValue = 0]) {
    if (value == null) return defaultValue;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? defaultValue;
  }

  @override
  void initState() {
    super.initState();
    _items = widget.items.whereType<Map>().map((i) => Map<String, dynamic>.from(i)).toList();
  }

  bool _secilebilir(Map<String, dynamic> item) =>
      item['payment_status'] != 'paid'; // odenmis kalem backend'de zaten reddedilir

  List<Map<String, dynamic>> get _secili =>
      _items.where((i) => _selectedIds.contains(i['id'])).toList();

  bool get _seciliHepsiNormal =>
      _secili.isNotEmpty && _secili.every((i) => !IkramRules.kalemIkramMi(i));
  bool get _seciliHepsiIkram =>
      _secili.isNotEmpty && _secili.every((i) => IkramRules.kalemIkramMi(i));

  double get _seciliTutar {
    double t = 0;
    for (final i in _secili) {
      t += _safeDouble(i['unit_price']) * _safeDouble(i['quantity'], 1);
    }
    return t;
  }

  void _toggle(int itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  /// Sebep sor: listeden chip secimi; liste BOSSA serbest metin. Zorunluluk ayara gore:
  /// zorunluysa sebepsiz onay PASIF; degilse "Sebepsiz Devam" ile bos gecilebilir.
  /// Doner: null = vazgec, String = sebep ('' = sebepsiz, sadece zorunlu DEGILKEN mumkun).
  Future<String?> _sebepSor() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? secilen;
        return StatefulBuilder(builder: (ctx, setDlg) {
          final listeVar = widget.sebepler.isNotEmpty;
          // 3 Agu 2026 — liste BOSSA serbest metin YOK: girilen daima bos kalir.
          // Zorunluysa onay butonu PASIF olur (veri girisi ZORUNLU), opsiyonelse
          // "Sebepsiz Devam" ile gecilebilir.
          final girilen = listeVar ? (secilen ?? '') : '';
          // Zorunluluk karari saf ve testli: IkramRules.onaylanabilirMi
          // (zorunluysa sebepsiz onay PASIF; opsiyonelse gecilebilir).
          final onaylanabilir =
              IkramRules.onaylanabilirMi(girilen: girilen, zorunlu: widget.sebepZorunlu);
          return Material(
            type: MaterialType.transparency,
            child: Center(
              child: Container(
                width: 460,
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: const [
                      Icon(Icons.card_giftcard_rounded, color: _turuncu, size: 24),
                      SizedBox(width: 8),
                      Expanded(child: Text('İkram Sebebi',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      widget.sebepZorunlu
                          ? 'Lütfen ikram sebebini seçin (zorunlu)'
                          : 'İkram sebebi seçebilirsiniz (opsiyonel)',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    if (listeVar)
                      Flexible(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: widget.sebepler.map<Widget>((r) {
                              final sebep = (r['reason'] ?? '').toString();
                              final isSelected = secilen == sebep;
                              return Material(
                                color: isSelected ? _turuncu : Colors.grey[100],
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  onTap: () => setDlg(() => secilen = isSelected ? null : sebep),
                                  borderRadius: BorderRadius.circular(8),
                                  splashColor: _turuncu.withOpacity(0.3),
                                  child: Container(
                                    constraints: const BoxConstraints(minHeight: 48),
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: isSelected ? _turuncu : Colors.grey[300]!,
                                          width: isSelected ? 2 : 1),
                                    ),
                                    child: Text(sebep,
                                        style: TextStyle(
                                            color: isSelected ? Colors.white : Colors.grey[800],
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 13)),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      )
                    else
                      // 3 Agu 2026 (Mustafa: "eger ikram sebebi adminden girilmediyse
                      // iptaldeki gibi YOLUNU ANLAT, veri girisine ZORUNLU hale getir")
                      // — onceki surumde serbest metin kabul ediliyordu; artik sebep
                      // listesi BOSSA kullanici serbest yazamaz, panelde tanimlamaya
                      // yonlendirilir. Sebep OPSIYONEL isaretliyse "Sebepsiz Devam"
                      // yine calisir (panelin kendi ayari ezilmez).
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          border: Border.all(color: const Color(0xFFFDE68A)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(children: [
                              const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFFB45309)),
                              const SizedBox(width: 7),
                              const Expanded(child: Text('Tanımlı ikram sebebi yok',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5,
                                      color: Color(0xFF92400E)))),
                            ]),
                            const SizedBox(height: 8),
                            Text(
                              widget.sebepZorunlu
                                  ? 'İkram yapabilmek için önce sebep listesi tanımlanmalı.'
                                  : 'Sebep listesi tanımlanmamış. Sebepsiz devam edebilirsiniz.',
                              style: const TextStyle(fontSize: 12.5, color: Color(0xFF78350F)),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(color: const Color(0xFFFDE68A)),
                              ),
                              child: const Text(
                                'Panel → Mağaza Merkezi → İkram Sebepleri\n'
                                '→ "+ Yeni Sebep" ile ekleyin.',
                                style: TextStyle(fontSize: 12, height: 1.45,
                                    fontWeight: FontWeight.w600, color: Color(0xFF92400E)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: onaylanabilir
                              ? () => Navigator.pop(ctx, listeVar ? (secilen ?? '') : '')
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _turuncu,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey[300],
                            disabledForegroundColor: Colors.grey[500],
                          ),
                          child: Text(
                            girilen.isEmpty && !widget.sebepZorunlu ? 'Sebepsiz Devam' : 'Onayla',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  /// Secili NORMAL kalemleri ikram isaretle (sebep akisiyla).
  Future<void> _ikramYap() async {
    if (_isProcessing || !_seciliHepsiNormal) return;
    final sebep = await _sebepSor();
    if (sebep == null) return; // vazgecti
    await _islet(iptal: false, sebep: sebep.isEmpty ? null : sebep);
  }

  /// Secili IKRAMLI kalemlerin ikramini geri al (iptal:true).
  Future<void> _geriAl() async {
    if (_isProcessing || !_seciliHepsiIkram) return;
    await _islet(iptal: true, sebep: null);
  }

  Future<void> _islet({required bool iptal, String? sebep}) async {
    final idler = _selectedIds.toList();
    if (idler.isEmpty) return;
    setState(() => _isProcessing = true);
    var basarili = 0;
    String? ilkHata;
    try {
      for (final id in idler) {
        final r = await widget.apiService.setItemIkram(
          ticketId: widget.ticketId,
          itemId: id,
          ikramReason: sebep,
          waiterId: widget.waiterId,
          iptal: iptal,
        );
        if (r['success'] == false) {
          ilkHata ??= r['error']?.toString() ?? 'bilinmeyen hata';
          continue; // kalanlari denemeye devam — yarim birakma
        }
        basarili++;
        final idx = _items.indexWhere((i) => i['id'] == id);
        if (idx >= 0) {
          _items[idx]['is_ikram'] = iptal ? 0 : 1;
          _items[idx]['ikram_reason'] = iptal ? null : sebep;
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }

    if (!mounted) return;
    if (basarili == 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(iptal
            ? 'İkram geri alınamadı: ${ilkHata ?? ''}'
            : 'İkram yapılamadı: ${ilkHata ?? ''}'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    if (ilkHata != null) {
      // Kismi basari — kasiyer MUTLAKA gormeli (kalan kalemler isaretlenmedi).
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('DİKKAT: $basarili/${idler.length} kalem işlendi, kalanı '
            'işlenemedi: $ilkHata'),
        backgroundColor: Colors.orange[800],
      ));
    }
    // Basari (tam veya kismi) -> dialog kapanir, "Tumunu Gor" tazelenmis halde gorunur.
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final secilebilirler = _items.where(_secilebilir).toList();
    final odenmisler = _items.where((i) => !_secilebilir(i)).toList();
    final karisikSecim = _selectedIds.isNotEmpty && !_seciliHepsiNormal && !_seciliHepsiIkram;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: Center(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.7,
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: const BoxDecoration(
                  color: _turuncu,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Text('İkram', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Material(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: _isProcessing ? null : widget.onClose,
                        borderRadius: BorderRadius.circular(8),
                        splashColor: Colors.white.withOpacity(0.3),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.close, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Kalem listesi + ozet/butonlar
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (secilebilirler.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('İkram edilecek / geri alınacak kalemi seçin',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700])),
                            ),
                          ...secilebilirler.map((item) => _kalemSatiri(item, kilitli: false)),
                          if (odenmisler.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('Ödenmiş kalemler (ikram edilemez)',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[700])),
                            ),
                            ...odenmisler.map((item) => _kalemSatiri(item, kilitli: true)),
                          ],
                        ],
                      ),
                    ),
                    Container(
                      width: 230,
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        border: Border(left: BorderSide(color: Colors.grey[200]!)),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Seçili: ${_selectedIds.length} kalem',
                                      style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                  const SizedBox(height: 8),
                                  Text('${_seciliTutar.toStringAsFixed(2)} TL',
                                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _turuncu)),
                                  const Divider(),
                                  Text(
                                    widget.sebepZorunlu
                                        ? 'Sebep seçimi ZORUNLU'
                                        : 'Sebep seçimi opsiyonel',
                                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                  ),
                                  if (karisikSecim)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        'İkramlı ve normal kalemleri aynı anda seçmeyin.',
                                        style: TextStyle(color: Colors.red[700], fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: _ikramBtn(
                                    icon: Icons.card_giftcard_rounded,
                                    label: 'İkram Yap',
                                    color: _turuncu,
                                    onTap: !_isProcessing && _seciliHepsiNormal ? _ikramYap : null,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: double.infinity,
                                  child: _ikramBtn(
                                    icon: Icons.undo_rounded,
                                    label: 'İkramı Geri Al',
                                    color: Colors.blueGrey,
                                    onTap: !_isProcessing && _seciliHepsiIkram ? _geriAl : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (_isProcessing) const LinearProgressIndicator(color: _turuncu),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kalemSatiri(Map<String, dynamic> item, {required bool kilitli}) {
    final itemId = item['id'] is num ? (item['id'] as num).toInt() : null;
    final isSelected = itemId != null && _selectedIds.contains(itemId);
    final isIkram = IkramRules.kalemIkramMi(item);
    final qty = item['quantity'] ?? 1;
    final price = _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);

    final Color borderColor = kilitli
        ? Colors.green[300]!
        : (isSelected ? _turuncu : (isIkram ? _turuncu.withOpacity(0.5) : Colors.grey[300]!));
    final Color bgColor = kilitli
        ? Colors.green[50]!
        : (isSelected ? _turuncu.withOpacity(0.10) : (isIkram ? _turuncu.withOpacity(0.05) : Colors.white));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: (kilitli || _isProcessing || itemId == null) ? null : () => _toggle(itemId),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
          ),
          child: Row(
            children: [
              if (!kilitli)
                Container(
                  width: 24, height: 24,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? _turuncu : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: isSelected ? _turuncu : Colors.grey[400]!, width: 2),
                  ),
                  child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                ),
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: kilitli ? Colors.green : (isIkram ? _turuncu : Colors.grey[600]),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(child: Text('$qty',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item['product_name']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF1F2937))),
                    if (isIkram && (item['ikram_reason'] ?? '').toString().trim().isNotEmpty)
                      Text((item['ikram_reason'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: Colors.orange[800], fontStyle: FontStyle.italic)),
                  ],
                ),
              ),
              if (isIkram)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: _turuncu,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('İKRAM',
                      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              Text(
                '${price.toStringAsFixed(2)} TL',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isIkram ? Colors.grey[500] : const Color(0xFF1F2937),
                  decoration: isIkram ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ikramBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return Material(
      color: isDisabled ? Colors.grey[200] : color,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        splashColor: Colors.white.withOpacity(0.35),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                      color: isDisabled ? Colors.grey[400] : Colors.white,
                      fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
