import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/download_source.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_target_sheet.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/friendly_error.dart';

/// Entradas de [remote] cuyo `sourceUrl` todavía no está entre las canciones
/// ya presentes en la playlist ([existingSongs]) — lo que decide qué se
/// vuelve a encolar al "Actualizar desde YouTube" sin descargar dos veces lo
/// mismo. Aparte como función pura para poder probarla sin necesitar un
/// `AudioPlayerHandler` real (que arrastra `just_audio`/canales de
/// plataforma, y para el que este proyecto no tiene ningún fake de test).
@visibleForTesting
List<RemoteTrack> missingPlaylistEntries(RemotePlaylist remote, List<Song> existingSongs) {
  final existingUrls = existingSongs.map((s) => s.sourceUrl).whereType<String>().toSet();
  return remote.entries.where((e) => !existingUrls.contains(e.sourceUrl)).toList();
}

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _renameController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'manual'; // manual, artist, title, date
  bool _isReordering = false;
  bool _isUpdatingFromYoutube = false;
  final List<String> _temporarilyRemovedSongIds = [];

  @override
  void initState() {
    super.initState();
    // Load playlist tracks when screen mounts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<MusicProvider>(context, listen: false)
          .loadSongsForPlaylist(widget.playlistId);
    });
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _renameController.dispose();
    super.dispose();
  }

  /// Expande de nuevo la playlist de origen y encola sólo lo que falta,
  /// comparando por `song.sourceUrl` — nunca vuelve a descargar lo que ya
  /// está. Sólo aparece para playlists con `originalUrl` (creadas desde una
  /// URL de YouTube en ImportScreen).
  Future<void> _updateFromYoutube(Playlist playlist) async {
    final originalUrl = playlist.originalUrl;
    if (originalUrl == null || originalUrl.isEmpty || _isUpdatingFromYoutube) return;

    setState(() => _isUpdatingFromYoutube = true);
    try {
      final musicProvider = context.read<MusicProvider>();
      final downloadProvider = context.read<DownloadProvider>();
      final source = context.read<DownloadSource>();

      final remote = await source.resolvePlaylist(originalUrl);
      final missing = missingPlaylistEntries(remote, musicProvider.currentPlaylistSongs);

      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (missing.isEmpty) {
        _showSnack(l10n.playlistNoNewSongs);
        return;
      }

      final added = await downloadProvider.enqueuePlaylist(
        RemotePlaylist(id: remote.id, name: remote.name, sourceUrl: remote.sourceUrl, entries: missing),
        playlistId: playlist.id,
      );
      downloadProvider.processQueue();
      if (!mounted) return;
      _showSnack(l10n.playlistSongsQueuedSnack(added));
    } on DownloadSourceException catch (e) {
      if (!mounted) return;
      _showSnack(localizedErrorReport(AppLocalizations.of(context)!, e), isError: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context)!.playlistUpdateError(localizedErrorReport(AppLocalizations.of(context)!, e)), isError: true);
    } finally {
      if (mounted) setState(() => _isUpdatingFromYoutube = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.withValues(alpha: 0.8) : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final musicProvider = Provider.of<MusicProvider>(context);
    final audioHandler = Provider.of<AudioPlayerHandler>(context);
    final l10n = AppLocalizations.of(context)!;

    // Fetch the active playlist metadata.
    //
    // Esto era un `firstWhere` cuyo `orElse` —el camino para "no encontrada"—
    // repetía la MISMA búsqueda sin `orElse`, así que lanzaba StateError justo en
    // el caso que pretendía cubrir; y su otra rama, `playlists.first`, lanzaba
    // igual si no quedaba ninguna playlist. Borrar la playlist que estabas viendo
    // reventaba `build()` con pantalla roja.
    final matches =
        musicProvider.playlists.where((p) => p.id == widget.playlistId);
    if (matches.isEmpty) {
      return _PlaylistGoneScaffold();
    }
    final playlist = matches.first;

    // Filter and sort tracks based on search bar and sort option
    final allSongs = musicProvider.currentPlaylistSongs;
    var filteredSongs = allSongs.where((song) {
      if (_temporarilyRemovedSongIds.contains(song.id)) return false;
      final titleMatch = song.title.toLowerCase().contains(_searchQuery);
      final artistMatch = song.artist.toLowerCase().contains(_searchQuery);
      return titleMatch || artistMatch;
    }).toList();

    // Apply sorting
    if (_sortBy == 'artist') {
      filteredSongs.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
    } else if (_sortBy == 'title') {
      filteredSongs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sortBy == 'duration') {
      filteredSongs.sort((a, b) => a.duration.compareTo(b.duration));
    }
    // manual = keep original order (import order)

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (playlist.originalUrl != null && playlist.originalUrl!.isNotEmpty)
            IconButton(
              icon: _isUpdatingFromYoutube
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              tooltip: l10n.playlistUpdateFromYoutube,
              onPressed: _isUpdatingFromYoutube ? null : () => _updateFromYoutube(playlist),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            tooltip: l10n.playlistSortTooltip,
            onSelected: (value) {
              setState(() {
                _sortBy = value;
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'manual',
                child: Row(
                  children: [
                    const Icon(Icons.list_rounded),
                    const SizedBox(width: 12),
                    Text(l10n.playlistSortImportOrder),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'artist',
                child: Row(
                  children: [
                    const Icon(Icons.person_rounded),
                    const SizedBox(width: 12),
                    Text(l10n.playlistSortArtist),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'title',
                child: Row(
                  children: [
                    const Icon(Icons.music_note_rounded),
                    const SizedBox(width: 12),
                    Text(l10n.playlistSortTitle),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'duration',
                child: Row(
                  children: [
                    const Icon(Icons.timer_rounded),
                    const SizedBox(width: 12),
                    Text(l10n.playlistSortDuration),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: Icon(_isReordering ? Icons.done : Icons.edit_outlined),
            tooltip: _isReordering ? l10n.playlistFinishEditing : l10n.playlistModifyOrder,
            onPressed: () {
              setState(() {
                _isReordering = !_isReordering;
                if (_isReordering) {
                  _sortBy = 'manual'; // Force manual sort for reordering
                }
              });
            },
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            Column(
              children: [
                // Sleek premium search field
                if (allSongs.isNotEmpty) _buildSearchField(),
                // Playlist songs list
                Expanded(
              child: allSongs.isEmpty
                  ? _buildEmptyState()
                  : filteredSongs.isEmpty
                      ? _buildNoResultsState()
                      : _isReordering
                          ? ReorderableListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 90),
                              itemCount: filteredSongs.length,
                              onReorder: (oldIndex, newIndex) async {
                                if (oldIndex < newIndex) {
                                  newIndex -= 1;
                                }
                                final song = filteredSongs.removeAt(oldIndex);
                                filteredSongs.insert(newIndex, song);
                                final List<String> songIds = filteredSongs.map((s) => s.id).toList();
                                await musicProvider.reorderSongsInPlaylist(widget.playlistId, songIds);
                              },
                              itemBuilder: (context, index) {
                                final song = filteredSongs[index];
                                return Container(
                                  key: Key(song.id),
                                  color: Colors.transparent, // Need color for ReorderableListView dragging
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: SongTile(
                                          song: song,
                                          isPlaying: false,
                                          index: index,
                                          onTap: () {},
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                                        child: Icon(Icons.drag_handle, color: Colors.white54),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 90),
                              itemCount: filteredSongs.length,
                              itemBuilder: (context, index) {
                                final song = filteredSongs[index];

                                return StreamBuilder<MediaItem?>(
                                  stream: audioHandler.mediaItem,
                                  builder: (context, mediaSnapshot) {
                                    final activeItem = mediaSnapshot.data;
                                    final isPlaying = activeItem?.id == song.id;

                                    return Dismissible(
                                      key: Key(song.id),
                                      direction: DismissDirection.horizontal,
                                      background: Container(
                                        color: Colors.blueAccent[700],
                                        alignment: Alignment.centerLeft,
                                        padding: const EdgeInsets.only(left: 24),
                                        margin: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 6),
                                        child: const Icon(
                                          Icons.queue_music_rounded,
                                          color: Colors.white,
                                          size: 28,
                                        ),
                                      ),
                                      secondaryBackground: Container(
                                        color: Colors.redAccent[700],
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 24),
                                        margin: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 6),
                                        child: const Icon(
                                          Icons.delete_sweep,
                                          color: Colors.white,
                                          size: 28,
                                        ),
                                      ),
                                      confirmDismiss: (direction) async {
                                        if (direction == DismissDirection.startToEnd) {
                                          final item = MediaItem(
                                            id: song.id,
                                            album: playlist.name,
                                            title: song.title,
                                            artist: song.artist,
                                            duration: Duration(seconds: song.duration),
                                            artUri: song.artPath.isNotEmpty
                                                ? Uri.file(song.artPath)
                                                : null,
                                            extras: {
                                              'filePath': song.playablePath,
                                              'artPath': song.artPath,
                                              'playlist_id': widget.playlistId,
                                            },
                                          );
                                          await audioHandler.insertPlayNext(item);
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).clearSnackBars();
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                    l10n.playlistPlayNextSnack(song.title)),
                                                duration: const Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                          return false;
                                        }
                                        return true;
                                      },
                                      onDismissed: (direction) async {
                                        final songId = song.id;
                                        final songTitle = song.title;

                                        setState(() {
                                          _temporarilyRemovedSongIds.add(songId);
                                        });

                                        bool undoClicked = false;
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).clearSnackBars();
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(l10n.playlistDeletedSnack(songTitle)),
                                              duration: const Duration(seconds: 4),
                                              action: SnackBarAction(
                                                label: l10n.playlistUndo,
                                                textColor: Colors.amberAccent,
                                                onPressed: () {
                                                  undoClicked = true;
                                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                                  if (mounted) {
                                                    setState(() {
                                                      _temporarilyRemovedSongIds.remove(songId);
                                                    });
                                                  }
                                                },
                                              ),
                                            ),
                                          ).closed.then((reason) async {
                                            if (!undoClicked) {
                                              await musicProvider.removeSongFromPlaylist(
                                                  widget.playlistId, songId);
                                              if (musicProvider.currentPlaylistId == widget.playlistId) {
                                                await musicProvider.refreshAudioHandlerQueue(audioHandler);
                                              }
                                            }
                                            _temporarilyRemovedSongIds.remove(songId);
                                          });
                                        }
                                      },
                                      child: SongTile(
                                        song: song,
                                        isPlaying: isPlaying,
                                        index: index,
                                        onTap: () => _playSong(
                                            audioHandler, filteredSongs, song, playlist.name),
                                        onLongPress: () => _showSongActionsSheet(
                                            context, audioHandler, musicProvider, song),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MiniPlayer(),
            ),
          ],
        ),
      ),
    );
  }



  Widget _buildSearchField() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 100, 16, 8),
      decoration: AppTheme.glassCard(),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: AppLocalizations.of(context)!.playlistSearchHint,
          hintStyle: TextStyle(color: Colors.grey[600], fontSize: 14),
          prefixIcon: Icon(Icons.search, color: AppTheme.primaryLight),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white70),
                  onPressed: () => _searchController.clear(),
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_off_outlined,
              size: 70,
              color: Colors.grey[800],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.playlistEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.playlistEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_outlined,
              size: 60,
              color: Colors.grey[800],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.playlistNoResultsTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.playlistNoResultsBody(_searchQuery),
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Map entire playlist items to MediaItem instances, load the queue, and play target song.
  Future<void> _playSong(AudioPlayerHandler audioHandler, List<Song> playlistSongs, Song targetSong, String playlistName) async {
    DesktopShellScope.maybeOf(context)?.openNowPlaying();
    final List<MediaItem> mediaItems = playlistSongs.map((song) {
      return MediaItem(
        id: song.id,
        album: playlistName,
        title: song.title,
        artist: song.artist,
        duration: Duration(seconds: song.duration),
        artUri: song.artPath.isNotEmpty ? Uri.file(song.artPath) : null,
        extras: {
          'filePath': song.playablePath,
          'artPath': song.artPath,
          'playlist_id': widget.playlistId,
        },
      );
    }).toList();

    await audioHandler.playPlaylist(mediaItems, targetSong.id);
  }

  Future<void> _showSongActionsSheet(
    BuildContext context,
    AudioPlayerHandler audioHandler,
    MusicProvider musicProvider,
    Song song,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline, color: Colors.white70),
              title: Text(l10n.playlistMoveToOther, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(sheetContext, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.content_copy_rounded, color: Colors.white70),
              title: Text(l10n.playlistCopyToOther, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(sheetContext, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.swap_vert_rounded, color: Colors.white70),
              title: Text(l10n.playlistChangePosition, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(sheetContext, 'position'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;

    switch (action) {
      case 'move':
        final choice = await pickTargetPlaylist(context, excludePlaylistId: widget.playlistId);
        if (choice == null || !mounted) return;
        final targetId = await resolveTargetPlaylistId(context, choice);
        if (targetId == null || !mounted) return;
        await musicProvider.moveSongToPlaylist(song.id, widget.playlistId, targetId);
        if (musicProvider.currentPlaylistId == widget.playlistId) {
          await musicProvider.refreshAudioHandlerQueue(audioHandler);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.playlistMovedSnack(song.title)),
            ),
          );
        }
        break;
      case 'copy':
        final choice = await pickTargetPlaylist(context, excludePlaylistId: widget.playlistId);
        if (choice == null || !mounted) return;
        final targetId = await resolveTargetPlaylistId(context, choice);
        if (targetId == null || !mounted) return;
        await musicProvider.copySongToPlaylist(song.id, targetId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.playlistCopiedSnack(song.title)),
            ),
          );
        }
        break;
      case 'position':
        final total = musicProvider.currentPlaylistSongs.length;
        if (total == 0) return;
        final position = await _promptPosition(context, total);
        if (position == null || !mounted) return;
        final orderedIds = musicProvider.currentPlaylistSongs.map((s) => s.id).toList();
        final currentIndex = orderedIds.indexOf(song.id);
        if (currentIndex == -1) return;
        orderedIds.removeAt(currentIndex);
        orderedIds.insert((position - 1).clamp(0, orderedIds.length), song.id);
        setState(() {
          _sortBy = 'manual';
        });
        await musicProvider.reorderSongsInPlaylist(widget.playlistId, orderedIds);
        break;
    }
  }

  Future<int?> _promptPosition(BuildContext context, int total) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    return showDialog<int>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: Text(l10n.playlistNewPositionTitle, style: const TextStyle(color: Colors.white)),
              content: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: l10n.playlistPositionHint(total),
                  hintStyle: const TextStyle(color: Colors.white38),
                  errorText: errorText,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());
                    if (value == null || value < 1 || value > total) {
                      setState(() {
                        errorText = l10n.playlistPositionError(total);
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(value);
                  },
                  child: Text(l10n.commonAccept),
                ),
              ],
            );
          },
        );
      },
    );
  }

}

/// Pantalla mínima para cuando la playlist que se estaba viendo ya no existe
/// (borrada desde otra pantalla mientras esta seguía en la pila de navegación).
///
/// Antes esto no existía y el caso terminaba en StateError dentro de `build()`.
/// Se resuelve con una salida explícita en vez de intentar adivinar otra
/// playlist, que es lo que hacía el `orElse` roto: mostrar contenido de una
/// playlist distinta a la que el usuario abrió sería peor que decirle la verdad.
class _PlaylistGoneScaffold extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.playlistGoneTitle)),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.playlist_remove_rounded,
                  size: 56,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.playlistGoneBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonBack),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
