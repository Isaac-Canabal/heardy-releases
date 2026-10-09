import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'download_source.dart';
import 'stream_resolver.dart';

/// Ejecuta un proceso con lista de argumentos (sin shell) y devuelve su salida.
/// Lanza [TimeoutException] si excede [timeout], tras matar el proceso.
typedef YtdlpProcessRunner = Future<YtdlpProcessResult> Function(
  String executable,
  List<String> arguments,
  Duration timeout,
);

class YtdlpProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const YtdlpProcessResult(this.exitCode, this.stdout, this.stderr);
}

Future<YtdlpProcessResult> runYtdlpProcess(String executable, List<String> arguments, Duration timeout) async {
  final process = await Process.start(executable, arguments, runInShell: false);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return YtdlpProcessResult(code, await out, await err);
  } on TimeoutException {
    process.kill();
    rethrow;
  }
}

final RegExp _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool isValidYoutubeVideoId(String id) => _videoIdPattern.hasMatch(id);

/// Sólo los campos que lee [streamInfoFromYtdlpJson]: `--dump-json` serializaba
/// toda la lista de formatos (~650 KB) y no aporta nada.
const String ytdlpOutputTemplate =
    '%(.{url,ext,duration,filesize,filesize_approx,abr,acodec,vcodec,http_headers})j';

/// Argumentos de yt-dlp para resolver sólo el audio. Sin cookies ni PO token:
/// los clientes por defecto de yt-dlp bastan hoy, sin runtime JS.
List<String> ytdlpResolveArguments(String videoId) => [
      '--ignore-config',
      '--no-warnings',
      '--no-playlist',
      '--socket-timeout',
      '15',
      '--no-check-formats',
      '-f',
      'bestaudio[ext=m4a][protocol=https]/bestaudio[protocol=https]',
      '-O',
      ytdlpOutputTemplate,
      '--',
      'https://www.youtube.com/watch?v=$videoId',
    ];

/// Convierte la salida de `yt-dlp -O` (ver [ytdlpOutputTemplate]) en [StreamInfo]. Falla en voz
/// alta si el JSON no trae lo imprescindible.
StreamInfo streamInfoFromYtdlpJson(String videoId, String stdout) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: JSON inválido');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: JSON inesperado');
  }
  final url = decoded['url'];
  final uri = url is String ? Uri.tryParse(url) : null;
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: url inválida');
  }
  final acodec = decoded['acodec'];
  final vcodec = decoded['vcodec'];
  if (acodec == 'none' || (vcodec is String && vcodec != 'none')) {
    throw const DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, 'yt-dlp local: sin audio puro');
  }
  final headers = <String, String>{};
  final rawHeaders = decoded['http_headers'];
  if (rawHeaders is Map) {
    rawHeaders.forEach((k, v) {
      if (k is String && v is String) headers[k] = v;
    });
  }
  final ext = decoded['ext'];
  final num? length = decoded['filesize'] is num ? decoded['filesize'] as num : decoded['filesize_approx'] as num?;
  final num? duration = decoded['duration'] as num?;
  final num? abr = decoded['abr'] as num?;
  return StreamInfo(
    videoId: videoId,
    url: url as String,
    mimeType: ext == 'webm' ? 'audio/webm' : 'audio/mp4',
    expiresAt: int.tryParse(uri.queryParameters['expire'] ?? ''),
    contentLength: length?.toInt(),
    durationSeconds: duration?.round() ?? 0,
    httpHeaders: headers,
    audioOnly: true,
    bitrateKbps: abr?.toDouble(),
  );
}

/// Traduce el stderr de yt-dlp a la excepción del seam. No incluye el texto
/// crudo (puede traer URLs firmadas).
DownloadSourceException ytdlpErrorFromStderr(String stderr) {
  final s = stderr.toLowerCase();
  if (s.contains('not a bot') || s.contains('http error 429') || s.contains('http error 403')) {
    return const DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, 'yt-dlp local: bloqueado por YouTube');
  }
  if (s.contains('video unavailable') ||
      s.contains('private video') ||
      s.contains('has been removed') ||
      s.contains('confirm your age') ||
      s.contains('members-only') ||
      s.contains('this video is not available')) {
    return const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: vídeo no disponible');
  }
  if (s.contains('requested format is not available')) {
    return const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: formato no disponible');
  }
  if (s.contains('unable to download') ||
      s.contains('timed out') ||
      s.contains('getaddrinfo') ||
      s.contains('connection') ||
      s.contains('network is unreachable')) {
    return const DownloadSourceException(DownloadSourceErrorKind.network, 'yt-dlp local: sin red');
  }
  return const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: fallo de extracción');
}

/// "Escuchar" en Windows: yt-dlp.exe embebido, ejecutado en este equipo para
/// que la URL firmada quede atada a la IP que luego reproduce.
class WindowsYtdlpStreamResolver implements StreamResolver {
  final String executablePath;
  final YtdlpProcessRunner _run;
  final Duration timeout;

