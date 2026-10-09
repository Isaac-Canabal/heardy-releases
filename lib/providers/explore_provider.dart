import 'package:flutter/foundation.dart';

import '../models/explore.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/explore_logic.dart';
import '../services/statistics_service.dart';

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

enum ExploreShelfId { recent, artists, radio, charts, newReleases, home, moods }

/// Estanterías de Explorar con caché en memoria durante la sesión. Las locales
/// (historial) son instantáneas y no tocan la red; las de red sólo se piden la
/// primera vez (o con [refresh]) y cada una falla por separado.
class ExploreProvider extends ChangeNotifier {
  static const _radioSeedCandidates = 12;

  final DownloadSource _source;
  final DatabaseHelper _db;
  final String? Function() _country;
  final Future<List<Map<String, dynamic>>> Function() _topArtistRows;

  final Map<ExploreShelfId, ShelfState<Object?>> _states = {
    for (final id in ExploreShelfId.values) id: const ShelfState<Object?>.idle(),
  };
  final Map<ExploreShelfId, int> _generation = {for (final id in ExploreShelfId.values) id: 0};
  bool _disposed = false;

  ExploreProvider({
    required DownloadSource source,
    DatabaseHelper? db,
    String? Function()? country,
    Future<List<Map<String, dynamic>>> Function()? topArtistRows,
  })  : _source = source,
        _db = db ?? DatabaseHelper.instance,
        _country = country ?? deviceExploreCountry,
        _topArtistRows = topArtistRows ?? (db ?? DatabaseHelper.instance).getTopArtistsThisMonth;

  ShelfState<List<Song>> get recent => _typed(ExploreShelfId.recent);
  ShelfState<List<String>> get artists => _typed(ExploreShelfId.artists);
  ShelfState<List<RemoteTrack>> get radio => _typed(ExploreShelfId.radio);
  ShelfState<List<ExplorePlaylist>> get charts => _typed(ExploreShelfId.charts);
  ShelfState<List<ExploreAlbum>> get newReleases => _typed(ExploreShelfId.newReleases);
  ShelfState<List<ExploreShelf>> get home => _typed(ExploreShelfId.home);
  ShelfState<List<ExploreMoodSection>> get moods => _typed(ExploreShelfId.moods);

  ShelfState<T> _typed<T>(ExploreShelfId id) {
    final s = _states[id]!;
    return ShelfState<T>._(s.status, s.data as T?, s.error);
  }

  /// Historial local: barato, se vuelve a pedir cada vez que se abre la pestaña.
  Future<void> loadLocal() => Future.wait([
        _run<List<Song>>(ExploreShelfId.recent, () => _db.getRecentlyPlayedSongs(limit: 20), silent: true),
        _run<List<String>>(ExploreShelfId.artists, _fetchArtists, silent: true),
      ]);

  /// Pide las estanterías de red que aún no se han pedido. Las que fallaron se
  /// reintentan sólo con [reloadShelf] o [refresh], para no martillar al
  /// servidor cada vez que se cambia de pestaña.
  Future<void> loadNetwork() => Future.wait([
        for (final id in _networkShelves)
          if (_states[id]!.isIdle) reloadShelf(id),
      ]);

  Future<void> refresh() async {
    await Future.wait([
      loadLocal(),
      for (final id in _networkShelves) reloadShelf(id),
    ]);
  }

  static const _networkShelves = [
    ExploreShelfId.radio,
    ExploreShelfId.charts,
    ExploreShelfId.newReleases,
    ExploreShelfId.home,
    ExploreShelfId.moods,
  ];

  Future<void> reloadShelf(ExploreShelfId id) {
    switch (id) {
      case ExploreShelfId.recent:
      case ExploreShelfId.artists:
        return loadLocal();
      case ExploreShelfId.radio:
        return _run<List<RemoteTrack>>(id, _fetchRadio);
      case ExploreShelfId.charts:
        return _run<List<ExplorePlaylist>>(id, () => _source.exploreCharts(country: _country()));
      case ExploreShelfId.newReleases:
        return _run<List<ExploreAlbum>>(id, () => _source.exploreNewReleases(country: _country()));
      case ExploreShelfId.home:
        return _run<List<ExploreShelf>>(id, () => _source.exploreHome(country: _country()));
      case ExploreShelfId.moods:
        return _run<List<ExploreMoodSection>>(id, () => _source.exploreMoods(country: _country()));
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
