import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';

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
                if (!compact && notes != null && notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      notes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic,
                      ),
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
