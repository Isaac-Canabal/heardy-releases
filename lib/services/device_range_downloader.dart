import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'download_source.dart';

const int deviceChunkBytes = 8 * 1024 * 1024;

class ContentRange {
  final int start;
  final int end;

  /// Null cuando el servidor responde `/*`.
  final int? total;

  const ContentRange(this.start, this.end, this.total);
}

final RegExp _contentRangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$');

ContentRange? parseContentRange(String? header) {
  if (header == null) return null;
  final m = _contentRangePattern.firstMatch(header.trim());
  if (m == null) return null;
  final start = int.parse(m.group(1)!);
  final end = int.parse(m.group(2)!);
  if (end < start) return null;
  return ContentRange(start, end, m.group(3) == '*' ? null : int.parse(m.group(3)!));
}

/// Último byte (inclusive) a pedir en el trozo que empieza en [offset].
int nextChunkEnd(int offset, int? total, int chunkBytes) {
  final end = offset + chunkBytes - 1;
  return total == null ? end : end.clamp(offset, total - 1);
}

/// Un 206 solo sirve si empieza donde se pidió, no se pasa de lo pedido y su
/// total concuerda con el que ya se conocía: si no, los bytes no encajan.
bool contentRangeIsCoherent(
  ContentRange range, {
  required int expectedStart,
  required int requestedEnd,
  required int? knownTotal,
}) {
  final total = range.total;
  if (total == null) return false;
  if (range.start != expectedStart || range.end > requestedEnd) return false;
  if (range.end >= total) return false;
  return knownTotal == null || knownTotal == total;
}

Duration defaultChunkBackoff(int failures) =>
    Duration(milliseconds: (500 * (1 << (failures - 1).clamp(0, 3))).clamp(500, 4000));

/// La URL caducó o está atada a otra IP: hay que resolver de nuevo.
class _UrlRejected implements Exception {
  const _UrlRejected();
}

/// Fallo pasajero de un trozo: se reintenta desde el último byte guardado.
class _ChunkFailed implements Exception {
  final String reason;
  const _ChunkFailed(this.reason);
}

/// Descarga un stream de audio de YouTube por trozos con `Range`, el mismo
/// patrón que usa el reproductor: sin Range las URL de googlevideo se
/// estrangulan. Escribe en [destPath] (temporal de la app, no medios del
/// usuario) y reanuda desde lo que ya haya en disco.
class RangeDownloader {
  final http.Client Function() clientFactory;
  final int chunkBytes;
  final int maxChunkRetries;
  final int maxReresolves;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration Function(int failures) backoff;

