import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/models/explore.dart';
import 'package:heardy/services/download_source.dart';

void main() {
  test('home: tres tipos de estantería y descarta las vacías', () {
    final home = parseExploreHome({
      'shelves': [
        {
          'title': 'Para ti',
          'kind': 'playlists',
          'items': [
            {'playlistId': 'PL1', 'title': 'Mix', 'subtitle': 'desc', 'thumbnailUrl': 'https://x/1'},
            {'title': 'sin id'},
          ],
        },
        {
          'title': 'Álbumes',
          'kind': 'albums',
          'items': [
            {'browseId': 'MPRE1', 'title': 'Alb', 'artist': 'A', 'year': '2026', 'thumbnailUrl': ''},
          ],
        },
        {
          'title': 'Temas',
          'kind': 'tracks',
          'items': [
            {'id': 'abcdefghijk', 'title': 'S', 'artist': 'A', 'durationSeconds': 0, 'thumbnailUrl': '', 'sourceUrl': 'u'},
          ],
        },
        {'title': 'Vacía', 'kind': 'tracks', 'items': []},
        {'title': 'Rara', 'kind': 'otra', 'items': [{}]},
      ],
    });
    expect(home.map((s) => s.kind), [ExploreShelfKind.playlists, ExploreShelfKind.albums, ExploreShelfKind.tracks]);
    expect(home[0].playlists.single.subtitle, 'desc');
    expect(home[0].playlists.single.playlistId, 'PL1');
    expect(home[1].albums.single.year, '2026');
    expect(home[2].tracks.single.id, 'abcdefghijk');
  });

  test('campos opcionales ausentes no rompen', () {
    final p = ExplorePlaylist.fromJson({'playlistId': 'PL', 'title': 'T'});
    expect(p.subtitle, '');
    expect(p.thumbnailUrl, '');
    final a = ExploreAlbum.fromJson({'browseId': 'B', 'title': 'T'});
    expect(a.artist, '');
    expect(a.year, '');
  });

  test('charts / nuevos / moods', () {
    expect(
      parseExplorePlaylists({'playlists': [{'playlistId': 'P', 'title': 'T', 'thumbnailUrl': 'u'}]}).single.title,
      'T',
    );
    expect(parseExploreAlbums({'albums': [{'browseId': 'B', 'title': 'T'}]}).single.browseId, 'B');
    final sections = parseExploreMoods({
      'sections': [
        {'title': 'Moods', 'moods': [{'title': 'Chill', 'params': 'gg'}, {'title': 'sin params'}]},
        {'title': 'Vacía', 'moods': []},
      ],
    });
    expect(sections.length, 1);
    expect(sections.single.moods.single.params, 'gg');
  });

  test('colección y radio reutilizan RemoteTrack y filtran ids vacíos', () {
    final c = parseExploreCollection({
      'title': 'Lista',
      'thumbnailUrl': 'u',
      'tracks': [
        {'id': 'aaaaaaaaaaa', 'title': 'T', 'artist': 'A', 'durationSeconds': 10, 'thumbnailUrl': '', 'sourceUrl': 's'},
        {'id': '', 'title': 'x'},
      ],
    });
    expect(c.title, 'Lista');
    expect(c.tracks.length, 1);
    expect(parseExploreRadio({'tracks': []}), isEmpty);
  });

  test('payload malformado falla en voz alta como extraction', () {
    for (final bad in <Object?>[null, 'x', [], {'shelves': 3}]) {
      expect(
        () => parseExploreHome(bad),
        throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.extraction)),
      );
    }
    expect(() => parseExplorePlaylists({'playlists': 'x'}), throwsA(isA<DownloadSourceException>()));
    expect(() => parseExploreCollection({'tracks': 1}), throwsA(isA<DownloadSourceException>()));
  });

  test('exploreCountryFromLocale', () {
    expect(exploreCountryFromLocale('co'), 'CO');
    expect(exploreCountryFromLocale(null), isNull);
    expect(exploreCountryFromLocale(''), isNull);
    expect(exploreCountryFromLocale('COL'), isNull);
  });

  test('artista: secciones, relacionados y tolerancia a secciones ausentes', () {
    final a = parseExploreArtist({
      'name': 'Art',
      'description': 'Bio',
      'thumbnailUrl': 'https://x/1',
      'subscribers': '15M',
      'topSongs': [
        {'id': 'abcdefghijk', 'title': 'S', 'artist': 'Art', 'durationSeconds': 0, 'thumbnailUrl': '', 'sourceUrl': 'u'},
        {'title': 'sin id'},
      ],
      'albums': [
        {'browseId': 'MPRE1', 'title': 'Alb', 'artist': 'Art', 'year': '2024', 'thumbnailUrl': ''},
        {'title': 'sin browse'},
      ],
      'related': [
        {'channelId': 'UC1', 'name': 'Otro', 'thumbnailUrl': 'https://x/2'},
        {'name': 'sin canal'},
      ],
    });
    expect(a.name, 'Art');
    expect(a.subscribers, '15M');
    expect(a.topSongs.single.id, 'abcdefghijk');
    expect(a.albums.single.browseId, 'MPRE1');
    expect(a.singles, isEmpty);
    expect(a.videos, isEmpty);
    expect(a.related.single.channelId, 'UC1');
  });

  test('artista: sin nombre o forma inválida falla en voz alta', () {
    expect(() => parseExploreArtist({'topSongs': []}), throwsA(isA<DownloadSourceException>()));
    expect(() => parseExploreArtist([]), throwsA(isA<DownloadSourceException>()));
    expect(() => parseExploreArtist({'name': 'A', 'albums': 'x'}), throwsA(isA<DownloadSourceException>()));
  });

  test('búsqueda de artistas descarta resultados sin canal', () {
    final hits = parseExploreArtistSearch({
      'artists': [
        {'channelId': 'UC1', 'name': 'Art', 'thumbnailUrl': 't', 'subscribers': '1M'},
        {'name': 'sin canal'},
      ],
    });
    expect(hits.single.channelId, 'UC1');
    expect(hits.single.subscribers, '1M');
    expect(() => parseExploreArtistSearch({'artists': 3}), throwsA(isA<DownloadSourceException>()));
  });
}
