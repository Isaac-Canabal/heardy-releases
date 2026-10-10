// "En tus otros dispositivos": lista bajo demanda de lo que la nube tiene y
// este equipo no, con descarga de un toque a la Bandeja.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/providers/cloud_library_provider.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';

class _FakeCloud implements CloudSource {
  bool hasLibrary = true;
  Object? error;
  int getLibraryCalls = 0;
  CloudLibrary library = const CloudLibrary(version: 1, songs: [], playlists: [], playlistSongs: []);

  @override
  Future<CloudAccount> getAccount() async {
    if (error != null) throw error!;
    return CloudAccount(
      identity: 'x',
      username: null,
      libraryVersion: 1,
      hasLibrary: hasLibrary,
      friendCount: 0,
    );
  }

  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) async {
    getLibraryCalls++;
    return library;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Siempre falla por red: el trabajo se queda en la cola con su espera, que es
/// lo que el test necesita inspeccionar.
class _OfflineService implements DownloadService {
  @override
  Future<DownloadResult> download(
    RemoteTrack track, {
    String? playlistId,
    bool resolveFirst = false,
    Future<void> Function(RemoteTrack resolved)? onResolved,
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async =>
      throw const DownloadSourceException(DownloadSourceErrorKind.network, 'sin red');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSource implements DownloadSource {
  List<RemoteTrack> searchResults = [];
  final List<String> queries = [];

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    queries.add(query);
    return searchResults;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _cloudSong(String hash, {String? url, int duration = 200}) => {
      'songId': 'id-$hash',
      'fileHash': hash,
      'title': 'Título $hash',
      'artist': 'Artista',
      'durationSeconds': duration,
      'sourceUrl': url,
    };

Song _localSong(String id, {bool missing = false, String? sourceUrl}) => Song(
      id: id,
      title: 'L',
      artist: 'A',
      duration: 1,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime.now(),
      uri: 'content://x/$id',
      fileHash: id,
      missing: missing,
      sourceUrl: sourceUrl,
    );

void main() {
  late DatabaseHelper db;
  late _FakeCloud cloud;
  late _FakeSource source;
  late DownloadProvider downloads;
  late CloudLibraryProvider provider;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_cloudlib_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    await db.clearDownloadQueue();
    cloud = _FakeCloud();
    source = _FakeSource();
    downloads = DownloadProvider(service: _OfflineService(), source: source, db: db);
    addTearDown(downloads.dispose);
    provider = CloudLibraryProvider(cloud: cloud, downloads: downloads, source: source, db: db, startProcessing: () {});
    addTearDown(provider.dispose);
  });

  test('no hace nada hasta que se pide refresh (sync manual)', () {
    expect(provider.status, CloudLibraryStatus.idle);
    expect(cloud.getLibraryCalls, 0);
  });

  test('sin biblioteca subida: estado noLibrary', () async {
    cloud.hasLibrary = false;
    await provider.refresh();
    expect(provider.status, CloudLibraryStatus.noLibrary);
  });

  test('error de red: estado error con la excepción, sin lista', () async {
    cloud.error = const CloudSourceException(CloudSourceErrorKind.network, 'x');
    await provider.refresh();
    expect(provider.status, CloudLibraryStatus.error);
    expect(provider.error, isA<CloudSourceException>());
    expect(provider.entries, isEmpty);
  });

  test('la lista excluye lo local por hash (incluso missing) y por id de vídeo', () async {
    await db.insertSong(_localSong('h-local', missing: true));
    await db.insertSong(_localSong('h-otro', sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
    cloud.library = CloudLibrary(
      version: 1,
      songs: [
        _cloudSong('h-local'),
        _cloudSong('h-video', url: 'https://youtu.be/dQw4w9WgXcQ'),
        _cloudSong('h-nueva', url: 'https://youtu.be/aaaaaaaaaaa'),
        _cloudSong('h-sin-enlace'),
      ],
      playlists: const [],
      playlistSongs: const [],
    );

    await provider.refresh();

    expect(provider.status, CloudLibraryStatus.ready);
    expect(provider.entries.map((e) => e.fileHash), ['h-nueva', 'h-sin-enlace']);
    expect(provider.entries.map((e) => e.hasLink), [true, false]);
  });

  test('downloadOne encola en la Bandeja como restore, con metadata plana', () async {
    cloud.library = CloudLibrary(
      version: 1,
      songs: [_cloudSong('h1', url: 'https://youtu.be/aaaaaaaaaaa')],
      playlists: const [],
      playlistSongs: const [],
    );
    await provider.refresh();

    final result = await provider.downloadOne(provider.entries.single);

    expect(result, CloudDownloadResult.queued);
    final rows = await db.getDownloadQueue();
    expect(rows, hasLength(1));
    expect(rows.single['playlistId'], inboxDownloadTarget);
    expect(rows.single['sourceType'], 'restore');
    expect(rows.single['sourceId'], 'aaaaaaaaaaa');
    expect(rows.single['metadataComplete'], 0);
    expect(provider.entries.single.queued, isTrue);

    expect(await provider.downloadOne(provider.entries.single), CloudDownloadResult.alreadyQueued);
  });

  test('downloadAll encola sólo las que tienen enlace y respeta el tope', () async {
    cloud.library = CloudLibrary(
      version: 1,
      songs: [
        for (var i = 0; i < 5; i++) _cloudSong('h$i', url: 'https://youtu.be/aaaaaaaaaa$i'),
        _cloudSong('sin'),
      ],
      playlists: const [],
      playlistSongs: const [],
    );
    await provider.refresh();

    expect(provider.downloadableCount, 5);
    final count = await provider.downloadAll(limit: 3);

    expect(count, 3);
    expect(await db.getDownloadQueue(), hasLength(3));
    expect(provider.downloadableCount, 2, reason: 'las ya encoladas no cuentan');
  });

  test('sin enlace: empareja por duración y encola; sin candidato aceptable no encola', () async {
    cloud.library = CloudLibrary(
      version: 1,
      songs: [_cloudSong('h-sin', duration: 200)],
      playlists: const [],
      playlistSongs: const [],
    );
    await provider.refresh();

    source.searchResults = [
      const RemoteTrack(
        id: 'bbbbbbbbbbb',
        title: 'Lejos',
        artist: 'C',
        album: null,
        durationSeconds: 900,
        thumbnailUrl: '',
        sourceUrl: 'https://youtu.be/bbbbbbbbbbb',
      ),
    ];
    expect(await provider.downloadOne(provider.entries.single), CloudDownloadResult.noMatch);
    expect(await db.getDownloadQueue(), isEmpty);

    source.searchResults = [
      const RemoteTrack(
        id: 'ccccccccccc',
        title: 'Cerca',
        artist: 'C',
        album: null,
        durationSeconds: 201,
        thumbnailUrl: '',
        sourceUrl: 'https://youtu.be/ccccccccccc',
      ),
    ];
    expect(await provider.downloadOne(provider.entries.single), CloudDownloadResult.queued);
    expect((await db.getDownloadQueue()).single['sourceId'], 'ccccccccccc');
  });
}
