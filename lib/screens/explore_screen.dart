import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../widgets/max_width_center.dart';
import '../models/explore.dart';
import '../models/followed_artist.dart';
import '../models/song.dart';
import '../providers/auth_provider.dart';
import '../providers/explore_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/download_source.dart';
import '../services/explore_queue.dart';
import '../services/explore_logic.dart';
import '../services/remote_track_actions.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/explore_customize_sheet.dart';
import '../widgets/explore_shelves.dart';
import '../widgets/remote_track_actions_mixin.dart';
import '../widgets/remote_track_tile.dart';
import '../widgets/skeleton_box.dart';
import 'auth/login_screen.dart';
import 'explore_artist_screen.dart';
import 'explore_collection_screen.dart';
import 'explore_mood_screen.dart';
import 'heardy_mixer_screen.dart';
import 'mixes_screen.dart';
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

class _ExploreScreenState extends State<ExploreScreen>
    with RemoteTrackActionsMixin<ExploreScreen>, WidgetsBindingObserver {
  bool _networkRequested = false;
  bool _startingPlay = false;
  String? _resolvingArtist;
  late int _followedRevision;

  @override
  void initState() {
    super.initState();
    _followedRevision = context.read<FollowedArtistsProvider>().revision;
    initRemoteTrackActions();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onActivated());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Volver a la app tras horas: sin esto Explorar seguía mostrando lo mismo
    // hasta matar el proceso. El estrangulado (15 min) vive en el provider.
    if (state == AppLifecycleState.resumed) _onActivated();
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _onActivated();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (_gate() == RemoteAccessGate.ok) {
      _networkRequested = true;
      provider.refreshIfStale();
    } else {
      provider.loadLocal();
    }
  }

  Future<void> _refresh() async {
    final provider = context.read<ExploreProvider>();
    if (_gate() != RemoteAccessGate.ok) return provider.loadLocal();
    await provider.refresh();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(provider.hasNetworkError ? l10n.exploreRefreshFailed : l10n.exploreRefreshed),
      ));
  }

  Future<void> _playLocal(Song song, List<Song> list) async {    DesktopShellScope.maybeOf(context)?.openNowPlaying();
    final handler = context.read<AudioPlayerHandler>();
    final label = AppLocalizations.of(context)!.exploreRecentTitle;
    await context.read<MusicProvider>().playSearchResults(list, song, handler, label);
  }

  /// Acción por defecto de una tarjeta: reproducir. Si la canción ya está en la
  /// biblioteca se usa el archivo local (sin red); si no, streaming.
  Future<void> _playTrack(RemoteTrack track, {List<RemoteTrack>? queue}) async {
    if (_startingPlay || streamingTrackId != null) return;
    _startingPlay = true;
    try {
      final local = await context.read<ExploreProvider>().findLocalSong(track.id);
      if (!mounted) return;
      if (local != null) {
        await _playLocal(local, [local]);
        return;
      }
      if (queue != null && queue.isNotEmpty) {
        await listenRemoteQueue(queue, track);
      } else {
        await listenRemoteTrack(track);
      }
    } finally {
      _startingPlay = false;
    }
  }

  /// Tras un cambio de ajustes (secciones o país) el provider carga lo recién
  /// mostrado y recarga las regionales; sin acceso remoto sólo las locales.
  void _applyPreferences() {
    if (!mounted) return;
    final provider = context.read<ExploreProvider>();
    if (_gate() == RemoteAccessGate.ok) {
      provider.syncPreferences();
    } else {
      provider.loadLocal();
    }
  }

  void _openCustomize() => showExploreCustomizeSheet(context, onChanged: _applyPreferences);

  Future<void> _hideShelf(ExploreShelfId id) => context.read<SettingsProvider>().setExploreShelfHidden(id, true);

  Future<void> _restoreShelves() async {
    await context.read<SettingsProvider>().showAllExploreShelves();
    _applyPreferences();
  }

  Widget _sectionMenu(ExploreShelfId id) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      key: Key('explore_section_menu_${id.name}'),
      tooltip: l10n.exploreSectionMenuTooltip,
      icon: Icon(Icons.more_horiz_rounded, color: Colors.white.withValues(alpha: 0.6)),
      onSelected: (action) {
        if (action == 'hide') {
          _hideShelf(id);
        } else {
          showExploreCountryPicker(context, onChanged: _applyPreferences);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'hide', child: Text(l10n.exploreSectionHide)),
        if (isRegionalShelf(id)) PopupMenuItem(value: 'country', child: Text(l10n.exploreSectionChangeCountry)),
      ],
    );
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
      channelId: chosen.channelId,
      thumbnailUrl: chosen.thumbnailUrl,
      loader: () => source.exploreArtist(chosen.channelId),
    ));
  }

  void _openFollowed(ExploreRelatedArtist artist) {
    final source = context.read<DownloadSource>();
    Navigator.of(context).push(ExploreArtistScreen.route(
      name: artist.name,
      channelId: artist.channelId,
      thumbnailUrl: artist.thumbnailUrl,
      loader: () => source.exploreArtist(artist.channelId),
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
    final followed = context.watch<FollowedArtistsProvider>();
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
      // Seguir o dejar de seguir (también desde un perfil abierto encima)
      // actualiza las novedades; con la pestaña oculta espera a que se abra.
      if (widget.active && followed.revision != _followedRevision) {
        _followedRevision = followed.revision;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.read<ExploreProvider>().syncFollowedReleases();
        });
      }
    } else {
      _networkRequested = false;
    }

    final settings = context.watch<SettingsProvider>();
    final hidden = settings.exploreHiddenShelves;
    final allHidden = hidden.length >= ExploreShelfId.values.length;
    final shelves = exploreShelvesToShow(
      order: settings.exploreShelfOrder,
      hidden: hidden,
      online: gate == RemoteAccessGate.ok,
    );
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(l10n)),
            SliverList(
              delegate: SliverChildListDelegate([
                if (allHidden)
                  _buildAllHidden(l10n)
                else
                  for (final id in shelves) ?_buildShelf(id, l10n, provider, followed, gate),
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
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 12, kScreenGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.exploreTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              IconButton(
                key: const Key('explore_mixer_button'),
                tooltip: l10n.mixerTitle,
                icon: const Icon(Icons.multitrack_audio_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).push(HeardyMixerScreen.route()),
              ),
              IconButton(
                key: const Key('explore_customize_button'),
                tooltip: l10n.exploreCustomizeTooltip,
                icon: const Icon(Icons.tune_rounded, color: Colors.white),
                onPressed: _openCustomize,
              ),
              IconButton(
                key: const Key('explore_refresh_button'),
                tooltip: l10n.exploreRefreshTooltip,
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                onPressed: _refresh,
              ),
            ],
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
          const SizedBox(height: 10),
          _buildMixesEntry(l10n),
        ],
      ),
    );
  }

  /// Entrada fija, no una estantería: es local (sin sesión ni red) y no se
  /// oculta ni se ordena con las demás.
  Widget _buildMixesEntry(AppLocalizations l10n) {
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const Key('explore_mixes_entry'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(MixesScreen.route()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.queue_music_rounded, color: AppTheme.primaryLight),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.mixesTitle,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                    Text(
                      l10n.mixesEntrySubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllHidden(AppLocalizations l10n) {
    return ExploreHintCard(
      title: l10n.exploreAllHiddenTitle,
      body: l10n.exploreAllHiddenBody,
      actionLabel: l10n.exploreRestoreSections,
      onAction: _restoreShelves,
      actionKey: const Key('explore_restore_button'),
    );
  }

  Widget _buildRecent(AppLocalizations l10n, ExploreProvider provider) {
    return ExploreShelfFrame<List<Song>>(
      title: l10n.exploreRecentTitle,
      trailing: _sectionMenu(ExploreShelfId.recent),
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
      trailing: _sectionMenu(ExploreShelfId.artists),
      state: provider.artists,
      onRetry: provider.loadLocal,
      skeleton: const ExploreCardsSkeleton(size: ArtistAvatarsRow.size, circle: true),
      isEmpty: (artists) => artists.isEmpty,
      builder: (artists) => ArtistAvatarsRow(artists: artists, onTap: _openArtistByName, loadingArtist: _resolvingArtist),
    );
  }

  /// Local: se muestra sin sesión. Sin ella, el perfil abre con cabecera y
  /// botón de seguir, y su contenido ofrece reintentar.
  Widget _buildFollowed(AppLocalizations l10n, FollowedArtistsProvider followed) {
    return ExploreShelfFrame<List<FollowedArtist>>(
      title: l10n.exploreFollowedTitle,
      trailing: _sectionMenu(ExploreShelfId.followed),
      state: followed.isLoaded ? ShelfState.data(followed.followed) : const ShelfState.idle(),
      onRetry: followed.load,
      skeleton: const ExploreCardsSkeleton(size: ExploreRelatedArtistsRow.size, circle: true),
      isEmpty: (artists) => artists.isEmpty,
      emptyState: ExploreEmptyNote(l10n.exploreFollowedEmpty),
      builder: (artists) => ExploreRelatedArtistsRow(
        artists: [
          for (final a in artists)
            ExploreRelatedArtist(channelId: a.channelId, name: a.name, thumbnailUrl: a.thumbnailUrl),
        ],
        onTap: _openFollowed,
      ),
    );
  }

  Widget? _buildMoods(ExploreProvider provider) {
    final moods = flattenMoods(provider.moods.data ?? const []);
    if (moods.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: MoodChipsRow(moods: moods, onTap: _openMood),
    );
  }

  /// null si esta estantería no tiene nada que dibujar. Sin acceso remoto, la
  /// de red que llega aquí es el sitio del aviso (ver [exploreShelvesToShow]).
  Widget? _buildShelf(
    ExploreShelfId id,
    AppLocalizations l10n,
    ExploreProvider provider,
    FollowedArtistsProvider followed,
    RemoteAccessGate gate,
  ) {
    if (gate != RemoteAccessGate.ok && kExploreNetworkShelves.contains(id)) {
      return ExploreHintCard(
        title: l10n.exploreOnlineHintTitle,
        body: gate == RemoteAccessGate.noServer ? l10n.exploreNeedsServerBody : l10n.exploreNeedsLoginBody,
        actionLabel: gate == RemoteAccessGate.needsLogin ? l10n.authRequiredButton : null,
        onAction: gate == RemoteAccessGate.needsLogin ? _openLogin : null,
      );
    }
    return switch (id) {
      ExploreShelfId.moods => _buildMoods(provider),
      ExploreShelfId.recent => _buildRecent(l10n, provider),
      ExploreShelfId.followed => _buildFollowed(l10n, followed),
      ExploreShelfId.artists => _buildArtists(l10n, provider),
      ExploreShelfId.followedReleases when followed.followed.isEmpty => null,
      ExploreShelfId.followedReleases =>
        ExploreShelfFrame<List<ExploreAlbum>>(
          title: l10n.exploreFollowedReleasesTitle,
          trailing: _sectionMenu(ExploreShelfId.followedReleases),
          state: provider.followedReleases,
          onRetry: () => provider.reloadShelf(ExploreShelfId.followedReleases),
          skeleton: const ExploreCardsSkeleton(),
          isEmpty: (l) => l.isEmpty,
          emptyState: ExploreEmptyNote(l10n.exploreFollowedReleasesEmpty),
          builder: (l) => ExploreAlbumsRow(albums: l, onTap: _openAlbum),
        ),
      ExploreShelfId.radio =>
        ExploreShelfFrame<List<RemoteTrack>>(
          title: l10n.exploreRadioTitle,
          trailing: _sectionMenu(ExploreShelfId.radio),
          state: provider.radio,
          onRetry: () => provider.reloadShelf(ExploreShelfId.radio),
          skeleton: const ExploreCardsSkeleton(size: RemoteTrackCard.size),
          isEmpty: (tracks) => tracks.isEmpty,
          builder: (tracks) => _tracksRow(tracks),
        ),
      ExploreShelfId.charts =>
        ExploreShelfFrame<List<ExplorePlaylist>>(
          title: l10n.exploreChartsTitle,
          trailing: _sectionMenu(ExploreShelfId.charts),
          state: provider.charts,
          onRetry: () => provider.reloadShelf(ExploreShelfId.charts),
          skeleton: const ExploreCardsSkeleton(size: 160),
          isEmpty: (l) => l.isEmpty,
          builder: (l) => ExplorePlaylistsRow(playlists: l, onTap: _openPlaylist),
        ),
      ExploreShelfId.newReleases =>
        ExploreShelfFrame<List<ExploreAlbum>>(
          title: l10n.exploreNewReleasesTitle,
          trailing: _sectionMenu(ExploreShelfId.newReleases),
          state: provider.newReleases,
          onRetry: () => provider.reloadShelf(ExploreShelfId.newReleases),
          skeleton: const ExploreCardsSkeleton(),
          isEmpty: (l) => l.isEmpty,
          builder: (l) => ExploreAlbumsRow(albums: l, onTap: _openAlbum),
        ),
      ExploreShelfId.home =>
        ExploreShelfFrame<List<ExploreShelf>>(
          title: null,
          state: provider.home,
          onRetry: () => provider.reloadShelf(ExploreShelfId.home),
          skeleton: const _HomeSkeleton(),
          isEmpty: (l) => l.isEmpty,
          builder: (shelves) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, shelf) in shelves.indexed) ...[
                ExploreShelfHeader(shelf.title, trailing: i == 0 ? _sectionMenu(ExploreShelfId.home) : null),
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
    };
  }

  Widget _tracksRow(List<RemoteTrack> tracks, {bool upscale = false}) {
    return ExploreHorizontalList(
      height: exploreCardListHeight(context, RemoteTrackCard.size),
      itemCount: tracks.length,
      itemBuilder: (_, i) {
        final track = upscale ? withUpscaledThumbnail(tracks[i]) : tracks[i];
        return ExploreTrackCard(
          track: track,
          onDownload: () => downloadRemoteTrack(track),
          onPlay: streamingSupported
              ? () => _playTrack(
                    track,
                    queue: exploreQueueFrom(
                      tracks,
                      i,
                      transform: upscale ? withUpscaledThumbnail : null,
                    ),
                  )
              : null,
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
