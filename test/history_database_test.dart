// stream_history y getLocalHistory contra sqflite_common_ffi, y la migración
// desde la versión anterior (14).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/history_entry.dart';
import 'package:heardy/services/database_helper.dart';

HistoryEntry _s(String id, DateTime at) => HistoryEntry(
      isStream: true,
      videoId: id,
      title: 'Título $id',
      artist: 'Artista',
      artUrl: 'https://i.ytimg.com/$id.jpg',
      durationSeconds: 100,
      playedAt: at,
    );

void main() {
  late Directory sandbox;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    sandbox = Directory.systemTemp.createTempSync('heardy_history_db_test_');
    await databaseFactory.setDatabasesPath(sandbox.path);
    final path = join(sandbox.path, 'heardy.db');
    // Base v14 mínima con una fila vieja: debe sobrevivir a la migración.
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE songs (id TEXT PRIMARY KEY, title TEXT)');
          await db.execute('CREATE TABLE play_history (id INTEGER PRIMARY KEY AUTOINCREMENT, songId TEXT)');
          await db.insert('songs', {'id': 'x', 'title': 'vieja'});
        },
      ),
    );
    await old.close();
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('migración 14 -> 15 crea stream_history sin tocar lo existente', () async {
    final db = await DatabaseHelper.instance.database;
    expect(await db.getVersion(), 15);
    final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='stream_history'");
    expect(tables, hasLength(1));
    expect(await db.query('songs'), hasLength(1));
  });

  group('stream_history', () {
    setUp(() => DatabaseHelper.instance.clearStreamHistory());

    test('misma pista: actualiza playedAt en vez de duplicar', () async {
      final h = DatabaseHelper.instance;
      await h.recordStreamPlay(_s('a', DateTime(2026, 1, 1)));
      await h.recordStreamPlay(_s('a', DateTime(2026, 2, 1)));
      final rows = await h.getStreamHistory();
      expect(rows, hasLength(1));
      expect(rows.single.playedAt, DateTime(2026, 2, 1));
      expect(rows.single.artUrl, 'https://i.ytimg.com/a.jpg');
    });

    test('poda a maxRows conservando las más recientes, orden descendente', () async {
      final h = DatabaseHelper.instance;
      for (var i = 0; i < 6; i++) {
        await h.recordStreamPlay(_s('v$i', DateTime(2026, 1, 1 + i)), maxRows: 4);
      }
      final rows = await h.getStreamHistory();
      expect([for (final r in rows) r.videoId], ['v5', 'v4', 'v3', 'v2']);
    });

    test('clearStreamHistory vacía la tabla', () async {
      final h = DatabaseHelper.instance;
      await h.recordStreamPlay(_s('a', DateTime(2026, 1, 1)));
      await h.clearStreamHistory();
      expect(await h.getStreamHistory(), isEmpty);
    });
  });
}
