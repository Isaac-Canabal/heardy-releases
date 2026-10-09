import 'dart:ui' show PlatformDispatcher;

import '../services/download_source.dart';

class ExplorePlaylist {
  final String playlistId;
  final String title;
  final String subtitle;
  final String thumbnailUrl;

  const ExplorePlaylist({
    required this.playlistId,
    required this.title,
    this.subtitle = '',
    this.thumbnailUrl = '',
  });

  factory ExplorePlaylist.fromJson(Map<String, dynamic> json) => ExplorePlaylist(
        playlistId: _str(json['playlistId']),
        title: _str(json['title']),
        subtitle: _str(json['subtitle']),
        thumbnailUrl: _str(json['thumbnailUrl']),
      );
}

class ExploreAlbum {
  final String browseId;
  final String title;
  final String artist;
  final String year;
  final String thumbnailUrl;

  const ExploreAlbum({
    required this.browseId,
    required this.title,
    this.artist = '',
    this.year = '',
    this.thumbnailUrl = '',
  });

  factory ExploreAlbum.fromJson(Map<String, dynamic> json) => ExploreAlbum(
        browseId: _str(json['browseId']),
        title: _str(json['title']),
        artist: _str(json['artist']),
        year: _str(json['year']),
        thumbnailUrl: _str(json['thumbnailUrl']),
      );
}

enum ExploreShelfKind { playlists, albums, tracks }

/// Una estantería de Inicio: sólo una de las tres listas viene llena, según [kind].
class ExploreShelf {
  final String title;
  final ExploreShelfKind kind;
  final List<ExplorePlaylist> playlists;
  final List<ExploreAlbum> albums;
  final List<RemoteTrack> tracks;

  const ExploreShelf({
    required this.title,
    required this.kind,
    this.playlists = const [],
    this.albums = const [],
    this.tracks = const [],
  });

  int get length => switch (kind) {
        ExploreShelfKind.playlists => playlists.length,
        ExploreShelfKind.albums => albums.length,
        ExploreShelfKind.tracks => tracks.length,
      };
}

class ExploreMood {
  final String title;
  final String params;

  const ExploreMood({required this.title, required this.params});
}

class ExploreMoodSection {
  final String title;
  final List<ExploreMood> moods;

  const ExploreMoodSection({required this.title, required this.moods});
}

/// Playlist o álbum de YouTube Music ya expandido.
class ExploreCollection {
  final String title;
  final String thumbnailUrl;
  final List<RemoteTrack> tracks;

  const ExploreCollection({required this.title, required this.thumbnailUrl, required this.tracks});
}

class ExploreRelatedArtist {
  final String channelId;
  final String name;
  final String thumbnailUrl;

  const ExploreRelatedArtist({required this.channelId, required this.name, this.thumbnailUrl = ''});

  factory ExploreRelatedArtist.fromJson(Map<String, dynamic> json) => ExploreRelatedArtist(
        channelId: _str(json['channelId']),
        name: _str(json['name']),
        thumbnailUrl: _str(json['thumbnailUrl']),
      );
}

/// Resultado de buscar un artista por nombre.
class ExploreArtistHit {
  final String channelId;
  final String name;
  final String thumbnailUrl;
  final String subscribers;

  const ExploreArtistHit({
    required this.channelId,
    required this.name,
    this.thumbnailUrl = '',
    this.subscribers = '',
  });

  factory ExploreArtistHit.fromJson(Map<String, dynamic> json) => ExploreArtistHit(
        channelId: _str(json['channelId']),
        name: _str(json['name']),
        thumbnailUrl: _str(json['thumbnailUrl']),
        subscribers: _str(json['subscribers']),
      );
}

class ExploreArtist {
  final String name;
  final String description;
  final String thumbnailUrl;
  final String subscribers;
  final List<RemoteTrack> topSongs;
  final List<ExploreAlbum> albums;
  final List<ExploreAlbum> singles;
  final List<RemoteTrack> videos;
  final List<ExploreRelatedArtist> related;

  const ExploreArtist({
    required this.name,
    this.description = '',
    this.thumbnailUrl = '',
    this.subscribers = '',
    this.topSongs = const [],
    this.albums = const [],
    this.singles = const [],
    this.videos = const [],
    this.related = const [],
  });
}

String _str(Object? v) => (v ?? '').toString();

Never _malformed(String what) => throw DownloadSourceException(
      DownloadSourceErrorKind.extraction,
      'Respuesta de Explorar mal formada: $what',
    );

Map<String, dynamic> _asMap(Object? json, String what) {
  if (json is Map<String, dynamic>) return json;
  _malformed(what);
}

List<Map<String, dynamic>> _items(Object? raw, String what) {
  if (raw == null) return const [];
  if (raw is! List) _malformed(what);
  return raw.whereType<Map<String, dynamic>>().toList();
}

List<RemoteTrack> _tracks(Object? raw, String what) =>
    _items(raw, what).map(RemoteTrack.fromJson).where((t) => t.id.isNotEmpty).toList();

