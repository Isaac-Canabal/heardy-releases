import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/stream_resolver.dart';
import 'package:heardy/services/ytdlp_local_stream_resolver.dart';

String _json({Map<String, Object?> extra = const {}}) => jsonEncode({
      'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&expire=1791571591',
      'ext': 'm4a',
      'acodec': 'mp4a.40.2',
      'vcodec': 'none',
      'abr': 129.5,
      'filesize': 3449447,
      'duration': 212.6,
      'http_headers': {'User-Agent': 'UA', 'Accept': '*/*'},
      ...extra,
    });

void main() {
  const id = 'dQw4w9WgXcQ';

  group('isValidYoutubeVideoId', () {
    test('acepta 11 caracteres válidos y rechaza el resto', () {
      expect(isValidYoutubeVideoId(id), isTrue);
      expect(isValidYoutubeVideoId('a-b_c1234Zz'), isTrue);
      expect(isValidYoutubeVideoId('short'), isFalse);
      expect(isValidYoutubeVideoId('dQw4w9WgXcQ '), isFalse);
      expect(isValidYoutubeVideoId('dQw4w9WgXc;'), isFalse);
      expect(isValidYoutubeVideoId('--exec=calc'), isFalse);
      expect(isValidYoutubeVideoId('dQw4w9WgXcQ\n'), isFalse);
    });
  });

  group('streamInfoFromYtdlpJson', () {
    test('mapea los campos', () {
      final info = streamInfoFromYtdlpJson(id, _json());
      expect(info.videoId, id);
      expect(info.mimeType, 'audio/mp4');
      expect(info.expiresAt, 1791571591);
      expect(info.contentLength, 3449447);
      expect(info.durationSeconds, 213);
      expect(info.bitrateKbps, 129.5);
      expect(info.httpHeaders['User-Agent'], 'UA');
      expect(info.audioOnly, isTrue);
    });

    test('webm se marca audio/webm', () {
      expect(streamInfoFromYtdlpJson(id, _json(extra: {'ext': 'webm'})).mimeType, 'audio/webm');
    });

    test('JSON roto, url no https o formato con vídeo fallan', () {
      expect(() => streamInfoFromYtdlpJson(id, 'no json'), throwsA(isA<DownloadSourceException>()));
      expect(() => streamInfoFromYtdlpJson(id, '[]'), throwsA(isA<DownloadSourceException>()));
      expect(() => streamInfoFromYtdlpJson(id, _json(extra: {'url': 'http://x.test/a'})),
          throwsA(isA<DownloadSourceException>()));
      expect(
        () => streamInfoFromYtdlpJson(id, _json(extra: {'vcodec': 'avc1'})),
        throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.unsupportedMedia)),
      );
    });
  });

  group('ytdlpErrorFromStderr', () {
    DownloadSourceErrorKind kind(String s) => ytdlpErrorFromStderr(s).kind;

    test('mapea a los kinds del seam', () {
      expect(kind('ERROR: Video unavailable'), DownloadSourceErrorKind.notFound);
      expect(kind("Sign in to confirm you're not a bot"), DownloadSourceErrorKind.antiBotBlocked);
      expect(kind('ERROR: Unable to download webpage'), DownloadSourceErrorKind.network);
      expect(kind('algo raro'), DownloadSourceErrorKind.extraction);
    });

    test('no filtra el texto crudo', () {
      expect(ytdlpErrorFromStderr('https://x.googlevideo.com/?sig=SECRET').message, isNot(contains('SECRET')));
    });
  });

  group('WindowsYtdlpStreamResolver', () {
    test('invoca el proceso con argumentos y rechaza el id inválido sin ejecutar', () async {
      List<String>? seen;
      final resolver = WindowsYtdlpStreamResolver('yt-dlp.exe', runner: (exe, args, t) async {
        seen = args;
        return YtdlpProcessResult(0, _json(), '');
      });
      final info = await resolver.resolve(id);
      expect(info.url, startsWith('https://'));
      expect(seen!.last, 'https://www.youtube.com/watch?v=$id');
      expect(seen!, contains('--'));

      var called = false;
      final guarded = WindowsYtdlpStreamResolver('yt-dlp.exe', runner: (e, a, t) async {
        called = true;
        return YtdlpProcessResult(0, _json(), '');
      });
      await expectLater(guarded.resolve('x; calc'), throwsA(isA<DownloadSourceException>()));
      expect(called, isFalse);
    });

    test('código de salida distinto de 0 mapea el error', () async {
      final resolver = WindowsYtdlpStreamResolver('y',
          runner: (e, a, t) async => const YtdlpProcessResult(1, '', 'ERROR: Private video'));
      await expectLater(
        resolver.resolve(id),
        throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.notFound)),
      );
    });

    test('timeout y binario ausente se traducen', () async {
      final slow = WindowsYtdlpStreamResolver('y', runner: (e, a, t) async => throw TimeoutException('x'));
      await expectLater(
        slow.resolve(id),
        throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.network)),
      );
      final missing = WindowsYtdlpStreamResolver('y', runner: (e, a, t) async => throw const ProcessException('y', []));
      await expectLater(missing.resolve(id), throwsA(isA<DownloadSourceException>()));
    });
  });

  group('streamingSupportedFor', () {
    test('Windows sólo con binario', () {
      expect(streamingSupportedFor(android: false, windows: true, binaryAvailable: false), isFalse);
      expect(streamingSupportedFor(android: false, windows: true, binaryAvailable: true), isTrue);
      expect(streamingSupportedFor(android: true, windows: false, binaryAvailable: false), isTrue);
    });
  });

  group('maybeUpdateYtdlp', () {
    test('corre -U una vez al día', () async {
      final dir = await Directory.systemTemp.createTemp('ytdlp_upd');
      addTearDown(() => dir.delete(recursive: true));
      final exe = '${dir.path}\\yt-dlp.exe';
      var runs = 0;
      Future<YtdlpProcessResult> runner(String e, List<String> a, Duration t) async {
        runs++;
        expect(a, ['-U']);
        return const YtdlpProcessResult(0, '', '');
      }

      final t0 = DateTime.now();
      await maybeUpdateYtdlp(exe, runner: runner, now: t0);
      await maybeUpdateYtdlp(exe, runner: runner, now: t0.add(const Duration(hours: 2)));
      expect(runs, 1);
      await maybeUpdateYtdlp(exe, runner: runner, now: t0.add(const Duration(days: 2)));
      expect(runs, 2);
    });

    test('es silencioso si el runner falla', () async {
      final dir = await Directory.systemTemp.createTemp('ytdlp_upd2');
      addTearDown(() => dir.delete(recursive: true));
      await maybeUpdateYtdlp('${dir.path}\\y.exe', runner: (e, a, t) async => throw const ProcessException('y', []));
    });
  });

  group('ytdlpResolveArguments', () {
    test('pide sólo los campos necesarios y no usa --dump-json', () {
      final a = ytdlpResolveArguments(id);
      expect(a, containsAll(['--no-playlist', '--no-check-formats', '-O', ytdlpOutputTemplate]));
      expect(a, isNot(contains('--dump-json')));
      expect(a.sublist(a.length - 2), ['--', 'https://www.youtube.com/watch?v=$id']);
    });
  });

  group('CachingStreamResolver', () {
    StreamInfo info(String vid, int? expires) => StreamInfo(
          videoId: vid,
          url: 'https://x.googlevideo.com/$vid',
          mimeType: 'audio/mp4',
          expiresAt: expires,
          contentLength: null,
          durationSeconds: 10,
          httpHeaders: const {},
          audioOnly: true,
          bitrateKbps: null,
        );

    test('reutiliza hasta el margen previo a expire y luego vuelve a resolver', () async {
      var clock = DateTime.utc(2026, 1, 1);
      final expires = clock.add(const Duration(hours: 6)).millisecondsSinceEpoch ~/ 1000;
      var calls = 0;
      final r = CachingStreamResolver(_FakeResolver((v) async => info(v, expires + calls++ * 0)),
          now: () => clock);
      await r.resolve(id);
      await r.resolve(id);
      expect(calls, 1);
      clock = clock.add(const Duration(hours: 6) - const Duration(seconds: streamCacheSafetySeconds - 1));
      await r.resolve(id);
      expect(calls, 2);
    });

    test('une resoluciones simultáneas y no cachea fallos', () async {
      var calls = 0;
      final gate = Completer<void>();
      final r = CachingStreamResolver(_FakeResolver((v) async {
        calls++;
        await gate.future;
        if (calls == 1) throw const DownloadSourceException(DownloadSourceErrorKind.network, 'x');
        return info(v, null);
      }));
      final a = r.resolve(id);
      final b = r.resolve(id);
      gate.complete();
      await expectLater(a, throwsA(isA<DownloadSourceException>()));
      await expectLater(b, throwsA(isA<DownloadSourceException>()));
      expect(calls, 1);
      expect((await r.resolve(id)).videoId, id);
      expect(calls, 2);
    });

    test('sin expire usa el TTL de respaldo y ids distintos no se mezclan', () async {
      final now = DateTime.utc(2026, 1, 1);
      expect(streamCacheDeadline(info(id, null), now), now.add(streamCacheFallbackTtl));
      final r = CachingStreamResolver(_FakeResolver((v) async => info(v, null)));
      expect((await r.resolve('aaaaaaaaaaa')).videoId, 'aaaaaaaaaaa');
      expect((await r.resolve('bbbbbbbbbbb')).videoId, 'bbbbbbbbbbb');
    });
  });
}

class _FakeResolver implements StreamResolver {
  final Future<StreamInfo> Function(String) _f;
  _FakeResolver(this._f);

  @override
  Future<StreamInfo> resolve(String videoId) => _f(videoId);
}
