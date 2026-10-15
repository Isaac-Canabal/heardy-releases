import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../providers/download_provider.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/explore_logic.dart';
import '../services/friendly_error.dart';
import '../services/import_destination_logic.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_target_sheet.dart';
import '../widgets/remote_track_actions_mixin.dart';
import '../widgets/remote_track_tile.dart';
import '../widgets/skeleton_box.dart';

/// Playlist o álbum de YouTube Music. El [loader] se inyecta para que las dos
/// colecciones compartan pantalla.
class ExploreCollectionScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final String thumbnailUrl;
  final Future<ExploreCollection> Function() loader;

  /// Las ya descargadas, para marcarlas y saltarlas en "Descargar todo".
  /// Inyectable para los tests; por defecto, `songs.sourceUrl` de la base.
  final Future<Set<String>> Function()? localSourceUrls;

  const ExploreCollectionScreen({
    super.key,
    required this.title,
    required this.loader,
    this.subtitle = '',
    this.thumbnailUrl = '',
    this.localSourceUrls,
  });

  @override
  State<ExploreCollectionScreen> createState() => _ExploreCollectionScreenState();
}

class _ExploreCollectionScreenState extends State<ExploreCollectionScreen>
    with RemoteTrackActionsMixin<ExploreCollectionScreen> {
  ExploreCollection? _collection;
  Object? _error;
  bool _loading = true;
  bool _downloadingAll = false;
  Set<String> _localIds = const {};

  @override
  void initState() {
    super.initState();
    initRemoteTrackActions();
    _load();
  }

  @override
  void dispose() {
    disposeRemoteTrackActions();
    super.dispose();
  }

  @override
  Iterable<RemoteTrack> get streamErrorLookupTracks => _collection?.tracks ?? const [];

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final urls = widget.localSourceUrls ?? DatabaseHelper.instance.getLocalSourceUrls;
      final results = await Future.wait<Object>([widget.loader(), urls()]);
      if (!mounted) return;
      _collection = results[0] as ExploreCollection;
      _localIds = localVideoIds(results[1] as Set<String>);
    } catch (e) {
      if (!mounted) return;
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _downloadAll() async {
    final collection = _collection;
    if (collection == null || _downloadingAll) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _downloadingAll = true);
    try {
      final destination = await pickPlaylistDestination(
        context,
        suggestedName: collection.title.isNotEmpty ? collection.title : widget.title,
      );
      if (destination == null || !mounted) return;

      if (destinationActionForKind(destination.kind) == DestinationAction.saveReferences) {
        await saveRemoteTracksToOnlinePlaylist(context, destination, collection.tracks);
        return;
      }

      final pending = tracksToDownload(collection.tracks, _localIds);
      if (pending.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(l10n.exploreDownloadAllNothing),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      final provider = context.read<DownloadProvider>();
      var added = 0;
      for (final track in pending) {
        // Listado aplanado: el worker lo re-resuelve antes de bajar (DD6).
        if (await provider.enqueueTrack(track, playlistId: destination.id, metadataComplete: false)) added++;
      }
      provider.processQueue();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(l10n.exploreDownloadAllSummary(added, collection.tracks.length - added)),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _downloadingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final collection = _collection;
    final title = (collection?.title.isNotEmpty ?? false) ? collection!.title : widget.title;
    final cover = (collection?.thumbnailUrl.isNotEmpty ?? false) ? collection!.thumbnailUrl : widget.thumbnailUrl;

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      extendBodyBehindAppBar: false,
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _buildHeader(l10n, title, cover, collection)),
                ..._buildBody(l10n, collection),
              ],
            ),
            const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n, String title, String cover, ExploreCollection? collection) {
    final canDownloadAll = collection != null && collection.tracks.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 180,
              height: 180,
              child: cover.isEmpty
                  ? _coverPlaceholder(title)
                  : Image.network(
                      cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _coverPlaceholder(title),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
          ),
          if (widget.subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 14),
            ),
          ],
          if (collection != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.exploreCollectionTracks(collection.tracks.length),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
            ),
          ],
          if (canDownloadAll) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (streamingSupported)
                  FilledButton.icon(
                    key: const Key('explore_play_all'),
                    style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                    onPressed: streamingTrackId != null
                        ? null
                        : () => listenRemoteQueue(collection.tracks, collection.tracks.first),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(l10n.explorePlayAll),
                  ),
                FilledButton.icon(
                  key: const Key('explore_download_all'),
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  onPressed: _downloadingAll ? null : _downloadAll,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(l10n.exploreDownloadAll),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverPlaceholder(String title) => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(title)),
        child: const Icon(Icons.queue_music_rounded, color: Colors.white70, size: 56),
      );

  List<Widget> _buildBody(AppLocalizations l10n, ExploreCollection? collection) {
    if (_loading && collection == null) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, __) => const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: SkeletonBox(height: 70, radius: 18),
              ),
              childCount: 6,
            ),
          ),
        ),
      ];
    }
    if (collection == null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Text(
                  _error == null ? '' : localizedErrorReport(l10n, _error!),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('explore_collection_retry'),
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  onPressed: _load,
                  child: Text(l10n.exploreShelfRetry),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (collection.tracks.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.exploreCollectionEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
          ),
        ),
      ];
    }
    final tracks = collection.tracks;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => RemoteTrackTile(
              track: tracks[i],
              downloaded: _localIds.contains(tracks[i].id),
              onDownload: () => downloadRemoteTrack(tracks[i]),
              onListen: null,
              onPlay: () => playRemoteTrack(tracks[i], queue: tracks),
              isLoadingStream: streamingTrackId == tracks[i].id,
            ),
            childCount: tracks.length,
          ),
        ),
      ),
    ];
  }
}
