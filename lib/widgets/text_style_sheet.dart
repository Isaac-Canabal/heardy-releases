import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../theme/app_fonts.dart';
import '../theme/app_theme.dart';

Future<void> showTextStyleSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const TextStyleSheet(),
  );
}

String _fontLabel(AppLocalizations l10n, AppFont font) => switch (font) {
      AppFont.system => l10n.textStyleFontSystem,
      AppFont.rounded => l10n.textStyleFontRounded,
      AppFont.serif => l10n.textStyleFontSerif,
      AppFont.mono => l10n.textStyleFontMono,
    };

String _scaleLabel(AppTextScale scale) => '${(scale.factor * 100).round()} %';

/// Cada cambio se aplica y se guarda en el acto; toda la app, esta hoja
/// incluida, se redibuja con él, así que la vista previa no necesita lógica.
class TextStyleSheet extends StatelessWidget {
  const TextStyleSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsTextStyle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.textStylePreview,
              key: const Key('text_style_preview'),
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 18),
            _Options<AppFont>(
              title: l10n.textStyleFontLabel,
              keyPrefix: 'text_style_font',
              values: AppFont.values,
              selected: settings.appFont,
              nameOf: (font) => font.name,
              labelOf: (font) => _fontLabel(l10n, font),
              onSelected: settings.setAppFont,
            ),
            const SizedBox(height: 18),
            _Options<AppTextScale>(
              title: l10n.textStyleScaleLabel,
              keyPrefix: 'text_style_scale',
              values: AppTextScale.values,
              selected: settings.textScale,
              nameOf: (scale) => scale.name,
              labelOf: _scaleLabel,
              onSelected: settings.setTextScale,
            ),
            const SizedBox(height: 18),
            _Options<AppTextScale>(
              title: l10n.textStyleLyricsScaleLabel,
              keyPrefix: 'lyrics_text_scale',
              values: AppTextScale.values,
              selected: settings.lyricsTextScale,
              nameOf: (scale) => scale.name,
              labelOf: _scaleLabel,
              onSelected: settings.setLyricsTextScale,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Options<T> extends StatelessWidget {
  final String title;
  final String keyPrefix;
  final List<T> values;
  final T selected;
  final String Function(T) nameOf;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  const _Options({
    required this.title,
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.nameOf,
    required this.labelOf,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final value in values)
              ChoiceChip(
                key: Key('${keyPrefix}_${nameOf(value)}'),
                label: Text(labelOf(value)),
                selected: value == selected,
                onSelected: (_) => onSelected(value),
              ),
          ],
        ),
      ],
    );
  }
}
