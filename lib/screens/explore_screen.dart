import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../models/song.dart';
import '../providers/auth_provider.dart';
import '../providers/explore_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/download_source.dart';
import '../services/explore_logic.dart';
import '../services/remote_track_actions.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/explore_shelves.dart';
import '../widgets/remote_track_actions_mixin.dart';
import '../widgets/remote_track_tile.dart';
import '../widgets/skeleton_box.dart';
import 'auth/login_screen.dart';
import 'explore_artist_screen.dart';
import 'explore_collection_screen.dart';
import 'explore_mood_screen.dart';
import 'search_screen.dart';

/// Pestaña Explorar: estanterías locales (historial, funcionan sin red) y de
/// YouTube Music (radio, tendencias, lanzamientos, Inicio). La búsqueda es una
/// ruta aparte ([SearchScreen]) a la que se llega desde el campo de arriba.
class ExploreScreen extends StatefulWidget {
  /// Es la pestaña visible. El `IndexedStack` construye todas desde el
  /// arranque; sin esto Explorar pediría red al abrir la app aunque nadie la
  /// mire.
  final bool active;

  const ExploreScreen({super.key, this.active = true});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> with RemoteTrackActionsMixin<ExploreScreen> {
  bool _networkRequested = false;
  String? _resolvingArtist;

  @override
  void initState() {
    super.initState();
    initRemoteTrackActions();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onActivated());
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _onActivated();
  }

  @override
  void dispose() {
    disposeRemoteTrackActions();
    super.dispose();
  }

  @override
  Iterable<RemoteTrack> get streamErrorLookupTracks sync* {
    final provider = context.read<ExploreProvider>();
    yield* provider.radio.data ?? const [];
    for (final shelf in provider.home.data ?? const <ExploreShelf>[]) {
      yield* shelf.tracks;
    }
  }

  RemoteAccessGate _gate() => remoteAccessGate(
        hasServer: context.read<SettingsProvider>().hasDownloadServer,
        isSignedIn: context.read<HeardyAuthProvider>().isReady,
      );

  void _onActivated() {
    if (!mounted || !widget.active) return;
    final provider = context.read<ExploreProvider>();
    // El historial cambia al escuchar; se relee cada vez que se abre la pestaña.
    provider.loadLocal();
    if (_gate() == RemoteAccessGate.ok) {
      _networkRequested = true;
      provider.loadNetwork();
    }
  }

  Future<void> _refresh() {
    final provider = context.read<ExploreProvider>();
    return _gate() == RemoteAccessGate.ok ? provider.refresh() : provider.loadLocal();
  }

  Future<void> _playLocal(Song song, List<Song> list) async {
    DesktopShellScope.maybeOf(context)?.openNowPlaying();
    final handler = context.read<AudioPlayerHandler>();
    final label = AppLocalizations.of(context)!.exploreRecentTitle;
    await context.read<MusicProvider>().playSearchResults(list, song, handler, label);
  }

  void _openSearch([String? query]) =>
      Navigator.of(context).push(SearchScreen.route(initialQuery: query));

