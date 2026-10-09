// Verifica SyncProvider contra un CloudSource falso, sin red y sin
// AudioPlayerHandler (attachPlayback nunca se llama acá — no hace falta un
// doble de just_audio para probar la subida de historial/biblioteca).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/providers/sync_provider.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/database_helper.dart';

class _FakeCloudSource implements CloudSource {
  int libraryVersion = 0;
  int friendCount = 0;
  List<Map<String, dynamic>> historyRows = [];
  int pushHistoryCalls = 0;
  int pushLibraryCalls = 0;
  int getAccountCalls = 0;
  CloudSourceException? failNextWith;

  /// Error sólo para `pushHistory`, sin tocar el resto — el caso que importa
  /// para comprobar que un historial roto ya no secuestra a la biblioteca.
  CloudSourceException? failHistoryWith;

  /// El índice tal como lo guardaría el servidor. `pushLibrary` lo REEMPLAZA
  /// entero, igual que `library_store.py:push_library` (que borra lo ausente
  /// y reescribe `library_playlist_songs` de cero) — si el fake sólo
  /// acumulara, ningún test podría ver el borrado que se quiere evitar.
  List<Map<String, dynamic>> cloudSongs = [];
  List<Map<String, dynamic>> cloudPlaylists = [];
  List<Map<String, dynamic>> cloudPlaylistSongs = [];

  @override
  Future<CloudAccount> getAccount() async {
    getAccountCalls++;
    if (failNextWith != null) {
      final e = failNextWith!;
      failNextWith = null;
      throw e;
    }
    return CloudAccount(
      identity: 'firebase:test',
      username: 'isaac',
      libraryVersion: libraryVersion,
      hasLibrary: libraryVersion > 0,
      friendCount: friendCount,
      shareNowPlaying: shareNowPlayingOnServer,
    );
  }