List<ExploreShelf> parseExploreHome(Object? json) {
  final shelves = <ExploreShelf>[];
  for (final s in _items(_asMap(json, 'home')['shelves'], 'shelves')) {
    final title = _str(s['title']);
    final items = _items(s['items'], 'items');
    ExploreShelf? shelf;
    switch (s['kind']) {
      case 'playlists':
        final l = items.map(ExplorePlaylist.fromJson).where((p) => p.playlistId.isNotEmpty).toList();
        shelf = ExploreShelf(title: title, kind: ExploreShelfKind.playlists, playlists: l);
      case 'albums':
        final l = items.map(ExploreAlbum.fromJson).where((a) => a.browseId.isNotEmpty).toList();
        shelf = ExploreShelf(title: title, kind: ExploreShelfKind.albums, albums: l);
      case 'tracks':
        shelf = ExploreShelf(title: title, kind: ExploreShelfKind.tracks, tracks: _tracks(items, 'tracks'));
    }
    if (shelf != null && shelf.length > 0) shelves.add(shelf);
  }
  return shelves;
}

List<ExplorePlaylist> parseExplorePlaylists(Object? json) =>
    _items(_asMap(json, 'playlists')['playlists'], 'playlists')
        .map(ExplorePlaylist.fromJson)
        .where((p) => p.playlistId.isNotEmpty)
        .toList();

List<ExploreAlbum> parseExploreAlbums(Object? json) =>
    _items(_asMap(json, 'albums')['albums'], 'albums')
        .map(ExploreAlbum.fromJson)
        .where((a) => a.browseId.isNotEmpty)
        .toList();

List<ExploreMoodSection> parseExploreMoods(Object? json) {
  final out = <ExploreMoodSection>[];
  for (final s in _items(_asMap(json, 'moods')['sections'], 'sections')) {
    final moods = _items(s['moods'], 'moods')
        .map((m) => ExploreMood(title: _str(m['title']), params: _str(m['params'])))
        .where((m) => m.params.isNotEmpty)
        .toList();
    if (moods.isNotEmpty) out.add(ExploreMoodSection(title: _str(s['title']), moods: moods));
  }
  return out;
}

ExploreCollection parseExploreCollection(Object? json) {
  final m = _asMap(json, 'colección');
  return ExploreCollection(
    title: _str(m['title']),
    thumbnailUrl: _str(m['thumbnailUrl']),
    tracks: _tracks(m['tracks'], 'tracks'),
  );
}

List<RemoteTrack> parseExploreRadio(Object? json) => _tracks(_asMap(json, 'radio')['tracks'], 'tracks');

ExploreArtist parseExploreArtist(Object? json) {
  final m = _asMap(json, 'artista');
  final name = _str(m['name']);
  if (name.isEmpty) _malformed('artista sin nombre');
  return ExploreArtist(
    name: name,
    description: _str(m['description']),
    thumbnailUrl: _str(m['thumbnailUrl']),
    subscribers: _str(m['subscribers']),
    topSongs: _tracks(m['topSongs'], 'topSongs'),
    albums: _items(m['albums'], 'albums').map(ExploreAlbum.fromJson).where((a) => a.browseId.isNotEmpty).toList(),
    singles: _items(m['singles'], 'singles').map(ExploreAlbum.fromJson).where((a) => a.browseId.isNotEmpty).toList(),
    videos: _tracks(m['videos'], 'videos'),
    related: _items(m['related'], 'related')
        .map(ExploreRelatedArtist.fromJson)
        .where((a) => a.channelId.isNotEmpty)
        .toList(),
  );
}

List<ExploreArtistHit> parseExploreArtistSearch(Object? json) =>
    _items(_asMap(json, 'artistas')['artists'], 'artists')
        .map(ExploreArtistHit.fromJson)
        .where((a) => a.channelId.isNotEmpty)
        .toList();

/// Qué busca `/explore/search`; `name` es el valor de `type` del servidor.
enum ExploreSearchKind { playlists, albums, artists }

/// Resultado de una búsqueda filtrada: solo la lista del tipo pedido viene llena.
class ExploreSearchResults {
  final List<ExplorePlaylist> playlists;
  final List<ExploreAlbum> albums;
  final List<ExploreArtistHit> artists;

  const ExploreSearchResults({this.playlists = const [], this.albums = const [], this.artists = const []});

  int get length => playlists.length + albums.length + artists.length;
  bool get isEmpty => length == 0;
}

ExploreSearchResults parseExploreSearch(ExploreSearchKind kind, Object? json) => switch (kind) {
      ExploreSearchKind.playlists => ExploreSearchResults(playlists: parseExplorePlaylists(json)),
      ExploreSearchKind.albums => ExploreSearchResults(albums: parseExploreAlbums(json)),
      ExploreSearchKind.artists => ExploreSearchResults(artists: parseExploreArtistSearch(json)),
    };

/// Código de país de 2 letras en mayúsculas, o null (el servidor usa el suyo).
String? exploreCountryFromLocale(String? countryCode) {
  final c = (countryCode ?? '').trim();
  return c.length == 2 ? c.toUpperCase() : null;
}

String? deviceExploreCountry() => exploreCountryFromLocale(PlatformDispatcher.instance.locale.countryCode);
