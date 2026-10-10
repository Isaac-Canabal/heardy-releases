// Bajada de historial: pasadas completas vs incrementales (H1).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/providers/sync_provider.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/database_helper.dart';

class _FakeCloud implements CloudSource {
  List<Map<String, dynamic>> serverHistoryRows = [];
  int pageSize = 2;
  final List<String?> getHistoryCalls = [];
  int getAccountCalls = 0;
  int libraryVersion = 0;

  @override
  Future<CloudAccount> getAccount() async {
    getAccountCalls++;
    return CloudAccount(
      identity: 'firebase:test',
      username: 'isaac',
      libraryVersion: libraryVersion,
      hasLibrary: false,
      friendCount: 0,
    );
  }

  @override
  Future<CloudHistoryPage> getHistory({String? cursor, int limit = 500}) async {
    getHistoryCalls.add(cursor);
    final start = cursor == null ? 0 : int.parse(cursor);
    final rows = serverHistoryRows.skip(start).take(pageSize).toList();
    return CloudHistoryPage(
      rows: rows,
      nextCursor: rows.length == pageSize ? '${start + rows.length}' : null,
    );
  }

  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) async =>
      CloudLibrary(version: libraryVersion, songs: [], playlists: [], playlistSongs: []);

  @override
  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  }) async =>
      ++libraryVersion;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _row(String songId, int n) => {
      'songId': songId,
      'playedAtLocal': '2026-01-01T00:00:0$n',
      'playedAtUtc': '2026-01-01T00:00:0${n}Z',
      'playSeconds': 30,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_hist_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    final raw = await db.database;
    await raw.delete('play_history');
    await raw.delete('songs');
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> insertSong(String id) => db.insertSong(Song(
        id: id,
        title: 't-$id',
        artist: 'a',
        duration: 100,
        filePath: '',
        artPath: '',
        format: 'm4a',
        downloadDate: DateTime.now(),
        uri: 'content://x/$id',
        fileHash: id,
        hashKind: 'mp4-mdat',
      ));

  Future<int> playCount() async =>
      (await (await db.database).rawQuery('SELECT COUNT(*) c FROM play_history')).first['c'] as int;

  test('pull de varias páginas inserta todo y avanza historyRevision', () async {
    await insertSong('a');
    final cloud = _FakeCloud()..serverHistoryRows = [for (var i = 0; i < 5; i++) _row('a', i)];
    final provider = SyncProvider(source: cloud, db: db);
    expect(provider.historyRevision, 0);
    await provider.syncNow();
    expect(await playCount(), 5);
    expect(provider.historyRevision, 1);
    await provider.syncNow();
    expect(provider.historyRevision, 1);
  });

  test('la pasada automática usa el cursor guardado', () async {
    await insertSong('a');
    final cloud = _FakeCloud()..serverHistoryRows = [for (var i = 0; i < 3; i++) _row('a', i)];
    final provider = SyncProvider(source: cloud, db: db);
    await provider.syncNow();
    cloud.getHistoryCalls.clear();
    await provider.syncNow();
    expect(cloud.getHistoryCalls.first, '2');
  });

  test('el manual (fullHistory) relee desde el principio y trae filas tardías', () async {
    await insertSong('a');
    final cloud = _FakeCloud()..serverHistoryRows = [for (var i = 1; i < 4; i++) _row('a', i)];
    final provider = SyncProvider(source: cloud, db: db);
    await provider.syncNow();
    expect(await playCount(), 3);

    // Otro dispositivo sube tarde una fila con played_at más viejo: queda
    // detrás del cursor.
    cloud.serverHistoryRows.insert(0, _row('a', 0));
    await provider.syncNow();
    expect(await playCount(), 3);

    cloud.getHistoryCalls.clear();
    await provider.syncNow(fullHistory: true);
    expect(cloud.getHistoryCalls.first, isNull);
    expect(await playCount(), 4);
  });

  test('un cambio en la biblioteca local fuerza pasada completa', () async {
    await insertSong('a');
    final cloud = _FakeCloud()..serverHistoryRows = [for (var i = 0; i < 3; i++) _row('a', i)];
    final provider = SyncProvider(source: cloud, db: db);
    await provider.syncNow();

    await insertSong('b');
    cloud.getHistoryCalls.clear();
    await provider.syncNow();
    expect(cloud.getHistoryCalls.first, isNull);
  });

  test('filas de una canción que aún no existía entran cuando aparece', () async {
    await insertSong('a');
    final cloud = _FakeCloud()
      ..serverHistoryRows = [_row('a', 0), _row('late', 1), _row('a', 2), _row('late', 3)];
    final provider = SyncProvider(source: cloud, db: db);
    await provider.syncNow();
    expect(await playCount(), 2);

    await insertSong('late');
    await provider.syncNow();
    expect(await playCount(), 4);
  });

  test('una pasada completa de hace más de 24 h fuerza pasada completa', () async {
    await insertSong('a');
    final cloud = _FakeCloud()..serverHistoryRows = [for (var i = 0; i < 3; i++) _row('a', i)];
    await SyncProvider(source: cloud, db: db).syncNow();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'sync_last_full_history_at',
      DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch,
    );
    cloud.getHistoryCalls.clear();
    await SyncProvider(source: cloud, db: db).syncNow();
    expect(cloud.getHistoryCalls.first, isNull);

    cloud.getHistoryCalls.clear();
    await SyncProvider(source: cloud, db: db).syncNow();
    expect(cloud.getHistoryCalls.first, '2');
  });
}
