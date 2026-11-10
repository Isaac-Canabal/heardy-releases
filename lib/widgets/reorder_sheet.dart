import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class ReorderItem {
  final String id;
  final String label;
  final IconData? icon;

  const ReorderItem({required this.id, required this.label, this.icon});
}

Future<void> showReorderSheet(
  BuildContext context, {
  required String title,
  required List<ReorderItem> items,
  required List<String> defaultOrder,
  required ValueChanged<List<String>> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ReorderSheet(
      title: title,
      items: items,
      defaultOrder: defaultOrder,
      onChanged: onChanged,
    ),
  );
}

/// Ordena una lista arrastrando su asa. Cada cambio llega a [onChanged] en el
/// acto, con los ids en el orden nuevo: no hay "Guardar" ni "Cancelar" porque
/// restablecer es igual de directo. [items] llega en el orden actual.
class ReorderSheet extends StatefulWidget {
  final String title;
  final List<ReorderItem> items;
  final List<String> defaultOrder;
  final ValueChanged<List<String>> onChanged;

  const ReorderSheet({
    super.key,
    required this.title,
    required this.items,
    required this.defaultOrder,
    required this.onChanged,
  });

  @override
  State<ReorderSheet> createState() => _ReorderSheetState();
}

class _ReorderSheetState extends State<ReorderSheet> {
  late List<ReorderItem> _items = [...widget.items];

  /// Un elemento que [ReorderSheet.defaultOrder] no nombra queda al final.
  List<ReorderItem> get _defaultItems {
    final position = {for (final (i, id) in widget.defaultOrder.indexed) id: i};
    final last = widget.defaultOrder.length;
    final sorted = [...widget.items];
    mergeSort<ReorderItem>(
      sorted,
      compare: (a, b) => (position[a.id] ?? last).compareTo(position[b.id] ?? last),
    );
    return sorted;
  }

  bool get _isDefault => listEquals(_items, _defaultItems);

  void _apply(List<ReorderItem> items) {
    setState(() => _items = items);
    widget.onChanged([for (final item in items) item.id]);
  }

  void _move(int from, int to) {
    final items = [..._items];
    items.insert(to, items.removeAt(from));
    _apply(items);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: _items.length,
                onReorderItem: _move,
                itemBuilder: _buildItem,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('reorder_reset'),
                onPressed: _isDefault ? null : () => _apply(_defaultItems),
                child: Text(l10n.reorderReset),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final item = _items[index];
    return ListTile(
      key: ValueKey(item.id),
      contentPadding: EdgeInsets.zero,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: ReorderableDragStartListener(
              index: index,
              // `ColoredBox` hace que toda el asa reciba el arrastre, no sólo
              // el dibujo del icono.
              child: ColoredBox(
                key: Key('reorder_handle_${item.id}'),
                color: Colors.transparent,
                child: SizedBox.square(
                  dimension: 48,
                  child: Icon(
                    Icons.drag_handle_rounded,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ),
          if (item.icon != null) Icon(item.icon, color: AppTheme.primaryLight, size: 20),
        ],
      ),
      title: Text(
        item.label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
