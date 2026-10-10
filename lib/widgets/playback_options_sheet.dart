import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/audio_player_handler.dart';
import '../services/playback_speed_logic.dart';
import '../services/repeat_count_logic.dart';

const _accent = Color(0xFF8C9EFF);

void _showSheet(BuildContext context, WidgetBuilder builder) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: builder,
  );
}

/// Elegir cuántas veces más se repite la canción actual.
void showRepeatCountSheet(BuildContext context, AudioPlayerHandler handler) {
  final l10n = AppLocalizations.of(context)!;
  _showSheet(context, (sheetContext) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.repeatCountTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder<int>(
              valueListenable: handler.repeatRemaining,
              builder: (context, remaining, _) => Text(
                remaining > 0
                    ? l10n.repeatCountRemaining(remaining)
                    : l10n.repeatCountBody,
                style: TextStyle(
                  color: remaining > 0 ? _accent : Colors.white54,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in const [1, 2, 3, 5, 10])
                  ActionChip(
                    label: Text(
                      l10n.repeatCountChip(clampRepeatCount(n)),
                      style: const TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    onPressed: () {
                      handler.startRepeatCount(n);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
              ],
            ),
            ValueListenableBuilder<int>(
              valueListenable: handler.repeatRemaining,
              builder: (context, remaining, _) {
                if (remaining <= 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton(
                    onPressed: () {
                      handler.cancelRepeatCount();
                      Navigator.of(sheetContext).pop();
                    },
                    child: Text(l10n.commonCancel),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  });
}

/// Velocidad (0.5x-2x) y, donde el motor lo permite, tono.
void showPlaybackSpeedSheet(BuildContext context, AudioPlayerHandler handler) {
  final l10n = AppLocalizations.of(context)!;
  _showSheet(context, (sheetContext) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: StreamBuilder<double>(
          stream: handler.player.speedStream,
          initialData: handler.player.speed,
          builder: (context, speedSnap) {
            final speed = normalizePlaybackRate(speedSnap.data ?? 1.0);
            return StreamBuilder<double>(
              stream: handler.player.pitchStream,
              initialData: handler.player.pitch,
              builder: (context, pitchSnap) {
                final pitch = normalizePlaybackRate(pitchSnap.data ?? 1.0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.playbackSpeedTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: isDefaultPlayback(speed, pitch)
                              ? null
                              : handler.resetPlaybackSpeedAndPitch,
                          child: Text(l10n.playbackReset),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _RateSlider(
                      label: l10n.playbackSpeedLabel,
                      value: speed,
                      onChanged: handler.setPlaybackSpeed,
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in playbackSpeedPresets)
                          ChoiceChip(
                            label: Text(playbackRateLabel(preset)),
                            selected: (speed - preset).abs() < 0.001,
                            onSelected: (_) => handler.setPlaybackSpeed(preset),
                          ),
                      ],
                    ),
                    if (handler.supportsPitch) ...[
                      const SizedBox(height: 20),
                      _RateSlider(
                        label: l10n.playbackPitchLabel,
                        value: pitch,
                        onChanged: handler.setPlaybackPitch,
                      ),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  });
}

class _RateSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _RateSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70)),
            Text(
              playbackRateLabel(value),
              style: const TextStyle(color: _accent),
            ),
          ],
        ),
        Slider(
          value: value,
          min: minPlaybackRate,
          max: maxPlaybackRate,
          divisions: ((maxPlaybackRate - minPlaybackRate) / playbackRateStep)
              .round(),
          activeColor: _accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
