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
    final h = compact ? 60.0 : 92.0;
    final qtyFont = compact ? 18.0 : 28.0;
    final nameFont = compact ? 14.0 : 20.0;
    final qty = item['quantity']?.toString() ?? '1';
    final name = item['product_name']?.toString() ?? '';
    final notes = item['notes']?.toString();
    final printed = item['printed'] == 1 || item['printed'] == true;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 8),
        height: h,
        decoration: BoxDecoration(
          color: isDelivered ? const Color(0xFFDCFCE7) : Colors.white,
          border: Border.all(
            color: isDelivered ? const Color(0xFF16A34A) : theme.primaryColor,
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
            width: compact ? 50 : 72,
            height: double.infinity,
            decoration: BoxDecoration(
              color: isDelivered ? const Color(0xFF16A34A) : theme.primaryColor,
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
          const SizedBox(width: 12),
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
}
