import 'package:flutter/foundation.dart';

import '../models/explore.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/explore_logic.dart';
import '../services/statistics_service.dart';

export '../services/explore_logic.dart' show ExploreShelfId;

enum ShelfStatus { idle, loading, data, error }

/// Estado de una estantería. En un refresco conserva [data] mientras vuelve a
/// cargar, para que la pantalla no parpadee a esqueleto.
class ShelfState<T> {
  final ShelfStatus status;
  final T? data;
  final Object? error;

  const ShelfState._(this.status, this.data, this.error);
  const ShelfState.idle() : this._(ShelfStatus.idle, null, null);
  const ShelfState.loading([T? previous]) : this._(ShelfStatus.loading, previous, null);
  const ShelfState.data(T data) : this._(ShelfStatus.data, data, null);
  const ShelfState.error(Object error, [T? previous]) : this._(ShelfStatus.error, previous, error);

  bool get isLoading => status == ShelfStatus.loading;
  bool get isIdle => status == ShelfStatus.idle;
  bool get hasError => status == ShelfStatus.error;
}

/// Estanterías de Explorar con caché en memoria durante la sesión. Las locales
/// (historial) son instantáneas y no tocan la red; las de red sólo se piden la
/// primera vez (o con [refresh]) y cada una falla por separado.
class ExploreProvider extends ChangeNotifier {
  static const _radioSeedCandidates = 12;

  final DownloadSource _source;
  final DatabaseHelper _db;
  final String? Function() _country;
  final Set<ExploreShelfId> Function() _hidden;
  final Future<List<Map<String, dynamic>>> Function() _topArtistRows;

  final Map<ExploreShelfId, ShelfState<Object?>> _states = {
    for (final id in ExploreShelfId.values) id: const ShelfState<Object?>.idle(),
  };
  /// País con el que se pidió cada estantería regional, para saber cuáles
  /// quedaron viejas al cambiarlo.
  final Map<ExploreShelfId, String?> _countryUsed = {};
  final Map<ExploreShelfId, int> _generation = {for (final id in ExploreShelfId.values) id: 0};
  bool _disposed = false;
  DateTime? _lastNetworkRefresh;
  final DateTime Function() _now;
  final Future<List<Song>> Function(String videoId) _localSongsForVideo;

  ExploreProvider({
    required DownloadSource source,
    DatabaseHelper? db,
    String? Function()? country,
    Set<ExploreShelfId> Function()? hiddenShelves,
    Future<List<Map<String, dynamic>>> Function()? topArtistRows,
    DateTime Function()? now,
    Future<List<Song>> Function(String videoId)? localSongsForVideo,
  })  : _source = source,
        _db = db ?? DatabaseHelper.instance,
        _country = country ?? deviceExploreCountry,
        _hidden = hiddenShelves ?? (() => const {}),
        _topArtistRows = topArtistRows ?? (db ?? DatabaseHelper.instance).getTopArtistsThisMonth,
        _now = now ?? DateTime.now,
        _localSongsForVideo = localSongsForVideo ??
            ((videoId) async {
              final database = await (db ?? DatabaseHelper.instance).database;
              final rows = await database.query(
                'songs',
                where: "missing = 0 AND sourceUrl LIKE ? ESCAPE '\\'",
                whereArgs: ['%${videoId.replaceAll('_', r'\_')}%'],
              );
              return [for (final r in rows) Song.fromMap(r)];
            });

  ShelfState<List<Song>> get recent => _typed(ExploreShelfId.recent);
  ShelfState<List<String>> get artists => _typed(ExploreShelfId.artists);
  ShelfState<List<RemoteTrack>> get radio => _typed(ExploreShelfId.radio);
  ShelfState<List<ExplorePlaylist>> get charts => _typed(ExploreShelfId.charts);
  ShelfState<List<ExploreAlbum>> get newReleases => _typed(ExploreShelfId.newReleases);
  ShelfState<List<ExploreShelf>> get home => _typed(ExploreShelfId.home);
  ShelfState<List<ExploreMoodSection>> get moods => _typed(ExploreShelfId.moods);

  List<ExploreShelfId> get _visibleNetworkShelves {
    final hidden = _hidden();
    return [for (final id in _networkShelves) if (!hidden.contains(id)) id];
  }

  bool get hasNetworkError => _visibleNetworkShelves.any((id) => _states[id]!.hasError);

  ShelfState<T> _typed<T>(ExploreShelfId id) {
    final s = _states[id]!;
    return ShelfState<T>._(s.status, s.data as T?, s.error);
  }

  /// Historial local: barato, se vuelve a pedir cada vez que se abre la pestaña.
  Future<void> loadLocal() {
    final hidden = _hidden();
    return Future.wait([
      if (!hidden.contains(ExploreShelfId.recent))
        _run<List<Song>>(ExploreShelfId.recent, () => _db.getRecentlyPlayedSongs(limit: 20), silent: true),
      if (!hidden.contains(ExploreShelfId.artists))
        _run<List<String>>(ExploreShelfId.artists, _fetchArtists, silent: true),
    ]);
  }

  /// Pide las estanterías de red que aún no se han pedido. Las que fallaron se
  /// reintentan sólo con [reloadShelf] o [refresh], para no martillar al
  /// servidor cada vez que se cambia de pestaña.
  Future<void> loadNetwork() async {
    final visible = _visibleNetworkShelves;
    final pending = [
      for (final id in visible)
        if (_states[id]!.isIdle) id,
    ];
    await Future.wait([for (final id in pending) reloadShelf(id)]);
    if (pending.length == visible.length) _stampIfHealthy();
  }

