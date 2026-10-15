import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'download_source.dart';

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

typedef YtdlpStdoutLine = void Function(String line);

/// Como [YtdlpProcessRunner] pero entrega stdout línea a línea y mata el
/// proceso en cuanto [isCancelled] devuelve true o vence [timeout]. No lanza
/// por cancelación: quien llama la detecta consultando [isCancelled].
typedef YtdlpStreamingRunner = Future<YtdlpProcessResult> Function(
  String executable,
  List<String> arguments, {
  required YtdlpStdoutLine onStdoutLine,
  required bool Function() isCancelled,
  required Duration timeout,
});

Future<YtdlpProcessResult> runYtdlpStreaming(
  String executable,
  List<String> arguments, {
  required YtdlpStdoutLine onStdoutLine,
  required bool Function() isCancelled,
  required Duration timeout,
}) async {
  final process = await Process.start(executable, arguments, runInShell: false);
  final err = process.stderr.transform(utf8.decoder).join();
  final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(onStdoutLine);
  final poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
    if (isCancelled()) process.kill();
  });
  try {
    final code = await process.exitCode.timeout(timeout);
    await out;
    return YtdlpProcessResult(code, '', await err);
  } on TimeoutException {
    process.kill();
    rethrow;
  } finally {
    poll.cancel();
  }
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
