import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'download_source.dart';
import 'input_sanitizer.dart';
import 'ytdlp_binary.dart';

const _youtubeHosts = {'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com'};
final RegExp _playlistIdPattern = RegExp(r'^[A-Za-z0-9_-]{2,64}$');

String _watchUrl(String videoId) => 'https://www.youtube.com/watch?v=$videoId';
String _playlistUrl(String listId) => 'https://www.youtube.com/playlist?list=$listId';

/// Id de vídeo de un id suelto o de una URL de YouTube / YouTube Music; null
/// si no lo es. Al binario sólo llega la URL canónica que se arma con él.
String? youtubeVideoIdFrom(String input) {
  final text = input.trim();
  if (isValidYoutubeVideoId(text)) return text;
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
  } else if (_youtubeHosts.contains(host)) {
    final segments = uri.pathSegments;
    if (segments.length == 1 && segments.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segments.length >= 2 && const {'shorts', 'embed', 'live', 'v'}.contains(segments.first)) {
      id = segments[1];
    }
  }
  return id != null && isValidYoutubeVideoId(id) ? id : null;
}

String? youtubePlaylistIdFrom(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  if (!_youtubeHosts.contains(uri.host.toLowerCase())) return null;
  final id = uri.queryParameters['list'];
  return id != null && _playlistIdPattern.hasMatch(id) ? id : null;
}

const List<String> _commonArguments = [
  '--ignore-config',
  '--no-warnings',
  '--socket-timeout',
  '15',
];

/// Sólo los campos que lee [remoteTrackFromYtdlpInfo]; `-J` serializaría
/// también la lista entera de formatos.
const String ytdlpMetadataTemplate =
    '%(.{id,title,track,artist,creator,uploader,channel,album,duration,thumbnails,webpage_url})j';

/// Sin forzar clientes de YouTube: forzarlos deja sin formatos de audio.
List<String> ytdlpMetadataArguments(String videoId) => [
      ..._commonArguments,
      '--no-playlist',
      '--ignore-no-formats-error',
      '-O',
      ytdlpMetadataTemplate,
      '--',
      _watchUrl(videoId),
    ];

List<String> ytdlpSearchArguments(String query, int limit) => [
      ..._commonArguments,
      '--flat-playlist',
      '-J',
      '--',
      'ytsearch$limit:${sanitizeSearchInput(query)}',
    ];

List<String> ytdlpPlaylistArguments(String listId, int maxEntries) => [
      ..._commonArguments,
      '--yes-playlist',
      '--flat-playlist',
      '--playlist-end',
      '$maxEntries',
      '-J',
      '--',
      _playlistUrl(listId),
    ];

/// El mix `RD<id>` solo se puede listar a través de la URL de reproducción:
/// `playlist?list=RD…` responde "unviewable".
String ytdlpRadioUrl(String seedVideoId) => 'https://www.youtube.com/watch?v=$seedVideoId&list=RD$seedVideoId';

List<String> ytdlpRadioArguments(String seedVideoId, int maxEntries) => [
      ..._commonArguments,
      '--yes-playlist',
      '--flat-playlist',
      '--playlist-end',
      '$maxEntries',
      '-J',
      '--',
      ytdlpRadioUrl(seedVideoId),
    ];

const String ytdlpProgressPrefix = '[heardy] ';

/// El AAC original tal cual (itag 140 o, si falta, otro M4A): sin `-x`, sin
/// postprocesado y sin `--fixup`, que necesitaría ffmpeg y reescribiría el contenedor.
List<String> ytdlpDownloadArguments(String videoId, String destPath) => [
      ..._commonArguments,
      '--no-playlist',
      '-f',
      '140/bestaudio[ext=m4a]',
      '--fixup',
      'never',
      '--no-part',
      '--no-mtime',
      '--force-overwrites',
      '--quiet',
      '--progress',
      '--newline',
      '--progress-template',
      'download:$ytdlpProgressPrefix%(progress.downloaded_bytes)s/%(progress.total_bytes)s/%(progress.total_bytes_estimate)s',
      '-o',
      destPath.replaceAll('%', '%%'),
      '--',
      _watchUrl(videoId),
    ];

({int received, int? total})? parseYtdlpProgressLine(String line) {
  if (!line.startsWith(ytdlpProgressPrefix)) return null;
  final parts = line.substring(ytdlpProgressPrefix.length).trim().split('/');
  if (parts.length != 3) return null;
  int? number(String s) => num.tryParse(s)?.toInt();
  final received = number(parts[0]);
  if (received == null) return null;
  return (received: received, total: number(parts[1]) ?? number(parts[2]));
}

