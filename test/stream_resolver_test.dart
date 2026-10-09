import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/stream_resolver.dart';
import 'package:heardy_yt_stream/heardy_yt_stream.dart';

void main() {
  YtStreamResult result({String url = 'https://rr1.googlevideo.com/videoplayback?itag=140', int? duration = 213}) =>
      YtStreamResult.fromMap({
        'url': url,
        'mimeType': 'audio/mp4',
        'itag': 140,
        'bitrateKbps': 129.5,
        'contentLength': 3456789,
        'expiresAt': 1760000000,
        'durationSeconds': duration,
        'httpHeaders': {'User-Agent': 'com.google.android.youtube/1'},
      });

  group('streamInfoFromYtStream', () {
    test('maps every field and marks the stream audio-only', () {
      final info = streamInfoFromYtStream('dQw4w9WgXcQ', result());

      expect(info.videoId, 'dQw4w9WgXcQ');
      expect(info.url, 'https://rr1.googlevideo.com/videoplayback?itag=140');
      expect(info.mimeType, 'audio/mp4');
      expect(info.bitrateKbps, 129.5);
      expect(info.contentLength, 3456789);
      expect(info.expiresAt, 1760000000);
      expect(info.durationSeconds, 213);
      expect(info.httpHeaders, {'User-Agent': 'com.google.android.youtube/1'});
      expect(info.audioOnly, isTrue);
    });

    test('missing duration becomes 0 so playStream falls back to the track', () {
      expect(streamInfoFromYtStream('dQw4w9WgXcQ', result(duration: null)).durationSeconds, 0);
    });

    test('rejects a non-https url', () {
      expect(
        () => streamInfoFromYtStream('dQw4w9WgXcQ', result(url: 'http://example.com/a')),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.extraction)),
      );
    });
  });

  group('DeviceStreamResolver', () {
    test('returns the mapped StreamInfo', () async {
      final resolver = DeviceStreamResolver(resolve: (_) async => result());
      final info = await resolver.resolve('dQw4w9WgXcQ');
      expect(info.audioOnly, isTrue);
    });

    test('maps plugin error codes to DownloadSourceException kinds', () async {
      Future<DownloadSourceErrorKind> kindFor(String code) async {
        final resolver = DeviceStreamResolver(
          resolve: (_) async => throw PlatformException(code: code, message: 'x'),
        );
        try {
          await resolver.resolve('dQw4w9WgXcQ');
        } on DownloadSourceException catch (e) {
          return e.kind;
        }
        fail('expected DownloadSourceException');
      }

      expect(await kindFor(YtStreamErrorCode.unavailable), DownloadSourceErrorKind.notFound);
      expect(await kindFor(YtStreamErrorCode.extractionFailed), DownloadSourceErrorKind.extraction);
      expect(await kindFor(YtStreamErrorCode.poTokenFailed), DownloadSourceErrorKind.extraction);
    });
  });

  group('offerDownloadAfterStreamFailure', () {
    DownloadSourceException failure(DownloadSourceErrorKind kind) => DownloadSourceException(kind, 'x');

    test('offers the download for transient and unknown failures', () {
      expect(offerDownloadAfterStreamFailure(failure(DownloadSourceErrorKind.extraction)), isTrue);
      expect(offerDownloadAfterStreamFailure(failure(DownloadSourceErrorKind.network)), isTrue);
      expect(offerDownloadAfterStreamFailure(StateError('player failed')), isTrue);
    });

    test('does not offer it when the video itself cannot be downloaded either', () {
      expect(offerDownloadAfterStreamFailure(failure(DownloadSourceErrorKind.notFound)), isFalse);
      expect(offerDownloadAfterStreamFailure(failure(DownloadSourceErrorKind.unsupportedMedia)), isFalse);
    });
  });
}
