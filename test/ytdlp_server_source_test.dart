// Verifica el cliente del servidor de descargas contra un http.Client falso,
// sin red. Lo que más importa aquí es el mapeo de códigos HTTP a
// DownloadSourceErrorKind: la cola de descargas decide si reintenta a partir
// de él, así que confundir un 415 (definitivo) con un 502 (transitorio)
// produce reintentos infinitos de un vídeo que nunca va a funcionar.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

/// Responde con lo que se le diga y registra lo que recibió.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

http.StreamedResponse _json(Object body, {int status = 200}) {
  final bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
    headers: {'content-type': 'application/json'},
  );
}

http.StreamedResponse _error(int status, String detail) => _json({'detail': detail}, status: status);

YtdlpServerSource _source(
  _FakeClient client, {
  String url = 'http://servidor:8080',
  String? token = 'token-de-firebase',
}) {
  return YtdlpServerSource(
    baseUrl: () => url,
    authToken: () async => token,
    clientFactory: () => client,
  );
}

void main() {
  late Directory sandbox;

  setUpAll(() {
    sandbox = Directory.systemTemp.createTempSync('heardy_source_test_');
  });

  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('normalización de la dirección', () {
    test('acepta lo que el usuario escribe de verdad: sin esquema y con barra final', () async {
      late Uri seen;
      final client = _FakeClient((request) async {
        seen = request.url;
        return _json({'id': 'abc', 'title': 'T', 'artist': 'A', 'durationSeconds': 10});
      });

      await _source(client, url: '  192.168.1.50:8080/  ').resolve('https://youtu.be/abc');

      expect(seen.toString(), 'http://192.168.1.50:8080/resolve');
    });

    test('sin dirección configurada falla como notConfigured, no como error de red', () async {
      final client = _FakeClient((_) async => _json({}));
      final source = _source(client, url: '   ');

      expect(source.isConfigured, isFalse);
      await expectLater(
        source.resolve('https://youtu.be/abc'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.notConfigured)
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
      expect(client.requests, isEmpty, reason: 'no debe salir ninguna petición sin servidor');
    });
  });

  group('resolve / playlist / search', () {
    test('resolve manda el token de Firebase y parsea el DTO', () async {
      final client = _FakeClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token-de-firebase');
        return _json({
          'id': 'dQw4',
          'title': 'Título',
          'artist': 'Artista',
          'album': 'Álbum',
          'durationSeconds': 213,
          'thumbnailUrl': 'http://img/1.jpg',
          'sourceUrl': 'https://www.youtube.com/watch?v=dQw4',
        });
      });

      final track = await _source(client).resolve('https://youtu.be/dQw4');

      expect(track.id, 'dQw4');
      expect(track.title, 'Título');
      expect(track.artist, 'Artista');
      expect(track.album, 'Álbum');
      expect(track.durationSeconds, 213);
      expect(track.sourceUrl, 'https://www.youtube.com/watch?v=dQw4');
    });

    test('un álbum vacío se normaliza a null, no a cadena vacía', () async {
      final client = _FakeClient((_) async => _json({
            'id': 'x',
            'title': 'T',
            'artist': 'A',
            'album': '   ',
            'durationSeconds': 1,
          }));

      final track = await _source(client).resolve('https://youtu.be/x');
      expect(track.album, isNull);
    });

    test('las entradas de playlist sin id se descartan en vez de encolarse para fallar', () async {
      final client = _FakeClient((_) async => _json({
            'id': 'PL1',
            'name': 'Mi lista',
            'sourceUrl': 'https://youtube.com/playlist?list=PL1',
            'entries': [
              {'id': 'a', 'title': 'Uno', 'artist': 'X', 'durationSeconds': 100},
              {'id': '', 'title': 'Vídeo privado', 'artist': '', 'durationSeconds': 0},
              {'id': 'b', 'title': 'Dos', 'artist': 'Y', 'durationSeconds': 200},
            ],
          }));

      final playlist = await _source(client).resolvePlaylist('https://youtube.com/playlist?list=PL1');

      expect(playlist.name, 'Mi lista');
      expect(playlist.entries.map((e) => e.id), ['a', 'b']);
    });

    test('search pasa la consulta y el límite como query params', () async {
      late Uri seen;
      final client = _FakeClient((request) async {
        seen = request.url;
        return _json({
          'results': [
            {'id': 'r1', 'title': 'Uno', 'artist': 'X', 'durationSeconds': 100},
          ],
        });
      });

      final results = await _source(client).search('bonnie tyler', limit: 5);

      expect(seen.queryParameters['q'], 'bonnie tyler');
      expect(seen.queryParameters['limit'], '5');
      expect(results.single.id, 'r1');
    });
  });

  group('mapeo de errores HTTP — decide si la cola reintenta', () {
    test('401 es unauthorized y NO se reintenta', () async {
      final client = _FakeClient((_) async => _error(401, 'X-Api-Key inválida'));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.unauthorized)
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('415 es unsupportedMedia y NO se reintenta: ese vídeo nunca tendrá pista AAC', () async {
      final client = _FakeClient((_) async => _error(415, 'sin pista AAC/M4A'));
      await expectLater(
        _source(client).fetchAudio('abc', '${sandbox.path}/no.m4a'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.unsupportedMedia)
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('502 es extraction y SÍ se reintenta: puede ser la IP del servidor, no el vídeo', () async {
      final client = _FakeClient((_) async => _error(502, 'Sign in to confirm you are not a bot'));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.extraction)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });

    test('503 es antiBotBlocked, SÍ se reintenta pero distinto de un 502 genérico', () async {
      final client = _FakeClient((_) async => _error(503, "Sign in to confirm you're not a bot"));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.antiBotBlocked)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', isNull)),
      );
    });

    test('429 es quotaExceeded, SÍ se reintenta y trae el Retry-After exacto del servidor', () async {
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'detail': 'límite alcanzado (per-key)'}))),
            429,
            headers: {'retry-after': '42'},
          ));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.quotaExceeded)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 42)),
      );
    });

    test('429 sin cabecera Retry-After no rompe el parseo: retryAfterSeconds queda null', () async {
      final client = _FakeClient((_) async => _error(429, 'límite alcanzado'));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.quotaExceeded)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', isNull)),
      );
    });

    test('429 con reason "daily_song_quota" es dailyQuotaExceeded, no quotaExceeded (Fase 3)', () async {
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({
              'detail': 'Llegaste a tu cupo diario de 150 canciones. Volvé mañana.',
              'reason': 'daily_song_quota',
              'usedToday': 150,
              'dailyLimit': 150,
            }))),
            429,
            headers: {'retry-after': '3600'},
          ));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.dailyQuotaExceeded)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 3600)
            .having((e) => e.userMessage, 'userMessage', contains('150'))),
      );
    });

    test('un fallo de socket se traduce a network, no se escapa como SocketException', () async {
      final client = _FakeClient((_) async => throw const SocketException('sin ruta al host'));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.network)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });

    test('un cuerpo de error que no es JSON no rompe el parseo', () async {
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.value(utf8.encode('<html>502 Bad Gateway</html>')),
            502,
          ));
      await expectLater(
        _source(client).resolve('https://youtu.be/x'),
        throwsA(isA<DownloadSourceException>().having((e) => e.message, 'message', contains('502'))),
      );
    });
  });

  group('fetchAudio', () {
    test('escribe los bytes, informa progreso y respeta Content-Length', () async {
      final payload = List<int>.generate(5000, (i) => i % 256);
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.fromIterable([payload.sublist(0, 2000), payload.sublist(2000)]),
            200,
            contentLength: payload.length,
          ));

      final dest = '${sandbox.path}/ok.m4a';
      final progreso = <int>[];
      await _source(client).fetchAudio('abc', dest, onProgress: (r, t) {
        expect(t, payload.length);
        progreso.add(r);
      });

      expect(await File(dest).readAsBytes(), payload);
      expect(progreso, [2000, 5000]);
    });

    test('una transferencia truncada se detecta por Content-Length y no deja archivo parcial', () async {
      // El servidor promete 5000 bytes y cierra limpiamente tras 2000: sin
      // comprobar Content-Length esto pasaría por una descarga correcta y
      // DownloadService pegaría un archivo cortado en la biblioteca.
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.value(List<int>.filled(2000, 7)),
            200,
            contentLength: 5000,
          ));

      final dest = '${sandbox.path}/truncado.m4a';
      await expectLater(
        _source(client).fetchAudio('abc', dest),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.network)),
      );
      expect(File(dest).existsSync(), isFalse,
          reason: 'un archivo parcial nunca debe sobrevivir a un fallo');
    });

    test('cancelar a mitad aborta y borra el archivo parcial', () async {
      var emitted = 0;
      final client = _FakeClient((_) async => http.StreamedResponse(
            Stream.fromIterable(List.generate(10, (_) => List<int>.filled(1000, 3))),
            200,
            contentLength: 10000,
          ));

      final dest = '${sandbox.path}/cancelado.m4a';
      await expectLater(
        _source(client).fetchAudio(
          'abc',
          dest,
          onProgress: (_, __) => emitted++,
          isCancelled: () => emitted >= 3,
        ),
        throwsA(isA<DownloadSourceException>()
            .having((e) => e.kind, 'kind', DownloadSourceErrorKind.cancelled)
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
      expect(File(dest).existsSync(), isFalse);
    });
  });

  group('probe', () {
    test('servidor sano y autenticado', () async {
      final client = _FakeClient((request) async {
        if (request.url.path == '/health') {
          return _json({
            'status': 'ok',
            'ytdlpVersion': '2026.07.20',
            'authRequired': true,
            'potProvider': {'reachable': true},
          });
        }
        return _json({'results': []});
      });

      final status = await _source(client).probe();

      expect(status.reachable, isTrue);
      expect(status.authenticated, isTrue);
      expect(status.version, '2026.07.20');
      expect(status.detail, contains('Conectado'));
    });

    test('distingue "clave inválida" de "servidor caído" — se arreglan en sitios distintos', () async {
      final client = _FakeClient((request) async {
        if (request.url.path == '/health') {
          return _json({'authRequired': true, 'potProvider': {'reachable': true}});
        }
        return _error(401, 'X-Api-Key inválida');
      });

      final status = await _source(client).probe();

      expect(status.reachable, isTrue, reason: 'el servidor sí responde');
      expect(status.authenticated, isFalse);
      expect(status.detail, contains('clave'));
    });

    test('avisa si el proveedor de PO tokens no responde, en vez de dejarlo descubrir descargando', () async {
      final client = _FakeClient((request) async {
        if (request.url.path == '/health') {
          return _json({
            'ytdlpVersion': '2026.07.20',
            'authRequired': true,
            'potProvider': {'reachable': false},
          });
        }
        return _json({'results': []});
      });

      final status = await _source(client).probe();

      expect(status.reachable, isTrue);
      expect(status.authenticated, isTrue);
      expect(status.potProviderReachable, isFalse);
      expect(status.detail, contains('PO tokens'));
    });

    test('probe no lanza cuando el servidor está apagado', () async {
      final client = _FakeClient((_) async => throw const SocketException('conexión rechazada'));
      final status = await _source(client).probe();

      expect(status.reachable, isFalse);
      expect(status.detail, isNotEmpty);
    });
  });

  group('usage (cupo diario, Fase 3)', () {
    test('parsea usedToday/dailyLimit del servidor', () async {
      final client = _FakeClient((_) async => _json({'usedToday': 37, 'dailyLimit': 150}));
      final status = await _source(client).usage();

      expect(status.usedToday, 37);
      expect(status.dailyLimit, 150);
      expect(status.isEnabled, isTrue);
      expect(status.remaining, 113);
    });

    test('dailyLimit 0 significa "sin cupo activo", no un error', () async {
      final client = _FakeClient((_) async => _json({'usedToday': 0, 'dailyLimit': 0}));
      final status = await _source(client).usage();

      expect(status.isEnabled, isFalse);
      expect(status.remaining, 0);
    });

    test('no lanza si el servidor no responde: se ve igual que "sin cupo"', () async {
      final client = _FakeClient((_) async => throw const SocketException('sin ruta al host'));
      final status = await _source(client).usage();

      expect(status, equals(UsageStatus.disabled));
    });

    test('no lanza si el servidor responde con un error HTTP', () async {
      final client = _FakeClient((_) async => _error(401, 'X-Api-Key inválida'));
      final status = await _source(client).usage();

      expect(status, equals(UsageStatus.disabled));
    });

    test('sin dirección configurada, devuelve disabled sin mandar ninguna petición', () async {
      final client = _FakeClient((_) async => _json({}));
      final status = await _source(client, url: '   ').usage();

      expect(status, equals(UsageStatus.disabled));
      expect(client.requests, isEmpty);
    });
  });
}