  WindowsYtdlpStreamResolver(
    this.executablePath, {
    YtdlpProcessRunner? runner,
    this.timeout = const Duration(seconds: 25),
  }) : _run = runner ?? runYtdlpProcess;

  @override
  Future<StreamInfo> resolve(String videoId) async {
    if (!isValidYoutubeVideoId(videoId)) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'yt-dlp local: id inválido');
    }
    final YtdlpProcessResult result;
    try {
      result = await _run(executablePath, ytdlpResolveArguments(videoId), timeout);
    } on TimeoutException {
      throw const DownloadSourceException(DownloadSourceErrorKind.network, 'yt-dlp local: tiempo agotado');
    } on ProcessException {
      throw const DownloadSourceException(DownloadSourceErrorKind.extraction, 'yt-dlp local: no se pudo ejecutar');
    }
    if (result.exitCode != 0) throw ytdlpErrorFromStderr(result.stderr);
    return streamInfoFromYtdlpJson(videoId, result.stdout);
  }
}

/// Margen antes de `expire` en que una URL en caché deja de reutilizarse.
const int streamCacheSafetySeconds = 300;

/// Vida de una entrada sin `expire` declarado.
const Duration streamCacheFallbackTtl = Duration(minutes: 30);

/// Decora un [StreamResolver] con una caché en memoria por videoId (las URLs
/// duran horas) y une las resoluciones simultáneas del mismo id. Los fallos no
/// se guardan.
class CachingStreamResolver implements StreamResolver {
  final StreamResolver _inner;
  final DateTime Function() _now;
  final Map<String, ({StreamInfo info, DateTime validUntil})> _cache = {};
  final Map<String, Future<StreamInfo>> _inFlight = {};

  CachingStreamResolver(this._inner, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  @override
  Future<StreamInfo> resolve(String videoId) {
    final hit = _cache[videoId];
    if (hit != null) {
      if (_now().isBefore(hit.validUntil)) return Future.value(hit.info);
      _cache.remove(videoId);
    }
    return _inFlight[videoId] ??= _fetch(videoId);
  }

  Future<StreamInfo> _fetch(String videoId) async {
    try {
      final info = await _inner.resolve(videoId);
      _cache[videoId] = (info: info, validUntil: streamCacheDeadline(info, _now()));
      return info;
    } finally {
      _inFlight.remove(videoId);
    }
  }
}

/// Hasta cuándo se puede reutilizar [info] resuelta en [now].
DateTime streamCacheDeadline(StreamInfo info, DateTime now) {
  final expires = info.expiresAt;
  if (expires == null) return now.add(streamCacheFallbackTtl);
  return DateTime.fromMillisecondsSinceEpoch(expires * 1000, isUtc: true)
      .subtract(const Duration(seconds: streamCacheSafetySeconds));
}

/// Localiza el yt-dlp.exe empaquetado (`<exe>/yt-dlp/yt-dlp.exe`) y lo copia a
/// una carpeta escribible del usuario, porque {app} suele estar en Program
/// Files y ahí `yt-dlp -U` no podría reemplazarse. Devuelve null si no existe.
Future<String?> prepareWindowsYtdlp({String? exeDir, String? localAppData}) async {
  if (!Platform.isWindows && exeDir == null) return null;
  final dir = exeDir ?? File(Platform.resolvedExecutable).parent.path;
  final bundled = File('$dir\\yt-dlp\\yt-dlp.exe');
  if (!await bundled.exists()) return null;
  final base = localAppData ?? Platform.environment['LOCALAPPDATA'];
  if (base == null || base.isEmpty) return bundled.path;
  final working = File('$base\\Heardy\\yt-dlp\\yt-dlp.exe');
  try {
    if (!await working.exists() || (await working.lastModified()).isBefore(await bundled.lastModified())) {
      await working.parent.create(recursive: true);
      await bundled.copy(working.path);
    }
    return working.path;
  } catch (e) {
    appLog('yt-dlp local: no se pudo preparar la copia de trabajo (${e.runtimeType})');
    return bundled.path;
  }
}

/// `yt-dlp -U` como mucho una vez al día; silencioso si falla.
Future<void> maybeUpdateYtdlp(
  String executablePath, {
  YtdlpProcessRunner? runner,
  DateTime? now,
  Duration minInterval = const Duration(days: 1),
}) async {
  try {
    final marker = File('$executablePath.last_update_check');
    final clock = now ?? DateTime.now();
    if (await marker.exists() && clock.difference(await marker.lastModified()) < minInterval) return;
    await marker.writeAsString(clock.toIso8601String());
    await marker.setLastModified(clock);
    await (runner ?? runYtdlpProcess)(executablePath, const ['-U'], const Duration(minutes: 2));
  } catch (e) {
    appLog('yt-dlp local: actualización omitida (${e.runtimeType})');
  }
}
