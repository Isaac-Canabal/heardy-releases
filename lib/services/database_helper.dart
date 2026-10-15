import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/song.dart';
import '../models/statistics_data.dart' show mergeTopSongRows;
import '../models/playlist.dart';
import '../models/remote_track_record.dart';
import '../models/history_entry.dart';
import 'explore_logic.dart' show youtubeVideoId;
import 'history_logic.dart' show maxStreamHistoryRows;
import 'library_storage.dart';
import 'smart_lists.dart';
import 'app_log.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('heardy.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 16,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future _onConfigure(Database db) async {
    // Enable Foreign Key support in SQLite to allow ON DELETE CASCADE
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future _createDB(Database db, int version) async {
    // Create songs table
    await db.execute('''
      CREATE TABLE songs (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        duration INTEGER NOT NULL,
        filePath TEXT NOT NULL,
        artPath TEXT NOT NULL,
        format TEXT NOT NULL,
        downloadDate TEXT NOT NULL,
        uri TEXT,
        fileHash TEXT,
        hashKind TEXT,
        fileSize INTEGER,
        modifiedAt INTEGER,
        album TEXT,
        missing INTEGER NOT NULL DEFAULT 0,
        ignoredFromInbox INTEGER NOT NULL DEFAULT 0,
        sourceUrl TEXT
      )
    ''');

    // Create playlists table
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        creationDate TEXT NOT NULL,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        originalUrl TEXT,
        kind TEXT NOT NULL DEFAULT 'local'
      )
    ''');

    // Create playlist_songs join table with foreign keys and cascade delete
    await db.execute('''
      CREATE TABLE playlist_songs (
        playlistId TEXT,
        songId TEXT,
        orderIndex INTEGER NOT NULL,
        PRIMARY KEY (playlistId, songId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');

    // Download queue, reintroduced in v11 on the download branch with a
    // generic shape (sourceType/sourceId) instead of the old one's loose
    // `spotify*` columns. The v10 drop of the historical table stands; this
    // is a new table that happens to reuse the name.
    await db.execute(_createDownloadQueueSql);
    await db.execute(_createDownloadQueueIndexSql);

    // Servidor oficial en un PC de casa: no siempre está prendido. Guarda una
    // URL pegada mientras no se pudo ni siquiera resolver (el servidor no
    // respondió) para reintentarla sola cuando vuelva a estar disponible. Ver
    // CLAUDE.md, "Lista de espera".
    await db.execute(_createPendingImportsSql);
    await db.execute(_createPendingImportsIndexSql);

    // Create play_history table for statistics
    await db.execute('''
      CREATE TABLE play_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        songId TEXT NOT NULL,
        playDate TEXT NOT NULL,
        playDuration INTEGER NOT NULL,
        syncedAt TEXT,
        playedAtUtc TEXT,
        FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_play_history_synced ON play_history(syncedAt)',
    );
    await db.execute(_createStreamHistorySql);
    await db.execute(_createStreamHistoryIndexSql);
    for (final sql in _onlinePlaylistSql) {
      await db.execute(sql);
    }
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS download_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          videoId TEXT NOT NULL,
          playlistId TEXT NOT NULL,
          addedDate TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE playlists ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0',
      );
      final rows = await db.query('playlists', orderBy: 'creationDate ASC');
      for (var i = 0; i < rows.length; i++) {
        await db.update(
          'playlists',
          {'sortOrder': i},
          where: 'id = ?',
          whereArgs: [rows[i]['id']],
        );
      }
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE playlists ADD COLUMN originalUrl TEXT',
      );
    }
    if (oldVersion < 5) {
      await db.execute("ALTER TABLE download_queue ADD COLUMN source TEXT DEFAULT 'youtube'");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyTitle TEXT");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyArtist TEXT");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyDurationMs INTEGER");
      await db.execute("ALTER TABLE download_queue ADD COLUMN spotifyThumbnailUrl TEXT");
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS play_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          songId TEXT NOT NULL,
          playDate TEXT NOT NULL,
          playDuration INTEGER NOT NULL,
          FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
        )
      ''');
    }
    if (oldVersion < 7) {
      // Add expectedOrderIndex to preserve playlist order during parallel downloads
      await db.execute(
        'ALTER TABLE download_queue ADD COLUMN expectedOrderIndex INTEGER',
      );
    }
    if (oldVersion < 8) {
      // Local-library pivot: SAF-imported songs identify by uri/fileHash
      // instead of filePath. Additive only — legacy rows keep working via
      // Song.playablePath (uri ?? filePath). See CLAUDE.md D9.
      await db.execute('ALTER TABLE songs ADD COLUMN uri TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN fileHash TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN hashKind TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN fileSize INTEGER');
      await db.execute('ALTER TABLE songs ADD COLUMN modifiedAt INTEGER');
      await db.execute('ALTER TABLE songs ADD COLUMN album TEXT');
      await db.execute(
        'ALTER TABLE songs ADD COLUMN missing INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 9) {
      // Inbox (D6): lets the user dismiss a stray/unwanted imported file
      // from the assignment screen without it reappearing on every scan.
      // Never touched by the scanner itself — only by an explicit user action.
      await db.execute(
        'ALTER TABLE songs ADD COLUMN ignoredFromInbox INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 10) {
      // The download pipeline that owned this table was pruned in Stage 5 —
      // see CLAUDE.md. Safe to drop outright: it only ever held in-flight
      // download jobs, nothing a user would expect to survive an update.
      await db.execute('DROP TABLE IF EXISTS download_queue');
    }
    if (oldVersion < 11) {
      // Download branch. `sourceUrl` lets an import detect "already
      // downloaded" without spending a request, and gives PlaylistDetail a
      // way to tell which tracks of a YouTube playlist are still missing.
      await db.execute('ALTER TABLE songs ADD COLUMN sourceUrl TEXT');
      // Recreate the queue with a generic shape. The old table (dropped in
      // v10) hardcoded `spotify*` columns; this one carries a sourceType so
      // YouTube and Spotify jobs share one code path.
      await db.execute('DROP TABLE IF EXISTS download_queue');
      await db.execute(_createDownloadQueueSql);
      await db.execute(_createDownloadQueueIndexSql);
    }
    if (oldVersion < 12) {
      // Un trabajo encolado desde /search o desde la expansión de una
      // playlist trae metadata "plana" (`extract_flat`), donde el artista es
      // en realidad el nombre del canal. Antes de descargar hay que pedir la
      // definitiva con /resolve — pero un trabajo encolado desde una URL
      // suelta ya la tiene, porque la vista previa la resolvió.
      //
      // Esta columna es lo que distingue ambos casos. Sin ella habría que
      // resolver siempre, y una descarga pasaría de 2 extracciones a 3 sobre
      // un presupuesto por IP medido en 12-24 peticiones.
      await db.execute(
        'ALTER TABLE download_queue ADD COLUMN metadataComplete INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 13) {
      // Lista de espera: una URL pegada cuando el servidor oficial (que ahora
      // vive en un PC de casa, no siempre encendido) no respondió ni siquiera
      // para el /resolve inicial. Se reintenta sola cuando el servidor vuelve
      // a estar disponible — ver CLAUDE.md.
      await db.execute(_createPendingImportsSql);
      await db.execute(_createPendingImportsIndexSql);
    }
    if (oldVersion < 14) {
      // Etapa 16 (cuentas en la nube): sincronización de historial.
      // `syncedAt` es una marca POR FILA (NULL = pendiente), no una marca de
      // agua en preferencias — entran filas nuevas mientras hay una subida en
      // vuelo, y un lote aceptado a medias tiene que poder reanudarse sin
      // resubir la cola entera. `playedAtUtc` sólo se llena para filas
      // nuevas (ver recordPlay); las históricas se etiquetan con el desfase
      // ACTUAL del dispositivo al subirlas — aproximación explícita, no un
      // error silencioso (reescribir `playDate`, que es hora local sin
      // desfase, sería el riesgo de migración que D9 evitó).
      await db.execute('ALTER TABLE play_history ADD COLUMN syncedAt TEXT');
      await db.execute('ALTER TABLE play_history ADD COLUMN playedAtUtc TEXT');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_play_history_synced ON play_history(syncedAt)',
      );
    }
    if (oldVersion < 15) {
      // Historial de streaming: sólo local, no se sincroniza ni cuenta en
      // estadísticas (no hay fila en `songs`).
      await db.execute(_createStreamHistorySql);
      await db.execute(_createStreamHistoryIndexSql);
    }
    if (oldVersion < 16) {
      // Playlists online: referencias a YouTube que suenan por streaming.
      // `songs` no se toca, así que la bandeja, el escáner y "ya descargada"
      // no ven estas pistas. Las playlists existentes quedan como 'local'.
      // Una migración interrumpida puede haber dejado la columna sin que la
      // versión llegara a subir: repetir el ALTER fallaría en cada arranque.
      final playlistColumns = await db.rawQuery('PRAGMA table_info(playlists)');
      if (!playlistColumns.any((c) => c['name'] == 'kind')) {
        await db.execute("ALTER TABLE playlists ADD COLUMN kind TEXT NOT NULL DEFAULT 'local'");
      }
      for (final sql in _onlinePlaylistSql) {
        await db.execute(sql);
      }
    }
  }

  static const _onlinePlaylistSql = [
    '''
      CREATE TABLE IF NOT EXISTS remote_tracks (
        videoId TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT,
        album TEXT,
        durationSeconds INTEGER,
        thumbnailUrl TEXT,
        sourceUrl TEXT
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS playlist_remote_tracks (
        playlistId TEXT NOT NULL,
        videoId TEXT NOT NULL,
        orderIndex INTEGER NOT NULL,
        PRIMARY KEY (playlistId, videoId),
        FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (videoId) REFERENCES remote_tracks (videoId)
      )
    ''',
    // Mismas fechas y clave natural que `play_history` (videoId + hora local).
    '''
      CREATE TABLE IF NOT EXISTS remote_play_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        videoId TEXT NOT NULL,
        playedAtLocal TEXT NOT NULL,
        playedAtUtc TEXT,
        playSeconds INTEGER NOT NULL,
        syncedAt TEXT,
        FOREIGN KEY (videoId) REFERENCES remote_tracks (videoId)
      )
    ''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_remote_play_history_key ON remote_play_history(videoId, playedAtLocal)',
    'CREATE INDEX IF NOT EXISTS idx_remote_play_history_synced ON remote_play_history(syncedAt)',
  ];

  /// Una fila por pista (clave = id de vídeo): volver a oírla actualiza
  /// `playedAt`. Sin FK: no hay canción local detrás.
  static const _createStreamHistorySql = '''
      CREATE TABLE IF NOT EXISTS stream_history (
        videoId TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        artUrl TEXT NOT NULL,
        durationSeconds INTEGER NOT NULL,
        playedAt TEXT NOT NULL
      )
    ''';

  static const _createStreamHistoryIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_stream_history_played ON stream_history(playedAt)';

  /// Persisted so an in-progress batch survives the app being killed.
  /// Deliberately NOT foreign-keyed to `playlists`: a queued job whose target
  /// playlist the user deletes mid-batch should fail as one job, not cascade
  /// away silently and leave the batch looking complete.
  static const _createDownloadQueueSql = '''
      CREATE TABLE IF NOT EXISTS download_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sourceType TEXT NOT NULL,
        sourceId TEXT NOT NULL,
        sourceUrl TEXT,
        playlistId TEXT NOT NULL,
        title TEXT,
        artist TEXT,
        album TEXT,
        durationSeconds INTEGER,
        thumbnailUrl TEXT,
        expectedOrderIndex INTEGER,
        addedDate TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        lastError TEXT,
        metadataComplete INTEGER NOT NULL DEFAULT 0
      )
    ''';

  /// Dedupe is on the triple, not on sourceId alone: queuing the same song
  /// into two different playlists is a legitimate thing to do.
  static const _createDownloadQueueIndexSql = '''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_download_queue_job
        ON download_queue (sourceType, sourceId, playlistId)
    ''';

  /// Una URL pegada mientras el servidor no respondió ni al /resolve inicial
  /// — antes de esto no hay ni id ni título, sólo lo que el usuario pegó y a
  /// qué playlist lo quería mandar. Sin FK a `playlists` por la misma razón
  /// que `download_queue`: si la playlist destino desaparece mientras se
  /// espera, esta entrada debe fallar sola, no arrastrar nada en cascada.
  static const _createPendingImportsSql = '''
      CREATE TABLE IF NOT EXISTS pending_imports (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        sourceUrl TEXT NOT NULL,
        playlistId TEXT NOT NULL,
        addedDate TEXT NOT NULL
      )
    ''';

  static const _createPendingImportsIndexSql = '''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_imports_job
        ON pending_imports (sourceUrl, playlistId)
    ''';

  // --- SONGS CRUD ---

  Future<int> insertSong(Song song) async {
    final db = await database;
    return await db.insert(
      'songs',
      song.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Song>> getSongs() async {
    final db = await database;
    final maps = await db.query('songs', orderBy: 'downloadDate DESC');
    return maps.map((map) => Song.fromMap(map)).toList();
  }

  Future<Song?> getSongById(String id) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Song.fromMap(maps.first);
    } else {
      return null;
    }
  }

  // --- LOCAL LIBRARY (SAF import) ---

  Future<Song?> getSongByUri(String uri) async {
    final db = await database;
    final maps = await db.query('songs', where: 'uri = ?', whereArgs: [uri]);
    return maps.isNotEmpty ? Song.fromMap(maps.first) : null;
  }

  Future<Song?> getSongByHash(String fileHash) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'fileHash = ?',
      whereArgs: [fileHash],
    );
    return maps.isNotEmpty ? Song.fromMap(maps.first) : null;
  }

  /// Looks up a song by where it was downloaded from. Lets the import flow
  /// answer "do I already have this?" without spending a network request.
  Future<Song?> getSongBySourceUrl(String sourceUrl) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'sourceUrl = ?',
      whereArgs: [sourceUrl],
    );
    return maps.isNotEmpty ? Song.fromMap(maps.first) : null;
  }

  Future<int> updateSongArtPath(String id, String artPath) async {
    final db = await database;
    return db.update('songs', {'artPath': artPath}, where: 'id = ?', whereArgs: [id]);
  }

  /// Rellena `sourceUrl` sólo si la fila no tiene ninguno: nunca pisa uno existente.
  Future<int> fillSongSourceUrlIfEmpty(String id, String sourceUrl) async {
    final db = await database;
    return db.update(
      'songs',
      {'sourceUrl': sourceUrl},
      where: "id = ? AND (sourceUrl IS NULL OR sourceUrl = '')",
      whereArgs: [id],
    );
  }

  /// Marks every previously-imported song (uri IS NOT NULL) as missing.
  /// Call once at the start of a scan; each file actually found on disk
  /// clears its own row's flag via [touchSongFound] as the scan proceeds,
  /// so anything left flagged at the end genuinely wasn't seen this pass.
  Future<void> markAllImportedSongsMissing() async {
    final db = await database;
    await db.update(
      'songs',
      {'missing': 1},
      where: 'uri IS NOT NULL',
    );
  }

  /// Updates a song's location/stats after finding it on disk during a scan
  /// (same uri, or same fileHash under a new uri) and clears its tombstone.
  Future<void> touchSongFound(
    String songId, {
    required String uri,
    required int fileSize,
    required int modifiedAt,
    String? fileHash,
    String? hashKind,
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? artPath,
  }) async {
    final db = await database;
    final values = <String, dynamic>{
      'uri': uri,
      'fileSize': fileSize,
      'modifiedAt': modifiedAt,
      'missing': 0,
    };
    if (fileHash != null) values['fileHash'] = fileHash;
    if (hashKind != null) values['hashKind'] = hashKind;
    if (title != null) values['title'] = title;
    if (artist != null) values['artist'] = artist;
    if (album != null) values['album'] = album;
    if (duration != null) values['duration'] = duration;
    if (artPath != null) values['artPath'] = artPath;
    await db.update('songs', values, where: 'id = ?', whereArgs: [songId]);
  }

  Future<int> getMissingImportedSongCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM songs WHERE uri IS NOT NULL AND missing = 1',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // --- INBOX (D6): songs imported loose in the library root, with no
  // playlist assigned yet. A missing or explicitly-ignored song never shows
  // up here — there's nothing useful to do with a file that's gone, and an
  // ignored one was already handled by the user.

  static const _inboxWhere =
      'ps.songId IS NULL AND s.missing = 0 AND s.ignoredFromInbox = 0';

  Future<List<Song>> getInboxSongs() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT s.* FROM songs s
      LEFT JOIN playlist_songs ps ON s.id = ps.songId
      WHERE $_inboxWhere
      ORDER BY s.downloadDate DESC
    ''');
    return maps.map((map) => Song.fromMap(map)).toList();
  }

  Future<int> getInboxSongCount() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as c FROM songs s
      LEFT JOIN playlist_songs ps ON s.id = ps.songId
      WHERE $_inboxWhere
    ''');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Hides songs from the inbox permanently — the scanner never sets or
  /// clears this flag, so once ignored a song stays ignored across rescans.
  Future<void> ignoreSongsFromInbox(List<String> songIds) async {
    if (songIds.isEmpty) return;
    final db = await database;
    await db.update(
      'songs',
      {'ignoredFromInbox': 1},
      where: 'id IN (${List.filled(songIds.length, '?').join(',')})',
      whereArgs: songIds,
    );
  }

  /// Songs previously dismissed via [ignoreSongsFromInbox] — the "Ignoradas"
  /// filter, so a dismiss is reversible instead of a dead end.
  Future<List<Song>> getIgnoredSongs() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT s.* FROM songs s
      LEFT JOIN playlist_songs ps ON s.id = ps.songId
      WHERE ps.songId IS NULL AND s.missing = 0 AND s.ignoredFromInbox = 1
      ORDER BY s.downloadDate DESC
    ''');
    return maps.map((map) => Song.fromMap(map)).toList();
  }

  /// Moves songs back from "Ignoradas" into the regular inbox.
  Future<void> unignoreSongsFromInbox(List<String> songIds) async {
    if (songIds.isEmpty) return;
    final db = await database;
    await db.update(
      'songs',
      {'ignoredFromInbox': 0},
      where: 'id IN (${List.filled(songIds.length, '?').join(',')})',
      whereArgs: songIds,
    );
  }

  /// Assigns every song in [songIds] to every playlist in [playlistIds],
  /// each appended after that playlist's current last track. Used by the
  /// inbox's batch-assign sheet, where a selection can go to more than one
  /// playlist at once.
  Future<void> assignSongsToPlaylists(List<String> songIds, List<String> playlistIds) async {
    if (songIds.isEmpty || playlistIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final playlistId in playlistIds) {
        final maxOrderResult = await txn.rawQuery(
          'SELECT MAX(orderIndex) as maxOrder FROM playlist_songs WHERE playlistId = ?',
          [playlistId],
        );
        var nextOrder = (maxOrderResult.first['maxOrder'] as int?) ?? -1;
        for (final songId in songIds) {
          nextOrder += 1;
          await txn.insert(
            'playlist_songs',
            {'playlistId': playlistId, 'songId': songId, 'orderIndex': nextOrder},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
  }

  /// Elimina la fila y, según proceda, el archivo real: `filePath` para una
  /// descarga heredada en almacenamiento privado, `uri` (SAF `content://`)
  /// para una canción importada o descargada dentro de la carpeta que el
  /// usuario eligió. **Enmienda a D3/D2, 2026-08-03**: antes se dejaba el
  /// archivo SAF intacto a propósito ("Heardy no borra los archivos del
  /// usuario"), pero eso hacía que "eliminar canción" no eliminara nada
  /// visible desde fuera de la app — confuso para el propio usuario, que
  /// gestiona esta carpeta como el mecanismo real de almacenamiento. D3 sigue
  /// vigente para todo lo demás (mover entre playlists nunca toca el disco);
  /// esto es específicamente sobre una eliminación explícita pedida por el
  /// usuario, no una reorganización silenciosa.
  Future<void> deleteSong(String songId) async {
    final db = await database;
    final song = await getSongById(songId);

    if (song != null) {
      // 1. Physically delete audio file
      try {
        final audioFile = File(song.filePath);
        if (await audioFile.exists()) {
          await audioFile.delete();
        }
      } catch (e) {
        appLog("Error deleting audio file: $e");
      }

      // 1b. Físicamente, el archivo real en la carpeta SAF, si lo hay.
      if (song.uri != null && song.uri!.isNotEmpty) {
        try {
          await defaultLibraryStorage().delete(song.uri!, isDir: false);
        } catch (e) {
          appLog("Error deleting SAF audio file: $e");
        }
      }

      // 2. Physically delete thumbnail file
      if (song.artPath.isNotEmpty) {
        try {
          final artFile = File(song.artPath);
          if (await artFile.exists()) {
            await artFile.delete();
          }
        } catch (e) {
          appLog("Error deleting thumbnail file: $e");
        }
      }
    }

    // 3. Delete DB record. Foreign key CASCADE deletes joint record in playlist_songs.
    await db.delete(
      'songs',
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  // --- PLAYLISTS CRUD ---

  Future<int> insertPlaylist(Playlist playlist) async {
    final db = await database;
    final maxOrder = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT MAX(sortOrder) FROM playlists',
        )) ??
        -1;
    final map = playlist.toMap();
    map['sortOrder'] = maxOrder + 1;
    return await db.insert(
      'playlists',
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Playlist>> getPlaylists() async {
    final db = await database;
    final maps = await db.query('playlists', orderBy: 'sortOrder ASC');
    return maps.map((map) => Playlist.fromMap(map)).toList();
  }

  Future<void> reorderPlaylists(List<String> orderedIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'playlists',
          {'sortOrder': i},
          where: 'id = ?',
          whereArgs: [orderedIds[i]],
        );
      }
    });
  }

  /// Para una online, [thumbnailUrl] es la miniatura de la primera pista y
  /// [coverArtPath] es null; para una local ocurre lo contrario.
  Future<({int songCount, int totalSeconds, String? coverArtPath, String? thumbnailUrl})>
      getPlaylistSummary(String playlistId) async {
    final db = await database;
    final kindRows = await db.query(
      'playlists',
      columns: ['kind'],
      where: 'id = ?',
      whereArgs: [playlistId],
    );
    if (kindRows.isNotEmpty && kindRows.first['kind'] == Playlist.kindOnline) {
      final remote = await db.rawQuery('''
        SELECT rt.durationSeconds, rt.thumbnailUrl
        FROM playlist_remote_tracks prt
        JOIN remote_tracks rt ON rt.videoId = prt.videoId
        WHERE prt.playlistId = ?
        ORDER BY prt.orderIndex ASC
      ''', [playlistId]);
      var total = 0;
      for (final row in remote) {
        total += row['durationSeconds'] as int? ?? 0;
      }
      final thumb = remote.isEmpty ? null : remote.first['thumbnailUrl'] as String?;
      return (
        songCount: remote.length,
        totalSeconds: total,
        coverArtPath: null,
        thumbnailUrl: thumb != null && thumb.isNotEmpty ? thumb : null,
      );
    }
    final rows = await db.rawQuery('''
      SELECT s.duration, s.artPath
      FROM playlist_songs ps
      JOIN songs s ON s.id = ps.songId
      WHERE ps.playlistId = ?
      ORDER BY ps.orderIndex ASC
    ''', [playlistId]);

    if (rows.isEmpty) {
      return (songCount: 0, totalSeconds: 0, coverArtPath: null, thumbnailUrl: null);
    }

    var total = 0;
    for (final row in rows) {
      total += row['duration'] as int? ?? 0;
    }
    final cover = rows.first['artPath'] as String?;
    return (
      songCount: rows.length,
      totalSeconds: total,
      coverArtPath: cover != null && cover.isNotEmpty ? cover : null,
      thumbnailUrl: null,
    );
  }

  Future<Playlist?> getPlaylistById(String id) async {
    final db = await database;
    final maps = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return Playlist.fromMap(maps.first);
    } else {
      return null;
    }
  }

  Future<int> updatePlaylistName(String id, String newName) async {
    final db = await database;
    return await db.update(
      'playlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updatePlaylistUrl(String id, String url) async {
    final db = await database;
    return await db.update(
      'playlists',
      {'originalUrl': url},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    // Foreign key constraint (ON DELETE CASCADE) will automatically delete associated playlist_songs rows.
    await db.transaction((txn) async {
      await txn.delete(
        'playlists',
        where: 'id = ?',
        whereArgs: [id],
      );
      await _pruneOrphanRemoteTracks(txn);
    });
  }

  // --- ONLINE PLAYLISTS (remote_tracks) ---

  /// Guarda o actualiza la referencia sin pisar con vacío los campos que ya
  /// se conocían.
  Future<void> upsertRemoteTrack(RemoteTrackRecord track) async {
    final db = await database;
    await _upsertRemoteTrack(db, track);
  }

  Future<void> _upsertRemoteTrack(DatabaseExecutor db, RemoteTrackRecord t) {
    return db.rawInsert('''
      INSERT INTO remote_tracks (videoId, title, artist, album, durationSeconds, thumbnailUrl, sourceUrl)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(videoId) DO UPDATE SET
        title = excluded.title,
        artist = COALESCE(NULLIF(excluded.artist, ''), remote_tracks.artist),
        album = COALESCE(NULLIF(excluded.album, ''), remote_tracks.album),
        durationSeconds = COALESCE(excluded.durationSeconds, remote_tracks.durationSeconds),
        thumbnailUrl = COALESCE(NULLIF(excluded.thumbnailUrl, ''), remote_tracks.thumbnailUrl),
        sourceUrl = COALESCE(NULLIF(excluded.sourceUrl, ''), remote_tracks.sourceUrl)
    ''', [t.videoId, t.title, t.artist, t.album, t.durationSeconds, t.thumbnailUrl, t.sourceUrl]);
  }

  /// Añade [tracks] al final de una playlist online, sin repetir ids de vídeo
  /// (ni dentro de la lista ni contra lo ya guardado). Devuelve cuántas
  /// entraron; una playlist local no admite referencias y devuelve 0.
  Future<int> addRemoteTracksToPlaylist(String playlistId, List<RemoteTrackRecord> tracks) async {
    final db = await database;
    return db.transaction((txn) async {
      final kind = await txn.query(
        'playlists',
        columns: ['kind'],
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      if (kind.isEmpty || kind.first['kind'] != Playlist.kindOnline) {
        appLog('addRemoteTracksToPlaylist: $playlistId no es una playlist online');
        return 0;
      }
      final present = {
        for (final r in await txn.query(
          'playlist_remote_tracks',
          columns: ['videoId'],
          where: 'playlistId = ?',
          whereArgs: [playlistId],
        ))
          r['videoId'] as String,
      };
      var next = (Sqflite.firstIntValue(await txn.rawQuery(
                'SELECT MAX(orderIndex) FROM playlist_remote_tracks WHERE playlistId = ?',
                [playlistId],
              )) ??
              -1) +
          1;
      var added = 0;
      for (final track in tracks) {
        if (track.videoId.isEmpty || !present.add(track.videoId)) continue;
        await _upsertRemoteTrack(txn, track);
        await txn.insert('playlist_remote_tracks', {
          'playlistId': playlistId,
          'videoId': track.videoId,
          'orderIndex': next++,
        });
        added++;
      }
      return added;
    });
  }

  Future<void> removeRemoteTrackFromPlaylist(String playlistId, String videoId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'playlist_remote_tracks',
        where: 'playlistId = ? AND videoId = ?',
        whereArgs: [playlistId, videoId],
      );
      await _pruneOrphanRemoteTracks(txn);
    });
  }

  Future<void> reorderRemoteTracks(String playlistId, List<String> videoIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < videoIds.length; i++) {
        await txn.update(
          'playlist_remote_tracks',
          {'orderIndex': i},
          where: 'playlistId = ? AND videoId = ?',
          whereArgs: [playlistId, videoIds[i]],
        );
      }
    });
  }

  Future<List<RemoteTrackRecord>> getRemoteTracksForPlaylist(String playlistId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT rt.* FROM remote_tracks rt
      JOIN playlist_remote_tracks prt ON prt.videoId = rt.videoId
      WHERE prt.playlistId = ?
      ORDER BY prt.orderIndex ASC
    ''', [playlistId]);
    return rows.map(RemoteTrackRecord.fromMap).toList();
  }

  /// Una referencia que ninguna playlist usa y que el historial no necesita
  /// ya no tiene razón de existir.
  Future<void> _pruneOrphanRemoteTracks(DatabaseExecutor db) {
    return db.rawDelete('''
      DELETE FROM remote_tracks
      WHERE videoId NOT IN (SELECT videoId FROM playlist_remote_tracks)
        AND videoId NOT IN (SELECT videoId FROM remote_play_history)
    ''');
  }

  Future<Set<String>> getRemoteTrackIds() async {
    final db = await database;
    return {
      for (final r in await db.query('remote_tracks', columns: ['videoId'])) r['videoId'] as String,
    };
  }

  /// Anota una escucha de una pista guardada. Devuelve false si ya existía
  /// (misma clave natural que el historial local) o si la pista no es una
  /// referencia guardada.
  Future<bool> insertRemotePlay(
    String videoId,
    String playedAtLocal,
    String? playedAtUtc,
    int playSeconds,
  ) async {
    final db = await database;
    final known = await db.query(
      'remote_tracks',
      columns: ['videoId'],
      where: 'videoId = ?',
      whereArgs: [videoId],
    );
    if (known.isEmpty) return false;
    final id = await db.insert(
      'remote_play_history',
      {
        'videoId': videoId,
        'playedAtLocal': playedAtLocal,
        'playedAtUtc': playedAtUtc,
        'playSeconds': playSeconds,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id > 0;
  }

  /// Historial remoto completo con la identidad por id de vídeo, para los
  /// sincronizadores.
  Future<List<Map<String, dynamic>>> getRemotePlayRowsForSync() async {
    final db = await database;
    return db.rawQuery('''
      SELECT videoId, playedAtLocal, playedAtUtc, playSeconds, syncedAt
      FROM remote_play_history
      ORDER BY playedAtLocal ASC
    ''');
  }

  // --- PLAYLIST SONGS (JOIN) CRUD ---

  Future<int> addSongToPlaylist(String playlistId, String songId, int order) async {
    final db = await database;
    return await db.insert(
      'playlist_songs',
      {
        'playlistId': playlistId,
        'songId': songId,
        'orderIndex': order,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> removeSongFromPlaylist(String playlistId, String songId) async {
    final db = await database;
    return await db.delete(
      'playlist_songs',
      where: 'playlistId = ? AND songId = ?',
      whereArgs: [playlistId, songId],
    );
  }

  Future<List<Song>> getSongsForPlaylist(String playlistId) async {
    final db = await database;
    
    // Join songs and playlist_songs, ordering by orderIndex
    final List<Map<String, dynamic>> results = await db.rawQuery('''
      SELECT s.* FROM songs s
      INNER JOIN playlist_songs ps ON s.id = ps.songId
      WHERE ps.playlistId = ?
      ORDER BY ps.orderIndex ASC
    ''', [playlistId]);

    return results.map((map) => Song.fromMap(map)).toList();
  }

  Future<int?> getMaxOrderForPlaylist(String playlistId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(orderIndex) as maxOrder FROM playlist_songs WHERE playlistId = ?',
      [playlistId],
    );

    if (result.isNotEmpty && result.first['maxOrder'] != null) {
      return result.first['maxOrder'] as int;
    }
    return null;
  }

  Future<int> deletePlaylistSong(String playlistId, String songId) async {
    return await removeSongFromPlaylist(playlistId, songId);
  }

  Future<bool> isSongInPlaylist(String playlistId, String songId) async {
    final db = await database;
    final maps = await db.query(
      'playlist_songs',
      where: 'playlistId = ? AND songId = ?',
      whereArgs: [playlistId, songId],
    );
    return maps.isNotEmpty;
  }

  Future<int> getPlaylistCountForSong(String songId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM playlist_songs WHERE songId = ?',
      [songId],
    );
    return result.first['count'] as int? ?? 0;
  }

  Future<void> reorderSongsInPlaylist(String playlistId, List<String> songIds) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var i = 0; i < songIds.length; i++) {
        await txn.update(
          'playlist_songs',
          {'orderIndex': i},
          where: 'playlistId = ? AND songId = ?',
          whereArgs: [playlistId, songIds[i]],
        );
      }
    });
  }

  /// Traspasa una canción de una playlist a otra dentro de una única
  /// transacción (inserta en destino antes de borrar de origen) para que
  /// nunca quede huérfana en caso de fallo a mitad de camino — la canción en
  /// sí y su archivo en disco no se tocan (D3/DD3: mover entre playlists
  /// nunca toca el disco).
  Future<void> moveSongToPlaylist(
    String songId,
    String fromPlaylistId,
    String toPlaylistId,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      final maxOrderResult = await txn.rawQuery(
        'SELECT MAX(orderIndex) as maxOrder FROM playlist_songs WHERE playlistId = ?',
        [toPlaylistId],
      );
      final nextOrder = (maxOrderResult.first['maxOrder'] as int?) ?? -1;
      await txn.insert(
        'playlist_songs',
        {'playlistId': toPlaylistId, 'songId': songId, 'orderIndex': nextOrder + 1},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'playlist_songs',
        where: 'playlistId = ? AND songId = ?',
        whereArgs: [fromPlaylistId, songId],
      );
    });
  }

  // --- DOWNLOAD QUEUE (rama de descargas, schema v11) ---

  /// Encola un trabajo. Devuelve false si ya estaba encolado para esa misma
  /// playlist — el índice único hace el dedupe en la propia base, no a base
  /// de un SELECT previo que dos llamadas concurrentes podrían saltarse.
  Future<bool> enqueueDownload({
    required String sourceType,
    required String sourceId,
    required String playlistId,
    String? sourceUrl,
    String? title,
    String? artist,
    String? album,
    int? durationSeconds,
    String? thumbnailUrl,
    int? expectedOrderIndex,
    bool metadataComplete = false,
  }) async {
    final db = await database;
    final inserted = await db.insert(
      'download_queue',
      {
        'sourceType': sourceType,
        'sourceId': sourceId,
        'sourceUrl': sourceUrl,
        'playlistId': playlistId,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        'expectedOrderIndex': expectedOrderIndex,
        'addedDate': DateTime.now().toIso8601String(),
        'attempts': 0,
        'metadataComplete': metadataComplete ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return inserted != 0;
  }

  /// Guarda la metadata definitiva obtenida con /resolve y marca el trabajo
  /// como resuelto.
  ///
  /// Se llama **en cuanto el resolve tiene éxito**, antes de descargar nada:
  /// si la descarga falla luego y el trabajo se reintenta, el resolve ya no
  /// se repite. Es la diferencia entre gastar una petición por canción y
  /// gastar una por intento.
  Future<void> markDownloadMetadataResolved(
    int queueId, {
    required String sourceId,
    required String title,
    required String artist,
    String? album,
    int? durationSeconds,
    String? thumbnailUrl,
    String? sourceUrl,
  }) async {
    final db = await database;
    await db.update(
      'download_queue',
      {
        'sourceId': sourceId,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        'metadataComplete': 1,
      },
      where: 'id = ?',
      whereArgs: [queueId],
    );
  }

  /// Sustituye el objetivo de un trabajo de la cola por otro vídeo — el
  /// original falló de forma definitiva (agotó reintentos, o un error no
  /// reintentable) y se encontró un reemplazo por búsqueda (ver
  /// `DownloadProvider._tryFallbackSearch`, motivado por los tracks de
  /// canales "- Topic" que YouTube bloquea a nivel de contenido: casi
  /// siempre existe el "Music Clip" oficial de la misma canción).
  ///
  /// `metadataComplete` se deja en 0 a propósito, aunque el trabajo original
  /// ya estuviera resuelto: el reemplazo viene de una búsqueda
  /// (`extract_flat`), así que `artist` es el nombre del canal, no el
  /// artista real — necesita el mismo paso de /resolve (DD6) que cualquier
  /// resultado de búsqueda. `attempts` se reinicia: es, a todos los efectos,
  /// un trabajo nuevo con su propio presupuesto de reintentos.
  Future<void> retargetDownloadQueueJob(
    int queueId, {
    required String sourceId,
    required String sourceUrl,
    required String title,
    required String artist,
    String? album,
    required int durationSeconds,
    required String thumbnailUrl,
  }) async {
    final db = await database;
    await db.update(
      'download_queue',
      {
        'sourceId': sourceId,
        'sourceUrl': sourceUrl,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        'metadataComplete': 0,
        'attempts': 0,
        'lastError': null,
      },
      where: 'id = ?',
      whereArgs: [queueId],
    );
  }

  /// La cola en orden de inserción, que para una playlist es su orden real.
  Future<List<Map<String, dynamic>>> getDownloadQueue() async {
    final db = await database;
    return db.query('download_queue', orderBy: 'id ASC');
  }

  Future<int> getDownloadQueueLength() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM download_queue');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> removeFromDownloadQueue(int queueId) async {
    final db = await database;
    await db.delete('download_queue', where: 'id = ?', whereArgs: [queueId]);
  }

  Future<void> clearDownloadQueue() async {
    final db = await database;
    await db.delete('download_queue');
  }

  Future<void> clearDownloadQueueForPlaylist(String playlistId) async {
    final db = await database;
    await db.delete('download_queue', where: 'playlistId = ?', whereArgs: [playlistId]);
  }

  /// Registra un intento fallido. El contador vive en la base y no en memoria
  /// para que un reinicio de la app no reinicie el presupuesto de reintentos
  /// de un trabajo que nunca va a funcionar.
  Future<void> markDownloadAttempt(int queueId, String? error) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE download_queue SET attempts = attempts + 1, lastError = ? WHERE id = ?',
      [error, queueId],
    );
  }

  // --- LISTA DE ESPERA (pending_imports, schema v13) ---

  /// Guarda una URL que no se pudo ni resolver porque el servidor no
  /// respondió. Devuelve false si ya estaba (misma URL, misma playlist
  /// destino) — el índice único hace el dedupe en la base.
  Future<bool> addPendingImport({
    required String kind,
    required String sourceUrl,
    required String playlistId,
  }) async {
    final db = await database;
    final inserted = await db.insert(
      'pending_imports',
      {
        'kind': kind,
        'sourceUrl': sourceUrl,
        'playlistId': playlistId,
        'addedDate': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return inserted != 0;
  }

  Future<List<Map<String, dynamic>>> getPendingImports() async {
    final db = await database;
    return db.query('pending_imports', orderBy: 'id ASC');
  }

  Future<void> removePendingImport(int id) async {
    final db = await database;
    await db.delete('pending_imports', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearPendingImports() async {
    final db = await database;
    await db.delete('pending_imports');
  }

  Future close() async {
    final db = await database;
    db.close();
  }

  // --- PLAY HISTORY / STATISTICS ---

  Future<int> recordPlay(String songId, int playDuration) async {
    final db = await database;
    final now = DateTime.now();
    return await db.insert(
      'play_history',
      {
        'songId': songId,
        'playDate': now.toIso8601String(),
        'playDuration': playDuration,
        // Se escriben las DOS a propósito: playDate se queda intacto (hora
        // local sin desfase) para que toda consulta local de estadísticas
        // siga funcionando byte a byte; playedAtUtc es lo que el sincronizador
        // manda al servidor — sólo las filas nuevas la llevan de entrada.
        'playedAtUtc': now.toUtc().toIso8601String(),
      },
    );
  }

  /// Anota (o refresca) una reproducción por streaming y poda el historial a
  /// [maxRows] entradas.
  Future<void> recordStreamPlay(
    HistoryEntry entry, {
    int maxRows = maxStreamHistoryRows,
  }) async {
    final id = entry.videoId;
    if (id == null || id.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('stream_history', entry.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.rawDelete(
        'DELETE FROM stream_history WHERE videoId NOT IN '
        '(SELECT videoId FROM stream_history ORDER BY playedAt DESC LIMIT ?)',
        [maxRows],
      );
    });
  }

  Future<List<HistoryEntry>> getStreamHistory({int limit = maxStreamHistoryRows}) async {
    final db = await database;
    final rows = await db.query('stream_history', orderBy: 'playedAt DESC', limit: limit);
    return [for (final r in rows) HistoryEntry.fromStreamMap(r)];
  }

  Future<void> clearStreamHistory() async {
    final db = await database;
    await db.delete('stream_history');
  }

  /// Última reproducción de cada canción presente (una fila por canción), de
  /// `play_history`; sólo lectura.
  Future<List<HistoryEntry>> getLocalHistory({int limit = maxStreamHistoryRows}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, h.lastPlayed
      FROM songs s
      JOIN (SELECT songId, MAX(playDate) AS lastPlayed FROM play_history GROUP BY songId) h
        ON h.songId = s.id
      WHERE s.missing = 0
      ORDER BY h.lastPlayed DESC
      LIMIT ?
    ''', [limit]);
    return [
      for (final r in rows)
        () {
          final song = Song.fromMap(r);
          return HistoryEntry(
            isStream: false,
            songId: song.id,
            videoId: youtubeVideoId(song.sourceUrl),
            title: song.title,
            artist: song.artist,
            artPath: song.artPath,
            durationSeconds: song.duration,
            playedAt: DateTime.parse(r['lastPlayed'] as String),
            song: song,
          );
        }(),
    ];
  }

  /// Canciones presentes ordenadas por su última reproducción, una fila por
  /// canción — "Escuchar de nuevo" en Explorar.
  Future<List<Song>> getRecentlyPlayedSongs({int limit = 20}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*
      FROM songs s
      JOIN (SELECT songId, MAX(playDate) AS lastPlayed FROM play_history GROUP BY songId) h
        ON h.songId = s.id
      WHERE s.missing = 0
      ORDER BY h.lastPlayed DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(Song.fromMap).toList();
  }

  /// Todas las canciones presentes con su número de reproducciones y la última
  /// fecha, sin filtrar: las listas inteligentes se derivan de esto con
  /// `buildSmartList`.
  Future<List<SongPlayStat>> getSongPlayStats() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, COALESCE(h.playCount, 0) AS playCount, h.lastPlayed AS lastPlayed
      FROM songs s
      LEFT JOIN (
        SELECT songId, COUNT(*) AS playCount, MAX(playDate) AS lastPlayed
        FROM play_history GROUP BY songId
      ) h ON h.songId = s.id
      WHERE s.missing = 0
    ''');
    return [
      for (final r in rows)
        SongPlayStat(
          song: Song.fromMap(r),
          playCount: r['playCount'] as int,
          lastPlayed: DateTime.tryParse((r['lastPlayed'] as String?) ?? ''),
        ),
    ];
  }

  /// `sourceUrl` de YouTube de las canciones más reproducidas (todo el
  /// historial): semillas de la radio de Explorar. El filtro fino por id válido
  /// lo hace `selectRadioSeedIds`; aquí sólo se descartan las que no son de
  /// YouTube.
  Future<List<String>> getMostPlayedYoutubeSourceUrls({int limit = 10}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.sourceUrl, COUNT(*) AS playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE s.missing = 0
        AND (s.sourceUrl LIKE '%youtube.com/watch%' OR s.sourceUrl LIKE '%youtu.be/%')
      GROUP BY s.id
      ORDER BY playCount DESC
      LIMIT ?
    ''', [limit]);
    return [for (final r in rows) r['sourceUrl'] as String];
  }

  // --- SINCRONIZACIÓN CON LA CUENTA (Etapa 16) ---

  /// `SELECT COUNT(*) FROM songs WHERE missing = 0` — calcado de
  /// [getInboxSongCount]. Usado por el popup de vinculación de cuenta:
  /// [getSongs] carga la tabla entera y no puede usarse en una comprobación
  /// de arranque.
  Future<int> getLibrarySongCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM songs WHERE missing = 0',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Todos los `fileHash` no vacíos de canciones presentes (`missing = 0`) —
  /// el lado local de la comparación de W6 (`missingCloudSongs`, la
  /// estrategia híbrida de la Etapa 16 E-2): qué del índice de la nube ya
  /// está en este equipo, por hash de audio, nunca por título/artista.
  Future<Set<String>> getLocalFileHashes() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT fileHash FROM songs WHERE missing = 0 AND fileHash IS NOT NULL AND fileHash != ''",
    );
    return rows.map((r) => r['fileHash'] as String).toSet();
  }

  /// Como [getLocalFileHashes] pero también incluye las filas `missing = 1`:
  /// una canción cuyo archivo no se ve ahora mismo sigue siendo "tuya", así
  /// que no debe ofrecerse como descargable desde otros dispositivos.
  Future<Set<String>> getAllLocalFileHashes() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT fileHash FROM songs WHERE fileHash IS NOT NULL AND fileHash != ''",
    );
    return rows.map((r) => r['fileHash'] as String).toSet();
  }

  /// Como [getLocalSourceUrls] pero incluyendo las filas `missing = 1`.
  Future<Set<String>> getAllLocalSourceUrls() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT sourceUrl FROM songs WHERE sourceUrl IS NOT NULL AND sourceUrl != ''",
    );
    return rows.map((r) => r['sourceUrl'] as String).toSet();
  }

  /// Todos los `sourceUrl` no vacíos de canciones presentes — para que
  /// restaurar una playlist por su enlace original (`resolvePlaylist`, no
  /// emparejamiento por duración) no vuelva a encolar una canción que este
  /// equipo ya tiene, aunque haya llegado por otro camino (import manual,
  /// otra playlist) y no por el índice de la nube.
  Future<Set<String>> getLocalSourceUrls() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT sourceUrl FROM songs WHERE missing = 0 AND sourceUrl IS NOT NULL AND sourceUrl != ''",
    );
    return rows.map((r) => r['sourceUrl'] as String).toSet();
  }

  /// Proyección EXPLÍCITA, nunca `SELECT *` — así `uri`/`filePath`/`artPath`/
  /// `modifiedAt`/`missing`/`ignoredFromInbox` no entran por accidente en
  /// memoria ni en un codificador JSON. Ver CLAUDE.md, "Cloud sync": el
  /// servidor guarda un índice, nunca nada que sólo signifique algo en este
  /// dispositivo.
  ///
  /// **Sin filtrar por `missing`**, a diferencia de [getLocalFileHashes]. El
  /// índice de la nube es el catálogo de lo que la cuenta TIENE, no de lo que
  /// este aparato puede reproducir ahora mismo: `missing` significa "el
  /// archivo no está a la vista en este momento" (permiso SAF revocado,
  /// volumen desmontado, tarjeta fuera), nunca "esta canción dejó de
  /// existir" — el escaneo jamás borra una fila por no encontrarla (D2). Con
  /// el filtro puesto, un teléfono con la tarjeta desmontada subía un índice
  /// vacío y `push_library` borraba del servidor la biblioteca entera, que es
  /// exactamente el riesgo que CLAUDE.md nombra en "Cloud sync" ("a device
  /// with its storage unmounted... must never be able to wipe out data that
  /// lives only on another device").
  ///
  /// [includeOnline] suma las playlists online (con `kind: 'online'`, que las
  /// locales no llevan), sus pistas remotas y la pertenencia con orden. Es
  /// opt-in: sin él el resultado es el de siempre (solo playlists locales).
  Future<Map<String, List<Map<String, dynamic>>>> getLibraryIndexRows({bool includeOnline = false}) async {
    final db = await database;
    final songs = await db.rawQuery('''
      SELECT id AS songId, title, artist, album, duration AS durationSeconds,
             fileHash, hashKind, sourceUrl
      FROM songs
    ''');
    final playlists = await db.rawQuery(includeOnline
        ? '''
      SELECT id AS playlistId, name, sortOrder, originalUrl, kind FROM playlists
    '''
        : '''
      SELECT id AS playlistId, name, sortOrder, originalUrl FROM playlists
      WHERE kind = 'local'
    ''');
    final playlistSongs = await db.rawQuery('''
      SELECT playlistId, songId, orderIndex FROM playlist_songs
    ''');
    if (!includeOnline) {
      return {
        'songs': songs,
        'playlists': playlists,
        'playlistSongs': playlistSongs,
      };
    }
    // Las locales no llevan `kind`: el payload (y su hash) de quien no tiene
    // playlists online queda idéntico al de antes.
    final playlistRows = [
      for (final row in playlists)
        {
          for (final entry in row.entries)
            if (entry.key != 'kind') entry.key: entry.value,
          if (row['kind'] == Playlist.kindOnline) 'kind': Playlist.kindOnline,
        },
    ];
    // `artist` nunca null: el servidor lo declara texto (vacío = sin dato).
    final remoteTracks = await db.rawQuery('''
      SELECT videoId, title, COALESCE(artist, '') AS artist, album, durationSeconds,
             thumbnailUrl, sourceUrl
      FROM remote_tracks
    ''');
    final playlistRemoteTracks = await db.rawQuery('''
      SELECT playlistId, videoId, orderIndex FROM playlist_remote_tracks
    ''');
    return {
      'songs': songs,
      'playlists': playlistRows,
      'playlistSongs': playlistSongs,
      'remoteTracks': remoteTracks,
      'playlistRemoteTracks': playlistRemoteTracks,
    };
  }

  /// Historial completo con la identidad del audio (`fileHash`) en vez del id
  /// local, para la sincronización por carpeta: otro equipo lo mapea a su
  /// propio id. Las filas de canciones sin hash no viajan.
  Future<List<Map<String, dynamic>>> getHistoryRowsForFolderSync() async {
    final db = await database;
    return db.rawQuery('''
      SELECT s.fileHash AS fileHash, ph.playDate AS playedAtLocal,
             ph.playedAtUtc AS playedAtUtc, ph.playDuration AS playSeconds
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE s.fileHash IS NOT NULL AND s.fileHash != ''
      ORDER BY ph.playDate ASC
    ''');
  }

  /// Filas de historial sin subir todavía. `LEFT JOIN`, no `INNER JOIN`: una
  /// fila de `play_history` cuya canción ya se borró (la tabla no tiene FK
  /// contra `songs` con cascada real en todos los caminos de borrado
  /// legítimos) quedaría reintentándose para siempre con un JOIN estricto —
  /// se detecta acá (`songId IS NULL` del lado de `songs`) y se marca
  /// `skipped` en vez de sincronizarse, ver [markPlaysSkipped].
  Future<List<Map<String, dynamic>>> getUnsyncedPlays({int limit = 500}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT ph.id, ph.songId, ph.playDate, ph.playDuration, ph.playedAtUtc,
             s.id AS existingSongId
      FROM play_history ph
      LEFT JOIN songs s ON s.id = ph.songId
      WHERE ph.syncedAt IS NULL
      ORDER BY ph.playDate ASC
      LIMIT ?
    ''', [limit]);
  }

  Future<void> markPlaysSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.rawUpdate(
      'UPDATE play_history SET syncedAt = ? WHERE id IN (${List.filled(ids.length, '?').join(',')})',
      [now, ...ids],
    );
  }

  /// Centinela, no una fecha — saca definitivamente de la cola una fila cuya
  /// canción ya no existe, sin fingir que se subió.
  Future<void> markPlaysSkipped(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.rawUpdate(
      "UPDATE play_history SET syncedAt = 'skipped' WHERE id IN (${List.filled(ids.length, '?').join(',')})",
      ids,
    );
  }

  /// Inserta historial traído de la nube (`GET /history`) y devuelve cuántas
  /// filas entraron de verdad. La pareja de [getUnsyncedPlays]: reconstruye
  /// las estadísticas de un equipo que perdió su base local.
  ///
  /// Tres reglas, todas necesarias:
  ///
  /// - **Sólo canciones que existen acá.** `play_history.songId` tiene clave
  ///   foránea contra `songs` y el `PRAGMA foreign_keys = ON` está puesto, así
  ///   que una fila de una canción ausente no es que sea inútil (no aparecería
  ///   en ninguna estadística, que hacen `JOIN songs`): es que hace fallar la
  ///   inserción entera.
  /// - **Deduplicado por la misma clave natural que usa el servidor**
  ///   (`songId` + hora local), no por un id: traer el historial dos veces no
  ///   duplica nada, igual que subirlo dos veces no lo duplica allá.
  /// - **Entran ya marcadas como sincronizadas.** Vinieron del servidor; sin
  ///   esto, la siguiente pasada de subida las devolvería tal cual, gastando
  ///   el cupo diario para escribir filas que ya están.
  ///
  /// Una pasada de varias páginas pasa [knownSongs]/[existingKeys] ya
  /// cargados (ver [loadRestoreContext]) para no releer `songs` y todo
  /// `play_history` por página; este método agrega al `existingKeys` recibido
  /// cada clave que inserta, así que el mismo set sirve para la página
  /// siguiente.
  Future<int> insertRestoredPlays(
    List<Map<String, dynamic>> rows, {
    Set<String>? knownSongs,
    Set<String>? existingKeys,
  }) async {
    if (rows.isEmpty) return 0;
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final context = (knownSongs == null || existingKeys == null) ? await loadRestoreContext() : null;
    knownSongs ??= context!.knownSongs;
    existingKeys ??= context!.existingKeys;

    var inserted = 0;
    final batch = db.batch();
    for (final row in rows) {
      final songId = row['songId'] as String?;
      final playedAtLocal = row['playedAtLocal'] as String?;
      if (songId == null || playedAtLocal == null) continue;
      if (!knownSongs.contains(songId)) continue;
      if (!existingKeys.add('$songId $playedAtLocal')) continue;
      batch.insert('play_history', {
        'songId': songId,
        'playDate': playedAtLocal,
        'playDuration': (row['playSeconds'] as num?)?.toInt() ?? 0,
        'playedAtUtc': row['playedAtUtc'],
        'syncedAt': now,
      });
      inserted++;
    }
    if (inserted > 0) await batch.commit(noResult: true);
    return inserted;
  }

  /// Escuchas remotas sin subir (`syncedAt` nulo), de la más vieja a la más
  /// nueva. Pareja de [getUnsyncedPlays] para `remote_play_history`.
  Future<List<Map<String, dynamic>>> getUnsyncedRemotePlays({int limit = 500}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT id, videoId, playedAtLocal, playedAtUtc, playSeconds
      FROM remote_play_history
      WHERE syncedAt IS NULL
      ORDER BY playedAtLocal ASC
      LIMIT ?
    ''', [limit]);
  }

  Future<void> markRemotePlaysSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.rawUpdate(
      'UPDATE remote_play_history SET syncedAt = ? WHERE id IN (${List.filled(ids.length, '?').join(',')})',
      [now, ...ids],
    );
  }

  /// Inserta historial remoto traído de la nube (`GET /history/remote`) y
  /// devuelve cuántas filas entraron. Mismas reglas que [insertRestoredPlays]:
  /// sólo `videoId` que existen en `remote_tracks` (hay clave foránea, así
  /// que las demás harían fallar el lote), deduplicado por la clave natural
  /// (`videoId` + hora local) y marcadas ya como sincronizadas. Pasar [known]
  /// y [existingKeys] ya cargados evita releer las tablas por página.
  Future<int> insertRestoredRemotePlays(
    List<Map<String, dynamic>> rows, {
    Set<String>? known,
    Set<String>? existingKeys,
  }) async {
    if (rows.isEmpty) return 0;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    known ??= await getRemoteTrackIds();
    existingKeys ??= {
      for (final r in await db.rawQuery('SELECT videoId, playedAtLocal FROM remote_play_history'))
        '${r['videoId']} ${r['playedAtLocal']}',
    };
    var inserted = 0;
    final batch = db.batch();
    for (final row in rows) {
      final videoId = row['videoId'] as String?;
      final playedAtLocal = row['playedAtLocal'] as String?;
      if (videoId == null || playedAtLocal == null) continue;
      if (!known.contains(videoId)) continue;
      if (!existingKeys.add('$videoId $playedAtLocal')) continue;
      batch.insert('remote_play_history', {
        'videoId': videoId,
        'playedAtLocal': playedAtLocal,
        'playedAtUtc': row['playedAtUtc'],
        'playSeconds': (row['playSeconds'] as num?)?.toInt() ?? 0,
        'syncedAt': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      inserted++;
    }
    if (inserted > 0) await batch.commit(noResult: true);
    return inserted;
  }

  /// Ids de canciones locales y claves naturales del historial, para pasarlos
  /// a [insertRestoredPlays] una sola vez por pasada de varias páginas.
  Future<({Set<String> knownSongs, Set<String> existingKeys})> loadRestoreContext() async {
    final db = await database;
    final knownSongs = {
      for (final r in await db.rawQuery('SELECT id FROM songs')) r['id'] as String,
    };
    final existingKeys = {
      for (final r in await db.rawQuery('SELECT songId, playDate FROM play_history'))
        '${r['songId']} ${r['playDate']}',
    };
    return (knownSongs: knownSongs, existingKeys: existingKeys);
  }

  /// La válvula de escape de privacidad (`DELETE /account/data`): tras
  /// borrar los datos en el servidor, un revínculo posterior de la misma
  /// cuenta debe resubir todo desde cero, no asumir que ya está allá.
  Future<void> resetHistorySyncMarkers() async {
    final db = await database;
    await db.rawUpdate('UPDATE play_history SET syncedAt = NULL');
    await db.rawUpdate('UPDATE remote_play_history SET syncedAt = NULL');
  }

  /// Día 1 del mes en curso a las 00:00 en hora local: el "mes" de las
  /// estadísticas es el mes natural, igual que la semana es la semana
  /// natural. El servidor replica esta definición (library_store.py,
  /// month_start_utc) para que lo que ve un amigo coincida con lo propio.
  String _getStartOfMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1).toIso8601String();
  }

  String _getStartOfWeek() {
    final now = DateTime.now();
    final daysToSubtract = now.weekday - 1;
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToSubtract));
    return monday.toIso8601String();
  }

  Future<List<Map<String, dynamic>>> getTopSongsThisWeek({int limit = 10}) =>
      _topSongsSince(_getStartOfWeek(), limit);

  Future<List<Map<String, dynamic>>> getTopSongsThisMonth({int limit = 10}) =>
      _topSongsSince(_getStartOfMonth(), limit);

  /// Canciones locales y pistas remotas guardadas en una sola lista. El id
  /// de las remotas es `yt:<videoId>` y su `artPath` va vacío: ningún
  /// consumidor puede asumir que el id existe en `songs`.
  Future<List<Map<String, dynamic>>> _topSongsSince(String since, int limit) async {
    final db = await database;
    final local = await db.rawQuery('''
      SELECT s.id, s.title, s.artist, s.artPath, COUNT(*) as playCount
      FROM play_history ph
      JOIN songs s ON s.id = ph.songId
      WHERE ph.playDate >= ?
      GROUP BY s.id
      ORDER BY playCount DESC
      LIMIT ?
    ''', [since, limit]);
    final remote = await db.rawQuery('''
      SELECT 'yt:' || rt.videoId AS id, rt.title AS title, COALESCE(rt.artist, '') AS artist,
             '' AS artPath, COUNT(*) as playCount
      FROM remote_play_history rph
      JOIN remote_tracks rt ON rt.videoId = rph.videoId
      WHERE rph.playedAtLocal >= ?
      GROUP BY rt.videoId
      ORDER BY playCount DESC
      LIMIT ?
    ''', [since, limit]);
    return mergeTopSongRows(local, remote, limit: limit);
  }

  Future<int> getTotalPlaysThisWeek() => _totalPlaysSince(_getStartOfWeek());

  Future<int> getTotalPlaysThisMonth() => _totalPlaysSince(_getStartOfMonth());

  Future<int> _totalPlaysSince(String since) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT (SELECT COUNT(*) FROM play_history WHERE playDate >= ?)
           + (SELECT COUNT(*) FROM remote_play_history WHERE playedAtLocal >= ?) as total
    ''', [since, since]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getTotalListenTimeThisWeek() => _listenTimeSince(_getStartOfWeek());

  Future<int> getTotalListenTimeThisMonth() => _listenTimeSince(_getStartOfMonth());

  Future<int> _listenTimeSince(String since) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT (SELECT COALESCE(SUM(playDuration), 0) FROM play_history WHERE playDate >= ?)
           + (SELECT COALESCE(SUM(playSeconds), 0) FROM remote_play_history WHERE playedAtLocal >= ?) as total
    ''', [since, since]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Sin `LIMIT` y sin plegar por nombre normalizado a propósito: SQLite
  /// compara TEXT con colación binaria, así que "Bad Bunny" y "bad bunny"
  /// son grupos distintos aquí. El plegado insensible a mayúsculas/espacios
  /// (igual que `compute_artist_key` en el servidor, para que las
  /// estadísticas propias y las de un amigo coincidan) lo hace
  /// `foldTopArtists` en `statistics_service.dart`, sobre TODAS las filas
  /// (locales y remotas juntas).
  Future<List<Map<String, dynamic>>> getTopArtistsThisWeek() => _topArtistsSince(_getStartOfWeek());

  Future<List<Map<String, dynamic>>> getTopArtistsThisMonth() => _topArtistsSince(_getStartOfMonth());

  Future<List<Map<String, dynamic>>> _topArtistsSince(String since) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT artist, SUM(playCount) as playCount FROM (
        SELECT s.artist AS artist, COUNT(*) as playCount
        FROM play_history ph
        JOIN songs s ON s.id = ph.songId
        WHERE ph.playDate >= ?
        GROUP BY s.artist
        UNION ALL
        SELECT rt.artist AS artist, COUNT(*) as playCount
        FROM remote_play_history rph
        JOIN remote_tracks rt ON rt.videoId = rph.videoId
        WHERE rph.playedAtLocal >= ? AND rt.artist IS NOT NULL
        GROUP BY rt.artist
      )
      GROUP BY artist
      ORDER BY playCount DESC
    ''', [since, since]);
  }

  // Delete all songs belonging to a playlist (files + DB rows).
  Future<void> deleteAllSongsForPlaylist(String playlistId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Get song IDs linked to the playlist
      final songMaps = await txn.rawQuery('SELECT songId FROM playlist_songs WHERE playlistId = ?', [playlistId]);
      final songIds = songMaps.map((e) => e['songId'] as String).toList();

      // Delete physical files for each song — filePath for a legacy
      // app-private download, uri (SAF) for anything imported/downloaded
      // into the user's chosen folder. See the amendment note on
      // [deleteSong]: this is an explicit user-requested deletion, not the
      // scanner reorganizing files on its own.
      for (final id in songIds) {
        final song = await getSongById(id);
        if (song != null) {
          try { await File(song.filePath).delete(); } catch (_) {}
          if (song.uri != null && song.uri!.isNotEmpty) {
            try { await defaultLibraryStorage().delete(song.uri!, isDir: false); } catch (_) {}
          }
          try { if (song.artPath.isNotEmpty) await File(song.artPath).delete(); } catch (_) {}
        }
      }

      // Delete song rows (cascade will clean playlist_songs)
      if (songIds.isNotEmpty) {
        await txn.delete('songs', where: 'id IN (${List.filled(songIds.length, '?').join(',')})', whereArgs: songIds);
      }
    });
  }
}
