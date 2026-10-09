// Cubre cloud_restore_match.dart — la restauración desde la cuenta (W7 del
// plan de escritorio, estrategia híbrida Etapa 16 E-2). Usa fixtures ya
// normalizadas a camelCase (lo que CloudSource.getLibrary entrega después de
// su propio arreglo) para no acoplar este test a esa capa de más abajo.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/cloud_restore_match.dart';
import 'package:heardy/services/download_source.dart';

RemoteTrack _track(String id, {required int durationSeconds}) => RemoteTrack(
      id: id,
      title: 'YouTube $id',
      artist: 'Canal $id',
      album: null,
      durationSeconds: durationSeconds,
      thumbnailUrl: '',
      sourceUrl: 'https://www.youtube.com/watch?v=$id',
    );

class _FakeSource implements DownloadSource {
  // Explorar no se usa en estos tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();


  _FakeSource(this.resultsByQuery, {this.resolveResults = const {}});
  final Map<String, List<RemoteTrack>> resultsByQuery;
  final Map<String, RemoteTrack> resolveResults;
  final List<String> queriesReceived = [];
  final List<String> urlsResolved = [];

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    queriesReceived.add(query);
    return resultsByQuery[query] ?? const [];
  }

  @override
  Future<RemoteTrack> resolve(String url) async {
    urlsResolved.add(url);
    final track = resolveResults[url];
    if (track == null) {
      throw const DownloadSourceException(DownloadSourceErrorKind.notFound, 'ya no existe');
    }
    return track;
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) => throw UnimplementedError();

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) =>
      throw UnimplementedError();

  @override
  Future<DownloadSourceStatus> probe() => throw UnimplementedError();

  @override
  Future<UsageStatus> usage() => throw UnimplementedError();
}

void main() {
  group('matchCloudSong', () {
    test('busca por "artista título" y elige el candidato más cercano en duración', () async {
      final source = _FakeSource({
        'Artista Título': [
          _track('lejos', durationSeconds: 100),
          _track('cerca', durationSeconds: 182),
        ],
      });

      final match = await matchCloudSong(
        {'title': 'Título', 'artist': 'Artista', 'durationSeconds': 180},
        source,
      );

      expect(source.queriesReceived.single, 'Artista Título');
      expect(match.youtubeTrack!.id, 'cerca');
      expect(match.durationDiffSeconds, 2);
      expect(match.isGoodMatch, isTrue);
    });

    test('con sourceUrl guardado, resuelve el original en vez de buscar', () async {
      final original = _track('original', durationSeconds: 180);
      final source = _FakeSource(
        {'Artista Título': [_track('parecido', durationSeconds: 179)]},
        resolveResults: {'https://www.youtube.com/watch?v=original': original},
      );

      final match = await matchCloudSong(
        {
          'title': 'Título',
          'artist': 'Artista',
          'durationSeconds': 180,
          'sourceUrl': 'https://www.youtube.com/watch?v=original',
        },
        source,
      );

      expect(match.youtubeTrack!.id, 'original');
      expect(match.isExactSource, isTrue);
      // resolve() de una URL es un resolve completo (no extract_flat): no
      // hace falta repetirlo en la cola antes de bajar (DD6).
      expect(match.metadataComplete, isTrue);
      // No es una coincidencia estimada: no hace falta buscar nada.
      expect(source.queriesReceived, isEmpty);
    });

    test('si el enlace original ya no existe, cae a la búsqueda por duración', () async {
      final source = _FakeSource({
        'Artista Título': [_track('sustituto', durationSeconds: 181)],
      });

      final match = await matchCloudSong(
        {
          'title': 'Título',
          'artist': 'Artista',
          'durationSeconds': 180,
          'sourceUrl': 'https://www.youtube.com/watch?v=borrado',
        },
        source,
      );

      expect(source.urlsResolved.single, 'https://www.youtube.com/watch?v=borrado');
      // Un enlace muerto no puede dejar la canción sin restaurar habiendo
      // una alternativa razonable.
      expect(match.youtubeTrack!.id, 'sustituto');
      expect(match.isExactSource, isFalse);
      // Resultado de búsqueda (extract_flat): sigue haciendo falta re-resolver
      // en la cola antes de bajar (DD6).
      expect(match.metadataComplete, isFalse);
      expect(match.isAcceptable, isTrue);
    });

    test('sin candidatos, el match no es aceptable pero no lanza', () async {
      final source = _FakeSource(const {});

      final match = await matchCloudSong(
        {'title': 'Nada', 'artist': 'Nadie', 'durationSeconds': 200},
        source,
      );

      expect(match.youtubeTrack, isNull);
      expect(match.isAcceptable, isFalse);
    });

    test('sin título ni artista, ni siquiera busca', () async {
      final source = _FakeSource(const {});

      final match = await matchCloudSong({'durationSeconds': 200}, source);

      expect(source.queriesReceived, isEmpty);
      expect(match.isAcceptable, isFalse);
    });
  });

  group('groupMissingSongsByPlaylist', () {
    test('agrupa por la primera playlist de la nube que contiene cada canción', () {
      final missing = [
        {'songId': 'a', 'title': 'A'},
        {'songId': 'b', 'title': 'B'},
        {'songId': 'c', 'title': 'C'},
      ];
      final playlistSongs = [
        {'playlistId': 'pl-1', 'songId': 'a', 'orderIndex': 0},
        {'playlistId': 'pl-1', 'songId': 'b', 'orderIndex': 1},
        {'playlistId': 'pl-2', 'songId': 'c', 'orderIndex': 0},
      ];

      final grouped = groupMissingSongsByPlaylist(missing, playlistSongs);

      expect(grouped['pl-1']!.map((s) => s['songId']), ['a', 'b']);
      expect(grouped['pl-2']!.map((s) => s['songId']), ['c']);
    });

    test('una canción sin ninguna playlist cae bajo la clave null', () {
      final missing = [
        {'songId': 'suelta', 'title': 'Suelta'},
      ];

      final grouped = groupMissingSongsByPlaylist(missing, const []);

      expect(grouped[null]!.single['songId'], 'suelta');
    });
  });
}
