import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import '../services/audio_player_handler.dart';
import '../services/stream_queue_logic.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../theme/area_colors.dart';
import '../screens/now_playing_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/overlap_view.dart';
import 'desktop_shell_scope.dart';
import 'overlap_cover_stack.dart';

/// Alto de la barra de progreso sobre el cuerpo del mini-reproductor.
const double _progressHeight = 3;

/// Alto del mini-reproductor sin texto agrandado: barra de progreso + cuerpo
/// de 68.
const double kMiniPlayerHeight = 71;

const double _titleFontSize = 14;
const double _artistFontSize = 12;
const double _labelsGap = 2;

/// Alto de línea holgado: cubre las fuentes empaquetadas y las de reserva del
/// sistema (CJK, árabe), que son más altas.
const double _lineHeightFactor = 1.5;

/// Borde superior más aire alrededor del texto.
const double _labelsMargin = 9;

/// Alto del cuerpo: el de siempre, salvo que el texto ya no quepa en él.
double miniPlayerBodyHeight(TextScaler textScaler) {
  final labels = (textScaler.scale(_titleFontSize) + textScaler.scale(_artistFontSize)) *
          _lineHeightFactor +
      _labelsGap;
  return math.max(68, labels + _labelsMargin);
}

/// Alto que una pantalla debe dejar libre abajo para que el mini-reproductor
/// (superpuesto en el shell) no tape sus controles. En escritorio la barra de
/// reproducción es otra y no se superpone.
double miniPlayerReservedHeight({
  required bool hasMedia,
  required bool desktopShell,
  TextScaler textScaler = TextScaler.noScaling,
}) =>
    hasMedia && !desktopShell ? _progressHeight + miniPlayerBodyHeight(textScaler) : 0;

/// Espacio que sube los controles fijos al pie de una pantalla (p. ej. la
/// barra de acciones de la bandeja) por encima del mini-reproductor.
class MiniPlayerInset extends StatelessWidget {
  const MiniPlayerInset({super.key});

  @override
  Widget build(BuildContext context) {
    final desktop = DesktopShellScope.maybeOf(context) != null;
    final audioHandler = Provider.of<AudioPlayerHandler>(context, listen: false);
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) => SizedBox(
        height: miniPlayerReservedHeight(
          hasMedia: snapshot.data != null,
          desktopShell: desktop,
          textScaler: MediaQuery.textScalerOf(context),
        ),
      ),
    );
  }
}

/// Título y artista del mini-reproductor. Es un widget aparte porque
/// [MiniPlayer] necesita el `AudioPlayerHandler` real y así el desborde se
/// puede probar con las fuentes de verdad.
class MiniPlayerTrackLabels extends StatelessWidget {
  final String title;
  final String artist;

  const MiniPlayerTrackLabels({super.key, required this.title, required this.artist});

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

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // En el shell de escritorio la barra inferior de reproducción ya ocupa
    // este papel; las pantallas que incrustan su propio MiniPlayer (detalle
    // de playlist) no tienen que saberlo.
    if (DesktopShellScope.maybeOf(context) != null) {
      return const SizedBox.shrink();
    }
    final audioHandler = Provider.of<AudioPlayerHandler>(context);
    final colors = resolveMiniPlayerColors(
      context.select<SettingsProvider, Color?>(
        (s) => s.areaColor(ColorArea.miniPlayer),
      ),
      progress: AppTheme.accent,
    );

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final mediaItem = snapshot.data;
        if (mediaItem == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: () => _openNowPlaying(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration>(
                stream: audioHandler.player.positionStream,
                builder: (context, posSnapshot) {
                  final position = posSnapshot.data ?? Duration.zero;
                  final duration = mediaItem.duration ?? Duration.zero;
                  final progress = duration.inMilliseconds > 0
                      ? position.inMilliseconds / duration.inMilliseconds
                      : 0.0;

                  return ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(colors.progress),
                      minHeight: _progressHeight,
                    ),
                  );
                },
              ),
              Container(
                height: miniPlayerBodyHeight(MediaQuery.textScalerOf(context)),
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
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    OverlapCoverStack(
                      item: mediaItem,
                      overlap: audioHandler.overlapView,
                      size: 44,
                      coverBuilder: (context, item) => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _buildAlbumArt(item),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ValueListenableBuilder<OverlapView?>(
                        valueListenable: audioHandler.overlapView,
                        builder: (context, view, _) {
                          final shown = displayedMediaItem(mediaItem, view);
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.centerLeft,
                              children: [...previous, if (current != null) current],
                            ),
                            child: MiniPlayerTrackLabels(
                              key: ValueKey<String>(shown.id),
                              title: shown.title,
                              artist: shown.artist ?? AppLocalizations.of(context)!.commonUnknownArtist,
                            ),
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded,
                          color: Colors.white, size: 26),
                      onPressed: () => audioHandler.skipToPrevious(),
                    ),
                    StreamBuilder<PlaybackState>(
                      stream: audioHandler.playbackState,
                      builder: (context, stateSnapshot) {
                        final playing = stateSnapshot.data?.playing ?? false;
                        return Container(
                          decoration: BoxDecoration(
                            color: colors.playButton,
                            gradient: colors.playButton == null
                                ? AppTheme.primaryGradient
                                : null,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: colors.playIcon,
                              size: 28,
                            ),
                            onPressed: () {
                              if (playing) {
                                audioHandler.pause();
                              } else {
                                audioHandler.play();
                              }
                            },
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded,
                          color: Colors.white, size: 26),
                      onPressed: () => audioHandler.skipToNext(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const NowPlayingScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: animation.drive(
              Tween(begin: const Offset(0, 1), end: Offset.zero).chain(
                CurveTween(curve: Curves.easeInOutCubic),
              ),
            ),
            child: child,
          );
        },
      ),
    );
  }

  Widget _buildAlbumArt(MediaItem item) {
    final artPath = item.extras?['artPath'] as String? ?? '';
    if (artPath.isNotEmpty) {
      final file = File(artPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(item.title),
        );
      }
    }
    final url = remoteArtUrlFor(artPath, item.artUri);
    if (url != null) {
      return Image.network(
        url,
        key: ValueKey(url),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        cacheHeight: 132,
        errorBuilder: (_, __, ___) => _buildPlaceholder(item.title),
      );
    }
    return _buildPlaceholder(item.title);
  }

  Widget _buildPlaceholder(String title) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: AppTheme.gradientForTitle(title),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
  }
}
