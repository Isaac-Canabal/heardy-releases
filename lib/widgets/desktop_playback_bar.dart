import 'dart:io';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/now_playing_screen.dart';
import '../services/audio_player_handler.dart';
import '../services/desktop_mini_mode_service.dart';
import '../services/overlap_view.dart';
import 'overlap_cover_stack.dart';
import '../services/stream_queue_logic.dart';
import '../models/now_playing_layout.dart';
import '../providers/settings_provider.dart';
import 'add_current_track.dart';
import '../theme/app_theme.dart';
import '../theme/area_colors.dart';

const double _titleFontSize = 13;
const double _artistFontSize = 11;
const double _labelsGap = 2;

/// Alto de línea holgado: cubre las fuentes empaquetadas y las de reserva del
/// sistema (CJK, árabe), que son más altas.
const double _lineHeightFactor = 1.5;

/// Borde superior más aire alrededor del texto.
const double _labelsMargin = 9;

/// Alto de la barra: el de siempre, salvo que el texto ya no quepa en él.
double desktopPlaybackBarHeight(TextScaler textScaler) {
  final labels = (textScaler.scale(_titleFontSize) + textScaler.scale(_artistFontSize)) *
          _lineHeightFactor +
      _labelsGap;
  return math.max(76, labels + _labelsMargin);
}

/// Barra inferior del escritorio, sólo bajo la columna de contenido (del
/// borde de la barra lateral al borde del panel derecho): la línea de tiempo
/// con sus tiempos y el volumen. Con el panel cerrado lleva además la
/// canción y los controles básicos, para que nunca haga falta abrirlo sólo
/// para pausar.
class DesktopPlaybackBar extends StatefulWidget {
  final bool panelOpen;
  final VoidCallback onTogglePanel;

  const DesktopPlaybackBar({
    super.key,
    required this.panelOpen,
    required this.onTogglePanel,
  });

  @override
  State<DesktopPlaybackBar> createState() => _DesktopPlaybackBarState();
}

class _DesktopPlaybackBarState extends State<DesktopPlaybackBar> {
  @override
  Widget build(BuildContext context) {
    final audioHandler = Provider.of<AudioPlayerHandler>(context);
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) return const SizedBox.shrink();

        return Container(
          height: desktopPlaybackBarHeight(MediaQuery.textScalerOf(context)),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.surface.withValues(alpha: 0.98),
                AppTheme.backgroundTop,
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (!widget.panelOpen) ...[
                _TrackInfo(
                  item: item,
                  overlap: audioHandler.overlapView,
                  onTap: widget.onTogglePanel,
                ),
                const SizedBox(width: 8),
                _Transport(audioHandler: audioHandler),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: WaveformSeekSection(
                  // Esta barra es el minirreproductor del escritorio: su color
                  // manda, y si no hay, el de los controles.
                  activeColor: context.select<SettingsProvider, Color?>(
                    (s) =>
                        s.areaColor(ColorArea.miniPlayer) ??
                        s.areaColor(ColorArea.playbackControls),
                  ),
                  inline: true,
                  compact: true,
                  mediaItem: item,
                  positionStream: audioHandler.player.positionStream,
                  onSeek: audioHandler.seek,
                ),
              ),
              const SizedBox(width: 12),
              const DesktopVolumeControl(),
              if (!widget.panelOpen) AddToPlaylistIconButton(item: item),
              IconButton(
                tooltip: l10n.desktopMiniModeEnter,
                icon: const Icon(
                  Icons.picture_in_picture_alt_rounded,
                  color: Colors.white70,
                ),
                onPressed: () => DesktopMiniModeService.instance.enter(),
              ),
              IconButton(
                tooltip: widget.panelOpen
                    ? l10n.desktopHideNowPlaying
                    : l10n.desktopShowNowPlaying,
                icon: Icon(
                  widget.panelOpen ==
                          context.select<SettingsProvider, bool>(
                            (s) => s.desktopPanelSide == DesktopPanelSide.right,
                          )
                      ? Icons.keyboard_double_arrow_right_rounded
                      : Icons.keyboard_double_arrow_left_rounded,
                  color: Colors.white70,
                ),
                onPressed: widget.onTogglePanel,
              ),
            ],
          ),
        );
      },
    );
  }

}

