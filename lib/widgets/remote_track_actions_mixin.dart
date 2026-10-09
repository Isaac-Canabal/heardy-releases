import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/download_provider.dart';
import '../providers/explore_provider.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/download_source.dart';
import '../services/friendly_error.dart';
import '../services/stream_resolver.dart';
import 'desktop_shell_scope.dart';
import 'playlist_target_sheet.dart';

/// Acciones "Descargar" y "Escuchar" de una pista remota para cualquier
/// pantalla con [State]. El host llama a [initRemoteTrackActions] en
/// `initState` y a [disposeRemoteTrackActions] en `dispose`.
mixin RemoteTrackActionsMixin<T extends StatefulWidget> on State<T> {
  /// Pista cuya URL directa se está pidiendo ahora; bloquea otro "Escuchar".
  String? streamingTrackId;

  // Un error a mitad de reproducción sólo trae el id, y la lista de la pantalla
  // pudo cambiar entre tanto.
  RemoteTrack? _lastListenedTrack;
  List<RemoteTrack> _lastQueueTracks = const [];
  StreamSubscription<StreamPlaybackError>? _streamErrorSub;

  /// Pistas visibles donde buscar la del error de reproducción si no es la
  /// última escuchada.
  Iterable<RemoteTrack> get streamErrorLookupTracks => const [];

  void initRemoteTrackActions() {
    _streamErrorSub = context.read<AudioPlayerHandler>().streamErrors.listen(_onStreamError);
  }

  void disposeRemoteTrackActions() {
    _streamErrorSub?.cancel();
  }

  void _onStreamError(StreamPlaybackError error) {
    if (!mounted) return;
    // Explorar vive en el IndexedStack mientras Búsqueda/colecciones se abren
    // encima: sólo la pantalla visible avisa, o saldría un snack por pantalla.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final last = _lastListenedTrack;
    final track = last != null && last.id == error.videoId
        ? last
        : findStreamErrorTrack(_lastQueueTracks, error.videoId) ??
            findStreamErrorTrack(streamErrorLookupTracks, error.videoId);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.skipped ? l10n.exploreStreamTrackSkipped : l10n.searchStreamPlaybackFailed),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: track != null ? 8 : 4),
        action: track != null
            ? SnackBarAction(
                label: l10n.searchListenDownloadAction,
                onPressed: () => downloadRemoteTrack(track),
              )
            : null,
      ),
    );
  }

  Future<void> downloadRemoteTrack(RemoteTrack track) =>
      enqueueRemoteTrackDownload(context, track, isMounted: () => mounted);

  bool _startingPlay = false;

  /// Acción por defecto al tocar una pista: si ya está en la biblioteca suena el
  /// archivo local; si no, streaming ([queue] = cola continua desde [track]).
  /// Sin streaming (escritorio) descarga.
  Future<void> playRemoteTrack(RemoteTrack track, {List<RemoteTrack>? queue}) async {
    if (!streamingSupported) return downloadRemoteTrack(track);
    if (_startingPlay || streamingTrackId != null) return;
    _startingPlay = true;
    try {
      final local = await context.read<ExploreProvider>().findLocalSong(track.id);
      if (!mounted) return;
      if (local != null) {
        final shell = DesktopShellScope.maybeOf(context);
        final handler = context.read<AudioPlayerHandler>();
        final label = AppLocalizations.of(context)!.exploreRecentTitle;
        shell?.openNowPlaying();
        await context.read<MusicProvider>().playSearchResults([local], local, handler, label);
        return;
      }
      if (queue != null) {
        await listenRemoteQueue(queue, track);
      } else {
        await listenRemoteTrack(track);
      }
    } finally {
      _startingPlay = false;
    }
  }

  Future<void> listenRemoteTrack(RemoteTrack track) async {
    if (streamingTrackId != null) return;
    final resolver = context.read<StreamResolver>();
    final handler = context.read<AudioPlayerHandler>();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shell = DesktopShellScope.maybeOf(context);
    setState(() => streamingTrackId = track.id);
    try {
      final info = await resolver.resolve(track.id);
      if (!mounted) return;
      _lastListenedTrack = track;
      await handler.playStream(track, info);
      shell?.openNowPlaying();
    } catch (e) {
      if (!mounted) return;
      _showListenFailure(l10n, messenger, track, e);
    } finally {
      if (mounted) setState(() => streamingTrackId = null);
    }
  }

  void _showListenFailure(
    AppLocalizations l10n,
    ScaffoldMessengerState messenger,
    RemoteTrack track,
    Object e,
  ) {
    final report = localizedErrorReport(l10n, e);
    final canDownload = offerDownloadAfterStreamFailure(e);
    messenger.showSnackBar(
      SnackBar(
        content: Text(e is DownloadSourceException ? report : l10n.searchListenFailed(report)),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: canDownload ? 8 : 4),
        action: canDownload
            ? SnackBarAction(
                label: l10n.searchListenDownloadAction,
                onPressed: () => downloadRemoteTrack(track),
              )
            : null,
      ),
    );
  }

  /// Reproduce [tracks] como cola de streaming empezando por [start] (E8). Los
  /// fallos por pista los avisa el handler por `streamErrors`.
  Future<void> listenRemoteQueue(List<RemoteTrack> tracks, RemoteTrack start) async {
    if (streamingTrackId != null) return;
    final resolver = context.read<StreamResolver>();
    final handler = context.read<AudioPlayerHandler>();
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shell = DesktopShellScope.maybeOf(context);
    setState(() => streamingTrackId = start.id);
    try {
      _lastListenedTrack = start;
      _lastQueueTracks = tracks;
      await handler.playStreamQueue(tracks, start.id, resolver);
      shell?.openNowPlaying();
    } catch (e) {
      if (!mounted) return;
      _showListenFailure(l10n, messenger, start, e);
    } finally {
      if (mounted) setState(() => streamingTrackId = null);
    }
  }
}

/// Elige playlist y encola la descarga de [track]; compartido por las pantallas
/// con el mixin y por Reproduciendo. [isMounted] protege los `await`.
Future<void> enqueueRemoteTrackDownload(
  BuildContext context,
  RemoteTrack track, {
  required bool Function() isMounted,
}) async {
  final choice = await pickTargetPlaylist(context);
  if (choice == null || !isMounted()) return;
  // ignore: use_build_context_synchronously
  final playlistId = await resolveTargetPlaylistId(context, choice);
  if (playlistId == null || !isMounted()) return;

  // ignore: use_build_context_synchronously
  final provider = context.read<DownloadProvider>();
  final added = await provider.enqueueTrack(
    track,
    playlistId: playlistId,
    // Viene de /search o de Explorar (listados aplanados): `artist` puede ser
    // el canal, no el artista real. metadataComplete=false hace que el worker
    // pida /resolve antes de bajar nada (DD6).
    metadataComplete: false,
  );
  if (!isMounted()) return;
  provider.processQueue();

  // ignore: use_build_context_synchronously
  final l10n = AppLocalizations.of(context)!;
  // ignore: use_build_context_synchronously
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(added ? l10n.searchAddedToQueueSnack(track.title) : l10n.searchAlreadyQueuedSnack),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}
