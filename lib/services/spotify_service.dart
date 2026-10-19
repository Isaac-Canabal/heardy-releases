import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'friendly_error.dart';
import 'app_log.dart';

/// Metadata for a single Spotify track, extracted from the embed page.
class SpotifyTrackInfo {
  final String title;
  final String artist;
  final int durationMs;
  final String? thumbnailUrl;
  final String? spotifyUri;

  const SpotifyTrackInfo({
    required this.title,
    required this.artist,
    required this.durationMs,
    this.thumbnailUrl,
    this.spotifyUri,
  });

  int get durationSeconds => (durationMs / 1000).round();

  @override
  String toString() => 'SpotifyTrackInfo($artist - $title, ${durationMs}ms)';
}

/// Result of analyzing a Spotify URL.
class SpotifyAnalysisResult {
  final String type; // 'track', 'album', 'playlist'
  final String name; // Collection name (or track title)
  final String? subtitle; // e.g. album artist
  final String? thumbnailUrl;
  final List<SpotifyTrackInfo> tracks;

  const SpotifyAnalysisResult({
    required this.type,
    required this.name,
    this.subtitle,
    this.thumbnailUrl,
    required this.tracks,
  });

  bool get isSingleTrack => type == 'track';
  bool get isCollection => type == 'album' || type == 'playlist';
}

/// Una página de pistas de playlist de la API interna del reproductor web
/// (`pathfinder`), la única vía sin clave propia para pasar de las 100 pistas
/// que trae la página embed.
class SpotifyPlaylistPage {
  final List<SpotifyTrackInfo> tracks;

  /// Ítems de la página, contando los no reproducibles que se descartaron:
  /// es lo que avanza el `offset`.
  final int itemCount;
  final int totalCount;

  const SpotifyPlaylistPage({required this.tracks, required this.itemCount, required this.totalCount});
}

/// Lee la respuesta de `fetchPlaylist`. Devuelve null si el formato no es el
/// esperado (Spotify lo cambia sin aviso).
SpotifyPlaylistPage? parsePathfinderPlaylistPage(Object? json) {
  if (json is! Map) return null;
  final data = json['data'];
  final playlist = data is Map ? data['playlistV2'] : null;
  final content = playlist is Map ? playlist['content'] : null;
  if (content is! Map) return null;
  final items = content['items'];
  final total = content['totalCount'];
  if (items is! List || total is! int) return null;

  final tracks = <SpotifyTrackInfo>[];
  for (final item in items) {
    final wrapper = item is Map ? item['itemV2'] : null;
    final track = wrapper is Map ? wrapper['data'] : null;
    if (track is! Map || track['__typename'] != 'Track') continue;
    final playability = track['playability'];
    if (playability is Map && playability['playable'] == false) continue;
    final name = track['name'];
    final duration = track['trackDuration'];
    final ms = duration is Map ? duration['totalMilliseconds'] : null;
    if (name is! String || ms is! int) continue;

    final artistItems = track['artists'] is Map ? (track['artists'] as Map)['items'] : null;
    final artists = [
      if (artistItems is List)
        for (final a in artistItems)
          if (a is Map && a['profile'] is Map && (a['profile'] as Map)['name'] is String)
            (a['profile'] as Map)['name'] as String,
    ];
    tracks.add(SpotifyTrackInfo(
      title: name,
      artist: artists.isEmpty ? 'Artista desconocido' : artists.join(', '),
      durationMs: ms,
      thumbnailUrl: _pathfinderCover(track['albumOfTrack']),
      spotifyUri: track['uri'] is String ? track['uri'] as String : null,
    ));
  }
  return SpotifyPlaylistPage(tracks: tracks, itemCount: items.length, totalCount: total);
}

String? _pathfinderCover(Object? album) {
  final cover = album is Map ? album['coverArt'] : null;
  final sources = cover is Map ? cover['sources'] : null;
  if (sources is! List) return null;
  String? best;
  var bestHeight = -1;
  for (final s in sources) {
    if (s is! Map || s['url'] is! String) continue;
    final h = s['height'] is int ? s['height'] as int : 0;
    if (h > bestHeight) {
      bestHeight = h;
      best = s['url'] as String;
    }
  }
  return best;
}

/// Extracts music metadata from Spotify embed pages.
///
/// This works by fetching the server-rendered HTML of
/// `open.spotify.com/embed/{type}/{id}` and parsing the `__NEXT_DATA__`
/// JSON block that Next.js injects into the page. This contains full
/// metadata (title, artist, duration, cover art) without requiring
/// any API keys or authentication.
class SpotifyService {
  SpotifyService();

