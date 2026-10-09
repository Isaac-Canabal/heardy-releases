/// Lógica pura de Explorar (semillas, mezcla, miniaturas), sin red ni widgets.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../models/explore.dart';
import '../models/song.dart';
import 'download_source.dart';
import 'stream_resolver.dart';

final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// Id de vídeo de una URL de YouTube (`watch?v=`, `youtu.be/`), o null.
String? youtubeVideoId(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    if (uri.path == '/watch') id = uri.queryParameters['v'];
  }
  return id != null && _videoIdPattern.hasMatch(id) ? id : null;
}

/// Hasta [max] ids distintos, en el orden recibido (el de más escuchadas).
List<String> selectRadioSeedIds(Iterable<String?> sourceUrls, {int max = 3}) {
  final ids = <String>[];
  for (final url in sourceUrls) {
    final id = youtubeVideoId(url);
    if (id == null || ids.contains(id)) continue;
    ids.add(id);
    if (ids.length >= max) break;
  }
  return ids;
}

Set<String> localVideoIds(Iterable<String> sourceUrls) =>
    {for (final u in sourceUrls) ?youtubeVideoId(u)};

/// Intercala las listas (una pista de cada semilla por vuelta, para que ninguna
/// domine), sin repetir ids, sin lo que ya está en la biblioteca, hasta [cap].
List<RemoteTrack> mergeRadioTracks(
  List<List<RemoteTrack>> lists, {
  required Set<String> localVideoIds,
  int cap = 20,
}) {
  final seen = <String>{...localVideoIds};
  final out = <RemoteTrack>[];
  final longest = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
  for (var i = 0; i < longest && out.length < cap; i++) {
    for (final list in lists) {
      if (i >= list.length || out.length >= cap) continue;
      final track = list[i];
      if (track.id.isEmpty || !seen.add(track.id)) continue;
      out.add(track);
    }
  }
  return out;
}

final _sizedThumb = RegExp(r'=w(\d+)-h(\d+)');

/// Las pistas de Inicio traen miniaturas de 120 px; en una tarjeta de 140 dp se
/// ven borrosas. Sólo reescribe el patrón `=wN-hN` de googleusercontent.
String upscaleThumbnail(String url, {int size = 400}) {
  final m = _sizedThumb.firstMatch(url);
  if (m == null) return url;
  final w = int.tryParse(m.group(1)!) ?? 0;
  if (w >= size) return url;
  return url.replaceRange(m.start, m.end, '=w$size-h$size');
}

/// Lo que "Descargar todo" encola: las pistas cuyo vídeo aún no está en la
/// biblioteca, una vez cada una aunque la lista las repita.
List<RemoteTrack> tracksToDownload(List<RemoteTrack> tracks, Set<String> localVideoIds) {
  final seen = <String>{...localVideoIds};
  return [
    for (final t in tracks)
      if (t.id.isNotEmpty && seen.add(t.id)) t,
  ];
}

RemoteTrack withUpscaledThumbnail(RemoteTrack t, {int size = 400}) => RemoteTrack(
      id: t.id,
      title: t.title,
      artist: t.artist,
      album: t.album,
      durationSeconds: t.durationSeconds,
      thumbnailUrl: upscaleThumbnail(t.thumbnailUrl, size: size),
      sourceUrl: t.sourceUrl,
    );

/// Parte [items] en columnas de [rows] elementos (la última puede quedar corta).
List<List<T>> chunkColumns<T>(List<T> items, {int rows = 2}) => [
      for (var i = 0; i < items.length; i += rows)
        items.sublist(i, i + rows > items.length ? items.length : i + rows),
    ];

List<ExploreMood> flattenMoods(List<ExploreMoodSection> sections) =>
    [for (final s in sections) ...s.moods];

/// El primer resultado con canal; la búsqueda del servidor ya viene ordenada
/// por relevancia y no comparamos cadenas (el nombre local puede diferir).
ExploreArtistHit? pickArtistHit(List<ExploreArtistHit> hits) {
  for (final h in hits) {
    if (h.channelId.isNotEmpty) return h;
  }
  return null;
}

