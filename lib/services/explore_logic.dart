/// Lógica pura de Explorar (semillas, mezcla, miniaturas), sin red ni widgets.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../models/explore.dart';
import '../models/followed_artist.dart';
import '../models/song.dart';
import 'download_source.dart';
import 'stream_resolver.dart';

enum ExploreShelfId { recent, artists, radio, charts, newReleases, home, moods, followed, followedReleases }

/// Las estanterías que dependen del país; el resto (historial, radio) no.
const Set<ExploreShelfId> kRegionalShelves = {
  ExploreShelfId.charts,
  ExploreShelfId.newReleases,
  ExploreShelfId.home,
  ExploreShelfId.moods,
};

bool isRegionalShelf(ExploreShelfId id) => kRegionalShelves.contains(id);

/// El orden de la pantalla de arriba abajo. Distinto del enum, que sólo fija
/// los nombres guardados.
const List<ExploreShelfId> kDefaultExploreShelfOrder = [
  ExploreShelfId.moods,
  ExploreShelfId.recent,
  ExploreShelfId.followed,
  ExploreShelfId.followedReleases,
  ExploreShelfId.radio,
  ExploreShelfId.charts,
  ExploreShelfId.newReleases,
  ExploreShelfId.home,
  ExploreShelfId.artists,
];

/// Las que sin acceso remoto se sustituyen, entre todas, por un solo aviso.
const Set<ExploreShelfId> kExploreNetworkShelves = {
  ExploreShelfId.followedReleases,
  ExploreShelfId.radio,
  ExploreShelfId.charts,
  ExploreShelfId.newReleases,
  ExploreShelfId.home,
};

/// Qué ocupa un sitio en Explorar, en orden. Sin acceso remoto ([online] falso)
/// `moods` desaparece y de las de red sólo queda la primera visible: es el
/// lugar del aviso.
List<ExploreShelfId> exploreShelvesToShow({
  required List<ExploreShelfId> order,
  required Set<ExploreShelfId> hidden,
  required bool online,
}) {
  final shelves = <ExploreShelfId>[];
  var hintPlaced = false;
  for (final id in order) {
    if (hidden.contains(id)) continue;
    if (!online) {
      if (id == ExploreShelfId.moods) continue;
      if (kExploreNetworkShelves.contains(id)) {
        if (hintPlaced) continue;
        hintPlaced = true;
      }
    }
    shelves.add(id);
  }
  return shelves;
}

/// Lee los nombres guardados; ignora los desconocidos (p. ej. de otra versión).
Set<ExploreShelfId> parseHiddenShelves(Iterable<String>? names) {
  if (names == null) return {};
  final byName = {for (final id in ExploreShelfId.values) id.name: id};
  return {for (final n in names) ?byName[n]};
}

/// En orden del enum, para que lo guardado no dependa del orden de inserción.
List<String> serializeHiddenShelves(Set<ExploreShelfId> hidden) =>
    [for (final id in ExploreShelfId.values) if (hidden.contains(id)) id.name];

class ExploreCountry {
  final String code;
  final String nameEs;
  final String nameEn;
  const ExploreCountry(this.code, this.nameEs, this.nameEn);

  String nameFor({required bool english}) => english ? nameEn : nameEs;
}

