import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../theme/area_colors.dart';
import 'color_picker_panel.dart';

Future<void> showAreaColorsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const AreaColorsSheet(),
  );
}

String _areaLabel(AppLocalizations l10n, ColorArea area) => switch (area) {
      ColorArea.lyrics => l10n.areaColorLyrics,
      ColorArea.nowPlayingTitle => l10n.areaColorNowPlayingTitle,
      ColorArea.playbackControls => l10n.areaColorPlaybackControls,
      ColorArea.navigation => l10n.areaColorNavigation,
      ColorArea.miniPlayer => l10n.areaColorMiniPlayer,
    };

/// Lo que se ve en cada zona sin anulación; también es de donde arranca el
/// selector.
Color _themeColor(ColorArea area) => switch (area) {
      ColorArea.lyrics || ColorArea.nowPlayingTitle => Colors.white,
      ColorArea.playbackControls => AppTheme.playerAccent,
      ColorArea.navigation => AppTheme.primaryLight,
      ColorArea.miniPlayer => AppTheme.accent,
    };

/// Cada cambio se aplica y se guarda en el acto: no hay "Guardar" ni "Cancelar"
/// porque restablecer es igual de directo.
class AreaColorsSheet extends StatefulWidget {
  const AreaColorsSheet({super.key});

  @override
  State<AreaColorsSheet> createState() => _AreaColorsSheetState();
}

class _AreaColorsSheetState extends State<AreaColorsSheet> {
  ColorArea? _open;

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
              l10n.settingsAreaColors,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            for (final area in ColorArea.values) ..._buildArea(area, settings, l10n),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('area_colors_reset_all'),
                onPressed: settings.areaColors.isEmpty ? null : settings.resetAreaColors,
                child: Text(l10n.areaColorResetAll),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildArea(
    ColorArea area,
    SettingsProvider settings,
    AppLocalizations l10n,
  ) {
    final override = settings.areaColor(area);
    final shown = override ?? _themeColor(area);
    final open = _open == area;
    final lowContrast = areaWantsContrastHint(area, override, background: AppTheme.surface);
    return [
      InkWell(
        key: Key('area_color_tile_${area.name}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _open = open ? null : area),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: shown,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _areaLabel(l10n, area),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    Text(
                      override == null ? l10n.areaColorFollowsTheme : l10n.areaColorCustomized,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                    if (lowContrast)
                      Text(
                        l10n.areaColorLowContrastHint,
                        key: Key('area_color_hint_${area.name}'),
                        style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (override != null)
                IconButton(
                  key: Key('area_color_reset_${area.name}'),
                  tooltip: l10n.areaColorReset,
                  icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70, size: 20),
                  onPressed: () => settings.setAreaColor(area, null),
                ),
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                color: Colors.white54,
                size: 20,
              ),
            ],
          ),
        ),
      ),
      if (open) ...[
        const SizedBox(height: 6),
        ColorPickerPanel(
          color: shown,
          showRgb: false,
          hueLabel: l10n.themePickerHueLabel,
          saturationValueLabel: l10n.themePickerSaturationValueLabel,
          onChanged: (color) => settings.setAreaColor(area, color),
        ),
        const SizedBox(height: 10),
      ],
    ];
  }
}