/// [ytdlpErrorFromStderr] más los casos propios de descargar y listar. No
/// incluye el texto crudo.
DownloadSourceException ytdlpClientErrorFromStderr(String stderr) {
  final s = stderr.toLowerCase();
  if (s.contains('requested format is not available')) {
    return const DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, 'yt-dlp local: sin audio M4A');
  }
  if (s.contains('playlist does not exist') || s.contains('playlist type is unviewable')) {
    return const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: playlist no disponible');
  }
  return ytdlpErrorFromStderr(stderr);
}

String _artistOf(Map<String, dynamic> info) {
  final artist = info['artist'] ?? info['creator'];
  if (artist is String && artist.trim().isNotEmpty) return artist.split(',').first.trim();
  var channel = (info['uploader'] ?? info['channel'] ?? '').toString().trim();
  const suffix = ' - Topic';
  if (channel.endsWith(suffix)) channel = channel.substring(0, channel.length - suffix.length).trim();
  return channel.isEmpty ? 'Desconocido' : channel;
}

const _thumbnailRank = {'maxresdefault': 0, 'hq720': 1, 'sddefault': 2, 'hqdefault': 3, 'mqdefault': 4};

/// Igual que `pick_thumbnail` del servidor: JPEG (un `.m4a` no admite WebP
/// como carátula) y por el nombre del tamaño, no por la preferencia de yt-dlp.
String _thumbnailOf(Map<String, dynamic> info, String videoId) {
  final candidates = <String>[];
  final raw = info['thumbnails'];
  if (raw is List) {
    for (final t in raw) {
      if (t is! Map) continue;
      var url = (t['url'] ?? '').toString();
      final path = url.split('?').first;
      if (path.endsWith('.webp') && path.contains('/vi_webp/')) {
        url = '${path.substring(0, path.length - '.webp'.length).replaceFirst('/vi_webp/', '/vi/')}.jpg';
      } else if (!path.endsWith('.jpg') && !path.endsWith('.jpeg')) {
        continue;
      }
      if (url.startsWith('https://') && !candidates.contains(url)) candidates.add(url);
    }
  }
  if (candidates.isEmpty) return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
  int rank(String url) {
    final name = url.split('?').first.split('/').last.split('.').first;
    return (_thumbnailRank[name] ?? _thumbnailRank.length) * 2 + (url.contains('?') ? 1 : 0);
  }

  candidates.sort((a, b) => rank(a).compareTo(rank(b)));
  return candidates.first;
}

/// Lanza si [info] no trae un id de vídeo válido.
RemoteTrack remoteTrackFromYtdlpInfo(Map<String, dynamic> info) {
  final id = (info['id'] ?? '').toString();
  if (!isValidYoutubeVideoId(id)) {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: id inesperado');
  }
  final album = info['album'];
  final title = ((info['track'] ?? info['title']) ?? '').toString().trim();
  final page = info['webpage_url'];
  return RemoteTrack(
    id: id,
    title: title.isEmpty ? id : title,
    artist: _artistOf(info),
    album: album is String && album.trim().isNotEmpty ? album.trim() : null,
    durationSeconds: (info['duration'] as num?)?.round() ?? 0,
    thumbnailUrl: _thumbnailOf(info, id),
    sourceUrl: page is String && page.startsWith('https://') ? page : _watchUrl(id),
  );
}

Map<String, dynamic> _decodeObject(String stdout) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: JSON inválido');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: JSON inesperado');
  }
  return decoded;
}

RemoteTrack metadataFromYtdlpJson(String stdout) => remoteTrackFromYtdlpInfo(_decodeObject(stdout));

bool _isLive(Map<String, dynamic> e) => e['live_status'] == 'is_live' || e['live_status'] == 'is_upcoming';

List<RemoteTrack> _entries(Map<String, dynamic> listing, {required bool requireDuration}) {
  final raw = listing['entries'];
  if (raw is! List) return const [];
  final out = <RemoteTrack>[];
  for (final e in raw) {
    if (e is! Map<String, dynamic> || _isLive(e)) continue;
    if (!isValidYoutubeVideoId((e['id'] ?? '').toString())) continue;
    final track = remoteTrackFromYtdlpInfo(e);
    if (requireDuration && track.durationSeconds <= 0) continue;
    out.add(track);
  }
  return out;
}

/// Sólo vídeos con duración: descarta directos y entradas rotas.
List<RemoteTrack> searchResultsFromYtdlpJson(String stdout) =>
    _entries(_decodeObject(stdout), requireDuration: true);

RemotePlaylist playlistFromYtdlpJson(String listId, String stdout) {
  final listing = _decodeObject(stdout);
  final title = (listing['title'] ?? '').toString().trim();
  return RemotePlaylist(
    id: listId,
    name: title.isEmpty ? 'Playlist' : title,
    sourceUrl: _playlistUrl(listId),
    entries: _entries(listing, requireDuration: false),
  );
}

