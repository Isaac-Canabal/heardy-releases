import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../services/download_source.dart';
import '../services/friendly_error.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/explore_shelves.dart';
import '../widgets/mini_player.dart';
import '../widgets/remote_track_actions_mixin.dart';
import '../widgets/remote_track_tile.dart';
import '../widgets/skeleton_box.dart';
import 'explore_collection_screen.dart';

/// Perfil de un artista de YouTube Music. El [loader] se inyecta (como en
/// [ExploreCollectionScreen]) para no atar la pantalla al servidor.
class ExploreArtistScreen extends StatefulWidget {
  final String name;
  final String thumbnailUrl;
  final Future<ExploreArtist> Function() loader;

  const ExploreArtistScreen({super.key, required this.name, required this.loader, this.thumbnailUrl = ''});

  static Route<void> route({
    required String name,
    required Future<ExploreArtist> Function() loader,
    String thumbnailUrl = '',
  }) =>
      MaterialPageRoute<void>(
        builder: (_) => ExploreArtistScreen(name: name, thumbnailUrl: thumbnailUrl, loader: loader),
      );

  @override
  State<ExploreArtistScreen> createState() => _ExploreArtistScreenState();
}

class _ExploreArtistScreenState extends State<ExploreArtistScreen>
    with RemoteTrackActionsMixin<ExploreArtistScreen> {
  ExploreArtist? _artist;
  Object? _error;
  bool _loading = true;
  bool _descriptionExpanded = false;

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
  Iterable<RemoteTrack> get streamErrorLookupTracks sync* {
    final a = _artist;
    if (a == null) return;
    yield* a.topSongs;
    yield* a.videos;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final artist = await widget.loader();
      if (!mounted) return;
      _artist = artist;
    } catch (e) {
      if (!mounted) return;
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAlbum(ExploreAlbum a) {
    final source = context.read<DownloadSource>();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExploreCollectionScreen(
        title: a.title,
        subtitle: a.artist,
        thumbnailUrl: a.thumbnailUrl,
        loader: () => source.exploreAlbum(a.browseId),
      ),
    ));
  }

  void _openRelated(ExploreRelatedArtist r) {
    final source = context.read<DownloadSource>();
    Navigator.of(context).push(ExploreArtistScreen.route(
      name: r.name,
      thumbnailUrl: r.thumbnailUrl,
      loader: () => source.exploreArtist(r.channelId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artist = _artist;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _buildHeader(l10n, artist)),
                ..._buildBody(l10n, artist),
              ],
            ),
            const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n, ExploreArtist? artist) {
    final name = artist?.name ?? widget.name;
    final cover = (artist?.thumbnailUrl.isNotEmpty ?? false) ? artist!.thumbnailUrl : widget.thumbnailUrl;
    final subscribers = artist?.subscribers ?? '';
    final description = artist?.description ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        children: [
          ClipOval(
            child: SizedBox(
              width: 160,
              height: 160,
              child: cover.isEmpty
                  ? _coverPlaceholder(name)
                  : Image.network(
                      cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _coverPlaceholder(name),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
          ),
          if (subscribers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              l10n.exploreArtistSubscribers(subscribers),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 14),
            ),
          ],
          if (description.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildDescription(l10n, description),
          ],
        ],
      ),
    );
  }

  Widget _buildDescription(AppLocalizations l10n, String description) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.exploreArtistAbout,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            key: const Key('explore_artist_description'),
            maxLines: _descriptionExpanded ? null : 3,
            overflow: _descriptionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 13, height: 1.35),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('explore_artist_toggle_description'),
              onPressed: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
              child: Text(_descriptionExpanded ? l10n.exploreArtistReadLess : l10n.exploreArtistReadMore),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(String name) => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(name)),
        child: const Icon(Icons.person_rounded, color: Colors.white70, size: 64),
      );

  List<Widget> _buildBody(AppLocalizations l10n, ExploreArtist? artist) {
    if (_loading && artist == null) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, __) => const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: SkeletonBox(height: 70, radius: 18),
              ),
              childCount: 5,
            ),
          ),
        ),
      ];
    }
    if (artist == null) {
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
                  key: const Key('explore_artist_retry'),
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
    final empty = artist.topSongs.isEmpty &&
        artist.albums.isEmpty &&
        artist.singles.isEmpty &&
        artist.videos.isEmpty &&
        artist.related.isEmpty;
    if (empty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.exploreArtistEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
          ),
        ),
      ];
    }
    return [
      if (artist.topSongs.isNotEmpty)
        ..._trackSection(l10n.exploreArtistSongs, artist.topSongs, playQueue: true, playAllLabel: l10n.explorePlayAll),
      if (artist.albums.isNotEmpty)
        _boxSection(l10n.exploreArtistAlbums, ExploreAlbumsRow(albums: artist.albums, onTap: _openAlbum)),
      if (artist.singles.isNotEmpty)
        _boxSection(l10n.exploreArtistSingles, ExploreAlbumsRow(albums: artist.singles, onTap: _openAlbum)),
      if (artist.videos.isNotEmpty) ..._trackSection(l10n.exploreArtistVideos, artist.videos),
      if (artist.related.isNotEmpty)
        _boxSection(
          l10n.exploreArtistRelated,
          ExploreRelatedArtistsRow(artists: artist.related, onTap: _openRelated),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 90)),
    ];
  }

  Widget _boxSection(String title, Widget body) => SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [ExploreShelfHeader(title), body],
        ),
      );

  /// Con [playQueue] las pistas suenan como cola continua (Escuchar = desde
  /// aquí) y se ofrece un botón de reproducir todo; si no, cada una suelta.
  List<Widget> _trackSection(
    String title,
    List<RemoteTrack> tracks, {
    bool playQueue = false,
    String playAllLabel = '',
  }) =>
      [
        SliverToBoxAdapter(child: ExploreShelfHeader(title)),
        if (playQueue && streamingSupported)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('explore_artist_play_all'),
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  onPressed: streamingTrackId != null ? null : () => listenRemoteQueue(tracks, tracks.first),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(playAllLabel),
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => RemoteTrackTile(
                track: tracks[i],
                onDownload: () => downloadRemoteTrack(tracks[i]),
                onListen: null,
                onPlay: () => playRemoteTrack(tracks[i], queue: playQueue ? tracks : null),
                isLoadingStream: streamingTrackId == tracks[i].id,
              ),
              childCount: tracks.length,
            ),
          ),
        ),
      ];
}
