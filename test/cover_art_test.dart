import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/models/song.dart';
import 'package:heardy/services/artwork_repair_service.dart';
import 'package:heardy/services/cover_art.dart';

/// Qué URLs de carátula se intentan, y en qué orden.
///
/// El servidor mandaba `maxresdefault.webp` (la "mejor" según yt-dlp) y
/// `audio_metadata_reader` descarta un WebP al escribir el `covr` de un .m4a
/// en silencio: las canciones descargadas quedaban sin carátula en disco.
void main() {
  test('un WebP de i.ytimg.com se cambia por su gemela JPEG', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi_webp/abc123/maxresdefault.webp', 'abc123'),
      [
        'https://i.ytimg.com/vi/abc123/maxresdefault.jpg',
        'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
      ],
    );
  });

  test('una JPEG se respeta tal cual, con su query, y hqdefault queda de respaldo', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi/abc123/hq720.jpg?sqp=xyz&rs=1', 'abc123'),
      [
        'https://i.ytimg.com/vi/abc123/hq720.jpg?sqp=xyz&rs=1',
        'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
      ],
    );
  });

  test('si la URL ya es hqdefault no se duplica', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi/abc123/hqdefault.jpg', 'abc123'),
      ['https://i.ytimg.com/vi/abc123/hqdefault.jpg'],
    );
  });

  test('sin URL pero con id, se intenta hqdefault', () {
    expect(coverArtCandidates('', 'abc123'), ['https://i.ytimg.com/vi/abc123/hqdefault.jpg']);
  });

  test('sin URL ni id no hay nada que intentar', () {
    expect(coverArtCandidates('', ''), isEmpty);
  });

  test('una URL de otro dominio se intenta sin tocar, y luego el respaldo por id', () {
    expect(
      coverArtCandidates('https://example.com/cover.webp', 'abc123'),
      ['https://example.com/cover.webp', 'https://i.ytimg.com/vi/abc123/hqdefault.jpg'],
    );
  });

  group('youtubeVideoIdFrom', () {
    test('reconoce las formas habituales del enlace', () {
      for (final url in [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD',
        'https://youtu.be/dQw4w9WgXcQ?si=abc',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ',
        'https://youtube.com/embed/dQw4w9WgXcQ',
      ]) {
        expect(youtubeVideoIdFrom(url), 'dQw4w9WgXcQ', reason: url);
      }
    });

    test('rechaza lo que no es de YouTube o no trae id válido', () {
      expect(youtubeVideoIdFrom(null), isNull);
      expect(youtubeVideoIdFrom(''), isNull);
      expect(youtubeVideoIdFrom('https://open.spotify.com/track/abc'), isNull);
      expect(youtubeVideoIdFrom('https://www.youtube.com/playlist?list=PL123'), isNull);
      expect(youtubeVideoIdFrom('https://www.youtube.com/watch?v=corto'), isNull);
    });
  });

  group('songsNeedingArtwork', () {
    Song song(String id, {String artPath = '', String? sourceUrl}) => Song(
          id: id,
          title: id,
          artist: 'a',
          duration: 1,
          filePath: '',
          artPath: artPath,
          format: 'm4a',
          downloadDate: DateTime(2026),
          sourceUrl: sourceUrl,
        );

    test('elige las que no tienen carátula, o la perdieron, y sí tienen id de YouTube', () {
      final songs = [
        song('sin-art', sourceUrl: 'https://youtu.be/dQw4w9WgXcQ'),
        song('art-perdida', artPath: '/t/perdida.jpg', sourceUrl: 'https://youtu.be/dQw4w9WgXcQ'),
        song('con-art', artPath: '/t/ok.jpg', sourceUrl: 'https://youtu.be/dQw4w9WgXcQ'),
        song('sin-origen'),
        song('spotify', sourceUrl: 'https://open.spotify.com/track/x'),
      ];
      final pending = songsNeedingArtwork(songs, artworkExists: (p) => p == '/t/ok.jpg');
      expect(pending.map((s) => s.id), ['sin-art', 'art-perdida']);
    });
  });
}
