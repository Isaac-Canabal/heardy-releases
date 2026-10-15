import 'dart:io';

import 'package:flutter/services.dart';
import 'package:heardy_yt_stream/heardy_yt_stream.dart';

import 'download_source.dart';

/// Resuelve la URL directa de audio para "Escuchar" sin descargar.
abstract class StreamResolver {
  Future<StreamInfo> resolve(String videoId);
}

/// Resuelve en el propio dispositivo (Android) con el plugin heardy_yt_stream.
class DeviceStreamResolver implements StreamResolver {
  final Future<YtStreamResult> Function(String videoId) _resolve;

  DeviceStreamResolver({Future<YtStreamResult> Function(String videoId)? resolve})
      : _resolve = resolve ?? HeardyYtStream.resolve;

  @override
  Future<StreamInfo> resolve(String videoId) async {
    final YtStreamResult result;
    try {
      result = await _resolve(videoId);
    } on PlatformException catch (e) {
      throw DownloadSourceException(
        e.code == YtStreamErrorCode.unavailable || e.code == YtStreamErrorCode.invalidUrl
            ? DownloadSourceErrorKind.notFound
            : DownloadSourceErrorKind.extraction,
        'Stream en el dispositivo: ${e.code}',
        reason: e.code,
      );
    }
    return streamInfoFromYtStream(videoId, result);
  }
}

StreamResolver defaultStreamResolver() => DeviceStreamResolver();

/// Ruta del yt-dlp.exe utilizable en Windows; la fija el arranque
/// ([configureWindowsStreaming]) y null significa que no hay binario.
String? _windowsYtdlpPath;

void configureWindowsStreaming(String? ytdlpPath) => _windowsYtdlpPath = ytdlpPath;

String? get windowsYtdlpPath => _windowsYtdlpPath;

/// Pura, para tests: Android siempre; Windows sólo si el binario existe.
bool streamingSupportedFor({required bool android, required bool windows, required bool binaryAvailable}) =>
    android || (windows && binaryAvailable);

/// "Escuchar": la URL directa va atada a la IP que la resuelve, así que se
/// resuelve en el propio equipo (plugin en Android, yt-dlp.exe en Windows).
bool get streamingSupported => streamingSupportedFor(
      android: Platform.isAndroid,
      windows: Platform.isWindows,
      binaryAvailable: _windowsYtdlpPath != null,
    );

/// Si tras fallar "Escuchar" tiene sentido ofrecer descargar: no cuando el
/// vídeo no existe o no tiene audio AAC, porque la descarga fallaría igual.
bool offerDownloadAfterStreamFailure(Object error) {
  if (error is DownloadSourceException) {
    return error.kind != DownloadSourceErrorKind.notFound &&
        error.kind != DownloadSourceErrorKind.unsupportedMedia;
  }
  return true;
}

/// Error de reproducción de una pista en streaming. Sólo lleva el id: la URL
/// directa va firmada y atada a la IP, nunca debe salir del handler.
class StreamPlaybackError {
  final String videoId;

  /// En una cola de streaming: la pista falló y la cola siguió con la
  /// siguiente (o se detuvo), en vez de cortarse una reproducción suelta.
  final bool skipped;

  const StreamPlaybackError(this.videoId, {this.skipped = false});
}

/// Id de vídeo a reportar para un error del reproductor, o null si no hay que
/// emitir: el ítem actual no es un stream, no trae id, o ya se reportó ese id.
String? streamErrorVideoIdToEmit(Map<String, dynamic>? extras, String? alreadyEmitted) {
  if (extras == null || extras['isStream'] != true) return null;
  final id = extras['videoId'];
  if (id is! String || id.isEmpty || id == alreadyEmitted) return null;
  return id;
}

RemoteTrack? findStreamErrorTrack(Iterable<RemoteTrack> tracks, String videoId) {
  for (final t in tracks) {
    if (t.id == videoId) return t;
  }
  return null;
}

StreamInfo streamInfoFromYtStream(String videoId, YtStreamResult result) {
  final uri = Uri.tryParse(result.url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw const DownloadSourceException(
      DownloadSourceErrorKind.extraction,
      'Stream en el dispositivo: url inválida',
    );
  }
  return StreamInfo(
    videoId: videoId,
    url: result.url,
    mimeType: result.mimeType,
    expiresAt: result.expiresAt,
    contentLength: result.contentLength,
    durationSeconds: result.durationSeconds ?? 0,
    httpHeaders: result.httpHeaders,
    audioOnly: true,
    bitrateKbps: result.bitrateKbps,
  );
}
