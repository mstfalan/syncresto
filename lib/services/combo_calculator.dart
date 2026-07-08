// COMBO ÜRÜN indirim hesaplayıcı — Flutter/Dart kopyası (FAZ 4 POS offline).
// KAYNAK: /home/ubuntu/syncresto-panel/api/comboCalculator.js (8 Tem 2026, TEK DOĞRU KAYNAK).
// Bu dosya o JS modülünün BİREBİR mantık kopyasıdır — panel/web ile aynı sonucu üretmeli
// (backend authoritative; POS offline'da bununla önizleme+uygulama yapar, online'da backend
// hesabı kesindir). JS güncellenirse BU DA güncellenmeli (mirror-drift riski, testle korunur).
//
// spec: aynı üründen (varyantlarıyla) X adet alınca → hediye VEYA yüzde/sabit indirim.
// TEK MOD: giftQty>0 → hediye; yoksa yüzde VEYA sabit. comboRepeat → katlanma.

class ComboResult {
  bool eligible;
  int sets;
  double discountAmount;
  int giftUnits;
  double giftUnitPrice;
  String mode; // 'gift-within' | 'gift-extra' | 'percent' | 'amount' | 'none'
  String label;

  ComboResult({
    this.eligible = false,
    this.sets = 0,
    this.discountAmount = 0,
    this.giftUnits = 0,
    this.giftUnitPrice = 0,
    this.mode = 'none',
    this.label = '',
  });
}

class ComboGiftLine {
  final dynamic productId;
  final String name;
  final int qty;
  final double unitPrice;
  final double sourcePrice;
  ComboGiftLine({
    required this.productId,
    required this.name,
    required this.qty,
    this.unitPrice = 0,
    this.sourcePrice = 0,
  });
}

class ComboBreakdown {
  final dynamic productId;
  final String name;
  final String label;
  final double amount;
  final int? giftUnits;
  ComboBreakdown({
    required this.productId,
    required this.name,
    required this.label,
    required this.amount,
    this.giftUnits,
  });

  Map<String, dynamic> toMap() => {
        'product_id': productId,
        'name': name,
        'label': label,
        'amount': amount,
        if (giftUnits != null) 'gift_units': giftUnits,
      };
}

class ComboCartResult {
  double totalDiscount;
  List<ComboBreakdown> breakdown;
  List<ComboGiftLine> giftLines;
  List<int> comboProductIds;
  ComboCartResult({
    this.totalDiscount = 0,
    List<ComboBreakdown>? breakdown,
    List<ComboGiftLine>? giftLines,
    List<int>? comboProductIds,
  })  : breakdown = breakdown ?? [],
        giftLines = giftLines ?? [],
        comboProductIds = comboProductIds ?? [];
}

class ComboCalculator {
  /// COMBO FIYAT BOLME (POS, Mustafa kesin kural): combo bir PAKET. Bolunecek toplam =
  /// ana restoran fiyati (basePrice) + secilen varyantlarin POZITIF modifier toplami. Bu toplam N odenen
  /// kaleme ESIT bolunur (kurus kalani SON kaleme -> toplam tam). Boylece ₺0 kalem/ciro kaybi olmaz.
  /// KURAL: negatif modifier (or restaurant_modifier -940 = "combo'da baz-fiyati sifirla" niyeti) toplama
  /// EKLENMEZ (0 sayilir). Pozitif modifier (+100 = "pakete uste ekle") toplanir.
  /// Girdi: modifiers = secilen odenen kalemlerin modifier'lari (varyant fiyati DEGIL, sadece modifier;
  /// baz bir KEZ eklenir). Doner: her kaleme yazilacak fiyat listesi.
  static List<double> splitComboPackagePrice(List<double> modifiers, double basePrice) {
    if (modifiers.isEmpty) return modifiers;
    final n = modifiers.length;
    double positiveMods = 0;
    for (final m in modifiers) {
      if (m > 0) positiveMods += m; // negatif (sifirlama niyeti) atlanir
    }
    final packageTotal = _round2((basePrice > 0 ? basePrice : 0) + positiveMods);
    final each = _round2(packageTotal / n);
    final out = List<double>.filled(n, each);
    final diff = _round2(packageTotal - each * n);
    out[n - 1] = _round2(out[n - 1] + diff);
    return out;
  }

