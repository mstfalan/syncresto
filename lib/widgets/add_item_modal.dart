import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/log_service.dart';
import '../services/image_cache_service.dart';
import '../services/storage_service.dart';
import '../services/combo_calculator.dart';
import '../providers/theme_provider.dart';
import 'kitchen_print_retry_modal.dart';

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
    if (raw is! Map) return true; // List/null -> yetki bilgisi yok say, izin ver (eski davranış)
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
  Future<void> _openMultiVariantDialog(Map<String, dynamic> product, List variants,
      {Map<String, dynamic>? guncellenecekKalem}) async {
    final basePrice = _restaurantBasePrice(product);
    final productName = product['name']?.toString() ?? '';
    final zorunlu = _posVaryantZorunlu(product);
    final secili = <Map<String, dynamic>>[];

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
      try {
        final res = await widget.apiService.updateTicketItem(
          ticketId: widget.ticketId,
          itemId: gItemId,
          // Not alanina fiyat YAZILMAZ (backend unit_price safety-net'i notlardaki
          // '+NTL' desenine bakiyor — cift sayim riski). Secimler extras'ta.
          notes: secili.isEmpty
              ? null
              : secili.map((v) => v['name']?.toString() ?? '').join(', '),
          unitPrice: basePrice + toplamFark,
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
    await _addProductWithPrice(product, productName, basePrice + toplamFark, extras: extras);
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

    await _addProductWithPrice(product, productName, toplam, extras: extras);
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
    return Material(
      color: secili ? const Color(0xFF1F2937) : Colors.grey[100],
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
    final _u = product['combo_pos_unlimited'];
    final bool posUnlimited = _u == true || _u == 1 || _u == '1' || _u == 'true';
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
        comboPickName: note ?? productName);  // secilen varyant → fiste alt satir
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
    if (_comboIsActive(Map<String, dynamic>.from(prod))) {
      final ad = prod['name']?.toString() ?? 'Bu ürün';
      _showError('$ad combo ürünü — varyant sonradan değiştirilemez. '
          'Combo paketinin fiyatı seçilen ürünlere bölündüğü için kalemi iptal edip '
          'combo seçimini yeniden yapmanız gerekir.');
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
  Future<void> _addProductWithPrice(Map<String, dynamic> product, String displayName, double price,
      {String? variantNote, String? comboGroupId, String? comboGroupName, String? comboPickName,
      List<Map<String, dynamic>>? extras}) async {
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
        setState(() {
          final idx = _ticketItems.indexWhere((i) => _safeInt(i['id']) == tempId);
          if (idx >= 0) {
            _ticketItems[idx] = Map<String, dynamic>.from(_ticketItems[idx])..['id'] = realId;
          }
          if (_selectedItemId == tempId) _selectedItemId = realId;
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
    final item = _findSelectedItem();
    if (item == null) return;
    // 12 May 2026 debug: yanlis ürüne not yazma bug'i tracker
    LogService().logAction('Not dialog acildi', details: {
      'selected_item_id': _selectedItemId,
      'item_id': item['id'],
      'item_product_id': item['product_id'],
      'item_product_name': item['product_name'],
      'ticket_items_count': _ticketItems.length,
      'all_items': _ticketItems.map((i) => '${i['id']}:${i['product_name']}').toList(),
    });
    final currentNote = item['notes']?.toString() ?? '';
    final controller = TextEditingController(text: currentNote);

    // Ürünün category_id'sini bul + MUTLAK FIYAT modeli icin urun kaydini sakla
    // (kayitta baz fiyat urun kaydindan okunur: restaurant_price ?? price —
    // item.unit_price'tan TURETILMEZ, o eski ekstralarla kirlenmis olabilir)
    final productId = item['product_id'];
    int? categoryId;
    dynamic dialogProd;
    if (productId != null) {
      final allProducts = await widget.apiService.getProducts();
      dialogProd = (allProducts as List).where((p) => p['id'] == productId).firstOrNull;
      if (dialogProd != null) categoryId = dialogProd['category_id'] as int?;
    }

    // Paralel API çağrıları
    final results = await Future.wait([
      widget.apiService.getProductNotes(),
      widget.apiService.getGlobalVariants(categoryId: categoryId),
      widget.apiService.getGlobalExtras(categoryId: categoryId),
    ]);
    final predefinedNotes = results[0] as List;
    final globalVariants = results[1] as List;
    final globalExtras = results[2] as List;

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
                          Expanded(child: Text('${item['product_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
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
      final itemId = _safeInt(item['id']);
      final ticketId = widget.ticketId;
      if (itemId == null) return;

      final note = result['note'] as String? ?? '';
      final chipsPrice = result['extraPrice'] as double? ?? 0;
      final freeSum = result['freeSum'] as double? ?? 0;
      final priceDirty = result['priceDirty'] as bool? ?? true;

      final currentUnitPrice = _safeDouble(item['unit_price']);

      // 12 Haz 2026 — MUTLAK FIYAT modeli (F1/F2 fix, Web POS ticket.js ile ayni):
      // - Fiyat ogesi DEGISMEDIYSE unit_price gonderilmez → backend COALESCE
      //   eski fiyati korur (manuel ozel fiyat + mevcut ekstra ucreti bozulmaz).
      // - DEGISTIYSE fiyat SIFIRDAN kurulur: baz (urun kaydi restaurant_price
      //   ?? price) + secili chip toplami + chip'e eslenmeyen serbest '(+N TL)'
      //   token toplami. Eski ADDITIVE model (currentUnitPrice + delta) her
      //   kayitta cift sayim yapiyordu (350→360→370) — kaldirildi. Ekstra
      //   kaldirilinca da fiyat artik DUSER (eskiden COALESCE eski fiyati
      //   tutuyordu, iz birakmayan fazla tahsilat).
      double? newUnitPrice;
      if (priceDirty) {
        double base = 0;
        if (dialogProd != null) {
          base = _safeDouble(dialogProd['restaurant_price'] ?? dialogProd['price']);
        }
        if (base <= 0) {
          // Urun kaydi bulunamadiysa baz'i mevcut fiyattan turet:
          // acilista bilinen fiyat ogelerini (chip + serbest token) dus.
          final initialChipsPrice = result['initialChipsPrice'] as double? ?? 0;
          final initialFreeSum = result['initialFreeSum'] as double? ?? 0;
          base = currentUnitPrice - initialChipsPrice - initialFreeSum;
          if (base < 0) base = currentUnitPrice;
        }
        newUnitPrice = base + chipsPrice + freeSum;
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

      await widget.apiService.updateTicketItem(
        ticketId: ticketId,
        itemId: itemId,
        notes: note,
        unitPrice: newUnitPrice,
      );

      await _loadTicketItems();
      widget.onItemAdded();
    } catch (e) {
      _showError('Not eklenemedi: $e');
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

    try {
      // 16 May 2026: Backend cancel_print payload'u döner (printed=1 + printer_ip varsa)
      // Mevcut mutfak fiş akışı bozulmadı, sadece response'a ek field eklendi.
      final cancelResponse = await widget.apiService.deleteTicketItem(
        ticketId: widget.ticketId,
        itemId: itemId,
        cancelReason: selectedReason,
        waiterId: widget.waiterId,
      );

      // Backend "cancel_print" payload döndüyse → mutfağa iptal fişi bas
      final cancelPrint = (cancelResponse is Map) ? cancelResponse['cancel_print'] : null;
      bool printedSuccess = false;
      if (cancelPrint != null && widget.printerService != null) {
        try {
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          printedSuccess = await widget.printerService!.printCancelItem(
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
        } catch (e) {
          print('[Cancel] İptal fişi yazılamadı: $e');
        }
      }

      setState(() => _selectedItemId = null);
      await _loadTicketItems();
      widget.onItemAdded();
      _showSuccess(printedSuccess
          ? 'Ürün iptal edildi + mutfağa iptal fişi gönderildi: $selectedReason'
          : (cancelPrint != null
              ? 'Ürün iptal edildi (iptal fişi yazıcıya ulaşamadı): $selectedReason'
              : 'Ürün iptal edildi: $selectedReason'));
    } catch (e) {
      _showError('Ürün iptal edilemedi: $e');
    }
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
    final unpaidItems = activeItems.where((i) => i['payment_status'] != 'paid').toList();
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
      if (item['payment_status'] != 'paid') {
        total += _safeDouble(item['unit_price']) * _safeDouble(item['quantity'], 1);
      }
    }
    return total;
  }

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
    final t = _ticketSubtotal - _ticketDiscount - _comboDiscount;
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
            child: _buildCategoryButton(theme, null, 'Tümü', Icons.apps),
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

  Widget _buildCategoryButton(ThemeProvider theme, int? categoryId, String label, IconData? icon, {String emoji = ''}) {
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
          constraints: const BoxConstraints(minHeight: 68),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? theme.primaryColor : Colors.grey[300]!,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
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
    final activeItems = _ticketItems.where((i) => i['status'] != 'cancelled').toList();
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
      _buildActionBtnVertical(icon: Icons.edit_note, label: 'Not Ekle', color: Colors.blueGrey, onTap: hasItems && _selectedItemId != null ? _openNoteDialog : null),
      _buildActionBtnVertical(
        icon: Icons.tune,
        label: 'Varyant',
        color: const Color(0xFFF59E0B),
        onTap: hasItems && _selectedItemId != null && _variantsForSelectedItem().isNotEmpty
            ? _openVariantDialogForSelected
            : null,
      ),
      _buildActionBtnVertical(icon: Icons.close, label: 'Ürün İptal', color: Colors.red[400]!, onTap: hasItems && _selectedItemId != null && (_hasPermission('cancel_item') || _hasPermission('cancel_item_unprinted')) ? _cancelSelectedItem : null),
      _buildActionBtnVertical(
        icon: Icons.drive_file_move,
        label: 'Ürün Taşı',
        color: const Color(0xFF7C3AED),
        onTap: hasItems && _selectedItemId != null && _hasPermission('move_item') ? _moveSelectedItem : null,
      ),
      _buildActionBtnVertical(icon: Icons.restaurant, label: 'Mutfak', color: const Color(0xFFF59E0B), onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null),
      _buildActionBtnVertical(icon: Icons.print, label: 'Yazdır', color: Colors.blueGrey, onTap: hasItems && _hasPermission('print_receipt') ? _printTicket : null),
    ];

    final btnGroup2 = <Widget>[
      if (_hasPermission('apply_discount'))
        _buildActionBtnVertical(icon: Icons.percent, label: 'İndirim', color: const Color(0xFFE11D48), onTap: hasItems ? _openDiscountDialog : null),
      if (_hasPermission('transfer_table'))
        _buildActionBtnVertical(icon: Icons.swap_horiz, label: 'Masa Değiştir', color: const Color(0xFF0EA5E9), onTap: hasItems ? _transferTable : null),
      _buildActionBtnVertical(icon: Icons.splitscreen, label: 'Parçalı Ödeme', color: const Color(0xFF7C3AED), onTap: hasItems && _hasPermission('close_ticket') ? _openPartialPayment : null),
    ];

    final btnGroup3 = <Widget>[
      _buildActionBtnVertical(icon: Icons.payments, label: 'Nakit Kapat', color: theme.primaryColor, onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null),
      _buildActionBtnVertical(icon: Icons.credit_card, label: 'Kart Kapat', color: const Color(0xFF3B82F6), onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('credit_card') : null),
      _buildActionBtnVertical(icon: Icons.receipt_long, label: 'Yaz+Nakit', color: const Color(0xFF059669), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('cash') : null),
      _buildActionBtnVertical(icon: Icons.receipt_long, label: 'Yaz+Kart', color: const Color(0xFF2563EB), onTap: hasItems && _hasPermission('close_ticket') && _hasPermission('print_receipt') ? () => _printAndCloseTicket('credit_card') : null),
      // 15 Tem 2026: Panelden gelen DİNAMİK ödeme yöntemleri (nakit/kart hariç). Her biri "X Kapat".
      // Kod (code) backend'e payment_method olarak gider; display_name fiş/dialog etiketinde kullanılır.
      for (final pm in _dynamicPaymentMethods)
        _buildActionBtnVertical(
          icon: Icons.account_balance_wallet,
          label: '${pm['display_name']} Kapat',
          color: const Color(0xFF7C3AED),
          onTap: hasItems && _hasPermission('close_ticket')
              ? () => _closeTicket(pm['code'] as String, methodLabel: pm['display_name'] as String?)
              : null,
        ),
    ];

    final btnGroup4 = <Widget>[
      if (_hasPermission('void_ticket'))
        _buildActionBtnVertical(icon: Icons.delete_outline, label: 'Adisyon İptal', color: const Color(0xFFDC2626), onTap: _voidTicket),
    ];

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(left: BorderSide(color: Colors.grey[200]!)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildActionGrid(btnGroup1),
            if (btnGroup2.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.grey[300], height: 1),
              const SizedBox(height: 10),
              _buildActionGrid(btnGroup2),
            ],
            const SizedBox(height: 10),
            Divider(color: Colors.grey[300], height: 1),
            const SizedBox(height: 10),
            _buildActionGrid(btnGroup3),
            if (btnGroup4.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(color: Colors.grey[300], height: 1),
              const SizedBox(height: 10),
              _buildActionGrid(btnGroup4),
            ],
          ],
        ),
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
    // 22 May 2026: Dokunmatik POS icin iyilestirme.
    // - GestureDetector → InkWell (ripple feedback verir, kullanici tikladigini anlar)
    // - Min yukseklik 60 (eski ~32) — parmakla daha kolay isabet
    // - Icon 22 (eski 18), font 11 (eski 9) — okunabilirligi artirir
    // - Material wrapper ile ink ripple animasyonu calisir
    final isDisabled = onTap == null;
    return Material(
      color: isDisabled ? Colors.grey[200] : color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: isDisabled ? null : color.withOpacity(0.3),
        highlightColor: isDisabled ? null : color.withOpacity(0.2),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDisabled ? Colors.grey[300]! : color.withOpacity(0.4),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: isDisabled ? Colors.grey[400] : color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isDisabled ? Colors.grey[400] : color,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
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
                    color: isPaid ? Colors.green[700] : const Color(0xFF1F2937),
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
                  icon: Icons.edit_note,
                  label: 'Not Ekle',
                  color: Colors.blueGrey,
                  onTap: hasItems && _selectedItemId != null ? _openNoteDialog : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.tune,
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
                  icon: Icons.close,
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
                  icon: Icons.restaurant,
                  label: 'Mutfak',
                  color: const Color(0xFFF59E0B),
                  onTap: hasItems && _hasPermission('print_receipt') ? _sendToKitchen : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.print,
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
              icon: Icons.splitscreen,
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
                  icon: Icons.payments,
                  label: 'Nakit',
                  color: theme.primaryColor,
                  onTap: hasItems && _hasPermission('close_ticket') ? () => _closeTicket('cash') : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionBtn(
                  icon: Icons.credit_card,
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
                  icon: Icons.receipt_long,
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
                  icon: Icons.receipt_long,
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
                    icon: Icons.swap_horiz,
                    label: 'Masa Değiştir',
                    color: const Color(0xFF0EA5E9),
                    onTap: hasItems ? _transferTable : null,
                  ),
                ),
              if (_hasPermission('transfer_table')) const SizedBox(width: 6),
              if (_hasPermission('apply_discount'))
                Expanded(
                  child: _buildActionBtn(
                    icon: Icons.percent,
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
                icon: Icons.delete_outline,
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
    final isDisabled = onTap == null;
    return Material(
      color: isDisabled ? Colors.grey[200] : color,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: isDisabled ? null : () => onTap(),
        borderRadius: BorderRadius.circular(10),
        splashColor: Colors.white.withOpacity(0.35),
        highlightColor: Colors.white.withOpacity(0.18),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: isDisabled ? Colors.grey[400] : Colors.white, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isDisabled ? Colors.grey[400] : Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
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
        final allPaid = _items.every((i) => i['payment_status'] == 'paid');
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

    final unpaidIds = _items
        .where((i) => i['payment_status'] != 'paid')
        .map((i) => i['id'] as int)
        .toList();

    if (unpaidIds.isEmpty) return;

    // Toplam tutarı hesapla
    double unpaidTotal = 0;
    for (var item in _items) {
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
    final unpaidItems = _items.where((i) => i['payment_status'] != 'paid').toList();
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

    // Renk şeması:
    //   Ödenmiş → yeşil
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
        onTap: isPaid ? null : () { if (itemId != null) _toggleItem(itemId); },
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
              // Checkbox
              if (!isPaid)
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
              // Badge (ödenmişse — yeşil/mavi; ödenmemişse — kırmızı "ÖDENMEDİ")
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
              // Fiyat
              Text(
                '${price.toStringAsFixed(2)} TL',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: textColor,
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
