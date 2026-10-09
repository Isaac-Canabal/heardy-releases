// Consultas locales de Explorar contra una base sqflite_common_ffi sembrada.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/services/database_helper.dart';

Song _song(String id, String title, {String? sourceUrl, bool missing = false}) => Song(
      id: id,
      title: title,
      artist: 'Artista',
      duration: 180,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime(2026, 1, 1),
      uri: 'content://fake/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
      sourceUrl: sourceUrl,
      missing: missing,
    );

Future<void> _play(String songId, DateTime when) async {
  final db = await DatabaseHelper.instance.database;
  await db.insert('play_history', {
    'songId': songId,
    'playDate': when.toIso8601String(),
    'playDuration': 60,
  });
}

String _yt(String id) => 'https://www.youtube.com/watch?v=$id';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final sandbox = Directory.systemTemp.createTempSync('heardy_explore_db_test_');
    await databaseFactory.setDatabasesPath(sandbox.path);
    await databaseFactory.deleteDatabase(join(sandbox.path, 'heardy.db'));
  });

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('play_history');
    await db.delete('songs');
  });

  group('getRecentlyPlayedSongs', () {
    test('ordena por última reproducción y no repite canciones', () async {
      final h = DatabaseHelper.instance;
      await h.insertSong(_song('s1', 'Uno'));
      await h.insertSong(_song('s2', 'Dos'));
      await h.insertSong(_song('s3', 'Tres'));
      final now = DateTime(2026, 5, 10, 12);
      await _play('s1', now.subtract(const Duration(hours: 5)));
      await _play('s2', now.subtract(const Duration(hours: 3)));
      await _play('s1', now.subtract(const Duration(hours: 1)));

      final songs = await h.getRecentlyPlayedSongs(limit: 10);

      expect(songs.map((s) => s.id), ['s1', 's2']);
    });

    test('respeta limit, omite faltantes y devuelve vacío sin historial', () async {
      final h = DatabaseHelper.instance;
      expect(await h.getRecentlyPlayedSongs(limit: 5), isEmpty);

      await h.insertSong(_song('s1', 'Uno'));
      await h.insertSong(_song('s2', 'Dos'));
      await h.insertSong(_song('s3', 'Tres', missing: true));
      final now = DateTime(2026, 5, 10, 12);
      await _play('s1', now.subtract(const Duration(hours: 3)));
      await _play('s2', now.subtract(const Duration(hours: 2)));
      await _play('s3', now.subtract(const Duration(hours: 1)));

      final songs = await h.getRecentlyPlayedSongs(limit: 1);

      expect(songs.map((s) => s.id), ['s2']);
    });
  });

  group('getMostPlayedYoutubeSourceUrls', () {
    test('ordena por reproducciones y sólo incluye URLs de YouTube', () async {
      final h = DatabaseHelper.instance;
      await h.insertSong(_song('s1', 'Uno', sourceUrl: _yt('aaaaaaaaaaa')));
      await h.insertSong(_song('s2', 'Dos', sourceUrl: _yt('bbbbbbbbbbb')));
      await h.insertSong(_song('s3', 'Tres', sourceUrl: 'https://example.com/x'));
      await h.insertSong(_song('s4', 'Cuatro'));
      final now = DateTime(2026, 5, 10, 12);
      await _play('s1', now);
      await _play('s2', now);
      await _play('s2', now);
      await _play('s3', now);
      await _play('s3', now);
      await _play('s3', now);
      await _play('s4', now);

      final urls = await h.getMostPlayedYoutubeSourceUrls(limit: 10);

      expect(urls, [_yt('bbbbbbbbbbb'), _yt('aaaaaaaaaaa')]);
    });

    test('sin historial devuelve vacío', () async {
      expect(await DatabaseHelper.instance.getMostPlayedYoutubeSourceUrls(limit: 3), isEmpty);
    });
  });
}
