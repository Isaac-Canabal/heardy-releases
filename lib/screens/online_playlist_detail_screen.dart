import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/playlist.dart';
import '../models/remote_track_record.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/friendly_error.dart';
import '../services/online_playlist_logic.dart';
import '../services/remote_track_actions.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_cover.dart';

/// Reproduce una playlist online y traduce los resultados no exitosos en un
/// aviso. Todo lo que depende de `context` se captura antes del primer `await`.
Future<void> playOnlinePlaylistWithFeedback(
  BuildContext context,
  String playlistId, {
  String? startVideoId,
  bool shuffle = false,
}) async {
  final provider = context.read<MusicProvider>();
  final handler = context.read<AudioPlayerHandler>();
  final resolver = context.read<StreamResolver>();
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final shell = DesktopShellScope.maybeOf(context);

  void snack(String message) => messenger.showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );

  try {
    final result = await provider.playOnlinePlaylist(
      playlistId,
      handler,
      resolver,
      startVideoId: startVideoId,
      shuffle: shuffle,
    );
    switch (result) {
      case OnlinePlayResult.started:
        shell?.openNowPlaying();
      case OnlinePlayResult.empty:
        snack(l10n.onlinePlaylistNothingToPlay);
      case OnlinePlayResult.streamingUnsupported:
        snack(l10n.onlinePlaylistStreamingUnsupported);
    }
  } catch (e) {
    final report = localizedErrorReport(l10n, e);
    snack(
      e is DownloadSourceException ? report : l10n.searchListenFailed(report),
    );
  }
}

/// Detalle de una playlist online: referencias a YouTube que suenan por
/// streaming. No hay acciones de descarga: una online nunca se convierte.
class OnlinePlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const OnlinePlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<OnlinePlaylistDetailScreen> createState() =>
      _OnlinePlaylistDetailScreenState();
}

