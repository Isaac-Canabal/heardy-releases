import 'package:flutter/services.dart';

/// Audio-only stream resolved on the device. The URL is signed for this
/// device's IP and expires: never persist it or log it.
class YtStreamResult {
  final String url;
  final String mimeType;
  final int itag;
  final double? bitrateKbps;
  final int? contentLength;

  /// Epoch seconds from the URL `expire` parameter, or null.
  final int? expiresAt;
  final int? durationSeconds;
  final Map<String, String> httpHeaders;

  const YtStreamResult({
    required this.url,
    required this.mimeType,
    required this.itag,
    required this.bitrateKbps,
    required this.contentLength,
    required this.expiresAt,
    required this.durationSeconds,
    required this.httpHeaders,
  });

  factory YtStreamResult.fromMap(Map<Object?, Object?> map) {
    final rawHeaders = map['httpHeaders'];
    return YtStreamResult(
      url: (map['url'] ?? '').toString(),
      mimeType: (map['mimeType'] ?? '').toString(),
      itag: (map['itag'] as num?)?.toInt() ?? -1,
      bitrateKbps: (map['bitrateKbps'] as num?)?.toDouble(),
      contentLength: (map['contentLength'] as num?)?.toInt(),
      expiresAt: (map['expiresAt'] as num?)?.toInt(),
      durationSeconds: (map['durationSeconds'] as num?)?.toInt(),
      httpHeaders: rawHeaders is Map
          ? {for (final e in rawHeaders.entries) e.key.toString(): e.value.toString()}
          : const {},
    );
  }
}

/// Error codes of the [PlatformException]s thrown by [HeardyYtStream.resolve].
abstract final class YtStreamErrorCode {
  static const unavailable = 'unavailable';
  static const extractionFailed = 'extraction_failed';
  static const poTokenFailed = 'po_token_failed';
}

class HeardyYtStream {
  static const MethodChannel _channel = MethodChannel('heardy_yt_stream');

  /// Throws [PlatformException] with a [YtStreamErrorCode] code.
  static Future<YtStreamResult> resolve(String videoId) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('resolve', {'videoId': videoId});
    if (map == null) {
      throw PlatformException(code: YtStreamErrorCode.extractionFailed, message: 'empty result');
    }
    return YtStreamResult.fromMap(map);
  }
}