/// Países en los que YouTube Music ofrece listas propias.
const List<ExploreCountry> kExploreCountries = [
  ExploreCountry('AL', 'Albania', 'Albania'),
  ExploreCountry('DZ', 'Argelia', 'Algeria'),
  ExploreCountry('AR', 'Argentina', 'Argentina'),
  ExploreCountry('AM', 'Armenia', 'Armenia'),
  ExploreCountry('AU', 'Australia', 'Australia'),
  ExploreCountry('AT', 'Austria', 'Austria'),
  ExploreCountry('AZ', 'Azerbaiyán', 'Azerbaijan'),
  ExploreCountry('BH', 'Baréin', 'Bahrain'),
  ExploreCountry('BD', 'Bangladés', 'Bangladesh'),
  ExploreCountry('BY', 'Bielorrusia', 'Belarus'),
  ExploreCountry('BE', 'Bélgica', 'Belgium'),
  ExploreCountry('BO', 'Bolivia', 'Bolivia'),
  ExploreCountry('BA', 'Bosnia y Herzegovina', 'Bosnia and Herzegovina'),
  ExploreCountry('BR', 'Brasil', 'Brazil'),
  ExploreCountry('BG', 'Bulgaria', 'Bulgaria'),
  ExploreCountry('KH', 'Camboya', 'Cambodia'),
  ExploreCountry('CA', 'Canadá', 'Canada'),
  ExploreCountry('CL', 'Chile', 'Chile'),
  ExploreCountry('CO', 'Colombia', 'Colombia'),
  ExploreCountry('CR', 'Costa Rica', 'Costa Rica'),
  ExploreCountry('HR', 'Croacia', 'Croatia'),
  ExploreCountry('CY', 'Chipre', 'Cyprus'),
  ExploreCountry('CZ', 'Chequia', 'Czechia'),
  ExploreCountry('DK', 'Dinamarca', 'Denmark'),
  ExploreCountry('DO', 'República Dominicana', 'Dominican Republic'),
  ExploreCountry('EC', 'Ecuador', 'Ecuador'),
  ExploreCountry('EG', 'Egipto', 'Egypt'),
  ExploreCountry('SV', 'El Salvador', 'El Salvador'),
  ExploreCountry('EE', 'Estonia', 'Estonia'),
  ExploreCountry('FI', 'Finlandia', 'Finland'),
  ExploreCountry('FR', 'Francia', 'France'),
  ExploreCountry('GE', 'Georgia', 'Georgia'),
  ExploreCountry('DE', 'Alemania', 'Germany'),
  ExploreCountry('GH', 'Ghana', 'Ghana'),
  ExploreCountry('GR', 'Grecia', 'Greece'),
  ExploreCountry('GT', 'Guatemala', 'Guatemala'),
  ExploreCountry('HN', 'Honduras', 'Honduras'),
  ExploreCountry('HK', 'Hong Kong', 'Hong Kong'),
  ExploreCountry('HU', 'Hungría', 'Hungary'),
  ExploreCountry('IS', 'Islandia', 'Iceland'),
  ExploreCountry('IN', 'India', 'India'),
  ExploreCountry('ID', 'Indonesia', 'Indonesia'),
  ExploreCountry('IQ', 'Irak', 'Iraq'),
  ExploreCountry('IE', 'Irlanda', 'Ireland'),
  ExploreCountry('IL', 'Israel', 'Israel'),
  ExploreCountry('IT', 'Italia', 'Italy'),
  ExploreCountry('JM', 'Jamaica', 'Jamaica'),
  ExploreCountry('JP', 'Japón', 'Japan'),
  ExploreCountry('JO', 'Jordania', 'Jordan'),
  ExploreCountry('KZ', 'Kazajistán', 'Kazakhstan'),
  ExploreCountry('KE', 'Kenia', 'Kenya'),
  ExploreCountry('KW', 'Kuwait', 'Kuwait'),
  ExploreCountry('LA', 'Laos', 'Laos'),
  ExploreCountry('LV', 'Letonia', 'Latvia'),
  ExploreCountry('LB', 'Líbano', 'Lebanon'),
  ExploreCountry('LY', 'Libia', 'Libya'),
  ExploreCountry('LI', 'Liechtenstein', 'Liechtenstein'),
  ExploreCountry('LT', 'Lituania', 'Lithuania'),
  ExploreCountry('LU', 'Luxemburgo', 'Luxembourg'),
  ExploreCountry('MY', 'Malasia', 'Malaysia'),
  ExploreCountry('MT', 'Malta', 'Malta'),
  ExploreCountry('MX', 'México', 'Mexico'),
  ExploreCountry('ME', 'Montenegro', 'Montenegro'),
  ExploreCountry('MA', 'Marruecos', 'Morocco'),
  ExploreCountry('NP', 'Nepal', 'Nepal'),
  ExploreCountry('NL', 'Países Bajos', 'Netherlands'),
  ExploreCountry('NZ', 'Nueva Zelanda', 'New Zealand'),
  ExploreCountry('NI', 'Nicaragua', 'Nicaragua'),
  ExploreCountry('NG', 'Nigeria', 'Nigeria'),
  ExploreCountry('MK', 'Macedonia del Norte', 'North Macedonia'),
  ExploreCountry('NO', 'Noruega', 'Norway'),
  ExploreCountry('OM', 'Omán', 'Oman'),
  ExploreCountry('PK', 'Pakistán', 'Pakistan'),
  ExploreCountry('PA', 'Panamá', 'Panama'),
  ExploreCountry('PG', 'Papúa Nueva Guinea', 'Papua New Guinea'),
  ExploreCountry('PY', 'Paraguay', 'Paraguay'),
  ExploreCountry('PE', 'Perú', 'Peru'),
  ExploreCountry('PH', 'Filipinas', 'Philippines'),
  ExploreCountry('PL', 'Polonia', 'Poland'),
  ExploreCountry('PT', 'Portugal', 'Portugal'),
  ExploreCountry('PR', 'Puerto Rico', 'Puerto Rico'),
  ExploreCountry('QA', 'Catar', 'Qatar'),
  ExploreCountry('RO', 'Rumanía', 'Romania'),
  ExploreCountry('RU', 'Rusia', 'Russia'),
  ExploreCountry('SA', 'Arabia Saudita', 'Saudi Arabia'),
  ExploreCountry('SN', 'Senegal', 'Senegal'),
  ExploreCountry('RS', 'Serbia', 'Serbia'),
  ExploreCountry('SG', 'Singapur', 'Singapore'),
  ExploreCountry('SK', 'Eslovaquia', 'Slovakia'),
  ExploreCountry('SI', 'Eslovenia', 'Slovenia'),
  ExploreCountry('ZA', 'Sudáfrica', 'South Africa'),
  ExploreCountry('KR', 'Corea del Sur', 'South Korea'),
  ExploreCountry('ES', 'España', 'Spain'),
  ExploreCountry('LK', 'Sri Lanka', 'Sri Lanka'),
  ExploreCountry('SE', 'Suecia', 'Sweden'),
  ExploreCountry('CH', 'Suiza', 'Switzerland'),
  ExploreCountry('TW', 'Taiwán', 'Taiwan'),
  ExploreCountry('TZ', 'Tanzania', 'Tanzania'),
  ExploreCountry('TH', 'Tailandia', 'Thailand'),
  ExploreCountry('TN', 'Túnez', 'Tunisia'),
  ExploreCountry('TR', 'Turquía', 'Turkey'),
  ExploreCountry('UG', 'Uganda', 'Uganda'),
  ExploreCountry('UA', 'Ucrania', 'Ukraine'),
  ExploreCountry('AE', 'Emiratos Árabes Unidos', 'United Arab Emirates'),
  ExploreCountry('GB', 'Reino Unido', 'United Kingdom'),
  ExploreCountry('US', 'Estados Unidos', 'United States'),
  ExploreCountry('UY', 'Uruguay', 'Uruguay'),
  ExploreCountry('VE', 'Venezuela', 'Venezuela'),
  ExploreCountry('VN', 'Vietnam', 'Vietnam'),
  ExploreCountry('YE', 'Yemen', 'Yemen'),
  ExploreCountry('ZW', 'Zimbabue', 'Zimbabwe'),
];

