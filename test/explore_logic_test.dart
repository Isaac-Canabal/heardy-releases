import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/models/explore.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/explore_logic.dart';

RemoteTrack _t(String id, {String title = 't'}) => RemoteTrack(
      id: id,
      title: title,
      artist: 'a',
      album: null,
      durationSeconds: 100,
      thumbnailUrl: '',
      sourceUrl: 'https://www.youtube.com/watch?v=$id',
    );

const _a = 'aaaaaaaaaaa';
const _b = 'bbbbbbbbbbb';
const _c = 'ccccccccccc';
const _d = 'ddddddddddd';

void main() {
  group('youtubeVideoId', () {
    test('extrae el id de las formas habituales', () {
      expect(youtubeVideoId('https://www.youtube.com/watch?v=$_a'), _a);
      expect(youtubeVideoId('https://music.youtube.com/watch?v=$_a&list=x'), _a);
      expect(youtubeVideoId('https://youtu.be/$_a?t=3'), _a);
    });

    test('null para lo que no es un vídeo', () {
      expect(youtubeVideoId(null), isNull);
      expect(youtubeVideoId(''), isNull);
      expect(youtubeVideoId('https://www.youtube.com/playlist?list=PLx'), isNull);
      expect(youtubeVideoId('https://example.com/watch?v=$_a'), isNull);
      expect(youtubeVideoId('https://www.youtube.com/watch?v=corto'), isNull);
      expect(youtubeVideoId('content://media/1'), isNull);
    });
  });

  group('selectRadioSeedIds', () {
    test('toma hasta max ids distintos conservando el orden', () {
      final urls = [
        'https://www.youtube.com/watch?v=$_a',
        'content://x',
        null,
        'https://www.youtube.com/watch?v=$_a',
        'https://www.youtube.com/watch?v=$_b',
        'https://www.youtube.com/watch?v=$_c',
        'https://www.youtube.com/watch?v=$_d',
      ];
      expect(selectRadioSeedIds(urls), [_a, _b, _c]);
      expect(selectRadioSeedIds(urls, max: 2), [_a, _b]);
    });

    test('sin semillas válidas devuelve vacío', () {
      expect(selectRadioSeedIds(['x', null]), isEmpty);
    });
  });

  group('mergeRadioTracks', () {
    test('intercala, deduplica por id, descarta las locales y recorta', () {
      final merged = mergeRadioTracks(
        [
          [_t(_a), _t(_b), _t('eeeeeeeeeee')],
          [_t(_b), _t(_c), _t('fffffffffff')],
        ],
        localVideoIds: {_c},
        cap: 4,
      );
      expect(merged.map((t) => t.id), [_a, _b, 'eeeeeeeeeee', 'fffffffffff']);
    });

    test('vacío si todo es local', () {
      expect(mergeRadioTracks([[_t(_a)]], localVideoIds: {_a}), isEmpty);
    });
  });

  test('localVideoIds ignora URLs que no son de YouTube', () {
    expect(
      localVideoIds({'https://www.youtube.com/watch?v=$_a', 'content://x', ''}),
      {_a},
    );
  });

  group('upscaleThumbnail', () {
    test('sube =w120-h120 conservando el resto de parámetros', () {
      expect(
        upscaleThumbnail('https://lh3.googleusercontent.com/abc=w120-h120-l90-rj'),
        'https://lh3.googleusercontent.com/abc=w400-h400-l90-rj',
      );
    });

    test('no toca lo que ya es grande ni lo que no encaja', () {
      const big = 'https://lh3.googleusercontent.com/abc=w544-h544-l90-rj';
      expect(upscaleThumbnail(big), big);
      const other = 'https://i.ytimg.com/vi/x/hqdefault.jpg';
      expect(upscaleThumbnail(other), other);
      expect(upscaleThumbnail(''), '');
    });
  });

  group('chunkColumns', () {
    test('agrupa de a rows elementos, el último puede quedar corto', () {
      expect(chunkColumns([1, 2, 3, 4, 5]), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect(chunkColumns(<int>[]), isEmpty);
    });
  });

  test('tracksToDownload salta las locales y las repetidas', () {
    final out = tracksToDownload([_t(_a), _t(_b), _t(_b), _t(_c)], {_a});
    expect(out.map((t) => t.id), [_b, _c]);
    expect(tracksToDownload([_t(_a)], {_a}), isEmpty);
  });

  test('withUpscaledThumbnail sólo cambia la miniatura', () {
    final t = RemoteTrack(
      id: _a,
      title: 'x',
      artist: 'y',
      album: 'z',
      durationSeconds: 5,
      thumbnailUrl: 'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
      sourceUrl: 'u',
    );
    final up = withUpscaledThumbnail(t);
    expect(up.thumbnailUrl, endsWith('=w400-h400-l90-rj'));
    expect([up.id, up.title, up.artist, up.album, up.durationSeconds, up.sourceUrl],
        [t.id, t.title, t.artist, t.album, t.durationSeconds, t.sourceUrl]);
  });

  test('flattenMoods aplana las secciones en orden', () {
    const sections = [
      ExploreMoodSection(title: 'A', moods: [ExploreMood(title: 'm1', params: 'p1')]),
      ExploreMoodSection(
        title: 'B',
        moods: [ExploreMood(title: 'm2', params: 'p2'), ExploreMood(title: 'm3', params: 'p3')],
      ),
    ];
    expect(flattenMoods(sections).map((m) => m.title), ['m1', 'm2', 'm3']);
  });

  group('pickArtistHit', () {
    test('toma el primero con canal', () {
      const hits = [
        ExploreArtistHit(channelId: '', name: 'vacío'),
        ExploreArtistHit(channelId: 'UC1', name: 'A'),
        ExploreArtistHit(channelId: 'UC2', name: 'B'),
      ];
      expect(pickArtistHit(hits)?.channelId, 'UC1');
    });

    test('null sin resultados', () {
      expect(pickArtistHit(const []), isNull);
    });
  });

  group('filtro de búsqueda', () {
    test('canciones no usa /explore/search; el resto mapea 1 a 1', () {
      expect(exploreKindFor(SearchKind.songs), isNull);
      expect(exploreKindFor(SearchKind.playlists), ExploreSearchKind.playlists);
      expect(exploreKindFor(SearchKind.albums), ExploreSearchKind.albums);
      expect(exploreKindFor(SearchKind.artists), ExploreSearchKind.artists);
      expect(ExploreSearchKind.playlists.name, 'playlists');
    });

    test('solo la última búsqueda vale', () {
      expect(isCurrentSearch(3, 3), isTrue);
      expect(isCurrentSearch(2, 3), isFalse);
    });

    test('parseExploreSearch llena solo la lista del tipo', () {
      final r = parseExploreSearch(ExploreSearchKind.artists, {
        'artists': [
          {'channelId': 'UC1', 'name': 'A'},
          {'name': 'sin id'},
        ]
      });
      expect(r.artists.length, 1);
      expect(r.length, 1);
      expect(r.playlists, isEmpty);
      expect(parseExploreSearch(ExploreSearchKind.albums, {'albums': []}).isEmpty, isTrue);
    });
  });
}