/// Metadata, búsqueda, playlists y descarga con el yt-dlp.exe local
/// (Windows). Todo corre en este equipo; ningún servidor interviene.
class YtdlpLocalClient {
  final String executablePath;
  final YtdlpProcessRunner _run;
  final YtdlpStreamingRunner _runStreaming;
  final Duration timeout;
  final Duration downloadTimeout;
  // Una playlist de miles de pistas son decenas de páginas de InnerTube:
  // el minuto de [timeout] no alcanza.
  final Duration playlistTimeout;

  static const int maxSearchLimit = 100;
  static const int maxPlaylistEntries = 10000;

  YtdlpLocalClient(
    this.executablePath, {
    YtdlpProcessRunner? runner,
    YtdlpStreamingRunner? streamingRunner,
    this.timeout = const Duration(seconds: 60),
    this.downloadTimeout = const Duration(minutes: 20),
    this.playlistTimeout = const Duration(minutes: 10),
  })  : _run = runner ?? runYtdlpProcess,
        _runStreaming = streamingRunner ?? runYtdlpStreaming;

  /// [urlOrId]: id de vídeo o URL de YouTube / YouTube Music.
  Future<RemoteTrack> metadata(String urlOrId) async {
    final id = youtubeVideoIdFrom(urlOrId);
    if (id == null) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: URL de vídeo inválida');
    }
    return metadataFromYtdlpJson(await _invoke(ytdlpMetadataArguments(id)));
  }

  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    if (sanitizeSearchInput(query).isEmpty) return const [];
    final stdout = await _invoke(ytdlpSearchArguments(query, limit.clamp(1, maxSearchLimit)));
    return searchResultsFromYtdlpJson(stdout);
  }

  /// URL de playlist de YouTube o YouTube Music, hasta [maxEntries] pistas.
  Future<RemotePlaylist> playlist(String url, {int maxEntries = maxPlaylistEntries}) async {
    final listId = youtubePlaylistIdFrom(url);
    if (listId == null) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: URL de playlist inválida');
    }
    final stdout = await _invoke(
      ytdlpPlaylistArguments(listId, maxEntries.clamp(1, maxPlaylistEntries)),
      timeout: playlistTimeout,
    );
    return playlistFromYtdlpJson(listId, stdout);
  }

  /// Mix de YouTube a partir de [seedVideoId]; la primera entrada suele ser la propia semilla.
  Future<RemotePlaylist> radio(String seedVideoId, {int maxEntries = 25}) async {
    if (!isValidYoutubeVideoId(seedVideoId)) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: id inválido');
    }
    final stdout = await _invoke(
      ytdlpRadioArguments(seedVideoId, maxEntries.clamp(1, maxPlaylistEntries)),
      timeout: playlistTimeout,
    );
    return playlistFromYtdlpJson('RD$seedVideoId', stdout);
  }

  /// Descarga el M4A original de [videoId] a [destPath]. Si se cancela, mata
  /// el proceso, borra lo escrito y lanza [DownloadSourceErrorKind.cancelled].
  Future<void> download(
    String videoId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    if (!isValidYoutubeVideoId(videoId)) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: id inválido');
    }
    final cancelled = isCancelled ?? () => false;
    final YtdlpProcessResult result;
    try {
      result = await _runStreaming(
        executablePath,
        ytdlpDownloadArguments(videoId, destPath),
        onStdoutLine: (line) {
          final p = parseYtdlpProgressLine(line);
          if (p != null) onProgress?.call(p.received, p.total);
        },
        isCancelled: cancelled,
        timeout: downloadTimeout,
      );
    } on TimeoutException {
      await _deletePartial(destPath);
      throw const DownloadSourceException(DownloadSourceErrorKind.network, 'yt-dlp local: tiempo agotado');
    } on ProcessException {
      throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: no se pudo ejecutar');
    }
    if (cancelled()) {
      await _deletePartial(destPath);
      throw const DownloadSourceException(DownloadSourceErrorKind.cancelled, 'yt-dlp local: cancelado');
    }
    if (result.exitCode != 0) {
      await _deletePartial(destPath);
      throw ytdlpClientErrorFromStderr(result.stderr);
    }
  }

  Future<String> _invoke(List<String> arguments, {Duration? timeout}) async {
    final YtdlpProcessResult result;
    try {
      result = await _run(executablePath, arguments, timeout ?? this.timeout);
    } on TimeoutException {
      throw const DownloadSourceException(DownloadSourceErrorKind.network, 'yt-dlp local: tiempo agotado');
    } on ProcessException {
      throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: no se pudo ejecutar');
    }
    if (result.exitCode != 0) throw ytdlpClientErrorFromStderr(result.stderr);
    return result.stdout;
  }

  static Future<void> _deletePartial(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
