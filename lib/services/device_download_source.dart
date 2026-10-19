import 'package:flutter/services.dart';
import 'package:heardy_yt_stream/heardy_yt_stream.dart';

import '../models/explore.dart';
import 'app_log.dart';
import 'device_range_downloader.dart';
import 'download_source.dart';
import 'stream_resolver.dart';
import 'ytdlp_local_client.dart';

const int deviceRadioMaxEntries = 25;

/// Plazo de la radio en el dispositivo: pasado, se cae al servidor en vez de dejar la estantería cargando.
const Duration deviceRadioTimeout = Duration(seconds: 25);

String _watchUrl(String id) => 'https://www.youtube.com/watch?v=$id';

/// Traduce el código del plugin a los tipos que la cola sabe interpretar.
DownloadSourceException downloadErrorFromYtStreamCode(String code) {
  switch (code) {
    case YtStreamErrorCode.unavailable:
    case YtStreamErrorCode.invalidUrl:
      return DownloadSourceException(DownloadSourceErrorKind.notFound, 'En el dispositivo: $code', reason: code);
    case YtStreamErrorCode.poTokenFailed:
      return DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, 'En el dispositivo: $code', reason: code);
    default:
      return DownloadSourceException(DownloadSourceErrorKind.extraction, 'En el dispositivo: $code', reason: code);
  }
}

Future<T> _guardPlugin<T>(Future<T> Function() op) async {
  try {
    return await op();
  } on PlatformException catch (e) {
    throw downloadErrorFromYtStreamCode(e.code);
  } on MissingPluginException {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'En el dispositivo: plugin no disponible');
  }
}

RemoteTrack remoteTrackFromYtStream(YtStreamResult result, {required String fallbackId}) {
  final id = result.videoId.isNotEmpty ? result.videoId : fallbackId;
  return RemoteTrack(
    id: id,
    title: result.title.isEmpty ? id : result.title,
    artist: result.uploader.isEmpty ? 'Desconocido' : result.uploader,
    album: null,
    durationSeconds: result.durationSeconds ?? 0,
    thumbnailUrl: result.thumbnailUrl ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
    sourceUrl: _watchUrl(id),
  );
}

RemoteTrack remoteTrackFromYtVideoItem(YtVideoItem item) => RemoteTrack(
      id: item.id,
      title: item.title.isEmpty ? item.id : item.title,
      artist: item.uploader.isEmpty ? 'Desconocido' : item.uploader,
      album: null,
      durationSeconds: item.durationSeconds ?? 0,
      thumbnailUrl: item.thumbnailUrl ?? 'https://i.ytimg.com/vi/${item.id}/hqdefault.jpg',
      sourceUrl: _watchUrl(item.id),
    );

/// De dónde salen metadata, búsqueda, playlists y bytes en este dispositivo.
abstract class DeviceBackend {
  Future<RemoteTrack> track(String urlOrId);
  Future<RemotePlaylist> playlist(String url);

  /// Mix de YouTube sembrado con [seedVideoId] (la semilla puede venir incluida).
  Future<List<RemoteTrack>> radio(String seedVideoId);
  Future<List<RemoteTrack>> search(String query, int limit);
  Future<void> fetchAudio(
    String videoId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  });
}

/// Android: NewPipeExtractor vía `heardy_yt_stream`, bytes por trozos con Range.
class AndroidDeviceBackend implements DeviceBackend {
  final Future<YtStreamResult> Function(String input) _resolve;
  final Future<List<YtVideoItem>> Function(String query, int limit) _search;
  final Future<YtPlaylist> Function(String url) _playlist;
  // Un mix de YouTube no tiene fin: sin tope el plugin pediría páginas hasta reunir el máximo por defecto.
  final Future<YtPlaylist> Function(String url, int maxEntries) _limitedPlaylist;
  final Future<StreamInfo> Function(String videoId) _resolveStream;
  final RangeDownloader _downloader;

