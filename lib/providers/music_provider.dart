import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:audio_service/audio_service.dart';
import '../models/remote_track_record.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/audio_player_handler.dart';
import '../services/playback_state_service.dart';
import '../services/friendly_error.dart';
import '../services/online_playlist_logic.dart';
import '../services/storage_service.dart';
import '../services/stream_resolver.dart';

class MusicProvider with ChangeNotifier {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final StorageService _storageService = StorageService();

  List<Playlist> _playlists = [];
  List<Song> _currentPlaylistSongs = [];
  String? _currentPlaylistId;
  int _inboxCount = 0;
  String? _libraryRootUri;
  int _librarySongsVersion = 0;

  List<Playlist> get playlists => _playlists;
  List<Song> get currentPlaylistSongs => _currentPlaylistSongs;
  String? get currentPlaylistId => _currentPlaylistId;
  int get inboxCount => _inboxCount;
  // Single source of truth for "is a library folder picked, and which one" —
  // read this everywhere instead of each screen tracking its own copy.
  // Settings/inbox_screen used to each load it independently, so picking a
  // folder in one never showed up in the other without navigating away and
  // back (IndexedStack keeps both alive, neither reloads on tab switch).
  String? get libraryRootUri => _libraryRootUri;
  // Bumped on every completed scan. search_screen.dart watches this to know
  // when to reload its song list — same IndexedStack staleness class as
  // libraryRootUri above: a screen that only loaded songs in initState()
  // never saw anything imported after the app's cold start.
  int get librarySongsVersion => _librarySongsVersion;

  MusicProvider() {
    loadPlaylists();
    refreshInboxCount();
    refreshLibraryRootUri();
  }

  /// Call after a scan completes — signals every screen that lists songs
  /// (currently just search) to reload from SQLite.
  void notifyLibraryChanged() {
    _librarySongsVersion++;
    notifyListeners();
  }

  /// Recomputes the inbox badge count. Call after a scan and after any
  /// batch-assign/ignore action so the bottom-nav badge stays live.
  Future<void> refreshInboxCount() async {
    try {
      _inboxCount = await _dbHelper.getInboxSongCount();
      notifyListeners();
    } catch (e) {
      print("Error refreshing inbox count: $e");
    }
  }

  /// Re-reads the persisted root — only needed at startup. Once loaded,
  /// mutate it via [setLibraryRootUri] instead of round-tripping through
  /// storage again.
  ///
  /// Validates the SAF grant before trusting the stored uri. Android revokes
  /// a tree's persisted permission on uninstall — always, unconditionally —
  /// but `SharedPreferences` (and the rest of the SQLite db) can come back
  /// on a reinstall via Android's own Auto Backup, which is enabled by
  /// default (`android:allowBackup` defaults to `true`, and nothing in this
  /// manifest overrides it). So the app can "remember" a root uri it no
  /// longer has permission for, and every downstream SAF call on it — scan,
  /// playback, a download's paste-into-folder step — would throw a raw
  /// `SecurityException` ("...requires that you obtain access using
  /// ACTION_OPEN_DOCUMENT") instead of the friendly re-pick prompt this
  /// project already built for "the root is gone" (`LibraryRootUnavailableException`,
  /// wired into `inbox_screen.dart`). `StorageService.hasValidPermission`
  /// already existed for exactly this check — it just was never called
  /// anywhere. Reported live on a real device: reinstalling the APK kept
  /// the stats (Auto Backup restoring the db) while every SAF operation
  /// started throwing (the grant itself gone) — same root cause, both
  /// symptoms.
  Future<void> refreshLibraryRootUri() async {
    try {
      final uri = await _storageService.getLibraryRootUri();
      if (uri != null && !await _storageService.hasValidPermission(uri)) {
        await _storageService.clearLibraryRootUri();
        _libraryRootUri = null;
        notifyListeners();
        return;
      }
      _libraryRootUri = uri;
      notifyListeners();
    } catch (e) {
      print("Error refreshing library root uri: $e");
    }
  }