/// Botón de silenciar + slider de volumen. Compartido entre la barra
/// inferior y la columna de info de la letra expandida (`DesktopNowPlayingPanel`),
/// para no duplicar el estado de "último volumen audible" en dos sitios.
class DesktopVolumeControl extends StatefulWidget {
  const DesktopVolumeControl({super.key});

  @override
  State<DesktopVolumeControl> createState() => _DesktopVolumeControlState();
}

class _DesktopVolumeControlState extends State<DesktopVolumeControl> {
  double _lastAudible = 1.0;

  @override
  Widget build(BuildContext context) {
    final audioHandler = Provider.of<AudioPlayerHandler>(context);
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<double>(
      valueListenable: audioHandler.volume,
      builder: (context, volume, _) {
        if (volume > 0) _lastAudible = volume;
        final icon = volume == 0
            ? Icons.volume_off_rounded
            : volume < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l10n.desktopVolume,
              iconSize: 20,
              icon: Icon(icon, color: Colors.white70),
              onPressed: () =>
                  audioHandler.setVolume(volume == 0 ? _lastAudible : 0),
            ),
            SizedBox(
              width: 110,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  activeTrackColor: Colors.white70,
                  inactiveTrackColor: Colors.white10,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  min: 0,
                  max: 1,
                  value: volume,
                  label: '${(volume * 100).round()} %',
                  onChanged: audioHandler.setVolume,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Título y artista de la barra. Es un widget aparte porque la barra necesita
/// el `AudioPlayerHandler` real y así el desborde se puede probar con las
/// fuentes de verdad.
class DesktopTrackLabels extends StatelessWidget {
  final String title;
  final String artist;

  const DesktopTrackLabels({super.key, required this.title, required this.artist});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: _titleFontSize,
          ),
        ),
        const SizedBox(height: _labelsGap),
        Text(
          artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: _artistFontSize,
          ),
        ),
      ],
    );
  }
}

class _TrackInfo extends StatelessWidget {
  final MediaItem item;
  final ValueListenable<OverlapView?> overlap;
  final VoidCallback onTap;
  const _TrackInfo({required this.item, required this.overlap, required this.onTap});

  Widget _cover(MediaItem item) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    final hasArt = artPath.isNotEmpty && File(artPath).existsSync();
    final artUrl = remoteArtUrlFor(artPath, item.artUri);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: hasArt
          ? Image.file(
              File(artPath),
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(item.title),
            )
          : artUrl != null
          ? Image.network(
              artUrl,
              key: ValueKey(artUrl),
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              cacheHeight: 132,
              errorBuilder: (_, __, ___) => _placeholder(item.title),
            )
          : _placeholder(item.title),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220, minWidth: 120),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OverlapCoverStack(
                item: item,
                overlap: overlap,
                size: 44,
                coverBuilder: (context, it) => _cover(it),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: ValueListenableBuilder<OverlapView?>(
                  valueListenable: overlap,
                  builder: (context, view, _) {
                    final shown = displayedMediaItem(item, view);
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, if (current != null) current],
                      ),
                      child: DesktopTrackLabels(
                        key: ValueKey<String>(shown.id),
                        title: shown.title,
                        artist: shown.artist ??
                            AppLocalizations.of(context)!.commonUnknownArtist,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(String title) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(title)),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
  }
}

class _Transport extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  const _Transport({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    final colors = resolveMiniPlayerColors(
      context.select<SettingsProvider, Color?>(
        (s) => s.areaColor(ColorArea.miniPlayer),
      ),
      progress: AppTheme.accent,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(
            Icons.skip_previous_rounded,
            color: Colors.white,
            size: 24,
          ),
          onPressed: () => audioHandler.skipToPrevious(),
        ),
        StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return Container(
              decoration: BoxDecoration(
                color: colors.playButton,
                gradient: colors.playButton == null ? AppTheme.primaryGradient : null,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 24,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: colors.playIcon,
                ),
                onPressed: () =>
                    playing ? audioHandler.pause() : audioHandler.play(),
              ),
            );
          },
        ),
        IconButton(
          icon: const Icon(
            Icons.skip_next_rounded,
            color: Colors.white,
            size: 24,
          ),
          onPressed: () => audioHandler.skipToNext(),
        ),
      ],
    );
  }
}
