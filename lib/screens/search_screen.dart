import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';
import '../providers/auth_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/auth/login_screen.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/explore_logic.dart';
import '../models/explore.dart';
import '../screens/explore_artist_screen.dart';
import '../screens/explore_collection_screen.dart';
import '../services/remote_track_actions.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/mini_player.dart';
import '../widgets/remote_track_actions_mixin.dart';
import '../widgets/remote_track_tile.dart';
import '../widgets/song_tile.dart';
import '../l10n/app_localizations.dart';
import '../widgets/desktop_horizontal_scroller.dart';
import '../widgets/max_width_center.dart';
import '../services/friendly_error.dart';
import '../services/input_sanitizer.dart';

/// Local o remoto: qué colección está mirando la pestaña de búsqueda.
enum _SearchScope { local, youtube }

/// Búsqueda con dos pestañas: local (sobre la biblioteca ya indexada, sin
/// red) y YouTube (vía [DownloadSource], para descargar sin tener que pegar
/// una URL). La pestaña local es la que recicló la vieja pantalla de
/// búsqueda de YouTube cuando se podó la capa de descarga (Etapa 5) — filtra
/// en cliente porque una colección personal no necesita paginación ni ida y
/// vuelta a la red.
class SearchScreen extends StatefulWidget {
  /// Con valor, arranca en la pestaña de Internet con esa búsqueda ya lanzada
  /// ("Tus artistas" de Explorar).
  final String? initialQuery;

  /// Abierta como ruta (desde Explorar) y no como pestaña: lleva su propio
  /// fondo y un botón para volver.
  final bool standalone;

  const SearchScreen({super.key, this.initialQuery, this.standalone = false});

  static Route<void> route({String? initialQuery}) => MaterialPageRoute<void>(
        builder: (_) => SearchScreen(initialQuery: initialQuery, standalone: true),
      );

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with RemoteTrackActionsMixin<SearchScreen> {
  final _controller = TextEditingController();
  List<Song> _allSongs = [];
  String _query = '';
  bool _loading = true;
  // -1 so the very first build (version starts at 0 in MusicProvider)
  // triggers the initial load too — one mechanism for both "first open"
  // and "reload after a scan", instead of an initState that only ever
  // saw whatever existed at cold start (IndexedStack keeps this screen
  // alive, so initState never runs again).
  int _loadedVersion = -1;

  _SearchScope _scope = _SearchScope.local;
  Timer? _debounce;
  SearchKind _kind = SearchKind.songs;
  ExploreSearchResults _exploreResults = const ExploreSearchResults();
  List<RemoteTrack> _youtubeResults = [];
  bool _youtubeLoading = false;
  String? _youtubeError;
  // Descarta una respuesta que llega tarde de una búsqueda ya superada por
  // una más nueva — sin esto, escribir rápido puede hacer que el resultado
  // de la letra "b" pise al de "bon" si "b" tarda más en volver.
  int _searchGeneration = 0;
  @override
  void initState() {
    super.initState();
    initRemoteTrackActions();
    final initial = sanitizeSearchInput(widget.initialQuery ?? '');
    if (initial.isNotEmpty) {
      _query = initial;
      _controller.text = initial;
      _scope = _SearchScope.youtube;
      _scheduleYoutubeSearch();
    }
  }

  @override
  Iterable<RemoteTrack> get streamErrorLookupTracks => _youtubeResults;

  @override
  void dispose() {
    disposeRemoteTrackActions();
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final songs = await DatabaseHelper.instance.getSongs();
    if (!mounted) return;
    setState(() {
      _allSongs = songs.where((s) => !s.missing).toList();
      _loading = false;
    });
  }

  List<Song> _matches(int maxResults) {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    final matches = _allSongs
        .where((s) => s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q))
        .toList();
    return matches.length > maxResults ? matches.sublist(0, maxResults) : matches;
  }

  Future<void> _play(Song song, List<Song> results) async {
    DesktopShellScope.maybeOf(context)?.openNowPlaying();
    final audioHandler = context.read<AudioPlayerHandler>();
    final albumLabel = AppLocalizations.of(context)!.searchResultsAlbumLabel;
    await context.read<MusicProvider>().playSearchResults(results, song, audioHandler, albumLabel);
  }

  void _onQueryChanged(String value) {
    setState(() => _query = sanitizeSearchInput(value));
    if (_scope == _SearchScope.youtube) _scheduleYoutubeSearch();
  }

  void _switchScope(_SearchScope scope) {
    setState(() => _scope = scope);
    if (scope == _SearchScope.youtube && _query.isNotEmpty && _youtubeResults.isEmpty && _exploreResults.isEmpty) {
      _scheduleYoutubeSearch();
    }
  }