  /// Call right after picking a folder (or after clearing it because a scan
  /// found it gone) — updates every screen watching this provider
  /// immediately, no navigation required.
  void setLibraryRootUri(String? uri) {
    _libraryRootUri = uri;
    notifyListeners();
  }

  bool _isRestoringPlayback = false;

  /// Intenta restaurar el estado de reproducción guardado.
  ///
  /// Idempotente por estado real, no por un flag de "ya corrí una vez": si
  /// `audioHandler` ya tiene una fuente cargada no hace nada, así que es seguro
  /// llamarla más de una vez (p. ej. tras un timing distinto en un arranque lento)
  /// sin pisar una reproducción ya en curso.
  Future<void> restorePlaybackState(AudioPlayerHandler audioHandler) async {
    if (_isRestoringPlayback) return;
    if (audioHandler.hasLoadedSource) {
      print('El reproductor ya tiene una fuente cargada, no hace falta restaurar');
      return;
    }

    _isRestoringPlayback = true;
    try {
      // Estado sucio: queue/mediaItem ya describen una canción (sobrevivieron en
      // memoria a un proceso que Android mató sin pasar por onTaskRemoved) pero
      // el player no tiene nada cargado. Reconstruir directo desde lo que ya hay
      // en memoria — no hace falta tocar SharedPreferences/SQLite para esto.
      final staleQueue = audioHandler.queue.value;
      final staleMediaItem = audioHandler.mediaItem.value;
      if (staleQueue.isNotEmpty && staleMediaItem != null) {
        print('Estado sucio detectado (queue/mediaItem sin fuente cargada), reconstruyendo...');
        await audioHandler.restorePlaylist(
          staleQueue,
          staleMediaItem.id,
          audioHandler.player.position,
        );
        return;
      }

      print('Verificando estado de reproducción guardado...');
      final savedState = await PlaybackStateService.restoreState();
      if (savedState == null) {
        print('No hay estado de reproducción guardado');
        return;
      }

      print('Estado guardado encontrado, iniciando restauración...');

      final playlistId = savedState['playlistId'] as String?;
      final currentMediaId = savedState['currentMediaId'] as String;
      final position = savedState['position'] as Duration;
      final queueIds = savedState['queueIds'] as List<String>;
      final isPlaying = savedState['isPlaying'] as bool;
      final shuffleModeStr = savedState['shuffleModeStr'] as String?;
      final speed = savedState['speed'] as double?;

      if (playlistId == null || playlistId.isEmpty) {
        print('No hay playlistId guardado');
        await PlaybackStateService.clearState();
        return;
      }

      // Asegurar que la lista de playlists esté cargada de la base de datos
      await loadPlaylists();

      final playlistExists = _playlists.any((p) => p.id == playlistId);
      if (!playlistExists) {
        print('La playlist guardada ya no existe');
        await PlaybackStateService.clearState();
        return;
      }

      await loadSongsForPlaylist(playlistId, updateCurrent: true);

      // Reconstruir la queue CON filePath y artPath en extras
      final playlist = _playlists.firstWhere((p) => p.id == playlistId);
      final queueSongs = _currentPlaylistSongs.where((song) {
        return queueIds.contains(song.id);
      }).toList();

      if (queueSongs.isEmpty) {
        print('La queue guardada está vacía o inválida');
        await PlaybackStateService.clearState();
        return;
      }

      final mediaItems = queueSongs.map((song) => MediaItem(
        id: song.id,
        album: playlist.name,
        title: song.title,
        artist: song.artist,
        duration: Duration(seconds: song.duration),
        artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
        extras: {
          'filePath': song.playablePath,   // ← crítico para que just_audio cargue el audio (uri SAF o ruta legacy)
          'artPath': song.artPath,
          'playlist_id': playlistId,
        },
      )).toList();

      // Restaurar shuffle y repeat mode ANTES de cargar
      if (shuffleModeStr != null) {
        try {
          final shuffleMode = AudioServiceShuffleMode.values.firstWhere(
            (mode) => mode.name == shuffleModeStr,
            orElse: () => AudioServiceShuffleMode.none,
          );
          await audioHandler.setShuffleMode(shuffleMode);
        } catch (e) {
          print('Error restaurando shuffle mode: $e');
        }
      }

      // El modo bucle NO se restaura a propósito: es una preferencia de la
      // sesión de reproducción actual, no algo que deba sobrevivir a un
      // reinicio en frío de la app (ver CLAUDE.md / plan de corrección).

      if (speed != null && speed > 0) {
        try {
          await audioHandler.player.setSpeed(speed);
        } catch (e) {
          print('Error restaurando velocidad: $e');
        }
      }

      // Cargar playlist con o sin reproducción según el estado guardado
      if (isPlaying) {
        // Estaba reproduciendo: cargar y reproducir desde la posición
        await audioHandler.playPlaylist(mediaItems, currentMediaId);
        await Future.delayed(const Duration(milliseconds: 150));
        await audioHandler.seek(position);
      } else {
        // Estaba pausado: cargar fuente de audio SIN reproducir
        await audioHandler.restorePlaylist(mediaItems, currentMediaId, position);
      }

      print('Estado de reproducción restaurado exitosamente (${isPlaying ? "PLAYING" : "PAUSED"} en ${position.inSeconds}s)');
    } catch (e) {
      print('Error restaurando estado de reproducción: $e');
      await PlaybackStateService.clearState();
    } finally {
      _isRestoringPlayback = false;
    }
  }