/// Código en mayúsculas si está en [kExploreCountries]; si no, null (automático).
String? normalizeExploreCountry(String? code) {
  final c = (code ?? '').trim().toUpperCase();
  return kExploreCountries.any((e) => e.code == c) ? c : null;
}

String foldForSearch(String text) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final buf = StringBuffer();
  for (final ch in text.toLowerCase().trim().split('')) {
    final i = from.indexOf(ch);
    buf.write(i < 0 ? ch : to[i]);
  }
  return buf.toString();
}

List<ExploreCountry> sortedExploreCountries({required bool english}) => [...kExploreCountries]
  ..sort((a, b) => foldForSearch(a.nameFor(english: english)).compareTo(foldForSearch(b.nameFor(english: english))));

/// Países cuyo nombre (sin acentos ni mayúsculas) o código contienen [query].
List<ExploreCountry> filterExploreCountries(String query, {required bool english}) {
  final q = foldForSearch(query);
  final all = sortedExploreCountries(english: english);
  if (q.isEmpty) return all;
  return [
    for (final c in all)
      if (foldForSearch(c.nameFor(english: english)).contains(q) || c.code.toLowerCase() == q) c,
  ];
}

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

final _creditSeparator = RegExp(r'\s*,\s*|\s+&\s+|\s+(?:feat|ft)\.?\s+|\s+x\s+', caseSensitive: false);