class _OnlinePlaylistDetailScreenState
    extends State<OnlinePlaylistDetailScreen> {
  List<RemoteTrackRecord> _tracks = const [];
  final Set<String> _hiddenIds = {};
  bool _loaded = false;
  bool _isReordering = false;
  StreamSubscription<StreamPlaybackError>? _errorSub;

  @override
  void initState() {
    super.initState();
    _load();
    _errorSub = context.read<AudioPlayerHandler>().streamErrors.listen(
      _onStreamError,
    );
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  void _onStreamError(StreamPlaybackError error) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error.skipped
              ? l10n.exploreStreamTrackSkipped
              : l10n.searchStreamPlaybackFailed,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _load() async {
    final tracks = await DatabaseHelper.instance.getRemoteTracksForPlaylist(
      widget.playlistId,
    );
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _loaded = true;
    });
  }

  List<RemoteTrackRecord> get _visibleTracks =>
      _tracks.where((t) => !_hiddenIds.contains(t.videoId)).toList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final musicProvider = context.watch<MusicProvider>();
    final matches = musicProvider.playlists.where(
      (p) => p.id == widget.playlistId,
    );
    if (matches.isEmpty) return _GoneScaffold(l10n: l10n);
    final playlist = matches.first;
    final visible = _visibleTracks;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (visible.length > 1)
            IconButton(
              icon: Icon(_isReordering ? Icons.done : Icons.edit_outlined),
              tooltip: _isReordering
                  ? l10n.playlistFinishEditing
                  : l10n.playlistModifyOrder,
              onPressed: () => setState(() => _isReordering = !_isReordering),
            ),
          PopupMenuButton<String>(
            color: AppTheme.surface,
            onSelected: (value) {
              if (value == 'rename') _rename(playlist);
              if (value == 'delete') _delete(playlist);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'rename',
                child: Text(
                  l10n.commonRename,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  l10n.commonDelete,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height:
                      MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                ),
                if (visible.isNotEmpty) _buildActions(l10n),
                Expanded(
                  child: !_loaded
                      ? const SizedBox.shrink()
                      : visible.isEmpty
                      ? _buildEmptyState(l10n)
                      : _isReordering
                      ? _buildReorderList(visible)
                      : _buildList(visible, playlist, l10n),
                ),
              ],
            ),
            const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 4, kScreenGutter, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              key: const Key('online_playlist_play'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () =>
                  playOnlinePlaylistWithFeedback(context, widget.playlistId),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.onlinePlaylistPlayAction),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('online_playlist_shuffle'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => playOnlinePlaylistWithFeedback(
                context,
                widget.playlistId,
                shuffle: true,
              ),
              icon: const Icon(Icons.shuffle_rounded),
              label: Text(l10n.onlinePlaylistShuffleAction),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    List<RemoteTrackRecord> visible,
    Playlist playlist,
    AppLocalizations l10n,
  ) {
    final handler = context.read<AudioPlayerHandler>();
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapshot) {
        final activeId = snapshot.data?.id;
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 90),
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final track = visible[index];
            return Dismissible(
              key: Key('online_track_${track.videoId}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Colors.redAccent[700],
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                margin: const EdgeInsets.symmetric(
                  horizontal: kScreenGutter,
                  vertical: 5,
                ),
                child: const Icon(
                  Icons.delete_sweep,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              onDismissed: (_) => _removeWithUndo(track, l10n),
              child: _TrackRow(
                track: track,
                isActive: activeId == track.videoId,
                onTap: () => playOnlinePlaylistWithFeedback(
                  context,
                  widget.playlistId,
                  startVideoId: track.videoId,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildReorderList(List<RemoteTrackRecord> visible) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 90),
      itemCount: visible.length,
      onReorder: (oldIndex, newIndex) async {
        final ids = reorderedIds(
          [for (final t in visible) t.videoId],
          oldIndex,
          newIndex,
        );
        final byId = {for (final t in _tracks) t.videoId: t};
        setState(() => _tracks = [for (final id in ids) byId[id]!]);
        await DatabaseHelper.instance.reorderRemoteTracks(
          widget.playlistId,
          ids,
        );
      },
      itemBuilder: (context, index) {
        final track = visible[index];
        return Container(
          key: Key('online_reorder_${track.videoId}'),
          color: Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: _TrackRow(track: track, isActive: false, onTap: () {}),
              ),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Icon(Icons.drag_handle, color: Colors.white54),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 64,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.onlinePlaylistEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.onlinePlaylistEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _removeWithUndo(RemoteTrackRecord track, AppLocalizations l10n) {
    final messenger = ScaffoldMessenger.of(context);
    final playlistId = widget.playlistId;
    setState(() => _hiddenIds.add(track.videoId));
    var undone = false;
    messenger.clearSnackBars();
    messenger
        .showSnackBar(
          SnackBar(
            content: Text(l10n.playlistDeletedSnack(track.title)),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: l10n.playlistUndo,
              textColor: Colors.amberAccent,
              onPressed: () {
                undone = true;
                if (mounted) setState(() => _hiddenIds.remove(track.videoId));
              },
            ),
          ),
        )
        .closed
        .then((_) async {
          if (!undone) {
            await DatabaseHelper.instance.removeRemoteTrackFromPlaylist(
              playlistId,
              track.videoId,
            );
            if (mounted) await _load();
          }
          _hiddenIds.remove(track.videoId);
        });
  }

  Future<void> _rename(Playlist playlist) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<MusicProvider>();
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          l10n.commonRename,
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty)
      await provider.renamePlaylist(playlist.id, name);
  }

  Future<void> _delete(Playlist playlist) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<MusicProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          l10n.homeDeleteListTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          l10n.onlinePlaylistDeleteBody(playlist.name),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.commonDelete,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await provider.deletePlaylist(playlist.id);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.homeDeletedSnack(playlist.name))),
    );
    if (navigator.canPop()) navigator.pop();
  }
}

class _TrackRow extends StatelessWidget {
  final RemoteTrackRecord track;
  final bool isActive;
  final VoidCallback onTap;

  const _TrackRow({
    required this.track,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final seconds = track.durationSeconds ?? 0;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: kScreenGutter,
        vertical: 5,
      ),
      decoration: AppTheme.glassCard(highlighted: isActive),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                PlaylistCover(
                  url: track.thumbnailUrl,
                  size: 50,
                  radius: 10,
                  placeholderIcon: Icons.music_note_rounded,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isActive
                              ? AppTheme.primaryLight
                              : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      if ((track.artist ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          track.artist!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (seconds > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 4),
                    child: Text(
                      formatTrackDuration(seconds),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
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

class _GoneScaffold extends StatelessWidget {
  final AppLocalizations l10n;

  const _GoneScaffold({required this.l10n});

  @override
  Widget build(BuildContext context) {
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
