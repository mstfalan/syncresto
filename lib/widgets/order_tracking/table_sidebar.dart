import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';

/// Masa bilgisini tutan lightweight data class
class TableBundle {
  final int tableId;
  final String tableNumber;
  final String sectionName;
  final List<Map<String, dynamic>> pending = [];
  final List<Map<String, dynamic>> delivered = [];

  TableBundle({
    required this.tableId,
    required this.tableNumber,
    required this.sectionName,
  });
}

class TableSidebar extends StatelessWidget {
  final List<TableBundle> bundles;
  final int? selectedTableId;
  final void Function(int) onSelect;

  const TableSidebar({
    super.key,
    required this.bundles,
    required this.selectedTableId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context, listen: false);

    if (bundles.isEmpty) {
      return Container(
        color: Colors.grey[100],
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Acik adisyon yok',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ),
        ),
      );
    }

    return Container(
      color: Colors.grey[100],
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: bundles.length,
        itemBuilder: (_, i) {
          final b = bundles[i];
          final selected = b.tableId == selectedTableId;
          final pendingCount = b.pending.length;

          // Masa rengi — en eski bekleyen item'in suresine gore (masalar ekranindakiyle ayni kural)
          int oldestWaitSeconds = 0;
          for (final it in b.pending) {
            final raw = it['item_created_at']?.toString();
            if (raw == null || raw.isEmpty) continue;
            final dt = DateTime.tryParse(raw);
            if (dt == null) continue;
            final sec = DateTime.now().toUtc().difference(dt.toUtc()).inSeconds;
            if (sec > oldestWaitSeconds) oldestWaitSeconds = sec;
          }
          final isLate = oldestWaitSeconds >= 1200;
          final isWarning = !isLate && oldestWaitSeconds >= 600;

          final Color? bgColor;
          final Color leftBarColor;
          final Color badgeColor;
          if (selected) {
            bgColor = theme.primaryColor.withValues(alpha: 0.1);
            leftBarColor = theme.primaryColor;
          } else if (isLate) {
            bgColor = const Color(0xFFFEE2E2);
            leftBarColor = const Color(0xFFDC2626);
          } else if (isWarning) {
            bgColor = const Color(0xFFFEF3C7);
            leftBarColor = const Color(0xFFF59E0B);
          } else {
            bgColor = null;
            leftBarColor = Colors.transparent;
          }
          if (isLate) {
            badgeColor = const Color(0xFFB91C1C);
          } else if (isWarning) {
            badgeColor = const Color(0xFFD97706);
          } else {
            badgeColor = Colors.orange[700]!;
          }

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(b.tableId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border(
                    left: BorderSide(
                      color: leftBarColor,
                      width: 4,
                    ),
                    bottom: BorderSide(color: Colors.grey[200]!, width: 0.5),
                  ),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Masa ${b.tableNumber}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: selected ? theme.primaryColor : Colors.black87,
                          ),
                        ),
                        if (b.sectionName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              b.sectionName,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (pendingCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: badgeColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$pendingCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}