  /// COMBO SECIM EKRANI yardimcisi (POS extra modu): kullanici N+G varyant secer; sepete SADECE N
  /// odenen kalem eklenir, en ucuz G HEDIYE slotu EKLENMEZ (backend close giftLines ile uretir —
  /// panel/web birebir, cifte-hediye onler). Girdi: her pick {..., 'price': double}. Doner: odenen
  /// pick listesi (en ucuz giftCount cikarilmis). within/percent/amount'ta giftCount=0 -> hepsi doner.
  static List<Map<String, dynamic>> paidPicksAfterGift(
      List<Map<String, dynamic>> picks, int giftCount) {
    if (giftCount <= 0 || picks.isEmpty) return List<Map<String, dynamic>>.from(picks);
    // Index'leri fiyata gore artan sirala; en ucuz giftCount index'i "hediye" isaretle.
    final idx = List<int>.generate(picks.length, (i) => i);
    idx.sort((a, b) => _num(picks[a]['price']).compareTo(_num(picks[b]['price'])));
    final giftIdx = idx.take(giftCount < picks.length ? giftCount : picks.length).toSet();
    final paid = <Map<String, dynamic>>[];
    for (int i = 0; i < picks.length; i++) {
      if (giftIdx.contains(i)) continue; // hediye slotu -> ekleme
      paid.add(picks[i]);
    }
    return paid;
  }

  // --- JS num()/toInt() eşleri (parseFloat/parseInt semantiği) ---
  static double _num(dynamic v, [double d = 0]) {
    if (v == null) return d;
    if (v is num) return v.toDouble();
    final n = double.tryParse(v.toString());
    return n ?? d;
  }

  static int _toInt(dynamic v, [int d = 0]) {
    if (v == null) return d;
    if (v is int) return v;
    if (v is num) return v.toInt();
    // parseInt(v,10): baştaki sayısal kısmı al (JS gibi)
    final s = v.toString().trim();
    final m = RegExp(r'^[+-]?\d+').firstMatch(s);
    if (m != null) return int.tryParse(m.group(0)!) ?? d;
    return d;
  }

  static double _round2(dynamic n) {
    final x = _num(n, 0);
    return (((x + 2.220446049250313e-16) * 100).round()) / 100.0;
  }

  static String _trimNum(dynamic n) {
    final x = _round2(n);
    // JS: x%1===0 ? String(x) : String(x) — ikisi de String(x); ondalık sıfırsa tam sayı göster
    if (x % 1 == 0) return x.toInt().toString();
    return x.toString();
  }

