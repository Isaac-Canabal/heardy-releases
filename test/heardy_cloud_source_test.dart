// Verifica HeardyCloudSource contra un http.Client falso, sin red — mismo
// molde que ytdlp_server_source_test.dart. Lo que más importa: el mapeo de
// códigos HTTP a CloudSourceErrorKind (409 con isVersionConflict, 428
// needsUsername, 304 → null en getLibrary).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/heardy_cloud_source.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() {}
}

http.StreamedResponse _json(Object body, {int status = 200, Map<String, String>? headers}) {
  final bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
    headers: {'content-type': 'application/json', ...?headers},
  );
}

http.StreamedResponse _empty(int status) => http.StreamedResponse(const Stream.empty(), status);

HeardyCloudSource _source(_FakeClient client) {
  return HeardyCloudSource(
    baseUrl: () => 'http://servidor:8080',
    authToken: () async => 'token-de-firebase',
    clientFactory: () => client,
  );
}

void main() {
  group('getAccount', () {
    test('parsea la respuesta y manda el Authorization Bearer', () async {
      final client = _FakeClient((req) async {
        expect(req.headers['Authorization'], 'Bearer token-de-firebase');
        return _json({
          'identity': 'firebase:abc',
          'username': 'isaac',
          'libraryVersion': 3,
          'hasLibrary': true,
          'friendCount': 2,
        });
      });
      final account = await _source(client).getAccount();
      expect(account.username, 'isaac');
      expect(account.libraryVersion, 3);
      expect(account.friendCount, 2);
    });
  });

  group('setUsername', () {
    test('409 se mapea a conflict', () async {
      final client = _FakeClient((req) async => _json({'detail': 'ocupado'}, status: 409));
      expect(
        () => _source(client).setUsername('isaac'),
        throwsA(isA<CloudSourceException>().having((e) => e.kind, 'kind', CloudSourceErrorKind.conflict)),
      );
    });
  });

  group('lookupUser', () {
    test('404 se mapea a notFound', () async {
      final client = _FakeClient((req) async => _json({'detail': 'no encontrado'}, status: 404));
      expect(
        () => _source(client).lookupUser('nadie'),
        throwsA(isA<CloudSourceException>().having((e) => e.kind, 'kind', CloudSourceErrorKind.notFound)),
      );
    });

    test('428 se mapea a needsUsername', () async {
      final client = _FakeClient((req) async => _json({'detail': 'elegí nombre'}, status: 428));
      expect(
        () => _source(client).lookupUser('alguien'),
        throwsA(isA<CloudSourceException>().having((e) => e.kind, 'kind', CloudSourceErrorKind.needsUsername)),
      );
    });
  });

  group('getLibrary', () {
    test('304 devuelve null, no una biblioteca vacía', () async {
      final client = _FakeClient((req) async {
        expect(req.headers['If-None-Match'], '5');
        return _empty(304);
      });
      final result = await _source(client).getLibrary(ifNoneMatchVersion: '5');
      expect(result, isNull);
    });

    test('200 devuelve la biblioteca parseada', () async {
      final client = _FakeClient((req) async => _json({
            'version': 7,
            'songs': [
              {'songId': 'a', 'title': 't', 'artist': 'ar'}
            ],
            'playlists': [],
            'playlistSongs': [],
          }));
      final result = await _source(client).getLibrary();
      expect(result!.version, 7);
      expect(result.songs, hasLength(1));
    });

    test(
      'normaliza a camelCase la forma real de /library (SELECT crudo, snake_case) — '
      'GET no pasa por el mismo modelo Pydantic que PUT, así que no llega ya en camelCase',
      () async {
        final client = _FakeClient((req) async => _json({
              'version': 3,
              'songs': [
                {
                  'song_id': 'hash-abc',
                  'title': 'Título',
                  'artist': 'Artista',
                  'album': null,
                  'duration_seconds': 180,
                  'file_hash': 'hash-abc',
                  'hash_kind': 'mp4-mdat',
                },
              ],
              'playlists': [
                {'playlist_id': 'pl-1', 'name': 'Favoritas', 'sort_order': 0},
              ],
              'playlistSongs': [
                {'playlist_id': 'pl-1', 'song_id': 'hash-abc', 'order_index': 0},
              ],
            }));

        final result = await _source(client).getLibrary();

        final song = result!.songs.single;
        expect(song['songId'], 'hash-abc');
        expect(song['durationSeconds'], 180);
        expect(song['fileHash'], 'hash-abc');
        expect(song['hashKind'], 'mp4-mdat');
        expect(song.containsKey('song_id'), isFalse, reason: 'la clave vieja no debe seguir viva');

        final playlist = result.playlists.single;
        expect(playlist['playlistId'], 'pl-1');
        expect(playlist['sortOrder'], 0);

        final playlistSong = result.playlistSongs.single;
        expect(playlistSong['playlistId'], 'pl-1');
        expect(playlistSong['songId'], 'hash-abc');
        expect(playlistSong['orderIndex'], 0);
      },
    );
  });

  group('pushLibrary', () {
    test('409 con reason de versión se marca isVersionConflict', () async {
      final client = _FakeClient((req) async => _json(
            {
              'detail': {'reason': 'library_version_conflict'}
            },
            status: 409,
          ));
      try {
        await _source(client).pushLibrary(baseVersion: 1, songs: const [], playlists: const [], playlistSongs: const []);
        fail('debía lanzar');
      } on CloudSourceException catch (e) {
        expect(e.kind, CloudSourceErrorKind.conflict);
        expect(e.isVersionConflict, isTrue);
      }
    });

    test('manda baseVersion/contentHash/songs en el cuerpo', () async {
      late Map<String, dynamic> sentBody;
      final client = _FakeClient((req) async {
        final body = await (req as http.Request).finalize().bytesToString();
        sentBody = jsonDecode(body) as Map<String, dynamic>;
        return _json({'version': 2});
      });
      final version = await _source(client).pushLibrary(
        baseVersion: 1,
        contentHash: 'hash123',
        songs: const [
          {'songId': 'a'}
        ],
        playlists: const [],
        playlistSongs: const [],
      );
      expect(version, 2);
      expect(sentBody['baseVersion'], 1);
      expect(sentBody['contentHash'], 'hash123');
      expect(sentBody['songs'], hasLength(1));
    });
  });

  group('pushHistory', () {
    test('parsea received/stored/skippedTooOld', () async {
      final client = _FakeClient((req) async => _json({'received': 3, 'stored': 2, 'skippedTooOld': 1}));
      final result = await _source(client).pushHistory(const [
        {'songId': 'a', 'playedAtLocal': 'x', 'playedAtUtc': 'y', 'playSeconds': 10}
      ]);
      expect(result.received, 3);
      expect(result.stored, 2);
      expect(result.skippedTooOld, 1);
    });
  });

  group('429 con Retry-After', () {
    test('quotaExceeded lleva retryAfterSeconds del header, no inventado', () async {
      final client = _FakeClient(
        (req) async => _json({'detail': 'cupo agotado'}, status: 429, headers: {'retry-after': '120'}),
      );
      try {
        await _source(client).lookupUser('alguien');
        fail('debía lanzar');
      } on CloudSourceException catch (e) {
        expect(e.kind, CloudSourceErrorKind.quotaExceeded);
        expect(e.retryAfterSeconds, 120);
      }
    });
  });

  group('2xx con forma inesperada', () {
    test('una lista JSON lanza CloudSourceException, no TypeError', () async {
      final client = _FakeClient((req) async => _json([1, 2, 3]));
      await expectLater(_source(client).getAccount(), throwsA(isA<CloudSourceException>()));
    });

    test('un cuerpo que no es JSON lanza CloudSourceException', () async {
      final client = _FakeClient((req) async {
        final bytes = utf8.encode('<html>hola</html>');
        return http.StreamedResponse(Stream.value(bytes), 200, contentLength: bytes.length);
      });
      await expectLater(_source(client).getAccount(), throwsA(isA<CloudSourceException>()));
    });
  });
}