  RangeDownloader({
    http.Client Function()? clientFactory,
    this.chunkBytes = deviceChunkBytes,
    this.maxChunkRetries = 3,
    this.maxReresolves = 2,
    this.headerTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 30),
    this.backoff = defaultChunkBackoff,
  }) : clientFactory = clientFactory ?? (() => http.Client());

  /// [initial] debe estar recién resuelto. [reresolve] se llama si la URL
  /// deja de servir a mitad (403/410); tras [maxReresolves] veces se rinde.
  Future<void> download(
    StreamInfo initial,
    String destPath, {
    required Future<StreamInfo> Function() reresolve,
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    final file = File(destPath);
    final client = clientFactory();
    RandomAccessFile? raf;
    try {
      await file.parent.create(recursive: true);
      var info = initial;
      var total = info.contentLength;
      var offset = 0;
      if (await file.exists()) {
        offset = await file.length();
        if (total != null && offset > total) {
          await file.delete();
          offset = 0;
        }
      }
      var out = await file.open(mode: FileMode.append);
      raf = out;

      var rejected = 0;
      var failures = 0;
      while (total == null || offset < total) {
        _throwIfCancelled(isCancelled);
        final end = nextChunkEnd(offset, total, chunkBytes);
        try {
          final result = await _fetchChunk(
            client,
            info,
            offset,
            end,
            total,
            out,
            (n) {
              offset += n;
              onProgress?.call(offset, total);
            },
            isCancelled,
          );
          total = result.total;
          if (result.written > 0) failures = 0;
          if (result.short) throw const _ChunkFailed('cuerpo incompleto');
        } on _UrlRejected {
          if (rejected >= maxReresolves) {
            throw const DownloadSourceException(
              DownloadSourceErrorKind.antiBotBlocked,
              'La URL de audio fue rechazada tras volver a resolverla',
              statusCode: 403,
            );
          }
          rejected++;
          info = await reresolve();
          final length = info.contentLength;
          if (length != null && total != null && length != total) {
            await out.close();
            raf = null;
            await file.delete();
            out = await file.open(mode: FileMode.append);
            raf = out;
            offset = 0;
            total = length;
          } else {
            total ??= length;
          }
        } on _ChunkFailed catch (e) {
          failures++;
          appLog('DeviceDownload: trozo fallido (${e.reason}) $failures/$maxChunkRetries');
          if (failures > maxChunkRetries) {
            throw DownloadSourceException(DownloadSourceErrorKind.network, 'Descarga interrumpida: ${e.reason}');
          }
          await Future<void>.delayed(backoff(failures));
        } on TimeoutException {
          failures++;
          appLog('DeviceDownload: tiempo agotado $failures/$maxChunkRetries');
          if (failures > maxChunkRetries) {
            throw const DownloadSourceException(DownloadSourceErrorKind.network, 'Descarga interrumpida: tiempo agotado');
          }
          await Future<void>.delayed(backoff(failures));
        } on http.ClientException catch (e) {
          failures++;
          appLog('DeviceDownload: fallo de transporte (${e.runtimeType}) $failures/$maxChunkRetries');
          if (failures > maxChunkRetries) {
            throw const DownloadSourceException(DownloadSourceErrorKind.network, 'Descarga interrumpida: sin conexión');
          }
          await Future<void>.delayed(backoff(failures));
        } on SocketException {
          failures++;
          appLog('DeviceDownload: socket caído $failures/$maxChunkRetries');
          if (failures > maxChunkRetries) {
            throw const DownloadSourceException(DownloadSourceErrorKind.network, 'Descarga interrumpida: sin conexión');
          }
          await Future<void>.delayed(backoff(failures));
        } on HandshakeException {
          failures++;
          if (failures > maxChunkRetries) {
            throw const DownloadSourceException(DownloadSourceErrorKind.network, 'Descarga interrumpida: TLS');
          }
          await Future<void>.delayed(backoff(failures));
        }
      }

      final size = await out.length();
      if (size != total) {
        throw DownloadSourceException(
          DownloadSourceErrorKind.network,
          'Tamaño final incorrecto: $size de $total bytes',
        );
      }
      await out.close();
      raf = null;
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<({int written, int? total, bool short})> _fetchChunk(
    http.Client client,
    StreamInfo info,
    int offset,
    int end,
    int? knownTotal,
    RandomAccessFile raf,
    void Function(int bytes) onWritten,
    CancellationCheck? isCancelled,
  ) async {
    final request = http.Request('GET', Uri.parse(info.url))
      ..headers.addAll(info.httpHeaders)
      ..headers['Range'] = 'bytes=$offset-$end';
    final response = await client.send(request).timeout(headerTimeout);
    final status = response.statusCode;
    if (status == 401 || status == 403 || status == 410) {
      await response.stream.drain<void>().timeout(headerTimeout, onTimeout: () {});
      throw const _UrlRejected();
    }
    if (status != 206) {
      await response.stream.drain<void>().timeout(headerTimeout, onTimeout: () {});
      throw _ChunkFailed('HTTP $status');
    }
    final range = parseContentRange(response.headers['content-range']);
    if (range == null ||
        !contentRangeIsCoherent(range, expectedStart: offset, requestedEnd: end, knownTotal: knownTotal)) {
      await response.stream.drain<void>().timeout(headerTimeout, onTimeout: () {});
      throw const _ChunkFailed('Content-Range incoherente');
    }

    final expected = range.end - range.start + 1;
    var written = 0;
    await for (final data in response.stream.timeout(idleTimeout)) {
      _throwIfCancelled(isCancelled);
      final take = written + data.length > expected ? expected - written : data.length;
      await raf.writeFrom(data, 0, take);
      written += take;
      onWritten(take);
      if (written >= expected) break;
    }
    return (written: written, total: range.total, short: written < expected);
  }

  void _throwIfCancelled(CancellationCheck? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const DownloadSourceException(DownloadSourceErrorKind.cancelled, 'Descarga cancelada');
    }
  }
}
