import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/now_playing_screen.dart';
import '../services/audio_player_handler.dart';
import '../services/desktop_tray_service.dart';
import '../services/open_artist_profile.dart';
import '../services/stream_queue_logic.dart';
import 'add_current_track.dart';
import 'playback_options_sheet.dart';
import 'desktop_playback_bar.dart' show DesktopVolumeControl;

/// El "reproduciendo ahora" del escritorio: la misma información que
/// `NowPlayingScreen` en el teléfono (carátula, título, artista, controles),
/// pero como columna fija a la derecha del shell en vez de una ruta a
/// pantalla completa, con la letra y la cola debajo de la carátula. La línea
/// de tiempo y el volumen no viven acá sino en la barra inferior del
/// contenido (`DesktopPlaybackBar`) — excepto con la letra expandida
/// (`lyricsExpanded`), donde el panel ocupa toda la fila y sí las muestra
/// él mismo, ver `_buildExpanded`.
class DesktopNowPlayingPanel extends StatefulWidget {
  final VoidCallback onClose;
  final ValueChanged<String> onOpenPlaylist;

  /// Empuja una ruta en el navegador de contenido del shell (no en el raíz),
  /// contrayendo antes la letra expandida que lo tapa.
  final ValueChanged<Route<void>> onPushContentRoute;

  /// `true` cuando la letra está expandida: el panel deja de recibir un
  /// ancho fijo del shell (pasa a ocupar todo lo que sobra a la derecha de
  /// la barra lateral) y reparte ese espacio internamente 2/3 letra, 1/3
  /// carátula/controles/línea de tiempo/volumen/cola.
  final bool lyricsExpanded;
  final VoidCallback onToggleLyricsExpanded;

  /// Sólo tiene efecto con [lyricsExpanded]: reemplaza la columna de
  /// carátula/controles/línea de tiempo/volumen/cola por sólo la carátula,
  /// girando lentamente como un disco — la letra pasa a ser lo único más
  /// grande en pantalla. `onToggleCinemaMode` es null cuando la letra no está
  /// expandida: ahí el botón no tiene dónde aparecer (ver
  /// `LyricsBottomSheet._buildEmbedded`, que sólo lo pinta si `expanded` es
  /// `true`).
  final bool cinemaMode;
  final VoidCallback? onToggleCinemaMode;

  const DesktopNowPlayingPanel({
    super.key,
    required this.onClose,
    required this.onOpenPlaylist,
    required this.onPushContentRoute,
    this.lyricsExpanded = false,
    required this.onToggleLyricsExpanded,
    this.cinemaMode = false,
    this.onToggleCinemaMode,
  });

  @override
  State<DesktopNowPlayingPanel> createState() => _DesktopNowPlayingPanelState();
}

class _DesktopNowPlayingPanelState extends State<DesktopNowPlayingPanel> {
  String? _currentId;
  Color _dominantColor = kNowPlayingFallbackColor;
  int _tab = 0;
  bool _openingArtist = false;

  Future<void> _openArtist(String credits) {
    if (_openingArtist) return Future.value();
    return openArtistProfile(
      context,
      credits,
      isMounted: () => mounted,
      setBusy: (busy) => setState(() => _openingArtist = busy),
      pushRoute: widget.onPushContentRoute,
    );
  }

  Widget _artistLink(MediaItem item, double fontSize) {
    final artist = item.artist ?? '';
    return ArtistLink(
      label: artist.isEmpty ? AppLocalizations.of(context)!.commonUnknownArtist : artist,
      busy: _openingArtist,
      fontSize: fontSize,
      onTap: artist.trim().isEmpty ? null : () => _openArtist(artist),
    );
  }

  String _artPathOf(MediaItem item) => item.extras?['artPath'] as String? ?? '';

  String? _artUrlOf(MediaItem item) =>
      remoteArtUrlFor(_artPathOf(item), item.artUri);