  void _openLogin() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));

  /// "Tus artistas" sólo guarda el nombre: se busca el canal y se abre el
  /// perfil; sin resultado (o con error) se cae a la búsqueda de siempre.
  Future<void> _openArtistByName(String name) async {
    if (_resolvingArtist != null) return;
    final source = context.read<DownloadSource>();
    final navigator = Navigator.of(context);
    final gate = _gate();
    if (gate != RemoteAccessGate.ok) {
      _openSearch(name);
      return;
    }
    setState(() => _resolvingArtist = name);
    ExploreArtistHit? hit;
    try {
      hit = pickArtistHit(await source.exploreArtistSearch(name));
    } catch (_) {
      hit = null;
    } finally {
      if (mounted) setState(() => _resolvingArtist = null);
    }
    if (!mounted) return;
    if (hit == null) {
      navigator.push(SearchScreen.route(initialQuery: name));
      return;
    }
    final chosen = hit;
    navigator.push(ExploreArtistScreen.route(
      name: chosen.name,
      thumbnailUrl: chosen.thumbnailUrl,
      loader: () => source.exploreArtist(chosen.channelId),
    ));
  }

  void _openPlaylist(ExplorePlaylist p) {
    final source = context.read<DownloadSource>();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExploreCollectionScreen(
        title: p.title,
        thumbnailUrl: p.thumbnailUrl,
        loader: () => source.explorePlaylist(p.playlistId),
      ),
    ));
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

  void _openMood(ExploreMood mood) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExploreMoodScreen(mood: mood)));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<ExploreProvider>();
    final gate = remoteAccessGate(
      hasServer: context.watch<SettingsProvider>().hasDownloadServer,
      isSignedIn: context.watch<HeardyAuthProvider>().isReady,
    );
    // Iniciar sesión (o configurar el servidor) con la pestaña ya abierta
    // dispara la carga de red sin esperar a volver a entrar.
    if (gate == RemoteAccessGate.ok) {
      if (widget.active && !_networkRequested) {
        _networkRequested = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.read<ExploreProvider>().loadNetwork();
        });
      }
    } else {
      _networkRequested = false;
    }

    final moods = flattenMoods(provider.moods.data ?? const []);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(l10n)),
            if (gate == RemoteAccessGate.ok && moods.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: MoodChipsRow(moods: moods, onTap: _openMood),
                ),
              ),
            SliverList(
              delegate: SliverChildListDelegate([
                _buildRecent(l10n, provider),
                ..._buildNetworkShelves(l10n, provider, gate),
                _buildArtists(l10n, provider),
                const SizedBox(height: 100),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.exploreTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 14),
          // Imita un campo de texto, pero abre la pantalla de búsqueda: el
          // teclado y los resultados viven allí (patrón de YouTube Music).
          Material(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const Key('explore_search_field'),
              borderRadius: BorderRadius.circular(14),
              onTap: _openSearch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: AppTheme.primaryLight),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.exploreSearchHint,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecent(AppLocalizations l10n, ExploreProvider provider) {
    return ExploreShelfFrame<List<Song>>(
      title: l10n.exploreRecentTitle,
      state: provider.recent,
      onRetry: provider.loadLocal,
      skeleton: const QuickPicksSkeleton(),
      isEmpty: (songs) => songs.isEmpty,
      emptyState: ExploreEmptyNote(l10n.exploreRecentEmpty),
      builder: (songs) => QuickPicksGrid(
        columns: chunkColumns(songs),
        onTap: (song) => _playLocal(song, songs),
      ),
    );
  }

  Widget _buildArtists(AppLocalizations l10n, ExploreProvider provider) {
    return ExploreShelfFrame<List<String>>(
      title: l10n.exploreArtistsTitle,
      state: provider.artists,
      onRetry: provider.loadLocal,
      skeleton: const ExploreCardsSkeleton(size: ArtistAvatarsRow.size, circle: true),
      isEmpty: (artists) => artists.isEmpty,
      builder: (artists) => ArtistAvatarsRow(artists: artists, onTap: _openArtistByName, loadingArtist: _resolvingArtist),
    );
  }

  List<Widget> _buildNetworkShelves(AppLocalizations l10n, ExploreProvider provider, RemoteAccessGate gate) {
    if (gate != RemoteAccessGate.ok) {
      return [
        ExploreHintCard(
          title: l10n.exploreOnlineHintTitle,
          body: gate == RemoteAccessGate.noServer ? l10n.exploreNeedsServerBody : l10n.exploreNeedsLoginBody,
          actionLabel: gate == RemoteAccessGate.needsLogin ? l10n.authRequiredButton : null,
          onAction: gate == RemoteAccessGate.needsLogin ? _openLogin : null,
        ),
      ];
    }
    return [
      ExploreShelfFrame<List<RemoteTrack>>(
        title: l10n.exploreRadioTitle,
        state: provider.radio,
        onRetry: () => provider.reloadShelf(ExploreShelfId.radio),
        skeleton: const ExploreCardsSkeleton(size: RemoteTrackCard.size),
        isEmpty: (tracks) => tracks.isEmpty,
        builder: (tracks) => _tracksRow(tracks),
      ),
      ExploreShelfFrame<List<ExplorePlaylist>>(
        title: l10n.exploreChartsTitle,
        state: provider.charts,
        onRetry: () => provider.reloadShelf(ExploreShelfId.charts),
        skeleton: const ExploreCardsSkeleton(size: 160),
        isEmpty: (l) => l.isEmpty,
        builder: (l) => ExplorePlaylistsRow(playlists: l, onTap: _openPlaylist),
      ),
      ExploreShelfFrame<List<ExploreAlbum>>(
        title: l10n.exploreNewReleasesTitle,
        state: provider.newReleases,
        onRetry: () => provider.reloadShelf(ExploreShelfId.newReleases),
        skeleton: const ExploreCardsSkeleton(),
        isEmpty: (l) => l.isEmpty,
        builder: (l) => ExploreAlbumsRow(albums: l, onTap: _openAlbum),
      ),
      ExploreShelfFrame<List<ExploreShelf>>(
        title: null,
        state: provider.home,
        onRetry: () => provider.reloadShelf(ExploreShelfId.home),
        skeleton: const _HomeSkeleton(),
        isEmpty: (l) => l.isEmpty,
        builder: (shelves) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final shelf in shelves) ...[
              ExploreShelfHeader(shelf.title),
              switch (shelf.kind) {
                ExploreShelfKind.playlists =>
                  ExplorePlaylistsRow(playlists: shelf.playlists, onTap: _openPlaylist),
                ExploreShelfKind.albums => ExploreAlbumsRow(albums: shelf.albums, onTap: _openAlbum),
                ExploreShelfKind.tracks => _tracksRow(shelf.tracks, upscale: true),
              },
            ],
          ],
        ),
      ),
    ];
  }

  Widget _tracksRow(List<RemoteTrack> tracks, {bool upscale = false}) {
    return ExploreHorizontalList(
      height: exploreCardListHeight(context, RemoteTrackCard.size),
      itemCount: tracks.length,
      itemBuilder: (_, i) {
        final track = upscale ? withUpscaledThumbnail(tracks[i]) : tracks[i];
        return RemoteTrackCard(
          track: track,
          onDownload: () => downloadRemoteTrack(track),
          onListen: streamingSupported ? () => listenRemoteTrack(track) : null,
          isLoadingStream: streamingTrackId == track.id,
        );
      },
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(kExploreGutter, 28, kExploreGutter, 12),
          child: SkeletonBox(width: 170, height: 20),
        ),
        ExploreCardsSkeleton(size: RemoteTrackCard.size),
      ],
    );
  }
}
