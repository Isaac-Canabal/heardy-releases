import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/smart_lists.dart';

Song _song(String id, {DateTime? added, bool missing = false}) => Song(
      id: id,
      title: id,
      artist: 'Artista',
      duration: 180,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: added ?? DateTime(2026, 1, 1),
      uri: 'content://fake/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
      missing: missing,
    );

SongPlayStat _stat(String id, {int plays = 0, DateTime? last, DateTime? added}) =>
    SongPlayStat(song: _song(id, added: added), playCount: plays, lastPlayed: last);

List<String> _ids(List<SongPlayStat> l) => [for (final s in l) s.song.id];

void main() {
  final now = DateTime(2026, 10, 10);

  group('buildSmartList', () {
    test('mostPlayed ordena por reproducciones y desempata por la más reciente', () {
      final stats = [
        _stat('a', plays: 2, last: DateTime(2026, 9, 1)),
        _stat('b', plays: 5, last: DateTime(2026, 8, 1)),
        _stat('c', plays: 2, last: DateTime(2026, 10, 1)),
        _stat('d'),
      ];
      expect(_ids(buildSmartList(SmartListKind.mostPlayed, stats, now)), ['b', 'c', 'a']);
    });

    test('recentlyAdded ordena por fecha de alta y respeta el límite', () {
      final stats = [
        _stat('a', added: DateTime(2026, 1, 1)),
        _stat('b', added: DateTime(2026, 3, 1)),
        _stat('c', added: DateTime(2026, 2, 1)),
      ];
      expect(_ids(buildSmartList(SmartListKind.recentlyAdded, stats, now, limit: 2)), ['b', 'c']);
    });

    test('neverPlayed sólo incluye canciones sin reproducciones, nuevas primero', () {
      final stats = [
        _stat('a', added: DateTime(2026, 1, 1)),
        _stat('b', plays: 1, last: now),
        _stat('c', added: DateTime(2026, 5, 1)),
      ];
      expect(_ids(buildSmartList(SmartListKind.neverPlayed, stats, now)), ['c', 'a']);
    });

    test('forgotten exige haberla escuchado y que pase el umbral', () {
      final stats = [
        _stat('viejaPoco', plays: 1, last: now.subtract(const Duration(days: 200))),
        _stat('viejaMucho', plays: 9, last: now.subtract(const Duration(days: 120))),
        _stat('reciente', plays: 9, last: now.subtract(const Duration(days: 10))),
        _stat('nunca'),
        _stat('justoUmbral', plays: 3, last: now.subtract(forgottenThreshold)),
      ];
      expect(
        _ids(buildSmartList(SmartListKind.forgotten, stats, now)),
        ['viejaMucho', 'justoUmbral', 'viejaPoco'],
      );
    });

    test('lista vacía devuelve vacío', () {
      for (final k in SmartListKind.values) {
        expect(buildSmartList(k, const [], now), isEmpty);
      }
    });
  });

  group('getSongPlayStats', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final sandbox = Directory.systemTemp.createTempSync('heardy_smart_lists_test_');
      await databaseFactory.setDatabasesPath(sandbox.path);
      await databaseFactory.deleteDatabase(join(sandbox.path, 'heardy.db'));
    });

    test('cuenta reproducciones, última fecha, incluye nunca escuchadas y omite faltantes', () async {
      final h = DatabaseHelper.instance;
      final db = await h.database;
      await db.delete('play_history');
      await db.delete('songs');
      await h.insertSong(_song('s1'));
      await h.insertSong(_song('s2'));
      await h.insertSong(_song('s3', missing: true));
      for (final d in [DateTime(2026, 5, 1), DateTime(2026, 6, 1)]) {
        await db.insert('play_history', {
          'songId': 's1',
          'playDate': d.toIso8601String(),
          'playDuration': 60,
        });
      }

      final stats = {for (final s in await h.getSongPlayStats()) s.song.id: s};

      expect(stats.keys.toSet(), {'s1', 's2'});
      expect(stats['s1']!.playCount, 2);
      expect(stats['s1']!.lastPlayed, DateTime(2026, 6, 1));
      expect(stats['s2']!.playCount, 0);
      expect(stats['s2']!.lastPlayed, isNull);
    });
  });
}