  void _switchKind(SearchKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _youtubeResults = [];
      _exploreResults = const ExploreSearchResults();
      _youtubeError = null;
    });
    _debounce?.cancel();
    if (_query.isNotEmpty) {
      _runYoutubeSearch();
    } else {
      _searchGeneration++;
    }
  }

  void _scheduleYoutubeSearch() {
    _debounce?.cancel();
    if (_query.isEmpty) {
      setState(() {
        _youtubeResults = [];
        _exploreResults = const ExploreSearchResults();
        _youtubeError = null;
        _youtubeLoading = false;
      });
      return;
    }
    // Espera a que el usuario deje de escribir en vez de buscar en cada
    // pulsación — cada búsqueda es una petición real al servidor.
    _debounce = Timer(const Duration(milliseconds: 500), _runYoutubeSearch);
  }

  Future<void> _runYoutubeSearch() async {
    final query = _query;
    final kind = _kind;
    final generation = ++_searchGeneration;
    setState(() {
      _youtubeLoading = true;
      _youtubeError = null;
    });
    try {
      final source = context.read<DownloadSource>();
      final exploreKind = exploreKindFor(kind);
      if (exploreKind == null) {
        final maxResults = context.read<SettingsProvider>().maxSearchResults;
        final results = await source.search(query, limit: maxResults);
        if (!mounted || !isCurrentSearch(generation, _searchGeneration)) return;
        setState(() => _youtubeResults = results);
      } else {
        final results = await source.exploreSearch(query, exploreKind, country: deviceExploreCountry());
        if (!mounted || !isCurrentSearch(generation, _searchGeneration)) return;
        setState(() => _exploreResults = results);
      }
    } on DownloadSourceException catch (e) {
      if (!mounted || !isCurrentSearch(generation, _searchGeneration)) return;
      setState(() => _youtubeError = localizedErrorReport(AppLocalizations.of(context)!, e));
    } catch (e) {
      if (!mounted || !isCurrentSearch(generation, _searchGeneration)) return;
      setState(() => _youtubeError = AppLocalizations.of(context)!.searchFailedGeneric(localizedErrorReport(AppLocalizations.of(context)!, e)));
    } finally {
      if (mounted && isCurrentSearch(generation, _searchGeneration)) {
        setState(() => _youtubeLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxResults = context.watch<SettingsProvider>().maxSearchResults;
    final audioHandler = context.watch<AudioPlayerHandler>();
    final libraryVersion = context.watch<MusicProvider>().librarySongsVersion;
    final l10n = AppLocalizations.of(context)!;
    if (_loadedVersion != libraryVersion) {
      _loadedVersion = libraryVersion;
      _load();
    }
    final results = _matches(maxResults);

    final body = SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(widget.standalone ? 8 : kScreenGutter, 12, kScreenGutter, 0),
            child: Row(
              children: [
                if (widget.standalone)
                  IconButton(
                    key: const Key('search_back_button'),
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                Text(
                  l10n.searchTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 16, kScreenGutter, 0),
            child: SegmentedButton<_SearchScope>(
              segments: [
                ButtonSegment(
                  value: _SearchScope.local,
                  icon: const Icon(Icons.folder_rounded, size: 16),
                  label: Text(l10n.searchLocalTab),
                ),
                ButtonSegment(
                  value: _SearchScope.youtube,
                  icon: const Icon(Icons.cloud_rounded, size: 16),
                  label: Text(l10n.searchInternetTab),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (selection) => _switchScope(selection.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 14, kScreenGutter, 8),
            child: TextField(
              key: const Key('search_field'),
              controller: _controller,
              onChanged: _onQueryChanged,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _scope == _SearchScope.local ? l10n.searchLocalHint : l10n.searchYoutubeHint,
                prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primaryLight),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (_scope == _SearchScope.youtube) _buildKindChips(l10n),
          Expanded(
            child: _scope == _SearchScope.local
                ? (_loading ? const Center(child: CircularProgressIndicator()) : _buildLocalContent(results, audioHandler))
                : _buildYoutubeContent(),
          ),
        ],
      ),
    );
    if (!widget.standalone) return body;
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            body,
            const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }

  Widget _buildKindChips(AppLocalizations l10n) {
    final labels = {
      SearchKind.songs: l10n.searchKindSongs,
      SearchKind.playlists: l10n.searchKindPlaylists,
      SearchKind.albums: l10n.searchKindAlbums,
      SearchKind.artists: l10n.searchKindArtists,
    };
    return DesktopHorizontalScroller(
      height: 44,
      builder: (context, controller, extra) => ListView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kScreenGutter).add(extra),
        children: [
          for (final kind in SearchKind.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: Key('search_kind_${kind.name}'),
                label: Text(labels[kind]!),
                selected: _kind == kind,
                onSelected: (_) => _switchKind(kind),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalContent(List<Song> results, AudioPlayerHandler audioHandler) {
    final l10n = AppLocalizations.of(context)!;
    if (_query.isEmpty) {
      return _buildHint(Icons.search_rounded, l10n.searchLocalEmptyTitle, l10n.searchLocalEmptySubtitle);
    }
    if (results.isEmpty) {
      return _buildHint(Icons.music_note_outlined, l10n.playlistNoResultsTitle, l10n.searchNoResultsSubtitle(_query));
    }
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final currentId = snapshot.data?.id;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 90),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final song = results[index];
            return SongTile(
              song: song,
              isPlaying: song.id == currentId,
              onTap: () => _play(song, results),
            );
          },
        );
      },
    );
  }

  Widget _buildYoutubeContent() {
    final l10n = AppLocalizations.of(context)!;
    final gate = remoteAccessGate(
      hasServer: context.watch<SettingsProvider>().hasDownloadServer,
      isSignedIn: context.watch<HeardyAuthProvider>().isReady,
    );
    if (gate == RemoteAccessGate.noServer) {
      return _buildHint(
        Icons.dns_outlined,
        l10n.searchNoServerTitle,
        l10n.searchNoServerSubtitle,
      );
    }
    // Fase 2 del plan de seguridad: descargar exige sesión (identidad real
    // en vez de la clave compilada de antes), pero la búsqueda local y el
    // resto de la app no — así que este chequeo vive sólo acá, no como un
    // gate global. Reusa el mismo widget de "hint" que ya existía para
    // "sin servidor" (arriba), sólo con el texto y el botón cambiados.
    if (gate == RemoteAccessGate.needsLogin) {
      return _buildHint(
        Icons.lock_outline_rounded,
        l10n.authRequiredTitle,
        l10n.authRequiredBody,
        actionLabel: l10n.authRequiredButton,
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
      );
    }
    if (_query.isEmpty) {
      return _buildHint(Icons.cloud_outlined, l10n.searchYoutubeEmptyTitle, l10n.searchYoutubeEmptySubtitle);
    }
    final isSongs = _kind == SearchKind.songs;
    if (_youtubeLoading && (isSongs ? _youtubeResults.isEmpty : _exploreResults.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_youtubeError != null) {
      return _buildHint(Icons.error_outline_rounded, l10n.searchFailedTitle, _youtubeError!);
    }
    if (isSongs ? _youtubeResults.isEmpty : _exploreResults.isEmpty) {
      return _buildHint(Icons.music_note_outlined, l10n.playlistNoResultsTitle, l10n.searchNoResultsSubtitle(_query));
    }
    if (!isSongs) return _buildExploreResults();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 90),
      itemCount: _youtubeResults.length,
      itemBuilder: (context, index) => RemoteTrackTile(
        track: _youtubeResults[index],
        onDownload: () => downloadRemoteTrack(_youtubeResults[index]),
        onListen: streamingSupported ? () => listenRemoteTrack(_youtubeResults[index]) : null,
        isLoadingStream: streamingTrackId == _youtubeResults[index].id,
      ),
    );
  }

  Widget _buildExploreResults() {
    final r = _exploreResults;
    final source = context.read<DownloadSource>();
    final tiles = <Widget>[
      for (final p in r.playlists)
        _ExploreResultTile(
          key: ValueKey('playlist_${p.playlistId}'),
          title: p.title,
          subtitle: p.subtitle,
          thumbnailUrl: p.thumbnailUrl,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ExploreCollectionScreen(
              title: p.title,
              thumbnailUrl: p.thumbnailUrl,
              loader: () => source.explorePlaylist(p.playlistId),
            ),
          )),
        ),
      for (final a in r.albums)
        _ExploreResultTile(
          key: ValueKey('album_${a.browseId}'),
          title: a.title,
          subtitle: [a.artist, a.year].where((s) => s.isNotEmpty).join(' · '),
          thumbnailUrl: a.thumbnailUrl,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ExploreCollectionScreen(
              title: a.title,
              subtitle: a.artist,
              thumbnailUrl: a.thumbnailUrl,
              loader: () => source.exploreAlbum(a.browseId),
            ),
          )),
        ),
      for (final h in r.artists)
        _ExploreResultTile(
          key: ValueKey('artist_${h.channelId}'),
          title: h.name,
          subtitle: h.subscribers,
          thumbnailUrl: h.thumbnailUrl,
          circular: true,
          onTap: () => Navigator.of(context).push(ExploreArtistScreen.route(
            name: h.name,
            thumbnailUrl: h.thumbnailUrl,
            loader: () => source.exploreArtist(h.channelId),
          )),
        ),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 90), children: tiles);
  }

  Widget _buildHint(
    IconData icon,
    String title,
    String subtitle, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    // Con el teclado abierto (p. ej. mientras se escribe en el campo de
    // arriba) el alto disponible para este hint se comprime bastante —
    // en un dispositivo real esto desbordaba 7px con un Column normal.
    // SingleChildScrollView + mainAxisSize.min hace que el contenido se
    // pueda desplazar en vez de reventar el layout cuando no entra entero.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExploreResultTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String thumbnailUrl;
  final bool circular;
  final VoidCallback onTap;

  const _ExploreResultTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbnailUrl,
    required this.onTap,
    this.circular = false,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: 52,
      height: 52,
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(circular ? Icons.person_rounded : Icons.library_music_rounded, color: Colors.white38),
    );
    final cover = thumbnailUrl.isEmpty
        ? placeholder
        : Image.network(
            thumbnailUrl,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          );
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(borderRadius: BorderRadius.circular(circular ? 26 : 8), child: cover),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
      trailing: Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.4)),
      onTap: onTap,
    );
  }
}
