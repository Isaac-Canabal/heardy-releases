import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

Future<String?> showArtistPickerSheet(BuildContext context, List<String> names) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => ArtistPickerSheet(names: names),
  );
}

class ArtistPickerSheet extends StatelessWidget {
  final List<String> names;

  const ArtistPickerSheet({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(l10n.artistPickerTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          for (final name in names)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(name),
            ),
        ],
      ),
    );
  }
}
