import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/now_playing_screen.dart';
import '../services/audio_player_handler.dart';
import '../services/desktop_mini_mode_service.dart';
import '../services/lyrics_service.dart';

/// Contenido de la ventana en modo "minimizar y superponer": carátula,
/// la línea de letra actual y transporte básico (anterior/pausa/siguiente),
/// para el rectángulo chico que [DesktopMiniModeService] deja siempre
/// encima de las demás ventanas. A propósito no repite la cola ni el resto
/// de controles del panel completo — es para operar lo mínimo sin tener que
/// volver a la vista completa, no un reproductor alternativo.
class DesktopMiniPlayerView extends StatefulWidget {
  const DesktopMiniPlayerView({super.key});

  @override
  State<DesktopMiniPlayerView> createState() => _DesktopMiniPlayerViewState();
}

class _DesktopMiniPlayerViewState extends State<DesktopMiniPlayerView> {
  String? _lyricsSongId;
  List<LyricLine> _lines = [];

  Future<void> _loadLyricsIfNeeded(MediaItem item) async {
    if (_lyricsSongId == item.id) return;
    _lyricsSongId = item.id;
    _lines = [];
    try {
      final lyrics = await LyricsService.instance.getLyrics(
        songId: item.id,
        title: item.title,
        artist: item.artist ?? '',
        durationSeconds: item.duration?.inSeconds ?? 0,
      );
      if (lyrics == null || !mounted || _lyricsSongId != item.id) return;
      final parsed = LyricsService.instance.parseLrc(lyrics);
      if (mounted && _lyricsSongId == item.id) setState(() => _lines = parsed);
    } catch (_) {
      // Sin letra en la vista mini: no es un fallo, sólo se muestra artista.
    }
  }

  String? _lineAt(Duration position) {
    if (_lines.isEmpty) return null;
    LyricLine? current;
    for (final line in _lines) {
      if (line.time > position) break;
      current = line;
    }
    return current?.text;
  }

  @override
  Widget build(BuildContext context) {
    final audioHandler = context.watch<AudioPlayerHandler>();
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Colors.black,
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, snapshot) {
          final item = snapshot.data;
          if (item != null) _loadLyricsIfNeeded(item);
          final artPath = item?.extras?['artPath'] as String? ?? '';

          return Stack(
            fit: StackFit.expand,
            children: [
              if (item != null)
                SmartAlbumArt(artPath: artPath, title: item.title, size: 180)
              else
                const ColoredBox(color: Colors.black),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.15),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 4,
                child: item == null
                    ? const SizedBox.shrink()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 30),
                            child: StreamBuilder<Duration>(
                              stream: audioHandler.player.positionStream,
                              builder: (context, posSnapshot) {
                                final line = _lineAt(posSnapshot.data ?? Duration.zero);
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
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
                                      line ??
                                          item.artist ??
                                          AppLocalizations.of(context)!.commonUnknownArtist,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: line != null ? 0.95 : 0.6),
                                        fontStyle: line != null ? FontStyle.italic : FontStyle.normal,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          _MiniTransport(audioHandler: audioHandler),
                        ],
                      ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: IconButton(
                  tooltip: l10n.desktopMiniModeRestore,
                  iconSize: 18,
                  color: Colors.white,
                  icon: const Icon(Icons.open_in_full_rounded),
                  onPressed: () => DesktopMiniModeService.instance.exit(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Anterior/pausa/siguiente, sin el resto del transporte del panel completo
/// (aleatorio, repetir, cola): lo mínimo para no tener que salir del modo
/// mini a cambiar de canción. Íconos chicos y sin padding extra — la
/// ventana entera mide 320×180.
class _MiniTransport extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  const _MiniTransport({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(
          icon: Icons.skip_previous_rounded,
          onPressed: () => audioHandler.skipToPrevious(),
        ),
        StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return _button(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
            );
          },
        ),
        _button(
          icon: Icons.skip_next_rounded,
          onPressed: () => audioHandler.skipToNext(),
        ),
      ],
    );
  }

  Widget _button({required IconData icon, required VoidCallback onPressed}) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      iconSize: 20,
      color: Colors.white,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}