  static final RegExp _spotifyUrlPattern = RegExp(
    r'(https?://)?(open\.spotify\.com|spotify\.link)/(intl-[a-z]{2}/)?(track|album|playlist)/([a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final RegExp _shortLinkPattern = RegExp(
    r'(https?://)?spotify\.link/[a-zA-Z0-9]+',
    caseSensitive: false,
  );

  /// Returns true if [url] looks like a Spotify link.
  static bool isSpotifyUrl(String url) {
    return _spotifyUrlPattern.hasMatch(url) || _shortLinkPattern.hasMatch(url);
  }

  /// Parses a Spotify URL and returns the type and ID.
  /// Returns null if the URL is not a valid Spotify URL.
  static ({String type, String id})? parseSpotifyUrl(String url) {
    final match = _spotifyUrlPattern.firstMatch(url);
    if (match == null) return null;
    return (type: match.group(4)!, id: match.group(5)!);
  }

  /// Techo de tiempo por petición HTTP a Spotify.
  ///
  /// `HttpClient.connectionTimeout` sólo acota el ESTABLECIMIENTO de la conexión:
  /// una vez abierta, `request.close()` y la lectura del cuerpo
  /// (`transform(...).join()`, `drain()`) esperan indefinidamente si Spotify
  /// acepta la conexión y luego no responde. Como todo este servicio corre detrás
  /// del botón "Analizar enlace", un cuelgue dejaba `_isAnalyzing` en `true` para
  /// siempre en `add_from_youtube_screen`, que es lo que deshabilita el campo de
  /// texto y el botón — la pantalla entera quedaba inutilizable hasta reiniciar
  /// la app, sin mensaje de error.
  static const Duration _requestTimeout = Duration(seconds: 20);

  Future<T> _withTimeout<T>(Future<T> future, String what) {
    return future.timeout(
      _requestTimeout,
      onTimeout: () => throw TimeoutException(
        '$what no respondió en ${_requestTimeout.inSeconds}s',
      ),
    );
  }

  /// Cuántos saltos de redirección se siguen antes de rendirse.
  ///
  /// `resolveShortLink` se llama a sí misma con el `location` recibido y no tenía
  /// ningún límite: una cadena de redirecciones cíclica (A→B→A) la dejaba
  /// recursando y haciendo peticiones de red para siempre.
  static const int _maxRedirects = 5;