  AndroidDeviceBackend({
    Future<YtStreamResult> Function(String input)? resolve,
    Future<List<YtVideoItem>> Function(String query, int limit)? search,
    Future<YtPlaylist> Function(String url)? playlist,
    Future<YtPlaylist> Function(String url, int maxEntries)? limitedPlaylist,
    Future<StreamInfo> Function(String videoId)? resolveStream,
    RangeDownloader? downloader,
  })  : _resolve = resolve ?? HeardyYtStream.resolve,
        _search = search ?? ((q, limit) => HeardyYtStream.search(q, limit: limit)),
        _playlist = playlist ?? ((url) => HeardyYtStream.playlist(url)),
        _limitedPlaylist =
            limitedPlaylist ?? ((url, max) => HeardyYtStream.playlist(url, maxEntries: max)),
        _resolveStream = resolveStream ?? _defaultResolveStream(resolve ?? HeardyYtStream.resolve),
        _downloader = downloader ?? RangeDownloader();

  static Future<StreamInfo> Function(String) _defaultResolveStream(Future<YtStreamResult> Function(String) resolve) =>
      (videoId) async => streamInfoFromYtStream(videoId, await _guardPlugin(() => resolve(videoId)));

  @override
  Future<RemoteTrack> track(String urlOrId) async {
    final result = await _guardPlugin(() => _resolve(urlOrId));
    final fallback = youtubeVideoIdFrom(urlOrId);
    if (result.videoId.isEmpty && fallback == null) {
      throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'En el dispositivo: sin id de vídeo');
    }
    return remoteTrackFromYtStream(result, fallbackId: fallback ?? '');
  }

  RemotePlaylist _asRemotePlaylist(YtPlaylist list) => RemotePlaylist(
        id: list.id,
        name: list.name.isEmpty ? 'Playlist' : list.name,
        sourceUrl: list.url,
        entries: list.entries.map(remoteTrackFromYtVideoItem).toList(),
      );

  @override
  Future<RemotePlaylist> playlist(String url) async => _asRemotePlaylist(await _guardPlugin(() => _playlist(url)));

  @override
  Future<List<RemoteTrack>> radio(String seedVideoId) async =>
      _asRemotePlaylist(await _guardPlugin(() => _limitedPlaylist(ytdlpRadioUrl(seedVideoId), deviceRadioMaxEntries)))
          .entries;

  @override
  Future<List<RemoteTrack>> search(String query, int limit) async {
    final items = await _guardPlugin(() => _search(query, limit));
    return items.where((i) => (i.durationSeconds ?? 0) > 0).map(remoteTrackFromYtVideoItem).toList();
  }

  @override
  Future<void> fetchAudio(
    String videoId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    // La URL va firmada para esta IP y caduca: siempre una resolución nueva
    // justo antes de bajar, nunca una guardada de la fase de metadata.
    final info = await _resolveStream(videoId);
    final mime = info.mimeType.toLowerCase();
    if (!mime.contains('mp4') && !mime.contains('m4a')) {
      throw const DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, 'En el dispositivo: sin audio M4A');
    }
    await _downloader.download(
      info,
      destPath,
      reresolve: () => _resolveStream(videoId),
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
}

/// Windows: yt-dlp.exe empaquetado.
class WindowsDeviceBackend implements DeviceBackend {
  final YtdlpLocalClient _client;

  WindowsDeviceBackend(this._client);

  @override
  Future<RemoteTrack> track(String urlOrId) => _client.metadata(urlOrId);

  @override
  Future<RemotePlaylist> playlist(String url) => _client.playlist(url);

  @override
  Future<List<RemoteTrack>> radio(String seedVideoId) async =>
      (await _client.radio(seedVideoId, maxEntries: deviceRadioMaxEntries)).entries;

  @override
  Future<List<RemoteTrack>> search(String query, int limit) => _client.search(query, limit: limit);

  @override
  Future<void> fetchAudio(
    String videoId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) =>
      _client.download(videoId, destPath, onProgress: onProgress, isCancelled: isCancelled);
}

/// Plataformas sin extractor (Linux/macOS, o Windows sin yt-dlp.exe).
class UnavailableDeviceBackend implements DeviceBackend {
  const UnavailableDeviceBackend();