/// Filtro de la búsqueda de Internet: canciones (yt-dlp `/search`) o uno de
/// los tipos de `/explore/search`.
enum SearchKind { songs, playlists, albums, artists }

/// Tipo de `/explore/search` para [kind]; null para canciones.
ExploreSearchKind? exploreKindFor(SearchKind kind) => switch (kind) {
      SearchKind.songs => null,
      SearchKind.playlists => ExploreSearchKind.playlists,
      SearchKind.albums => ExploreSearchKind.albums,
      SearchKind.artists => ExploreSearchKind.artists,
    };

/// Una respuesta solo vale si no la superó una búsqueda más nueva (el último gana).
bool isCurrentSearch(int responseGeneration, int latestGeneration) => responseGeneration == latestGeneration;

/// Cuánto vale lo ya cargado de las estanterías de red antes de volver a pedirlo
/// al entrar o volver a la app.
const Duration kExploreMaxAge = Duration(minutes: 15);

/// Si toca refrescar las estanterías de red: nunca se refrescaron, o lo hicieron
/// hace [maxAge] o más. Un reloj que retrocedió cuenta como vencido.
bool exploreNeedsRefresh(DateTime? lastRefresh, DateTime now, {Duration maxAge = kExploreMaxAge}) {
  if (lastRefresh == null) return true;
  final age = now.difference(lastRefresh);
  return age.isNegative || age >= maxAge;
}

/// Tope para resolver la URL de audio de una pista. Pasado esto la resolución se
/// da por fallida: sin tope, una WebView o una red colgadas dejaban la tarjeta
/// en "cargando" para siempre y bloqueaban cualquier otra reproducción.
const Duration kStreamResolveTimeout = Duration(seconds: 30);

/// Decora un [StreamResolver] con un tope de tiempo ([TimeoutException] al
/// vencer). Cubre a la vez el "Escuchar" suelto, la cola y la pre-resolución.
class TimeoutStreamResolver implements StreamResolver {
  final StreamResolver _inner;
  final Duration timeout;

  TimeoutStreamResolver(this._inner, {this.timeout = kStreamResolveTimeout});

  @override
  Future<StreamInfo> resolve(String videoId) => _inner.resolve(videoId).timeout(timeout);
}

/// La canción local que corresponde a [videoId] (por `sourceUrl`), ignorando las
/// que faltan en disco; null si no hay ninguna.
Song? pickLocalSongForVideo(String videoId, Iterable<Song> candidates) {
  if (videoId.isEmpty) return null;
  for (final s in candidates) {
    if (s.missing) continue;
    if (youtubeVideoId(s.sourceUrl) == videoId) return s;
  }
  return null;
}

/// La pista remota detrás de un [MediaItem] en streaming (para añadirla/descargarla
/// desde Reproduciendo), o null si no es de streaming o le falta el id de vídeo.
RemoteTrack? remoteTrackFromStreamItem(MediaItem item) {
  if (item.extras?['isStream'] != true) return null;
  final id = item.extras?['videoId'];
  if (id is! String || id.isEmpty) return null;
  return RemoteTrack(
    id: id,
    title: item.title,
    artist: item.artist ?? '',
    album: item.album,
    durationSeconds: item.duration?.inSeconds ?? 0,
    thumbnailUrl: item.artUri?.toString() ?? '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

/// Qué hace "Añadir" en Reproduciendo con [item]: descargar a una playlist
/// (streaming), copiar una canción de la biblioteca, o nada si no hay qué añadir.
enum NowPlayingAddAction { downloadStream, addLocal, none }

NowPlayingAddAction nowPlayingAddAction(MediaItem item) {
  if (item.extras?['isStream'] == true) {
    return remoteTrackFromStreamItem(item) != null ? NowPlayingAddAction.downloadStream : NowPlayingAddAction.none;
  }
  return item.id.isEmpty ? NowPlayingAddAction.none : NowPlayingAddAction.addLocal;
}