  /// Fetches all playlists from the database and updates the local cache.
  Future<void> loadPlaylists() async {
    try {
      _playlists = await _dbHelper.getPlaylists();
      notifyListeners();
    } catch (e) {
      print("Error loading playlists: $e");
    }
  }

  /// Loads tracks inside a specific playlist, making them available to play or view.
  Future<void> loadSongsForPlaylist(String playlistId, {bool updateCurrent = true}) async {
    // `updateCurrent: false` significa "esta playlist no es la que se está
    // viendo ahora" (ver DownloadProvider.onDownloadComplete en main.dart):
    // antes esto sólo protegía _currentPlaylistId, pero _currentPlaylistSongs
    // se pisaba igual sin condición — así que terminar una descarga hacia
    // OTRA playlist reemplazaba en el acto las canciones que
    // PlaylistDetailScreen estaba mostrando, aunque el título de la pantalla
    // (que sí usa el playlistId correcto) no cambiara. Reportado por un
    // usuario como "la app salta a la playlist de destino" al terminar una
    // descarga estando dentro de otra playlist.
    if (!updateCurrent) return;
    try {
      _currentPlaylistId = playlistId;
      _currentPlaylistSongs = await _dbHelper.getSongsForPlaylist(playlistId);
      notifyListeners();
    } catch (e) {
      print("Error loading songs for playlist $playlistId: $e");
    }
  }

  /// Inserts a new playlist into SQFlite and updates the UI state.
  Future<void> createPlaylist(String name, {String kind = Playlist.kindLocal}) async {
    try {
      // Check for duplicate names (case-insensitive)
      final existing = _playlists.where((p) => p.name.toLowerCase() == name.toLowerCase()).toList();
      if (existing.isNotEmpty) {
        throw const FriendlyException('Ya existe una playlist con ese nombre.', 'E-PL-DUP');
      }

      final newPlaylist = Playlist(
        id: const Uuid().v4(),
        name: name,
        creationDate: DateTime.now(),
        kind: kind,
      );

      await _dbHelper.insertPlaylist(newPlaylist);
      await loadPlaylists();
    } catch (e) {
      print("Error creating playlist: $e");
      rethrow;
    }
  }

