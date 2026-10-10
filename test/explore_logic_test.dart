import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/models/explore.dart';
import 'package:heardy/models/song.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/explore_logic.dart';
import 'package:heardy/services/stream_resolver.dart';

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

  group('exploreNeedsRefresh', () {
    final now = DateTime(2026, 10, 9, 12);

    test('nunca refrescado: toca', () => expect(exploreNeedsRefresh(null, now), isTrue));

    test('reciente: no toca; en el límite o pasado: toca', () {
      expect(exploreNeedsRefresh(now.subtract(const Duration(minutes: 14)), now), isFalse);
      expect(exploreNeedsRefresh(now.subtract(const Duration(minutes: 15)), now), isTrue);
      expect(exploreNeedsRefresh(now.subtract(const Duration(hours: 6)), now), isTrue);
    });

    test('un reloj que retrocedió cuenta como vencido', () {
      expect(exploreNeedsRefresh(now.add(const Duration(minutes: 5)), now), isTrue);
    });
  });

  group('pickLocalSongForVideo', () {
    Song song(String id, String? url, {bool missing = false}) => Song(
          id: id,
          title: id,
          artist: 'a',
          duration: 1,
          filePath: '',
          artPath: '',
          format: 'm4a',
          downloadDate: DateTime(2026),
          sourceUrl: url,
          missing: missing,
        );

    test('empareja por id de vídeo aunque cambie la forma de la URL', () {
      final s = song('s1', 'https://music.youtube.com/watch?v=$_a&list=x');
      expect(pickLocalSongForVideo(_a, [song('s0', null), s])?.id, 's1');
      expect(pickLocalSongForVideo(_a, [song('s2', 'https://youtu.be/$_a')])?.id, 's2');
    });

    test('ignora las que faltan en disco, las de otro vídeo y los ids vacíos', () {
      expect(pickLocalSongForVideo(_a, [song('s1', 'https://www.youtube.com/watch?v=$_a', missing: true)]), isNull);
      expect(pickLocalSongForVideo(_a, [song('s1', 'https://www.youtube.com/watch?v=$_b')]), isNull);
      expect(pickLocalSongForVideo('', [song('s1', null)]), isNull);
    });
  });

  group('TimeoutStreamResolver', () {
    test('una resolución colgada falla por tiempo en vez de quedar pendiente', () async {
      final resolver = TimeoutStreamResolver(_HangingResolver(), timeout: const Duration(milliseconds: 20));
      await expectLater(resolver.resolve(_a), throwsA(isA<TimeoutException>()));
    });
  });

  group('Añadir desde Reproduciendo', () {
    MediaItem stream({String? videoId = _a}) => MediaItem(
          id: 'stream:$_a',
          title: 'T',
          artist: 'Art',
          duration: const Duration(seconds: 90),
          artUri: Uri.parse('https://i.ytimg.com/x.jpg'),
          extras: {'isStream': true, if (videoId != null) 'videoId': videoId},
        );

    test('una pista en streaming se reconstruye como RemoteTrack', () {
      final t = remoteTrackFromStreamItem(stream())!;
      expect(t.id, _a);
      expect(t.title, 'T');
      expect(t.artist, 'Art');
      expect(t.durationSeconds, 90);
      expect(t.thumbnailUrl, 'https://i.ytimg.com/x.jpg');
      expect(t.sourceUrl, 'https://www.youtube.com/watch?v=$_a');
    });

    test('sin videoId o sin isStream no hay RemoteTrack', () {
      expect(remoteTrackFromStreamItem(stream(videoId: null)), isNull);
      expect(remoteTrackFromStreamItem(stream(videoId: '')), isNull);
      expect(remoteTrackFromStreamItem(const MediaItem(id: 'x', title: 't')), isNull);
    });

    test('la acción depende de si es streaming o local', () {
      expect(nowPlayingAddAction(stream()), NowPlayingAddAction.downloadStream);
      expect(nowPlayingAddAction(stream(videoId: null)), NowPlayingAddAction.none);
      expect(nowPlayingAddAction(const MediaItem(id: 'song1', title: 't')), NowPlayingAddAction.addLocal);
      expect(nowPlayingAddAction(const MediaItem(id: '', title: 't')), NowPlayingAddAction.none);
    });
  });

  group('personalizar Explorar', () {
    test('parseHiddenShelves ignora nombres desconocidos y repetidos', () {
      expect(parseHiddenShelves(null), isEmpty);
      expect(
        parseHiddenShelves(['charts', 'nope', 'charts', 'moods']),
        {ExploreShelfId.charts, ExploreShelfId.moods},
      );
    });

    test('serializeHiddenShelves es estable y ida y vuelta', () {
      final hidden = {ExploreShelfId.moods, ExploreShelfId.recent};
      final raw = serializeHiddenShelves(hidden);
      expect(raw, ['recent', 'moods']);
      expect(parseHiddenShelves(raw), hidden);
    });

    test('las estanterías regionales son las de país', () {
      expect(kRegionalShelves, {
        ExploreShelfId.charts,
        ExploreShelfId.newReleases,
        ExploreShelfId.home,
        ExploreShelfId.moods,
      });
      expect(isRegionalShelf(ExploreShelfId.radio), isFalse);
      expect(isRegionalShelf(ExploreShelfId.charts), isTrue);
    });

    test('normalizeExploreCountry acepta sólo códigos de la lista', () {
      expect(normalizeExploreCountry('mx'), 'MX');
      expect(normalizeExploreCountry(' ES '), 'ES');
      expect(normalizeExploreCountry('ZZ'), isNull);
      expect(normalizeExploreCountry(''), isNull);
      expect(normalizeExploreCountry(null), isNull);
    });

    test('la lista de países no repite códigos y está ordenada por nombre', () {
      final codes = kExploreCountries.map((c) => c.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
      expect(codes.every((c) => c.length == 2 && c == c.toUpperCase()), isTrue);
      expect(codes, containsAll(['ES', 'MX', 'US', 'AR', 'CO']));
      for (final english in [false, true]) {
        final names = sortedExploreCountries(english: english).map((c) => c.nameFor(english: english)).toList();
        final sorted = [...names]..sort((a, b) => foldForSearch(a).compareTo(foldForSearch(b)));
        expect(names, sorted);
      }
    });

    test('filterExploreCountries busca por nombre sin acentos ni mayúsculas, o por código', () {
      expect(filterExploreCountries('mexi', english: false).map((c) => c.code), ['MX']);
      expect(filterExploreCountries('MÉXICO', english: false).map((c) => c.code), ['MX']);
      expect(filterExploreCountries('germany', english: true).map((c) => c.code), ['DE']);
      expect(filterExploreCountries('es', english: false).map((c) => c.code), contains('ES'));
      expect(filterExploreCountries('  ', english: false), hasLength(kExploreCountries.length));
      expect(filterExploreCountries('xyzxyz', english: false), isEmpty);
    });
  });
}

class _HangingResolver implements StreamResolver {
  @override
  Future<StreamInfo> resolve(String videoId) => Completer<StreamInfo>().future;
}
