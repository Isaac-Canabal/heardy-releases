import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/models/explore.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

class _Client extends http.BaseClient {
  _Client(this.status, this.body);
  final int status;
  final Object body;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);
  }
}

YtdlpServerSource _source(_Client c) => YtdlpServerSource(
      baseUrl: () => 'http://servidor:8080',
      authToken: () async => 't',
      clientFactory: () => c,
    );

void main() {
  test('exploreHome manda país y auth y parsea estanterías', () async {
    final c = _Client(200, {
      'shelves': [
        {
          'title': 'Mix',
          'kind': 'playlists',
          'items': [
            {'playlistId': 'PL', 'title': 'T'}
          ]
        }
      ]
    });
    final shelves = await _source(c).exploreHome(country: 'CO');
    expect(shelves.single.playlists.single.playlistId, 'PL');
    final req = c.requests.single;
    expect(req.url.path, '/explore/home');
    expect(req.url.queryParameters['country'], 'CO');
    expect(req.headers['Authorization'], 'Bearer t');
  });

  test('rutas y parámetros de cada método', () async {
    final c = _Client(200, {'playlists': [], 'albums': [], 'sections': [], 'tracks': [], 'title': 'x'});
    final s = _source(c);
    await s.exploreCharts(country: 'US');
    await s.exploreNewReleases();
    await s.exploreMoods();
    await s.exploreMood('gg MP');
    await s.explorePlaylist('PL1');
    await s.exploreAlbum('MPRE1');
    await s.exploreRadio('abcdefghijk');
    final uris = c.requests.map((r) => r.url).toList();
    expect(uris[0].path, '/explore/charts');
    expect(uris[0].queryParameters['country'], 'US');
    expect(uris[1].path, '/explore/new-releases');
    expect(uris[2].path, '/explore/moods');
    expect(uris[3].path, '/explore/mood');
    expect(uris[3].queryParameters['params'], 'gg MP');
    expect(uris[4].path, '/explore/playlist/PL1');
    expect(uris[5].path, '/explore/album/MPRE1');
    expect(uris[6].path, '/explore/radio');
    expect(uris[6].queryParameters['seed'], 'abcdefghijk');
  });

  test('fresh=1 sólo se manda cuando se pide', () async {
    final c = _Client(200, {'playlists': [], 'albums': [], 'sections': [], 'shelves': []});
    final s = _source(c);
    await s.exploreCharts();
    await s.exploreCharts(fresh: true);
    await s.exploreHome(fresh: true);
    await s.exploreNewReleases(fresh: true);
    await s.exploreMoods(country: 'CO', fresh: true);
    final q = c.requests.map((r) => r.url.queryParameters).toList();
    expect(q[0].containsKey('fresh'), isFalse);
    expect(q[1]['fresh'], '1');
    expect(q[2]['fresh'], '1');
    expect(q[3]['fresh'], '1');
    expect(q[4], {'country': 'CO', 'fresh': '1'});
  });

  test('502 explore_unavailable es extraction (reintentable)', () async {
    final c = _Client(502, {'detail': 'x', 'reason': 'explore_unavailable'});
    await expectLater(
      _source(c).exploreCharts(),
      throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.extraction)),
    );
  });

  test('404 explore_not_found es notFound', () async {
    final c = _Client(404, {'detail': 'x', 'reason': 'explore_not_found'});
    await expectLater(
      _source(c).explorePlaylist('PLnope'),
      throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.notFound)),
    );
  });

  test('cuerpo mal formado falla como extraction', () async {
    final c = _Client(200, [1, 2]);
    await expectLater(
      _source(c).exploreHome(),
      throwsA(isA<DownloadSourceException>().having((e) => e.kind, 'kind', DownloadSourceErrorKind.extraction)),
    );
  });

  test('exploreArtist y exploreArtistSearch: rutas y parseo', () async {
    final c = _Client(200, {'name': 'Art', 'artists': [
      {'channelId': 'UC1', 'name': 'Art'}
    ]});
    final s = _source(c);
    final artist = await s.exploreArtist('UCabc');
    final hits = await s.exploreArtistSearch('bad bunny');
    expect(artist.name, 'Art');
    expect(hits.single.channelId, 'UC1');
    expect(c.requests[0].url.path, '/explore/artist/UCabc');
    expect(c.requests[1].url.path, '/explore/artist-search');
    expect(c.requests[1].url.queryParameters['q'], 'bad bunny');
  });

  test('exploreSearch manda q, type y país, y parsea según el tipo', () async {
    final c = _Client(200, {
      'playlists': [
        {'playlistId': 'PL1', 'title': 'Rock', 'subtitle': 'Ana'}
      ],
      'albums': [
        {'browseId': 'MPRE1', 'title': 'Alb', 'artist': 'Col', 'year': '2014'}
      ],
      'artists': [
        {'channelId': 'UC1', 'name': 'Art'}
      ],
    });
    final s = _source(c);
    final pl = await s.exploreSearch('rock', ExploreSearchKind.playlists, country: 'CO');
    final al = await s.exploreSearch('cold', ExploreSearchKind.albums);
    final ar = await s.exploreSearch('art', ExploreSearchKind.artists);
    expect(pl.playlists.single.playlistId, 'PL1');
    expect(pl.albums, isEmpty);
    expect(al.albums.single.browseId, 'MPRE1');
    expect(ar.artists.single.channelId, 'UC1');
    final q = c.requests[0].url;
    expect(q.path, '/explore/search');
    expect(q.queryParameters, {'q': 'rock', 'type': 'playlists', 'country': 'CO'});
    expect(c.requests[1].url.queryParameters.containsKey('country'), isFalse);
    expect(c.requests[2].url.queryParameters['type'], 'artists');
  });
}