  Future<void> _updatePalette(MediaItem item) async {
    final artPath = item.extras?['artPath'] as String? ?? '';
    final color = await dominantColorForArt(
      artPath,
      artUrl: remoteArtUrlFor(artPath, item.artUri),
    );
    if (mounted && _currentId == item.id) {
      setState(() => _dominantColor = color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final audioHandler = context.read<AudioPlayerHandler>();
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) {
          return _Frame(
            color: _dominantColor,
            child: Column(
              children: [
                _header(context, audioHandler, null),
                Expanded(
                  child: Center(
                    child: Text(
                      l10n.nowPlayingNoMusic,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (_currentId != item.id) {
          _currentId = item.id;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _updatePalette(item),
          );
        }

        return _Frame(
          color: _dominantColor,
          child: widget.lyricsExpanded
              ? _buildExpanded(context, audioHandler, item)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final artSize = math.min(
                      constraints.maxWidth - 56,
                      constraints.maxHeight * 0.34,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context, audioHandler, item),
                        const SizedBox(height: 4),
                        Center(
                          child: Card(
                            elevation: 12,
                            shadowColor: _dominantColor.withValues(alpha: 0.35),
                            margin: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: SmartAlbumArt(
                                artPath: _artPathOf(item),
                                artUrl: _artUrlOf(item),
                                title: item.title,
                                size: artSize,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                          child: Column(
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              _artistLink(item, 14),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        _Controls(audioHandler: audioHandler),
                        const SizedBox(height: 6),
                        _tabs(context),
                        const Divider(color: Colors.white12, height: 1),
                        Expanded(
                          child: IndexedStack(
                            index: _tab,
                            children: [
                              LyricsBottomSheet(
                                // Una sola instancia para todo el panel: el
                                // sheet se suscribe al stream de `mediaItem`
                                // y se actualiza solo al cambiar de canción.
                                key: const ValueKey('desktop-lyrics'),
                                mediaItem: item,
                                audioHandler: audioHandler,
                                dominantColor: _dominantColor,
                                embedded: true,
                                onToggleExpanded: widget.onToggleLyricsExpanded,
                              ),
                              QueueBottomSheet(
                                key: const ValueKey('desktop-queue'),
                                audioHandler: audioHandler,
                                embedded: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }

  /// Con la letra expandida no hay tabs: la letra se muestra siempre a la
  /// izquierda y la columna angosta de la derecha se reparte entre dos
  /// vistas según [DesktopNowPlayingPanel.cinemaMode] — la normal
  /// (carátula/controles/línea de tiempo/volumen/cola, 2/3 + 1/3) o la de
  /// modo cine (sólo la carátula girando, sin controles ni cola: ver
  /// [_buildCinemaSide]), con más ancho para la letra (3/2) porque no hay
  /// nada más que mostrar en la columna derecha que compita por ese espacio.
  Widget _buildExpanded(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    MediaItem item,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, audioHandler, item),
        const Divider(color: Colors.white12, height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: widget.cinemaMode ? 3 : 2,
                child: LyricsBottomSheet(
                  key: const ValueKey('desktop-lyrics-expanded'),
                  mediaItem: item,
                  audioHandler: audioHandler,
                  dominantColor: _dominantColor,
                  embedded: true,
                  expanded: true,
                  onToggleExpanded: widget.onToggleLyricsExpanded,
                  cinemaMode: widget.cinemaMode,
                  onToggleCinemaMode: widget.onToggleCinemaMode,
                ),
              ),
              const VerticalDivider(color: Colors.white12, width: 1),
              if (widget.cinemaMode)
                Expanded(flex: 2, child: _buildCinemaSide(item))
              else
                Expanded(
                  flex: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final artSize = math.min(
                              constraints.maxWidth,
                              180.0,
                            );
                            return Center(
                              child: Card(
                                elevation: 12,
                                shadowColor: _dominantColor.withValues(
                                  alpha: 0.35,
                                ),
                                margin: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: SmartAlbumArt(
                                    artPath: _artPathOf(item),
                                    artUrl: _artUrlOf(item),
                                    title: item.title,
                                    size: artSize,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _artistLink(item, 13),
                        const SizedBox(height: 12),
                        _Controls(audioHandler: audioHandler),
                        const SizedBox(height: 12),
                        WaveformSeekSection(
                          compact: true,
                          mediaItem: item,
                          positionStream: audioHandler.player.positionStream,
                          onSeek: audioHandler.seek,
                        ),
                        const SizedBox(height: 4),
                        const Center(child: DesktopVolumeControl()),
                        const SizedBox(height: 12),
                        const Divider(color: Colors.white12, height: 1),
                        Expanded(
                          child: QueueBottomSheet(
                            key: const ValueKey('desktop-queue-expanded'),
                            audioHandler: audioHandler,
                            embedded: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// La columna derecha del modo cine: sólo la carátula girando, centrada y
  /// tan grande como el espacio disponible lo permita (acotada para que
  /// nunca opaque a la letra ni se sienta desproporcionada en una ventana
  /// muy alta). Sin título/artista/controles/cola a propósito — el pedido
  /// explícito fue "sólo dejar la letra con la carátula".
  Widget _buildCinemaSide(MediaItem item) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final discSize = math
              .min(constraints.maxWidth, constraints.maxHeight)
              .clamp(120.0, 460.0);
          return Center(
            child: _SpinningDisc(
              artPath: _artPathOf(item),
              artUrl: _artUrlOf(item),
              title: item.title,
              size: discSize,
            ),
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    MediaItem? item,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final playlistId = item?.extras?['playlist_id'] as String?;
    final playlistName = item?.album ?? '';
    final label = playlistName.isNotEmpty
        ? l10n.desktopNowPlayingFrom(playlistName)
        : l10n.desktopNowPlaying;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
        letterSpacing: 1.0,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.desktopHideNowPlaying,
            icon: const Icon(
              Icons.keyboard_double_arrow_right_rounded,
              color: Colors.white70,
            ),
            onPressed: widget.onClose,
          ),
          Expanded(
            child: playlistId == null || playlistId.isEmpty
                ? labelText
                : InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onOpenPlaylist(playlistId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: labelText,
                    ),
                  ),
          ),
          if (item != null) AddToPlaylistIconButton(item: item),
          ValueListenableBuilder<int>(
            valueListenable: audioHandler.repeatRemaining,
            builder: (context, remaining, _) => IconButton(
              tooltip: remaining > 0
                  ? l10n.repeatCountRemaining(remaining)
                  : l10n.repeatCountTitle,
              icon: Icon(
                Icons.repeat_one,
                color: remaining > 0 ? const Color(0xFF8C9EFF) : Colors.white70,
              ),
              onPressed: () => showRepeatCountSheet(context, audioHandler),
            ),
          ),
          StreamBuilder<double>(
            stream: audioHandler.player.speedStream,
            initialData: audioHandler.player.speed,
            builder: (context, snapshot) {
              final changed = (snapshot.data ?? 1.0) != 1.0;
              return IconButton(
                tooltip: l10n.playbackSpeedTitle,
                icon: Icon(
                  Icons.speed,
                  color: changed ? const Color(0xFF8C9EFF) : Colors.white70,
                ),
                onPressed: () => showPlaybackSpeedSheet(context, audioHandler),
              );
            },
          ),
          ValueListenableBuilder<int?>(
            valueListenable: audioHandler.sleepTracksRemaining,
            builder: (context, tracksLeft, _) => StreamBuilder<Duration?>(
              stream: audioHandler.sleepTimerStream,
              initialData: audioHandler.sleepTimerRemainingNow,
              builder: (context, snapshot) {
                final active = snapshot.data != null || tracksLeft != null;
                return IconButton(
                  tooltip: l10n.nowPlayingSleepTimerTitle,
                  icon: Icon(
                    active ? Icons.bedtime : Icons.bedtime_outlined,
                    color: active ? const Color(0xFF8C9EFF) : Colors.white70,
                  ),
                  onPressed: () => active
                      ? audioHandler.cancelSleepTimer()
                      : showSleepTimerPicker(context, audioHandler),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStatePropertyAll(
            BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.white60,
          ),
        ),
        segments: [
          ButtonSegment(
            value: 0,
            icon: const Icon(Icons.lyrics_outlined, size: 16),
            label: Text(l10n.nowPlayingLyricsButton),
          ),
          ButtonSegment(
            value: 1,
            icon: const Icon(Icons.queue_music, size: 16),
            label: Text(l10n.nowPlayingQueueButton),
          ),
        ],
        selected: {_tab},
        onSelectionChanged: (s) => setState(() => _tab = s.first),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  final Color color;
  final Widget child;
  const _Frame({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.4), const Color(0xFF0D0D0D)],
          stops: const [0.0, 0.85],
        ),
      ),
      child: child,
    );
  }
}

/// Aleatorio · anterior · play/pausa · siguiente · repetir. Sin los ±5 s del
/// teléfono: en el escritorio las flechas del teclado ya hacen eso.
class _Controls extends StatelessWidget {
  final AudioPlayerHandler audioHandler;
  const _Controls({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final shuffle = state?.shuffleMode == AudioServiceShuffleMode.all;
        final repeat = state?.repeatMode ?? AudioServiceRepeatMode.none;
        final repeatOn = repeat != AudioServiceRepeatMode.none;
        const active = Color(0xFF8C9EFF);

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: l10n.nowPlayingShuffleTitle,
              icon: Icon(
                Icons.shuffle_rounded,
                size: 22,
                color: shuffle ? active : Colors.white60,
              ),
              onPressed: () => audioHandler.setShuffleMode(
                shuffle
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.skip_previous_rounded,
                size: 34,
                color: Colors.white,
              ),
              onPressed: () => audioHandler.skipToPrevious(),
            ),
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: IconButton(
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.black,
                  size: 32,
                ),
                onPressed: () =>
                    playing ? audioHandler.pause() : audioHandler.play(),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.skip_next_rounded,
                size: 34,
                color: Colors.white,
              ),
              onPressed: () => audioHandler.skipToNext(),
            ),
            IconButton(
              tooltip: l10n.nowPlayingRepeatTitle,
              icon: Icon(
                repeat == AudioServiceRepeatMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                size: 22,
                color: repeatOn ? active : Colors.white60,
              ),
              onPressed: () => audioHandler.setRepeatMode(switch (repeat) {
                AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                _ => AudioServiceRepeatMode.none,
              }),
            ),
          ],
        );
      },
    );
  }
}

/// La carátula del modo cine: recortada en círculo, con un aro y un "hoyo"
/// central para que se lea como disco (no sólo como una carátula redondeada),
/// girando de forma continua y lenta — 18 s por vuelta, deliberadamente lejos
/// de los ~33-45 rpm de un vinilo real, que a este tamaño distraería de la
/// letra en vez de acompañarla.
class _SpinningDisc extends StatefulWidget {
  final String artPath;
  final String? artUrl;
  final String title;
  final double size;

  const _SpinningDisc({
    required this.artPath,
    this.artUrl,
    required this.title,
    required this.size,
  });

  @override
  State<_SpinningDisc> createState() => _SpinningDiscState();
}

class _SpinningDiscState extends State<_SpinningDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void initState() {
    super.initState();
    // Ventana minimizada u oculta en la bandeja: nadie ve el disco girar,
    // así que se detiene en vez de seguir gastando frames en segundo plano.
    // `isVisible` empieza en `true` y sólo cambia si `DesktopTrayService` se
    // inicializó (Windows), así que esto es inofensivo en cualquier otro caso.
    DesktopTrayService.instance.isVisible.addListener(_onVisibilityChanged);
  }

  void _onVisibilityChanged() {
    if (DesktopTrayService.instance.isVisible.value) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    DesktopTrayService.instance.isVisible.removeListener(_onVisibilityChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final holeSize = widget.size * 0.07;
    return RepaintBoundary(
      child: RotationTransition(
        turns: _controller,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipOval(
            // Sin `fit: StackFit.expand` a propósito: con expand, TODO hijo no
            // posicionado se estira al tamaño completo del stack ignorando su
            // propio width/height — el "hoyo" de abajo (pensado como un
            // círculo chico, ~7% del disco) se volvía del tamaño entero del
            // disco, y su color casi negro tapaba la carátula por completo.
            // `StackFit.loose` (el default) deja que cada hijo respete su
            // propio tamaño; `SmartAlbumArt` igual llena el círculo porque
            // pide explícitamente `widget.size`.
            child: Stack(
              alignment: Alignment.center,
              children: [
                SmartAlbumArt(
                  artPath: widget.artPath,
                  artUrl: widget.artUrl,
                  title: widget.title,
                  size: widget.size,
                ),
                // Surco sutil del vinilo — un aro nada más, no un patrón real.
                Container(
                  width: widget.size * 0.8,
                  height: widget.size * 0.8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
                Container(
                  width: holeSize,
                  height: holeSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.85),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
