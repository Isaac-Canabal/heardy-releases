import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/now_playing_screen.dart';
import '../services/audio_player_handler.dart';
import '../services/desktop_mini_mode_service.dart';
import '../services/stream_queue_logic.dart';
import 'add_current_track.dart';
import '../theme/app_theme.dart';

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
          height: 76,
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
                _TrackInfo(item: item, onTap: widget.onTogglePanel),
                const SizedBox(width: 8),
                _Transport(audioHandler: audioHandler),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: StreamBuilder<Duration>(
                  stream: audioHandler.player.positionStream,
                  builder: (context, posSnapshot) {
                    return SeekBar(
                      inline: true,
                      position: posSnapshot.data ?? Duration.zero,
                      duration: item.duration ?? Duration.zero,
                      onChangeEnd: audioHandler.seek,
                    );
                  },
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
                  widget.panelOpen
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

class _TrackInfo extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  const _TrackInfo({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    final hasArt = artPath.isNotEmpty && File(artPath).existsSync();
    final artUrl = remoteArtUrlFor(artPath, item.artUri);
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
              ClipRRect(
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
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.artist ??
                          AppLocalizations.of(context)!.commonUnknownArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ],
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
                gradient: AppTheme.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 24,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
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