  /// Refresco pedido por el usuario: además de volver a pedir, le dice al
  /// servidor que se salte su caché. [refreshIfStale] no lo hace.
  Future<void> refresh() async {
    await Future.wait([
      loadLocal(),
      for (final id in _visibleNetworkShelves) reloadShelf(id, fresh: true),
    ]);
    _stampIfHealthy();
  }

  /// Al entrar o volver a la app: si lo cargado tiene [kExploreMaxAge] o más
  /// (o nunca se cargó) lo vuelve a pedir conservando lo visible mientras tanto;
  /// si sigue fresco, sólo completa lo que falte.
  Future<void> refreshIfStale() async {
    if (exploreNeedsRefresh(_lastNetworkRefresh, _now())) {
      await Future.wait([
        loadLocal(),
        for (final id in _visibleNetworkShelves) reloadShelf(id),
      ]);
      _stampIfHealthy();
      return;
    }
    await loadLocal();
    await loadNetwork();
  }

  /// Sólo se da por fresco si ninguna estantería de red quedó en error: una
  /// que falló se reintenta en la siguiente entrada, no tras 15 minutos.
  void _stampIfHealthy() {
    if (_visibleNetworkShelves.any((id) => _states[id]!.status == ShelfStatus.error)) return;
    _lastNetworkRefresh = _now();
  }

  /// La canción ya descargada que corresponde a [videoId], o null. Falla en
  /// silencio (null): el llamador cae a reproducir por streaming.
  Future<Song?> findLocalSong(String videoId) async {
    try {
      return pickLocalSongForVideo(videoId, await _localSongsForVideo(videoId));
    } catch (e) {
      print('Explorar: no se pudo buscar la canción local (${e.runtimeType})');
      return null;
    }
  }

  static const _networkShelves = [
    ExploreShelfId.radio,
    ExploreShelfId.charts,
    ExploreShelfId.newReleases,
    ExploreShelfId.home,
    ExploreShelfId.moods,
  ];

  /// Aplica un cambio de ajustes de Explorar (secciones visibles o país): lo
  /// recién mostrado se carga y las regionales cargadas con otro país se vuelven
  /// a pedir (frescas, el servidor cachea por país).
  Future<void> syncPreferences() async {
    final country = _country();
    final stale = [
      for (final id in _visibleNetworkShelves)
        if (isRegionalShelf(id) && !_states[id]!.isIdle && _countryUsed[id] != country) id,
    ];
    await Future.wait([
      loadLocal(),
      for (final id in stale) reloadShelf(id, fresh: true),
    ]);
    await loadNetwork();
  }

  Future<void> reloadShelf(ExploreShelfId id, {bool fresh = false}) {
    if (_hidden().contains(id)) return Future.value();
    if (isRegionalShelf(id)) _countryUsed[id] = _country();
    switch (id) {
      case ExploreShelfId.recent:
      case ExploreShelfId.artists:
        return loadLocal();
      case ExploreShelfId.radio:
        return _run<List<RemoteTrack>>(id, _fetchRadio);
      case ExploreShelfId.charts:
        return _run<List<ExplorePlaylist>>(id, () => _source.exploreCharts(country: _country(), fresh: fresh));
      case ExploreShelfId.newReleases:
        return _run<List<ExploreAlbum>>(id, () => _source.exploreNewReleases(country: _country(), fresh: fresh));
      case ExploreShelfId.home:
        return _run<List<ExploreShelf>>(id, () => _source.exploreHome(country: _country(), fresh: fresh));
      case ExploreShelfId.moods:
        return _run<List<ExploreMoodSection>>(id, () => _source.exploreMoods(country: _country(), fresh: fresh));
    }
  }

  Future<List<String>> _fetchArtists() async {
    final folded = foldTopArtists(await _topArtistRows(), limit: 12);
    return [for (final r in folded) r['artist'] as String];
  }

  Future<List<RemoteTrack>> _fetchRadio() async {
    final urls = await _db.getMostPlayedYoutubeSourceUrls(limit: _radioSeedCandidates);
    final seeds = selectRadioSeedIds(urls);
    if (seeds.isEmpty) return const [];
    final lists = <List<RemoteTrack>>[];
    Object? lastError;
    // En secuencia: son pocas semillas y cada una es una petición real al
    // servidor; en paralelo sólo ganaríamos unos segundos a costa de ráfaga.
    for (final seed in seeds) {
      try {
        lists.add(await _source.exploreRadio(seed));
      } catch (e) {
        lastError = e;
      }
    }
    if (lists.isEmpty && lastError != null) throw lastError;
    final local = localVideoIds(await _db.getLocalSourceUrls());
    return mergeRadioTracks(lists, localVideoIds: local);
  }

  Future<void> _run<T>(ExploreShelfId id, Future<T> Function() fetch, {bool silent = false}) async {
    final generation = _generation[id]! + 1;
    _generation[id] = generation;
    final previous = _states[id]!.data as T?;
    // Las locales no muestran esqueleto: tardan milisegundos y parpadearían.
    if (!silent) _set(id, ShelfState<T>.loading(previous));
    try {
      final data = await fetch();
      if (generation != _generation[id]) return;
      _set(id, ShelfState<T>.data(data));
    } catch (e) {
      if (generation != _generation[id]) return;
      _set(id, ShelfState<T>.error(e, previous));
    }
  }

  void _set(ExploreShelfId id, ShelfState<Object?> state) {
    if (_disposed) return;
    _states[id] = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
