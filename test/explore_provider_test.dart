import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/explore.dart';
import 'package:heardy/models/song.dart';
import 'package:heardy/providers/explore_provider.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_source.dart';

const _a = 'aaaaaaaaaaa';
const _b = 'bbbbbbbbbbb';
const _x = 'xxxxxxxxxxx';
const _y = 'yyyyyyyyyyy';

String _yt(String id) => 'https://www.youtube.com/watch?v=$id';

RemoteTrack _t(String id) => RemoteTrack(
      id: id,
      title: 'T $id',
      artist: 'A',
      album: null,
      durationSeconds: 100,
      thumbnailUrl: '',
      sourceUrl: _yt(id),
    );

Song _song(String id, String artist, String? url) => Song(
      id: id,
      title: 'Canción $id',
      artist: artist,
      duration: 180,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime(2026, 1, 1),
      uri: 'content://fake/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
      sourceUrl: url,
    );

class _FakeSource implements DownloadSource {
  final radioSeeds = <String>[];
  int chartsCalls = 0;
  bool failCharts = false;
  final Map<String, List<RemoteTrack>> radioBySeed = {};

  @override
  Future<List<RemoteTrack>> exploreRadio(String seedVideoId) async {
    radioSeeds.add(seedVideoId);
    return radioBySeed[seedVideoId] ?? const [];
  }

  @override
  Future<List<ExplorePlaylist>> exploreCharts({String? country}) async {
    chartsCalls++;
    if (failCharts) throw DownloadSourceException(DownloadSourceErrorKind.network, 'x');
    return const [ExplorePlaylist(playlistId: 'PL1', title: 'Top')];
  }

  @override
  Future<List<ExploreAlbum>> exploreNewReleases({String? country}) async =>
      const [ExploreAlbum(browseId: 'MPRE1', title: 'Álbum')];

  @override
  Future<List<ExploreShelf>> exploreHome({String? country}) async => const [
        ExploreShelf(
          title: 'Para ti',
          kind: ExploreShelfKind.playlists,
          playlists: [ExplorePlaylist(playlistId: 'PL2', title: 'Mix')],
        ),
      ];

  @override
  Future<List<ExploreMoodSection>> exploreMoods({String? country}) async => const [
        ExploreMoodSection(title: 'Moods', moods: [ExploreMood(title: 'Chill', params: 'p')]),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _play(String songId) async {
  final db = await DatabaseHelper.instance.database;
  await db.insert('play_history', {
    'songId': songId,
    'playDate': DateTime.now().toIso8601String(),
    'playDuration': 60,
  });
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final sandbox = Directory.systemTemp.createTempSync('heardy_explore_provider_test_');
    await databaseFactory.setDatabasesPath(sandbox.path);
    await databaseFactory.deleteDatabase(join(sandbox.path, 'heardy.db'));
  });

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('play_history');
    await db.delete('songs');
  });

  test('loadLocal llena recientes y artistas desde el historial', () async {
    final h = DatabaseHelper.instance;
    await h.insertSong(_song('s1', 'Artista Uno', null));
    await h.insertSong(_song('s2', 'Artista Dos', null));
    await _play('s1');
    await _play('s2');
    await _play('s2');
    final provider = ExploreProvider(source: _FakeSource());

    await provider.loadLocal();

    expect(provider.recent.data!.map((s) => s.id), ['s2', 's1']);
    expect(provider.artists.data, ['Artista Dos', 'Artista Uno']);
  });

  test('radio: semillas más escuchadas, sin pistas ya locales, y caché de sesión', () async {
    final h = DatabaseHelper.instance;
    await h.insertSong(_song('s1', 'A', _yt(_a)));
    await h.insertSong(_song('s2', 'B', _yt(_b)));
    await h.insertSong(_song('s3', 'C', _yt(_x)));
    await _play('s1');
    await _play('s1');
    await _play('s2');
    final source = _FakeSource()
      ..radioBySeed[_a] = [_t(_x), _t(_y)]
      ..radioBySeed[_b] = [_t(_y), _t('zzzzzzzzzzz')];
    final provider = ExploreProvider(source: source);

    await provider.loadNetwork();

    expect(source.radioSeeds, [_a, _b]);
    expect(provider.radio.data!.map((t) => t.id), [_y, 'zzzzzzzzzzz']);

    await provider.loadNetwork();
    expect(source.radioSeeds, hasLength(2));
    expect(source.chartsCalls, 1);
  });

  test('sin semillas la radio queda vacía y no pide nada', () async {
    final source = _FakeSource();
    final provider = ExploreProvider(source: source);

    await provider.loadNetwork();

    expect(provider.radio.data, isEmpty);
    expect(source.radioSeeds, isEmpty);
  });

  test('una estantería que falla no arrastra a las demás y refresh la reintenta', () async {
    final source = _FakeSource()..failCharts = true;
    final provider = ExploreProvider(source: source);

    await provider.loadNetwork();

    expect(provider.charts.hasError, isTrue);
    expect(provider.newReleases.data, hasLength(1));
    expect(provider.home.data, hasLength(1));
    expect(provider.moods.data, hasLength(1));

    // Sin refresh no se reintenta (cambiar de pestaña no debe martillar).
    await provider.loadNetwork();
    expect(source.chartsCalls, 1);

    source.failCharts = false;
    await provider.refresh();
    expect(provider.charts.hasError, isFalse);
    expect(provider.charts.data, hasLength(1));
  });

  test('refreshIfStale: fresco no vuelve a pedir; vencido sí; con error reintenta', () async {
    var clock = DateTime(2026, 10, 9, 8);
    final source = _FakeSource();
    final provider = ExploreProvider(source: source, now: () => clock);

    await provider.refreshIfStale();
    expect(source.chartsCalls, 1);

    clock = clock.add(const Duration(minutes: 10));
    await provider.refreshIfStale();
    expect(source.chartsCalls, 1);

    clock = clock.add(const Duration(minutes: 6));
    await provider.refreshIfStale();
    expect(source.chartsCalls, 2);
    // Mientras recarga conserva lo anterior (sin parpadeo a esqueleto).
    expect(provider.charts.data, hasLength(1));

    source.failCharts = true;
    clock = clock.add(const Duration(hours: 1));
    await provider.refreshIfStale();
    expect(provider.charts.hasError, isTrue);
    expect(provider.charts.data, hasLength(1));

    // Una estantería caída no da el refresco por bueno: la siguiente entrada reintenta.
    source.failCharts = false;
    clock = clock.add(const Duration(minutes: 1));
    await provider.refreshIfStale();
    expect(provider.charts.hasError, isFalse);
    expect(source.chartsCalls, 4);
  });

  test('findLocalSong encuentra la descargada por id de vídeo y no las que faltan', () async {
    final h = DatabaseHelper.instance;
    await h.insertSong(_song('s1', 'A', 'https://music.youtube.com/watch?v=$_a&list=z'));
    final provider = ExploreProvider(source: _FakeSource());

    expect((await provider.findLocalSong(_a))?.id, 's1');
    expect(await provider.findLocalSong(_b), isNull);

    final db = await h.database;
    await db.update('songs', {'missing': 1}, where: 'id = ?', whereArgs: ['s1']);
    expect(await provider.findLocalSong(_a), isNull);
  });
}