  /// Resolves a short `spotify.link/xxx` URL to its full `open.spotify.com` URL.
  Future<String> resolveShortLink(String url, {int depth = 0}) async {
    if (depth >= _maxRedirects) {
      appLog('Spotify short link: demasiadas redirecciones ($depth), me quedo con $url');
      return url;
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = false;
      final response = await _withTimeout(
        request.close(),
        'La resolución del enlace corto',
      );
      await _withTimeout(response.drain<void>(), 'La resolución del enlace corto');

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null && location.contains('open.spotify.com')) {
          return location;
        }
      }
      // Try following more redirects manually
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null) {
          return resolveShortLink(location, depth: depth + 1);
        }
      }
      return url;
    } finally {
      client.close();
    }
  }

  /// Analyzes a Spotify URL (track, album, or playlist) and returns
  /// structured metadata for all tracks.
  Future<SpotifyAnalysisResult> analyze(String url) async {
    // Resolve short links first
    String resolvedUrl = url;
    if (_shortLinkPattern.hasMatch(url) && !url.contains('open.spotify.com')) {
      resolvedUrl = await resolveShortLink(url);
    }

    final parsed = parseSpotifyUrl(resolvedUrl);
    if (parsed == null) {
      throw const FriendlyException('Ese enlace de Spotify no es válido. Comprueba que lo copiaste completo.', 'E-SP-URL');
    }

    final embedUrl = 'https://open.spotify.com/embed/${parsed.type}/${parsed.id}';
    final nextData = await _fetchNextData(embedUrl);

    final entity = nextData['props']?['pageProps']?['state']?['data']?['entity'];
    if (entity == null) {
      throw const FriendlyException(
        'No se pudieron obtener los datos de Spotify. El enlace puede ser privado o no válido.',
        'E-SP-DATA',
      );
    }

    switch (parsed.type) {
      case 'track':
        return _parseTrack(entity);
      case 'album':
        return await _parseCollection(entity, parsed.type);
      case 'playlist':
        final token = nextData['props']?['pageProps']?['state']?['settings']?['session']?['accessToken'];
        return await _parseCollection(
          entity,
          parsed.type,
          playlistId: parsed.id,
          accessToken: token is String ? token : null,
        );
      default:
        throw const FriendlyException('Ese tipo de enlace de Spotify no se puede descargar todavía.', 'E-SP-TYPE');
    }
  }

  /// Fetches the embed page HTML and extracts the `__NEXT_DATA__` JSON.
  Future<Map<String, dynamic>> _fetchNextData(String embedUrl) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(embedUrl));
      request.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      request.headers.set('Accept', 'text/html,application/xhtml+xml');
      request.headers.set('Accept-Language', 'en-US,en;q=0.9');

      final response = await _withTimeout(
        request.close(),
        'La petición a Spotify',
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        appLog('SpotifyService: respuesta ${response.statusCode} al pedir $embedUrl');
        throw FriendlyException(
          'No se pudo acceder a Spotify. Comprueba que el enlace sea correcto y público.',
          'E-SP-${response.statusCode}',
        );
      }

      final html = await _withTimeout(
        response.transform(utf8.decoder).join(),
        'La lectura de la página de Spotify',
      );

      // Extract __NEXT_DATA__ JSON from the HTML
      final regex = RegExp(
          r'<script\s+id="__NEXT_DATA__"\s+type="application/json">\s*(\{.*?\})\s*</script>',
          dotAll: true);
      final match = regex.firstMatch(html);
      if (match == null) {
        throw const FriendlyException(
          'No se encontraron datos en la página de Spotify. '
          'Es posible que Spotify haya cambiado su formato.',
          'E-SP-FMT',
        );
      }

      return jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Parses a single track entity from __NEXT_DATA__.
  SpotifyAnalysisResult _parseTrack(Map<String, dynamic> entity) {
    final title = entity['title'] as String? ?? entity['name'] as String? ?? 'Sin título';
    final artists = _extractArtists(entity);
    final durationMs = entity['duration'] as int? ?? 0;
    final thumbnailUrl = _extractBestThumbnail(entity);

    final track = SpotifyTrackInfo(
      title: title,
      artist: artists,
      durationMs: durationMs,
      thumbnailUrl: thumbnailUrl,
      spotifyUri: entity['uri'] as String?,
    );

    return SpotifyAnalysisResult(
      type: 'track',
      name: title,
      subtitle: artists,
      thumbnailUrl: thumbnailUrl,
      tracks: [track],
    );
  }

  /// Parses an album or playlist entity with its trackList from __NEXT_DATA__.
  Future<SpotifyAnalysisResult> _parseCollection(
    Map<String, dynamic> entity,
    String type, {
    String? playlistId,
    String? accessToken,
  }) async {
    final name = entity['title'] as String? ?? entity['name'] as String? ?? 'Sin nombre';
    final subtitle = entity['subtitle'] as String?;
    final thumbnailUrl = _extractBestThumbnail(entity);

    final trackList = entity['trackList'] as List<dynamic>? ?? [];
    final tracks = <SpotifyTrackInfo>[];

    for (final trackData in trackList) {
      if (trackData is! Map<String, dynamic>) continue;
      
      final trackTitle = trackData['title'] as String? ?? 'Sin título';
      final trackArtist = trackData['subtitle'] as String? ?? 
                           _extractArtists(trackData);
      final trackDuration = trackData['duration'] as int? ?? 0;
      final trackUri = trackData['uri'] as String?;

      // Skip unplayable tracks
      final isPlayable = trackData['isPlayable'] as bool? ?? true;
      if (!isPlayable) continue;

      tracks.add(SpotifyTrackInfo(
        title: trackTitle,
        artist: trackArtist,
        durationMs: trackDuration,
        thumbnailUrl: thumbnailUrl, // Fallback to playlist/album cover
        spotifyUri: trackUri,
      ));
    }

    // For playlists, fetch track-specific thumbnails via oEmbed in parallel
    if (type == 'playlist' && tracks.isNotEmpty) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      try {
        final futures = tracks.map((track) async {
          try {
            final trackId = track.spotifyUri?.split(':').last;
            if (trackId != null) {
              final oembedUrl = 'https://open.spotify.com/oembed?url=https://open.spotify.com/track/$trackId';
              final request = await client.getUrl(Uri.parse(oembedUrl));
              final response = await _withTimeout(
                request.close(),
                'La miniatura de "${track.title}"',
              );
              if (response.statusCode == 200) {
                final body = await _withTimeout(
                  response.transform(utf8.decoder).join(),
                  'La miniatura de "${track.title}"',
                );
                final data = jsonDecode(body) as Map<String, dynamic>;
                final trackThumbnail = data['thumbnail_url'] as String?;
                if (trackThumbnail != null && trackThumbnail.isNotEmpty) {
                  return SpotifyTrackInfo(
                    title: track.title,
                    artist: track.artist,
                    durationMs: track.durationMs,
                    thumbnailUrl: trackThumbnail,
                    spotifyUri: track.spotifyUri,
                  );
                }
              }
            }
          } catch (e) {
            appLog('Error fetching oEmbed for track "${track.title}": $e');
          }
          return track; // fallback to original playlist cover
        }).toList();

        final resolvedTracks = await Future.wait(futures);
        tracks.clear();
        tracks.addAll(resolvedTracks);
      } finally {
        client.close();
      }
    }

    if (playlistId != null && accessToken != null && trackList.length >= _embedTrackLimit) {
      tracks.addAll(await _fetchRemainingPlaylistTracks(playlistId, accessToken, trackList.length));
    }

    return SpotifyAnalysisResult(
      type: type,
      name: name,
      subtitle: subtitle,
      thumbnailUrl: thumbnailUrl,
      tracks: tracks,
    );
  }

  /// La página embed corta las playlists en 100 pistas.
  static const int _embedTrackLimit = 100;
  static const int _maxPlaylistTracks = 10000;
  static const int _pathfinderPageSize = 100;

  /// Hash de la consulta persistida `fetchPlaylist` del reproductor web. No
  /// es una API pública: cuando Spotify despliega una versión nueva el hash
  /// puede dejar de valer, y entonces la playlist se queda en las primeras
  /// 100 pistas en vez de fallar.
  static const String _fetchPlaylistHash = '19ff1327c29e99c208c86d7a9d8f1929cfdf3d3202a0ff4253c821f1901aa94d';

  /// Pide a `pathfinder`, con el token anónimo de la página embed, las pistas
  /// desde [offset]. Ante cualquier fallo se queda con lo que ya tenía.
  Future<List<SpotifyTrackInfo>> _fetchRemainingPlaylistTracks(String playlistId, String token, int offset) async {
    final result = <SpotifyTrackInfo>[];
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      var total = _maxPlaylistTracks;
      while (offset < total && offset < _maxPlaylistTracks) {
        final request = await client.postUrl(Uri.parse('https://api-partner.spotify.com/pathfinder/v2/query'));
        request.headers.set('Authorization', 'Bearer $token');
        request.headers.set('App-Platform', 'WebPlayer');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'operationName': 'fetchPlaylist',
          'variables': {
            'uri': 'spotify:playlist:$playlistId',
            'offset': offset,
            'limit': _pathfinderPageSize,
            'enableWatchFeedEntrypoint': false,
          },
          'extensions': {
            'persistedQuery': {'version': 1, 'sha256Hash': _fetchPlaylistHash},
          },
        }));
        final response = await _withTimeout(request.close(), 'La lista de Spotify');
        final body = await _withTimeout(response.transform(utf8.decoder).join(), 'La lista de Spotify');
        if (response.statusCode != 200) {
          appLog('SpotifyService: pathfinder respondió ${response.statusCode} en offset $offset');
          break;
        }
        final page = parsePathfinderPlaylistPage(jsonDecode(body));
        if (page == null || page.itemCount == 0) {
          appLog('SpotifyService: formato inesperado de pathfinder en offset $offset');
          break;
        }
        result.addAll(page.tracks);
        total = page.totalCount;
        offset += page.itemCount;
      }
    } catch (e) {
      appLog('SpotifyService: no se pudieron leer más pistas (${e.runtimeType})');
    } finally {
      client.close();
    }
    return result;
  }

  /// Extracts artist name(s) from the entity data.
  String _extractArtists(Map<String, dynamic> entity) {
    final artists = entity['artists'] as List<dynamic>?;
    if (artists != null && artists.isNotEmpty) {
      return artists
          .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
          .where((name) => name.isNotEmpty)
          .join(', ');
    }
    // Fallback to subtitle field (used in album/playlist trackList items)
    return entity['subtitle'] as String? ?? 'Artista desconocido';
  }

  /// Extracts the highest quality thumbnail URL from the visual identity data.
  String? _extractBestThumbnail(Map<String, dynamic> entity) {
    final visualIdentity = entity['visualIdentity'] as Map<String, dynamic>?;
    if (visualIdentity == null) return null;

    final images = visualIdentity['image'] as List<dynamic>?;
    if (images == null || images.isEmpty) return null;

    // Sort by resolution (highest first) and return the best one
    final sortedImages = List<Map<String, dynamic>>.from(images)
      ..sort((a, b) =>
          (b['maxHeight'] as int? ?? 0).compareTo(a['maxHeight'] as int? ?? 0));

    return sortedImages.first['url'] as String?;
  }
}
