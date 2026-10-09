// Cubre la lógica de emparejamiento Spotify -> YouTube (Fase 8): elegir el
// resultado de /search cuya duración esté más cerca del original, y decidir
// si esa coincidencia es lo bastante buena como para descargarla.
//
// La regla que más importa: NUNCA se compara por título/artista, sólo por
// duración — y una coincidencia a más de 30s de diferencia se descarta en
// vez de descargarse a ciegas (rescatada del `searchAndDownload` original).
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/spotify_match.dart';
import 'package:heardy/services/spotify_service.dart';

class _FakeDownloadSource implements DownloadSource {
  // Explorar no se usa en estos tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();


  List<RemoteTrack> results = [];
  DownloadSourceException? searchError;
  final List<String> queries = [];

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    queries.add(query);
    if (searchError != null) throw searchError!;
    return results;
  }

  @override
  Future<RemoteTrack> resolve(String url) => throw UnimplementedError();
  @override
  Future<RemotePlaylist> resolvePlaylist(String url) => throw UnimplementedError();
  @override
  Future<void> fetchAudio(String trackId, String destPath,
          {ProgressCallback? onProgress, CancellationCheck? isCancelled}) =>
      throw UnimplementedError();
  @override
  Future<DownloadSourceStatus> probe() => throw UnimplementedError();
  @override
  Future<UsageStatus> usage() => throw UnimplementedError();
}

RemoteTrack _yt(String id, {required int durationSeconds, String title = 'T', String artist = 'Canal'}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: null,
    durationSeconds: durationSeconds,
    thumbnailUrl: '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

SpotifyTrackInfo _spotify({
  String title = 'Total Eclipse of the Heart',
  String artist = 'Bonnie Tyler',
  required int durationMs,
}) {
  return SpotifyTrackInfo(title: title, artist: artist, durationMs: durationMs);
}

void main() {
  group('pickClosestByDuration', () {
    test('elige el candidato con la duración más cercana, no el primero de la lista', () {
      final candidates = [
        _yt('lejos', durationSeconds: 100),
        _yt('cerca', durationSeconds: 205),
        _yt('mediano', durationSeconds: 150),
      ];

      final best = pickClosestByDuration(candidates, 200);

      expect(best?.id, 'cerca');
    });

    test('ignora candidatos sin duración conocida', () {
      final candidates = [_yt('sin-duracion', durationSeconds: 0), _yt('con-duracion', durationSeconds: 200)];

      final best = pickClosestByDuration(candidates, 200);

      expect(best?.id, 'con-duracion');
    });

    test('sin candidatos comparables, devuelve null', () {
      final candidates = [_yt('sin-duracion', durationSeconds: 0)];

      expect(pickClosestByDuration(candidates, 200), isNull);
    });

    test('lista vacía, devuelve null', () {
      expect(pickClosestByDuration(const [], 200), isNull);
    });
  });

  group('matchSpotifyTrack', () {
    test('busca por "artista título", nunca al revés ni sólo por título', () async {
      final source = _FakeDownloadSource()..results = [_yt('x', durationSeconds: 213)];
      final track = _spotify(durationMs: 213000);

      await matchSpotifyTrack(track, source);

      expect(source.queries.single, 'Bonnie Tyler Total Eclipse of the Heart');
    });

    test('una diferencia de 2s es una coincidencia buena y aceptable', () async {
      final source = _FakeDownloadSource()..results = [_yt('bueno', durationSeconds: 215)];
      final track = _spotify(durationMs: 213000); // 213s

      final match = await matchSpotifyTrack(track, source);

      expect(match.durationDiffSeconds, 2);
      expect(match.isGoodMatch, isTrue);
      expect(match.isAcceptable, isTrue);
    });

    test('una diferencia de 15s es aceptable pero no "buena sin más"', () async {
      final source = _FakeDownloadSource()..results = [_yt('revisar', durationSeconds: 228)];
      final track = _spotify(durationMs: 213000);

      final match = await matchSpotifyTrack(track, source);

      expect(match.durationDiffSeconds, 15);
      expect(match.isAcceptable, isTrue);
      expect(match.isGoodMatch, isFalse, reason: '15s no es "sin dudarlo", aunque siga siendo descargable');
    });

    test('una diferencia de más de 30s se descarta: mejor nada que la canción equivocada', () async {
      final source = _FakeDownloadSource()..results = [_yt('cover-o-remix', durationSeconds: 400)];
      final track = _spotify(durationMs: 213000); // diff = 187s

      final match = await matchSpotifyTrack(track, source);

      expect(match.youtubeTrack, isNotNull, reason: 'sigue habiendo un candidato, sólo que no es aceptable');
      expect(match.isAcceptable, isFalse);
    });

    test('sin resultados de búsqueda, no hay coincidencia y no se lanza', () async {
      final source = _FakeDownloadSource()..results = [];
      final track = _spotify(durationMs: 213000);

      final match = await matchSpotifyTrack(track, source);

      expect(match.youtubeTrack, isNull);
      expect(match.durationDiffSeconds, isNull);
      expect(match.isAcceptable, isFalse);
    });

    test('un error de búsqueda se propaga tal cual, no se traga como "sin coincidencia"', () async {
      final source = _FakeDownloadSource()
        ..searchError = const DownloadSourceException(DownloadSourceErrorKind.network, 'sin red');
      final track = _spotify(durationMs: 213000);

      await expectLater(
        matchSpotifyTrack(track, source),
        throwsA(isA<DownloadSourceException>()),
      );
    });
  });
}