/// Artistas acreditados en un campo "artista" (`A, B`, `A & B`, `A feat. B`,
/// `A x B`), sin vacíos ni repetidos.
List<String> splitArtistCredits(String credits) {
  final out = <String>[];
  final seen = <String>{};
  for (final part in credits.split(_creditSeparator)) {
    final name = part.trim();
    if (name.isEmpty || !seen.add(normalizeArtistName(name))) continue;
    out.add(name);
  }
  return out;
}

const _diacritics = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ñ': 'n', 'ç': 'c',
};

/// Minúsculas, sin tildes y con espacios colapsados: lo único que se ignora al
/// comparar nombres de artista.
String normalizeArtistName(String name) {
  final lower = name.toLowerCase();
  final sb = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    sb.write(_diacritics[ch] ?? ch);
  }
  return sb.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Coincidencia exacta (normalizada) con [name]; si no hay, el primer
/// resultado con canal. Sin similitud difusa.
ExploreArtistHit? pickArtistHitForName(String name, List<ExploreArtistHit> hits) {
  final target = normalizeArtistName(name);
  for (final h in hits) {
    if (h.channelId.isNotEmpty && normalizeArtistName(h.name) == target) return h;
  }
  return pickArtistHit(hits);
}

/// Cuántos artistas se consultan por carga de "Novedades": cada uno es una
/// petición real, y el servidor limita a 120 por minuto y 5000 al día.
const int kFollowedReleasesArtistCap = 15;

/// Cuántos lanzamientos muestra la estantería de "Novedades".
const int kFollowedReleasesCap = 30;

/// Los [cap] artistas que se consultan: los seguidos más recientes.
List<FollowedArtist> selectFollowedForReleases(
  Iterable<FollowedArtist> artists, {
  int cap = kFollowedReleasesArtistCap,
}) {
  final following = [for (final a in artists) if (a.isFollowing) a]
    ..sort((a, b) => b.followedAt.compareTo(a.followedAt));
  return following.take(cap).toList();
}

final _yearPattern = RegExp(r'(?<!\d)\d{4}(?!\d)');

/// El año de un lanzamiento, o null: el servidor no da fecha exacta y a veces
/// ni siquiera año.
int? releaseYear(String year) {
  final match = _yearPattern.firstMatch(year);
  return match == null ? null : int.parse(match.group(0)!);
}

/// Los lanzamientos de varios artistas, sin repetir y sin los que no tienen
/// `browseId`: los más nuevos primero, los que no tienen año al final y, a
/// igual año, en el orden recibido (`sort` no es estable, de ahí el índice).
List<ExploreAlbum> mergeFollowedReleases(List<List<ExploreAlbum>> sections, {int cap = kFollowedReleasesCap}) {
  final seen = <String>{};
  final albums = [
    for (final section in sections)
      for (final album in section)
        if (album.browseId.isNotEmpty && seen.add(album.browseId)) album,
  ];
  final order = [
    for (final (index, album) in albums.indexed) (album: album, index: index, year: releaseYear(album.year) ?? -1),
  ]..sort((a, b) {
      final byYear = b.year.compareTo(a.year);
      return byYear != 0 ? byYear : a.index.compareTo(b.index);
    });
  return [for (final e in order.take(cap)) e.album];
}

/// Fallos que no son de un artista sino del servidor o la red: insistir con los
/// demás sólo gastaría el límite de peticiones o haría esperar más.
const Set<DownloadSourceErrorKind> _batchStoppingErrors = {
  DownloadSourceErrorKind.notConfigured,
  DownloadSourceErrorKind.network,
  DownloadSourceErrorKind.unauthorized,
  DownloadSourceErrorKind.quotaExceeded,
  DownloadSourceErrorKind.antiBotBlocked,
  DownloadSourceErrorKind.serviceUnavailable,
  DownloadSourceErrorKind.serverCapacityExhausted,
};

bool stopsFollowedReleasesBatch(Object error) =>
    error is DownloadSourceException && _batchStoppingErrors.contains(error.kind);

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

/// En el teléfono el botón "Añadir" sólo sirve para bajar una pista en streaming.
bool showsPhoneAddButton(MediaItem item) =>
    nowPlayingAddAction(item) == NowPlayingAddAction.downloadStream;