  static bool _truthy(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  /// Bir combo ürünü için indirimi hesapla. product = combo_* alanlı satır; lines = [{unit_price, qty}].
  static ComboResult calcComboForProduct(Map<String, dynamic> product, List<Map<String, dynamic>> lines) {
    final res = ComboResult();
    // JS: product.combo_enabled !== true. DB'den bool true gelir (panel_products); esnek guard (1/'t' de kabul).
    if (product['combo_enabled'] != true && !_truthy(product['combo_enabled'])) return res;
    if (lines.isEmpty) return res;

    final N = (_toInt(product['combo_required_qty'], 2)).clamp(1, 10);
    final G = (_toInt(product['combo_gift_qty'], 0)).clamp(0, 1 << 30);
    final giftMode = product['combo_gift_mode'] == 'extra' ? 'extra' : 'within';
    final repeat = !(product['combo_repeat'] == false);
    final pct = G == 0 ? _num(product['combo_discount_percent'], 0) : 0.0;
    final amt = G == 0 ? _num(product['combo_discount_amount'], 0) : 0.0;

    // Toplam adet (tüm varyant satırları)
    int Q = 0;
    for (final l in lines) {
      final q = _toInt(l['qty'], 0);
      Q += q > 0 ? q : 0;
    }
    if (Q < N) return res; // kural devrede değil

    final sets = repeat ? (Q ~/ N) : 1;
    if (sets < 1) return res;

    res.eligible = true;
    res.sets = sets;

    // Birim fiyat listesi (her adet ayrı birim, artan sıralı)
    final units = <double>[];
    for (final l in lines) {
      final q = _toInt(l['qty'], 0);
      final up = _num(l['unit_price'], 0);
      for (int i = 0; i < (q > 0 ? q : 0); i++) {
        units.add(up);
      }
    }
    units.sort((a, b) => a.compareTo(b)); // artan: en ucuz başta

    if (G > 0) {
      final giftCount = sets * G;
      if (giftMode == 'within') {
        res.mode = 'gift-within';
        final freeUnits = units.sublist(0, giftCount < units.length ? giftCount : units.length);
        res.discountAmount = _round2(freeUnits.fold<double>(0, (s, p) => s + p));
        res.giftUnits = freeUnits.length;
        res.giftUnitPrice = freeUnits.isNotEmpty ? freeUnits[freeUnits.length - 1] : 0;
        res.label = '$N al ${(N - G) < 1 ? 1 : (N - G)} öde';
      } else {
        res.mode = 'gift-extra';
        res.giftUnits = giftCount;
        res.giftUnitPrice = units.isNotEmpty ? units[0] : 0;
        res.discountAmount = 0;
        res.label = '$N al $G hediye';
      }
    } else if (pct > 0) {
      res.mode = 'percent';
      final p = pct.clamp(0, 100).toDouble();
      final setUnits = units.sublist(0, (sets * N) < units.length ? (sets * N) : units.length);
      final setTotal = setUnits.fold<double>(0, (s, u) => s + u);
      res.discountAmount = _round2(setTotal * p / 100);
      res.label = '%${_trimNum(p)} indirim';
    } else if (amt > 0) {
      res.mode = 'amount';
      final setUnits = units.sublist(0, (sets * N) < units.length ? (sets * N) : units.length);
      final setTotal = setUnits.fold<double>(0, (s, u) => s + u);
      final byAmt = sets * amt;
      res.discountAmount = _round2(byAmt < setTotal ? byAmt : setTotal);
      res.label = '₺${_trimNum(amt)} indirim';
    } else {
      res.eligible = false; // enabled ama indirim tanımlı değil
    }

    return res;
  }

  /// Tüm sepet için combo indirimlerini topla. cartItems = [{product_id, unit_price/price, quantity/qty}].
  /// productsById = { product_id.toString(): combo_* alanlı satır }. __combo_gift işaretli satırlar atlanır.
  static ComboCartResult calcCartCombos(
      List<Map<String, dynamic>> cartItems, Map<String, Map<String, dynamic>> productsById) {
    final out = ComboCartResult();
    if (cartItems.isEmpty) return out;

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final it in cartItems) {
      if (_truthy(it['__combo_gift'])) continue; // önceden eklenmiş hediye satırını sayma
      final pidRaw = it['product_id'] ?? it['id'];
      if (pidRaw == null) continue;
      final pid = pidRaw.toString();
      (groups[pid] ??= []).add({
        'unit_price': _num(it['unit_price'] ?? it['price'], 0),
        'qty': _toInt(it['quantity'] ?? it['qty'], 0),
      });
    }

    groups.forEach((pid, lines) {
      final product = productsById[pid];
      if (product == null) return;
      if (product['combo_enabled'] != true && !_truthy(product['combo_enabled'])) return;
      final calc = calcComboForProduct(product, lines);
      if (!calc.eligible) return;
      final pidInt = int.tryParse(pid) ?? 0;
      out.comboProductIds.add(pidInt);
      if (calc.discountAmount > 0) {
        out.totalDiscount = _round2(out.totalDiscount + calc.discountAmount);
        out.breakdown.add(ComboBreakdown(
          productId: pidInt,
          name: product['name']?.toString() ?? '',
          label: calc.label,
          amount: calc.discountAmount,
        ));
      }
      if (calc.mode == 'gift-extra' && calc.giftUnits > 0) {
        out.giftLines.add(ComboGiftLine(
          productId: pidInt,
          name: '${product['name']?.toString() ?? ''} (HEDİYE)',
          qty: calc.giftUnits,
          unitPrice: 0,
          sourcePrice: calc.giftUnitPrice,
        ));
        out.breakdown.add(ComboBreakdown(
          productId: pidInt,
          name: product['name']?.toString() ?? '',
          label: calc.label,
          amount: 0,
          giftUnits: calc.giftUnits,
        ));
      }
    });

    return out;
  }
}
