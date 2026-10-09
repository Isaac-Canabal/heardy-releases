import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/services/database_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_restored_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    final raw = await db.database;
    await raw.delete('play_history');
    await raw.delete('songs');
  });

  Map<String, dynamic> row(String songId, int n) => {
        'songId': songId,
        'playedAtLocal': '2026-01-01T00:00:0$n',
        'playedAtUtc': '2026-01-01T00:00:0${n}Z',
        'playSeconds': 10,
      };

  test('con contexto precargado, varias páginas no duplican ni releen', () async {
    await db.insertSong(Song(
      id: 'a',
      title: 't',
      artist: 'a',
      duration: 1,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime.now(),
      uri: 'content://x/a',
      fileHash: 'a',
      hashKind: 'mp4-mdat',
    ));
    final ctx = await db.loadRestoreContext();
    final first = await db.insertRestoredPlays([row('a', 1), row('a', 2), row('zz', 3)],
        knownSongs: ctx.knownSongs, existingKeys: ctx.existingKeys);
    final second = await db.insertRestoredPlays([row('a', 2), row('a', 4)],
        knownSongs: ctx.knownSongs, existingKeys: ctx.existingKeys);
    expect(first, 2);
    expect(second, 1);
    final count = (await (await db.database).rawQuery('SELECT COUNT(*) c FROM play_history')).first['c'];
    expect(count, 3);
  });
}
