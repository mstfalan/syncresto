import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';

/// 🔴 6 Agu 2026 — MASA TAKIP URUN DETAYI (Mustafa: "masa takip kisminda bunun
/// detaylari gozukmuyor maalesef ... flutter ve garson webde de").
///
/// Takip ekrani yalnizca `product_name` + `notes` gosteriyordu. Varyant secimi,
/// coklu secim ve eklenen/cikarilan icerikler `extras` alaninda durur ve backend
/// sorgusunda HIC SECILMIYORDU. Ornek: "Citir Tavuk 4'lu" kaleminde notes NULL,
/// extras `[{"name":"Acisiz"}]` -> garson "Acisiz" bilgisini HIC goremiyordu.
///
/// BICIM (fis ile ayni kural, printer_service._extraSatiri esleniği):
///   - Oge Map ise `name` okunur; String ise aynen kullanilir (eski kayitlar).
///     `label`/`title` yedekleri UYDURMA DEGIL — fis tarafi 31 Tem 2026'dan beri
///     `e['name'] ?? e['label'] ?? e['title']` okuyor, ayni veri iki ekranda
///     farkli tolere edilmesin diye birebir eslendi. Canlida bugun ikisi de
///     kullanilmiyor (6 Agu taramasi: 150.915 kaydin hepsi `name`'li).
///   - Ad '-' ile basliyorsa CIKARILAN demektir -> onek temizlenir, cagiran taraf
///     kirmizi/uzeri-cizili gosterir. Fiste bu "CIKAR: Sogan" olarak basiliyor.
///   - Fiyat EKRANDA GOSTERILMEZ: takip ekrani mutfak/servis icindir, tutar degil
///     icerik onemlidir; satir zaten dar.
/// Ayni ad birden fazla gecebilir (2 porsiyon patates = iki kayit) — BIRLESTIRILMEZ,
/// canli veride boyle duruyor ve adet bilgisi bundan okunuyor.
List<({String ad, bool cikarilan})> takipDetayParcalari(dynamic extrasRaw) {
  if (extrasRaw == null) return const [];
  dynamic veri = extrasRaw;
  // Cevrimdisi SQLite'ta jsonb metin olarak saklanir -> once coz.
  if (veri is String) {
    final s = veri.trim();
    if (s.isEmpty) return const [];
    try {
      veri = jsonDecode(s);
    } catch (_) {
      return const [];
    }
  }
  if (veri is! List) return const [];
  final out = <({String ad, bool cikarilan})>[];
  for (final e in veri) {
    var ad = '';
    if (e is Map) {
      ad = (e['name'] ?? e['label'] ?? e['title'] ?? '').toString().trim();
    } else {
      ad = e?.toString().trim() ?? '';
    }
    if (ad.isEmpty) continue;
    final cikarilan = ad.startsWith('-');
    if (cikarilan) ad = ad.substring(1).trim();
    if (ad.isEmpty) continue;
    out.add((ad: ad, cikarilan: cikarilan));
  }
  return out;
}

/// Detay parcalarini tek satirlik ozete cevirir: "Acisiz · 4'lu · Sogan yok"
String takipDetayOzet(dynamic extrasRaw) {
  final p = takipDetayParcalari(extrasRaw);
  if (p.isEmpty) return '';
  return p.map((x) => x.cikarilan ? '${x.ad} yok' : x.ad).join(' · ');
}

class ItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isDelivered;
  final bool compact;
  final VoidCallback onTap;

  const ItemCard({
    super.key,
    required this.item,
    required this.isDelivered,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);
    // Daha fazla urun sigsin diye kompakt boyutlar — meta satiri eklenince yukseklik artti
    final h = compact ? 56.0 : 72.0;
    final qtyFont = compact ? 14.0 : 18.0;
    final nameFont = compact ? 12.0 : 14.0;
    final qty = item['quantity']?.toString() ?? '1';
    final name = item['product_name']?.toString() ?? '';
    final notes = item['notes']?.toString();
    // Varyant / coklu secim / eklenen-cikarilan icerikler (backend `extras`)
    final detay = takipDetayOzet(item['extras']);
    final printed = item['printed'] == 1 || item['printed'] == true;
    final addedTime = _formatTime(item['item_created_at']);
    final addedBy = item['added_by_name']?.toString() ?? '';
    final deliveredTime = _formatTime(item['delivered_at']);
    final deliveredBy = item['delivered_by_name']?.toString() ?? '';

    // Bekleme suresi rengi (delivered olmayanlar icin) — masalar ekranindaki ile ayni:
    // 0-10dk normal, 10-20dk sari, 20+dk kirmizi
    int waitSeconds = 0;
    if (!isDelivered) {
      final createdRaw = item['item_created_at']?.toString();
      if (createdRaw != null && createdRaw.isNotEmpty) {
        final created = DateTime.tryParse(createdRaw);
        if (created != null) {
          waitSeconds = DateTime.now().toUtc().difference(created.toUtc()).inSeconds;
        }
      }
    }
    final isLate = waitSeconds >= 1200;
    final isWarning = !isLate && waitSeconds >= 600;
    final waitMinutes = waitSeconds ~/ 60;

    final Color bgColor;
    final Color edgeColor;
    if (isDelivered) {
      bgColor = const Color(0xFFDCFCE7);
      edgeColor = const Color(0xFF16A34A);
    } else if (isLate) {
      bgColor = const Color(0xFFFEE2E2);
      edgeColor = const Color(0xFFDC2626);
    } else if (isWarning) {
      bgColor = const Color(0xFFFEF3C7);
      edgeColor = const Color(0xFFF59E0B);
    } else {
      bgColor = Colors.white;
      edgeColor = theme.primaryColor;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 8),
        height: h,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(
            color: edgeColor,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(children: [
          Container(
            width: compact ? 38 : 48,
            height: double.infinity,
            decoration: BoxDecoration(
              color: edgeColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '${qty}x',
              style: TextStyle(
                color: Colors.white,
                fontSize: qtyFont,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  name,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: nameFont,
                    fontWeight: FontWeight.w700,
                    decoration: isDelivered ? TextDecoration.lineThrough : null,
                    color: isDelivered ? Colors.grey[700] : Colors.black87,
                  ),
                ),
                // 6 Agu 2026 — DETAY + NOT ayni satirda. Kart yuksekligi SABIT
                // (h = 56/72) oldugu icin yeni satir eklemek tasma yaratirdi;
                // bu yuzden detay mevcut not satirina alindi. Sira bilincli:
                // DETAY ONCE gelir (varyant/icerik mutfak icin kritik, uzun
                // metinde ellipsis'e once serbest not kurban edilir).
                if (!compact && (detay.isNotEmpty || (notes != null && notes.isNotEmpty)))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(children: [
                        if (detay.isNotEmpty)
                          TextSpan(
                            text: detay,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.indigo[700],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (detay.isNotEmpty && notes != null && notes.isNotEmpty)
                          TextSpan(
                            text: '  •  ',
                            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                          ),
                        if (notes != null && notes.isNotEmpty)
                          TextSpan(
                            text: notes,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ]),
                    ),
                  ),
                // META: ekleyen + saat (isDelivered ise teslim eden + saat)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      if (addedTime.isNotEmpty)
                        _metaChip(Icons.access_time, addedTime + (addedBy.isNotEmpty ? ' · $addedBy' : ''), Colors.blueGrey[700]!),
                      if (!isDelivered && waitMinutes > 0)
                        _metaChip(
                          Icons.hourglass_bottom,
                          isLate ? '$waitMinutes dk — gec' : '$waitMinutes dk',
                          isLate ? const Color(0xFFB91C1C) : (isWarning ? const Color(0xFFD97706) : Colors.grey[600]!),
                        ),
                      if (isDelivered && deliveredTime.isNotEmpty)
                        _metaChip(Icons.check, 'Teslim $deliveredTime' + (deliveredBy.isNotEmpty ? ' · $deliveredBy' : ''), Colors.green[700]!),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!compact && printed)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                Icons.print_outlined,
                size: 20,
                color: Colors.grey[500],
              ),
            ),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _formatTime(dynamic iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