  /// Guarda [records] como referencias al final de la playlist online
  /// [playlistId], sin repetir las que ya tiene. Devuelve cuántas se añadieron.
  Future<int> saveRemoteTracksToPlaylist(String playlistId, List<RemoteTrackRecord> records) async {
    try {
      final added = await _dbHelper.addRemoteTracksToPlaylist(playlistId, records);
      await loadPlaylists();
      return added;
    } catch (e) {
      print('Error guardando referencias en la playlist online $playlistId: $e');
      rethrow;
    }
  }

  Future<void> createPlaylistWithId(String id, String name, {String kind = Playlist.kindLocal}) async {
    try {
      final newPlaylist = Playlist(
        id: id,
        name: name,
        creationDate: DateTime.now(),
        kind: kind,
      );
      await _dbHelper.insertPlaylist(newPlaylist);
      await loadPlaylists();
    } catch (e) {
      print("Error creating playlist: $e");
    }
  }

  /// Renames a playlist and triggers a reload.
  Future<void> renamePlaylist(String id, String newName) async {
    try {
      await _dbHelper.updatePlaylistName(id, newName);
      await loadPlaylists();
    } catch (e) {
      print("Error renaming playlist: $e");
    }
  }

  /// Updates the original URL of a playlist.
  Future<void> updatePlaylistUrl(String id, String url) async {
    try {
      await _dbHelper.updatePlaylistUrl(id, url);
      await loadPlaylists();
    } catch (e) {
      print("Error updating playlist URL: $e");
    }
  }

  /// Reorders playlists (top to bottom).
  Future<void> reorderPlaylists(List<Playlist> ordered) async {
    try {
      await _dbHelper.reorderPlaylists(ordered.map((p) => p.id).toList());
      await loadPlaylists();
    } catch (e) {
      print("Error reordering playlists: $e");
    }
  }

  /// Starts playback for a playlist from the first track.
  Future<void> playPlaylistFromStart(
    String playlistId,
    AudioPlayerHandler audioHandler,
  ) async {
    final songs = await _dbHelper.getSongsForPlaylist(playlistId);
    if (songs.isEmpty) return;
    final playlist = await _dbHelper.getPlaylistById(playlistId);
    final name = playlist?.name ?? '';
    await _playSongList(audioHandler, songs, songs.first, name, playlistId: playlistId);
    _currentPlaylistId = playlistId;
    _currentPlaylistSongs = songs;
    notifyListeners();
  }

  Future<void> playSongInPlaylist(
    String playlistId,
    Song target,
    AudioPlayerHandler audioHandler,
  ) async {
    final songs = await _dbHelper.getSongsForPlaylist(playlistId);
    if (songs.isEmpty) return;
    final playlist = await _dbHelper.getPlaylistById(playlistId);
    await _playSongList(audioHandler, songs, target, playlist?.name ?? '', playlistId: playlistId);
    _currentPlaylistId = playlistId;
    _currentPlaylistSongs = songs;
    notifyListeners();
  }

  /// Reproduce una playlist online por streaming (cola con la siguiente
  /// pista pre-resuelta). Con [shuffle] la cola es la misma lista en orden
  /// aleatorio, empezando por [startVideoId] si se indica. Devuelve
  /// [OnlinePlayResult.streamingUnsupported] o [OnlinePlayResult.empty] para
  /// que la pantalla muestre su mensaje (un fallo al arrancar se relanza); los fallos por pista los avisa el
  /// handler por `streamErrors`. Los modos de repetición de la cola de
  /// streaming siguen siendo los del handler (se desactivan al empezar).
  Future<OnlinePlayResult> playOnlinePlaylist(
    String playlistId,
    AudioPlayerHandler handler,
    StreamResolver resolver, {
    String? startVideoId,
    bool shuffle = false,
  }) async {
    try {
      final records = await _dbHelper.getRemoteTracksForPlaylist(playlistId);
      final plan = planOnlinePlayback(
        records,
        streamingSupported: streamingSupported,
        startVideoId: startVideoId,
        shuffle: shuffle,
      );
      if (plan.result != OnlinePlayResult.started) return plan.result;
      await handler.playStreamQueue(plan.tracks, plan.startId, resolver, savedVideoIds: plan.savedIds);
      return OnlinePlayResult.started;
    } catch (e) {
      print('Error reproduciendo la playlist online $playlistId: $e');
      rethrow;
    }
  }


