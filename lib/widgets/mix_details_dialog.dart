import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/mix_record.dart';
import '../screens/heardy_mixer_screen.dart' show mixerQualityLabel, mixerStyleName;
import '../services/mix/mixer_labels.dart';
import '../theme/app_theme.dart';

/// Localized date and time; a plain fallback if the locale data is missing.
String mixCreatedText(DateTime when, String languageCode) {
  try {
    return DateFormat.yMMMd(languageCode).add_Hm().format(when);
  } catch (_) {
    return when.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  }
}

/// What "Detalles" says about one mix: style, quality, creation time and songs.
class MixDetailsDialog extends StatelessWidget {
  const MixDetailsDialog({super.key, required this.record});

  final MixRecord record;

  static Future<void> show(BuildContext context, MixRecord record) =>
      showDialog<void>(context: context, builder: (_) => MixDetailsDialog(record: record));

  String _styleText(AppLocalizations l10n, MixDetails d) {
    final name = d.template == null ? null : mixerStyleName(l10n, d.template!);
    return switch (d.style) {
      MixStyleKind.automatic => l10n.mixesDetailsStyleAutomatic(name!),
      MixStyleKind.chosen => name!,
      MixStyleKind.edited => name == null ? l10n.mixesDetailsStyleEditedOnly : l10n.mixesDetailsStyleEdited(name),
      MixStyleKind.unknown => l10n.mixesDetailsUnknown,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final d = mixDetailsOf(record);
    final lang = Localizations.localeOf(context).languageCode;
    final rows = <(String, String)>[
      (l10n.mixesDetailsStyle, _styleText(l10n, d)),
      (l10n.mixesDetailsQuality, d.quality == null ? l10n.mixesDetailsUnknown : mixerQualityLabel(l10n, d.quality!)),
      (l10n.mixesDetailsCreated, mixCreatedText(d.createdAt, lang)),
      if (d.titleA.isNotEmpty && d.titleB.isNotEmpty)
        (l10n.mixesDetailsSongs, l10n.mixesDetailsSongsValue(d.titleA, d.titleB)),
    ];
    return AlertDialog(
      key: const Key('mixes_details_dialog'),
      backgroundColor: AppTheme.surface,
      title: Text(l10n.mixesDetailsTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(color: Colors.white, fontSize: 15)),
                ]),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('mixes_details_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.mixesDetailsClose),
        ),
      ],
    );
  }
}