  @override
  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes}) async {
    pushHistoryCalls++;
    if (failHistoryWith != null) throw failHistoryWith!;
    if (failNextWith != null) {
      final e = failNextWith!;
      failNextWith = null;
      throw e;
    }
    historyRows.addAll(rows);
    return HistoryPushResult(received: rows.length, stored: rows.length, skippedTooOld: 0);
  }

  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) async => CloudLibrary(
        version: libraryVersion,
        songs: cloudSongs,
        playlists: cloudPlaylists,
        playlistSongs: cloudPlaylistSongs,
      );

  @override
  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  }) async {
    pushLibraryCalls++;
    cloudSongs = [...songs];
    cloudPlaylists = [...playlists];
    cloudPlaylistSongs = [...playlistSongs];
    libraryVersion = baseVersion + 1;
    return libraryVersion;
  }

  // --- Sin usar en estos tests ---
  @override
  Future<void> acceptFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<void> clearPresence() async {}
  @override
  Future<void> deleteAccountData() async {}
  /// Historial "en la nube" para probar la bajada automática. `fakeHistoryPageSize`
  /// permite paginar con páginas chicas en los tests sin depender del límite
  /// real de 500 filas por página.
  List<Map<String, dynamic>> serverHistoryRows = [];
  int? fakeHistoryPageSize;
  List<String?> getHistoryCalls = [];

  @override
  Future<CloudHistoryPage> getHistory({String? cursor, int limit = 500}) async {
    getHistoryCalls.add(cursor);
    final effectiveLimit = fakeHistoryPageSize ?? limit;
    final start = cursor == null ? 0 : int.parse(cursor);
    final rows = serverHistoryRows.skip(start).take(effectiveLimit).toList();
    final end = start + rows.length;
    return CloudHistoryPage(
      rows: rows,
      nextCursor: rows.length == effectiveLimit ? '$end' : null,
    );
  }
  @override
  Future<FriendsList> getFriends() => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes}) =>
      throw UnimplementedError();
  @override
  Future<UserLookupResult> lookupUser(String username) => throw UnimplementedError();
  @override
  Future<void> putPresence({required String songId, required int expiresInSeconds}) async {}
  @override
  Future<void> rejectOrCancelFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<void> removeFriend(String username) => throw UnimplementedError();
  @override
  Future<String> sendFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<bool> setShareNowPlaying(bool enabled) async {
    shareNowPlayingOnServer = enabled;
    setShareCalls++;
    return enabled;
  }

  bool shareNowPlayingOnServer = false;
  int setShareCalls = 0;
  @override
  Future<String> setUsername(String username) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_sync_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    final rawDb = await db.database;
    await rawDb.delete('play_history');
    await rawDb.delete('songs');
    await rawDb.delete('playlists');
    await rawDb.delete('playlist_songs');
    // Cada SyncProvider nuevo debe partir sin hash persistido de una prueba
    // anterior — igual que un dispositivo que nunca sincronizó.
    SharedPreferences.setMockInitialValues({});
  });

  Future<String> insertSong(String id) async {
    await db.insertSong(Song(
      id: id,
      title: 't-$id',
      artist: 'a-$id',
      duration: 100,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime.now(),
      uri: 'content://x/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
    ));
    return id;
  }

  test('sube historial no sincronizado y lo marca synced', () async {
    final songId = await insertSong('s1');
    await db.recordPlay(songId, 60);

    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(source.historyRows, hasLength(1));
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, isEmpty);
  });

  test('una fila huérfana (canción borrada) se marca skipped sin llamar a la red', () async {
    final songId = await insertSong('s2');
    await db.recordPlay(songId, 30);
    await db.deleteSong(songId);

    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(source.pushHistoryCalls, 0);
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, isEmpty);
  });

  test('un fallo de red detiene la pasada sin marcar nada como sincronizado', () async {
    final songId = await insertSong('s3');
    await db.recordPlay(songId, 45);

    final source = _FakeCloudSource()
      ..failNextWith = const CloudSourceException(CloudSourceErrorKind.network, 'sin conexión');
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(provider.lastError, isNotNull);
    final unsynced = await db.getUnsyncedPlays();
    expect(unsynced, hasLength(1));
  });

  test('push de biblioteca se salta si el contenido no cambió desde la última subida', () async {
    await insertSong('s4');
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);

    await provider.syncNow();
    expect(source.pushLibraryCalls, 1);

    await provider.syncNow();
    // Nada cambió en la biblioteca local entre las dos pasadas: el hash de
    // contenido calculado del lado del cliente evita la segunda subida.
    expect(source.pushLibraryCalls, 1);
  });

  test('un cambio real en la biblioteca dispara una subida nueva', () async {
    await insertSong('s5');
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();
    expect(source.pushLibraryCalls, 1);

    await insertSong('s6');
    await provider.syncNow();
    expect(source.pushLibraryCalls, 2);
  });

  test('reentrada: llamar syncNow mientras ya está sincronizando es un no-op', () async {
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    final first = provider.syncNow();
    final second = provider.syncNow();
    await Future.wait([first, second]);
    // Sólo una pasada real corrió — getAccount() no se llamó dos veces en paralelo.
    expect(source.getAccountCalls, 1);
  });

  test('un historial que falla ya no impide subir la biblioteca', () async {
    final songId = await insertSong('s7');
    await db.recordPlay(songId, 60);

    final source = _FakeCloudSource()
      ..failHistoryWith = const CloudSourceException(CloudSourceErrorKind.badRequest, 'fila rechazada');
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    // El error del historial se ve...
    expect(provider.lastError, contains('historial'));
    expect(provider.lastError, isNot(contains('[historial]')));
    expect(provider.lastError, contains('Código: E-SY-HI-'));
    // ...pero la biblioteca subió igual. Con los dos pasos en el mismo `try`,
    // una fila de historial rechazada de forma permanente dejaba la
    // biblioteca sin subir para siempre.
    expect(source.pushLibraryCalls, 1);
    expect(source.cloudSongs, isNotEmpty);
  });

  test('una instalación nueva no borra de la nube lo que todavía no tiene', () async {
    // La nube ya tiene la biblioteca de otro dispositivo...
    final source = _FakeCloudSource()
      ..libraryVersion = 7
      ..cloudSongs = [
        {
          'songId': 'remota',
          'title': 'Sólo en el teléfono',
          'artist': 'X',
          'album': null,
          'durationSeconds': 200,
          'fileHash': 'remota',
          'hashKind': 'mp4-mdat',
        },
      ]
      ..cloudPlaylists = [
        {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0},
      ]
      ..cloudPlaylistSongs = [
        {'playlistId': 'p1', 'songId': 'remota', 'orderIndex': 0},
      ];

    // ...y este equipo acaba de instalarse: sólo tiene una canción distinta.
    await insertSong('local');
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    final ids = source.cloudSongs.map((s) => s['songId']).toSet();
    expect(ids, containsAll(<String>['remota', 'local']));
    expect(source.cloudPlaylists.map((p) => p['playlistId']), contains('p1'));
    expect(source.cloudPlaylistSongs, hasLength(1));
  });

  test('el payload no lleva columnas que el servidor rechazaría', () async {
    await insertSong('s8');
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    // `extra="forbid"` en los modelos de Pydantic: una columna de más
    // (uri, artPath, missing...) devuelve 422 y tira la subida entera.
    expect(
      source.cloudSongs.single.keys.toSet(),
      {'songId', 'title', 'artist', 'album', 'durationSeconds', 'fileHash', 'hashKind', 'sourceUrl'},
    );
  });

  test('una canción marcada como ausente sigue estando en el índice que se sube', () async {
    await insertSong('s9');
    final rawDb = await db.database;
    // Lo que hace el escaneo cuando el volumen no está montado: marca, nunca borra.
    await rawDb.update('songs', {'missing': 1});

    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    await provider.syncNow();

    expect(source.cloudSongs.map((s) => s['songId']), contains('s9'));
  });

  group('escuchando ahora: el interruptor llega al servidor', () {
    test('cambiarlo lo empuja al servidor y devuelve lo confirmado', () async {
      final source = _FakeCloudSource();
      final provider = SyncProvider(source: source, db: db, shareNowPlayingEnabled: () => true);

      expect(await provider.setShareNowPlaying(true), isTrue);
      expect(source.shareNowPlayingOnServer, isTrue);
      expect(await provider.setShareNowPlaying(false), isFalse);
      expect(source.shareNowPlayingOnServer, isFalse);
    });

    test('la sincronización corrige un servidor que no coincide con la preferencia local', () async {
      // El caso real: interruptor encendido en el teléfono desde una versión
      // que nunca se lo decía al servidor — los amigos veían "sin actividad".
      final source = _FakeCloudSource()..shareNowPlayingOnServer = false;
      final provider = SyncProvider(source: source, db: db, shareNowPlayingEnabled: () => true);
      await provider.syncNow();

      expect(source.setShareCalls, 1);
      expect(source.shareNowPlayingOnServer, isTrue);
      expect(provider.lastError, isNull);
    });

    test('si ya coinciden no se hace ninguna petición', () async {
      final source = _FakeCloudSource()..shareNowPlayingOnServer = true;
      final provider = SyncProvider(source: source, db: db, shareNowPlayingEnabled: () => true);
      await provider.syncNow();

      expect(source.setShareCalls, 0);
    });
  });

  group('insertRestoredPlays', () {
    Map<String, dynamic> play(String songId, String local) => {
          'songId': songId,
          'playedAtLocal': local,
          'playedAtUtc': '${local}Z',
          'playSeconds': 90,
        };

    test('reconstruye el historial y lo deja ya marcado como sincronizado', () async {
      await insertSong('r1');

      final inserted = await db.insertRestoredPlays([
        play('r1', '2026-08-01T10:00:00.000'),
        play('r1', '2026-08-02T10:00:00.000'),
      ]);

      expect(inserted, 2);
      // Vinieron del servidor: volver a subirlas gastaría cupo para escribir
      // filas que ya están allá.
      expect(await db.getUnsyncedPlays(), isEmpty);
    });

    test('traerlo dos veces no duplica nada', () async {
      await insertSong('r2');
      final rows = [play('r2', '2026-08-01T10:00:00.000')];

      expect(await db.insertRestoredPlays(rows), 1);
      expect(await db.insertRestoredPlays(rows), 0);
    });

    test('una fila cuya canción no está acá se descarta sin romper la inserción', () async {
      await insertSong('r3');

      // `play_history.songId` tiene clave foránea contra `songs` y
      // `PRAGMA foreign_keys = ON`: colar la huérfana tiraría el lote entero.
      final inserted = await db.insertRestoredPlays([
        play('r3', '2026-08-01T10:00:00.000'),
        play('canción-que-no-tengo', '2026-08-01T11:00:00.000'),
      ]);

      expect(inserted, 1);
    });

    test('no pisa una reproducción local con la misma clave natural', () async {
      final songId = await insertSong('r4');
      await db.recordPlay(songId, 30);
      final existing = (await db.getUnsyncedPlays()).single;

      final inserted = await db.insertRestoredPlays([
        play('r4', existing['playDate'] as String),
      ]);

      expect(inserted, 0);
    });
  });

  group('bajada automática de historial (syncNow)', () {
    Map<String, dynamic> remotePlay(String songId, String local) => {
          'songId': songId,
          'playedAtLocal': local,
          'playedAtUtc': '${local}Z',
          'playSeconds': 90,
        };

    test('trae lo que otro dispositivo subió, sin acción manual', () async {
      await insertSong('d1');
      final source = _FakeCloudSource()
        ..serverHistoryRows = [remotePlay('d1', '2026-08-01T10:00:00.000')];
      final provider = SyncProvider(source: source, db: db);

      await provider.syncNow();

      final rawDb = await db.database;
      expect(await rawDb.query('play_history'), hasLength(1));
    });

    test('una segunda pasada retoma desde el cursor guardado, no desde el principio', () async {
      await insertSong('d2');
      final source = _FakeCloudSource()
        ..fakeHistoryPageSize = 2
        ..serverHistoryRows = [
          remotePlay('d2', '2026-08-01T10:00:00.000'),
          remotePlay('d2', '2026-08-01T11:00:00.000'),
        ];
      final provider = SyncProvider(source: source, db: db);
      await provider.syncNow();

      final rawDb = await db.database;
      expect(await rawDb.query('play_history'), hasLength(2));
      // Página llena (2 de 2) + una página vacía para confirmar el fin.
      expect(source.getHistoryCalls, [null, '2']);

      // Otro dispositivo sube una reproducción más entre pasadas.
      source.serverHistoryRows.add(remotePlay('d2', '2026-08-01T12:00:00.000'));
      await provider.syncNow();

      expect(await rawDb.query('play_history'), hasLength(3));
      // La segunda pasada arranca del cursor guardado ('2'), no repite desde
      // cero: una sola petición más, no una pasada completa por las 2
      // primeras filas otra vez.
      expect(source.getHistoryCalls, [null, '2', '2']);
    });
  });

  test('noteUsernameSaved refleja el nombre al instante, sin esperar una sync completa', () async {
    final source = _FakeCloudSource();
    final provider = SyncProvider(source: source, db: db);
    expect(provider.account, isNull);

    provider.noteUsernameSaved('isaac');
    expect(provider.account?.username, 'isaac');
  });

  test('noteUsernameSaved sobrevive a una sync que falla después', () async {
    final source = _FakeCloudSource()
      ..failNextWith = const CloudSourceException(CloudSourceErrorKind.network, 'sin conexión');
    final provider = SyncProvider(source: source, db: db);
    provider.noteUsernameSaved('isaac');

    // getAccount() falla en esta pasada (simula el servidor caído) — el
    // nombre ya notificado no debe desaparecer de la UI por eso.
    await provider.syncNow();
    expect(provider.lastError, isNotNull);
    expect(provider.account?.username, 'isaac');
  });
}