  /// Plays a tapped result from local search, queuing the rest of the
  /// current result set so next/previous stay within it — not tied to any
  /// playlist, so it doesn't touch `_currentPlaylistId`/`_currentPlaylistSongs`
  /// and is passed no `playlistId` (the "playing from" header has nothing to
  /// link to for a search-originated queue).
  Future<void> playSearchResults(
    List<Song> results,
    Song target,
    AudioPlayerHandler audioHandler,
    String albumLabel,
  ) async {
    if (results.isEmpty) return;
    await _playSongList(audioHandler, results, target, albumLabel);
  }

  Future<void> _playSongList(
    AudioPlayerHandler audioHandler,
    List<Song> songs,
    Song target,
    String playlistName, {
    String? playlistId,
  }) async {
    final items = songs
        .map(
          (song) => MediaItem(
            id: song.id,
            album: playlistName,
            title: song.title,
            artist: song.artist,
            duration: Duration(seconds: song.duration),
            artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
            extras: {
              'filePath': song.playablePath,
              'artPath': song.artPath,
              'playlist_id': playlistId,
            },
          ),
        )
        .toList();
    await audioHandler.playPlaylist(items, target.id);
  }

  /// Deletes a playlist, cascades joint tables, cleans up active references, and deletes orphaned songs from device.
  Future<void> deletePlaylist(String id) async {
    try {
      // 0. El nombre hace falta para encontrar la carpeta después — una vez
      // borrada la fila de la playlist ya no está disponible.
      final playlist = await _dbHelper.getPlaylistById(id);

      // 1. Find all songs in this playlist BEFORE deleting anything
      final songs = await _dbHelper.getSongsForPlaylist(id);

      // 2. For each song, check if it belongs to OTHER playlists (not counting this one)
      final orphanedSongIds = <String>[];
      for (var song in songs) {
        final count = await _dbHelper.getPlaylistCountForSong(song.id);
        // count includes this playlist, so if count <= 1, the song is only in this playlist
        if (count <= 1) {
          orphanedSongIds.add(song.id);
        }
      }

      // 3. Delete the playlist from DB (CASCADE deletes playlist_songs rows)
      await _dbHelper.deletePlaylist(id);

      // 4. Delete orphaned songs (files + DB records)
      for (var songId in orphanedSongIds) {
        await _dbHelper.deleteSong(songId);
      }

      // 5. Con las canciones huérfanas ya borradas, su carpeta debería haber
      // quedado vacía — si es así, se borra también en vez de dejarla para
      // que el usuario la borre a mano.
      if (playlist != null && !playlist.isOnline && _libraryRootUri != null) {
        await _storageService.deletePlaylistFolderIfEmpty(_libraryRootUri!, playlist.name);
      }

      if (_currentPlaylistId == id) {
        _currentPlaylistId = null;
        _currentPlaylistSongs = [];
      }

      await loadPlaylists();
    } catch (e) {
      print("Error deleting playlist: $e");
    }
  }