  static const _error = DownloadSourceException(
    DownloadSourceErrorKind.extraction,
    'Descargar en este dispositivo no está disponible en esta plataforma',
  );

  @override
  Future<RemoteTrack> track(String urlOrId) => Future.error(_error);

  @override
  Future<RemotePlaylist> playlist(String url) => Future.error(_error);

  @override
  Future<List<RemoteTrack>> radio(String seedVideoId) => Future.error(_error);

  @override
  Future<List<RemoteTrack>> search(String query, int limit) => Future.error(_error);

  @override
  Future<void> fetchAudio(
    String videoId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) =>
      Future.error(_error);
}

/// Descargas que corren enteras en el dispositivo. Explorar sigue en el
/// servidor y se delega en [_explore].
class DeviceDownloadSource implements DownloadSource {
  final DeviceBackend _backend;
  final DownloadSource _explore;
  final Duration _radioTimeout;

  DeviceDownloadSource({
    required DeviceBackend backend,
    required DownloadSource explore,
    Duration radioTimeout = deviceRadioTimeout,
  })  : _backend = backend,
        _explore = explore,
        _radioTimeout = radioTimeout;

  @override
  Future<RemoteTrack> resolve(String url) => _backend.track(url);

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) => _backend.playlist(url);

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) => _backend.search(query, limit);

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) =>
      _backend.fetchAudio(trackId, destPath, onProgress: onProgress, isCancelled: isCancelled);

  @override
  Future<DownloadSourceStatus> probe() async => const DownloadSourceStatus(
        reachable: true,
        authenticated: true,
        version: null,
        potProviderReachable: true,
        detail: 'Las descargas se hacen en este dispositivo',
      );

  @override
  Future<List<ExploreShelf>> exploreHome({String? country, bool fresh = false}) =>
      _explore.exploreHome(country: country, fresh: fresh);

  @override
  Future<List<ExplorePlaylist>> exploreCharts({String? country, bool fresh = false}) =>
      _explore.exploreCharts(country: country, fresh: fresh);

  @override
  Future<List<ExploreAlbum>> exploreNewReleases({String? country, bool fresh = false}) =>
      _explore.exploreNewReleases(country: country, fresh: fresh);

  @override
  Future<List<ExploreMoodSection>> exploreMoods({String? country, bool fresh = false}) =>
      _explore.exploreMoods(country: country, fresh: fresh);

  @override
  Future<List<ExplorePlaylist>> exploreMood(String params, {String? country}) =>
      _explore.exploreMood(params, country: country);

  @override
  Future<ExploreCollection> explorePlaylist(String playlistId) => _explore.explorePlaylist(playlistId);

  @override
  Future<ExploreCollection> exploreAlbum(String browseId) => _explore.exploreAlbum(browseId);

  @override
  Future<List<RemoteTrack>> exploreRadio(String seedVideoId) async {
    // La IP del servidor está bloqueada por YouTube en este endpoint: primero
    // se intenta con la IP del propio usuario y el servidor queda de respaldo.
    try {
      final seen = <String>{seedVideoId};
      final tracks = <RemoteTrack>[];
      for (final t in await _backend.radio(seedVideoId).timeout(_radioTimeout)) {
        if (t.durationSeconds <= 0 || !seen.add(t.id)) continue;
        tracks.add(t);
        if (tracks.length >= deviceRadioMaxEntries) break;
      }
      if (tracks.isNotEmpty) return tracks;
    } catch (e) {
      appLog('radio en el dispositivo falló: ${e.runtimeType}');
    }
    return _explore.exploreRadio(seedVideoId);
  }

  @override
  Future<ExploreArtist> exploreArtist(String channelId) => _explore.exploreArtist(channelId);

  @override
  Future<List<ExploreArtistHit>> exploreArtistSearch(String query) => _explore.exploreArtistSearch(query);

  @override
  Future<ExploreSearchResults> exploreSearch(String query, ExploreSearchKind kind, {String? country}) =>
      _explore.exploreSearch(query, kind, country: country);
}
