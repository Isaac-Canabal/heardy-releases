import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/now_playing_layout.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'reorder_sheet.dart';

Future<void> showNowPlayingLayoutSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => NowPlayingLayoutSheet(showDesktopOptions: Platform.isWindows),
  );
}

const _blockIcons = {
  NowPlayingBlock.art: Icons.album_rounded,
  NowPlayingBlock.info: Icons.title_rounded,
  NowPlayingBlock.actions: Icons.lyrics_outlined,
  NowPlayingBlock.seekBar: Icons.linear_scale_rounded,
  NowPlayingBlock.controls: Icons.play_circle_outline_rounded,
};

String _blockLabel(AppLocalizations l10n, NowPlayingBlock block) => switch (block) {
      NowPlayingBlock.art => l10n.nowPlayingBlockArt,
      NowPlayingBlock.info => l10n.nowPlayingBlockInfo,
      NowPlayingBlock.actions => l10n.nowPlayingBlockActions,
      NowPlayingBlock.seekBar => l10n.nowPlayingBlockSeekBar,
      NowPlayingBlock.controls => l10n.nowPlayingBlockControls,
    };

Future<void> _showBlockOrderSheet(BuildContext context, SettingsProvider settings) {
  final l10n = AppLocalizations.of(context)!;
  return showReorderSheet(
    context,
    title: l10n.nowPlayingLayoutBlockOrder,
    items: [
      for (final block in settings.nowPlayingBlockOrder)
        ReorderItem(id: block.name, label: _blockLabel(l10n, block), icon: _blockIcons[block]),
    ],
    defaultOrder: [for (final block in NowPlayingBlock.values) block.name],
    onChanged: (names) => settings.setNowPlayingBlockOrder(names.map(NowPlayingBlock.values.byName).toList()),
  );
}

/// Cada cambio se aplica y se guarda en el acto. [showDesktopOptions] añade lo
/// que sólo tiene efecto en el panel de escritorio.
class NowPlayingLayoutSheet extends StatelessWidget {
  final bool showDesktopOptions;

  const NowPlayingLayoutSheet({super.key, this.showDesktopOptions = false});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final captionStyle = TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsNowPlayingLayout,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            _Options<NowPlayingTitleAlign>(
              title: l10n.nowPlayingLayoutTitleAlign,
              keyPrefix: 'now_playing_title_align',
              values: NowPlayingTitleAlign.values,
              selected: settings.nowPlayingTitleAlign,
              nameOf: (align) => align.name,
              labelOf: (align) => switch (align) {
                NowPlayingTitleAlign.left => l10n.nowPlayingLayoutAlignLeft,
                NowPlayingTitleAlign.center => l10n.nowPlayingLayoutAlignCenter,
                NowPlayingTitleAlign.right => l10n.nowPlayingLayoutAlignRight,
              },
              onSelected: settings.setNowPlayingTitleAlign,
            ),
            const SizedBox(height: 18),
            _Options<NowPlayingArtSize>(
              title: l10n.nowPlayingLayoutArtSize,
              keyPrefix: 'now_playing_art_size',
              values: NowPlayingArtSize.values,
              selected: settings.nowPlayingArtSize,
              nameOf: (size) => size.name,
              labelOf: (size) => switch (size) {
                NowPlayingArtSize.small => l10n.nowPlayingLayoutArtSmall,
                NowPlayingArtSize.medium => l10n.nowPlayingLayoutArtMedium,
                NowPlayingArtSize.large => l10n.nowPlayingLayoutArtLarge,
              },
              onSelected: settings.setNowPlayingArtSize,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('now_playing_seek_buttons'),
              contentPadding: EdgeInsets.zero,
              value: settings.showSeekButtons,
              title: Text(
                l10n.nowPlayingLayoutSeekButtons,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              onChanged: settings.setShowSeekButtons,
            ),
            ListTile(
              key: const Key('now_playing_block_order'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.nowPlayingLayoutBlockOrder,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.4),
              ),
              onTap: () => _showBlockOrderSheet(context, settings),
            ),
            if (showDesktopOptions) ...[
              Text(l10n.nowPlayingLayoutDesktopNote, style: captionStyle),
              const SizedBox(height: 18),
              _Options<DesktopPanelSide>(
                title: l10n.nowPlayingLayoutPanelSide,
                keyPrefix: 'desktop_panel_side',
                values: DesktopPanelSide.values,
                selected: settings.desktopPanelSide,
                nameOf: (side) => side.name,
                labelOf: (side) => switch (side) {
                  DesktopPanelSide.right => l10n.nowPlayingLayoutAlignRight,
                  DesktopPanelSide.left => l10n.nowPlayingLayoutAlignLeft,
                },
                onSelected: settings.setDesktopPanelSide,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('now_playing_layout_reset'),
                onPressed: settings.nowPlayingLayoutIsDefault ? null : settings.resetNowPlayingLayout,
                child: Text(l10n.nowPlayingLayoutReset),
              ),
            ),
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