  /// Dissociates a track from a playlist and deletes the file if it's not in any other playlist.
  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    try {
      await _dbHelper.removeSongFromPlaylist(playlistId, songId);
      
      // Check if song is in any other playlists
      final playlistCount = await _dbHelper.getPlaylistCountForSong(songId);
      if (playlistCount == 0) {
        // Song is not in any playlist anymore, delete the file
        await _dbHelper.deleteSong(songId);
      }
      
      if (_currentPlaylistId == playlistId) {
        await loadSongsForPlaylist(playlistId);
      }
    } catch (e) {
      print("Error removing song from playlist: $e");
    }
  }

  /// Refreshes the audio handler queue when the current playlist is modified
  Future<void> refreshAudioHandlerQueue(AudioPlayerHandler audioHandler) async {
    if (_currentPlaylistId == null || _currentPlaylistSongs.isEmpty) return;
    
    try {
      final playlist = await _dbHelper.getPlaylistById(_currentPlaylistId!);
      if (playlist == null) return;
      
      final songs = await _dbHelper.getSongsForPlaylist(_currentPlaylistId!);
      if (songs.isEmpty) return;
      
      // Get current media item to restore position
      final currentMediaItem = await audioHandler.mediaItem.first;
      final currentSongId = currentMediaItem?.id;
      
      // Rebuild the queue
      final items = songs
          .map(
            (song) => MediaItem(
              id: song.id,
              album: playlist.name,
              title: song.title,
              artist: song.artist,
              duration: Duration(seconds: song.duration),
              artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
              extras: {
                'filePath': song.playablePath,
                'artPath': song.artPath,
                'playlist_id': _currentPlaylistId,
              },
            ),
          )
          .toList();

      // Find the index of the current song
      final currentIndex = currentSongId != null 
          ? items.indexWhere((item) => item.id == currentSongId)
          : -1;
      
      // Reload the queue
      if (currentIndex >= 0) {
        await audioHandler.playPlaylist(items, currentSongId!);
      } else if (items.isNotEmpty) {
        // Current song not found, start from beginning
        await audioHandler.playPlaylist(items, items.first.id);
      }
    } catch (e) {
      print("Error refreshing audio handler queue: $e");
    }
  }

  /// Permanently deletes a track from SQLite and deletes local file and thumbnail.
  Future<void> permanentlyDeleteSong(String songId) async {
    try {
      await _dbHelper.deleteSong(songId);
      if (_currentPlaylistId != null) {
        await loadSongsForPlaylist(_currentPlaylistId!);
      }
    } catch (e) {
      print("Error permanently deleting song: $e");
    }
  }

  /// Deletes every song belonging to a playlist from the device.
  Future<void> deleteAllSongsFromPlaylist(String playlistId) async {
    try {
      await _dbHelper.deleteAllSongsForPlaylist(playlistId);
      if (_currentPlaylistId == playlistId) {
        _currentPlaylistSongs = [];
        notifyListeners();
      }
    } catch (e) {
      print("Error deleting all songs for playlist $playlistId: $e");
    }
  }

  /// Moves a song from one playlist to another (removed from source, appended
  /// to target). File on disk is never touched.
  Future<void> moveSongToPlaylist(
    String songId,
    String fromPlaylistId,
    String toPlaylistId,
  ) async {
    try {
      await _dbHelper.moveSongToPlaylist(songId, fromPlaylistId, toPlaylistId);
      if (_currentPlaylistId == fromPlaylistId) {
        await loadSongsForPlaylist(fromPlaylistId);
      }
    } catch (e) {
      print("Error moving song $songId from $fromPlaylistId to $toPlaylistId: $e");
    }
  }

  /// Copies a song into another playlist, appended at the end. Source
  /// playlist is left untouched.
  Future<void> copySongToPlaylist(String songId, String toPlaylistId) async {
    try {
      await _dbHelper.assignSongsToPlaylists([songId], [toPlaylistId]);
    } catch (e) {
      print("Error copying song $songId to $toPlaylistId: $e");
    }
  }

  /// Reorders songs within a playlist.
  Future<void> reorderSongsInPlaylist(String playlistId, List<String> songIds) async {
    try {
      await _dbHelper.reorderSongsInPlaylist(playlistId, songIds);
      if (_currentPlaylistId == playlistId) {
        await loadSongsForPlaylist(playlistId);
      }
    } catch (e) {
      print("Error reordering songs in playlist $playlistId: $e");
    }
  }

  /// Resets the active playlist reference and song list to clean up player state.
  void clearPlaybackState() {
    _currentPlaylistId = null;
    _currentPlaylistSongs = [];
    notifyListeners();
  }
}
