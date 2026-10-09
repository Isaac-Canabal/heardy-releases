// La misma validación de extremo a extremo que download_live_integration_test,
// pero por el camino de ESCRITORIO: `FileLibraryStorage` sobre una carpeta de
// verdad, en vez de SAF con su backend falso.
//
// Por qué hace falta aparte: el test de SAF no puede ver este camino (SAF no
// existe fuera de Android) y ningún test de unidad lo cubre entero — escribir
// el archivo, el `stat` de después de pegarlo, el cálculo de identidad sobre
// el archivo ya pegado y el reescaneo son cuatro piezas distintas de
// `FileLibraryStorage`, y las cuatro tienen que coincidir con lo que hace la
// de Android o el mismo audio daría hashes distintos en el teléfono y en el
// PC (ver la regla que encabeza LibraryStorage).
//
// **Se salta solo si el servidor no responde**, igual que su gemelo. Para
// ejercitarlo:
//     cd server && run.bat
//     flutter test test/download_live_desktop_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/file_library_storage.dart';
import 'package:heardy/services/library_scan_service.dart';
import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/metadata_service.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

/// Mismo canario que el test de SAF: 19 s, público desde 2005, y gasta lo
/// mínimo del presupuesto de peticiones por IP.
const _videoUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
const _videoId = 'jNQXAC9IVRw';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

String? _readApiKey() {
  final file = File(join(Directory.current.path, 'server', '.env'));
  if (!file.existsSync()) return null;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('HEARDY_API_KEY=')) {
      final value = line.split('=').skip(1).join('=').trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

void main() {
  late Directory sandbox;
  late Directory libraryRoot;
  late DatabaseHelper db;
  late YtdlpServerSource source;
  var serverReady = false;
  var skipReason = '';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_desktop_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;

    sandbox = Directory.systemTemp.createTempSync('heardy_desktop_live_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
    libraryRoot = Directory(join(sandbox.path, 'Heardy'))..createSync(recursive: true);

    final apiKey = _readApiKey();
    source = YtdlpServerSource(
      baseUrl: () => 'http://127.0.0.1:8080',
      authToken: () async => null,
      apiKey: () => apiKey ?? '',
    );

    if (apiKey == null) {
      skipReason = 'no hay HEARDY_API_KEY en server/.env';
      return;
    }
    final status = await source.probe();
    if (!status.reachable) {
      skipReason = 'el servidor no responde en 127.0.0.1:8080';
      return;
    }
    if (!status.authenticated) {
      skipReason = 'la clave de API no es válida: ${status.detail}';
      return;
    }
    if (!status.potProviderReachable) {
      skipReason = 'el proveedor de PO tokens no responde';
      return;
    }
    serverReady = true;
  });

  test('escritorio: cola -> servidor real -> disco -> biblioteca, y el reescaneo dice unchanged',
      () async {
    if (!serverReady) {
      markTestSkipped('Integración de escritorio omitida: $skipReason');
      return;
    }

    // Lo único que cambia frente al test de SAF: el backend de almacenamiento.
    debugOverrideLibraryStorageForTests(() => FileLibraryStorage());
    addTearDown(() => debugOverrideLibraryStorageForTests(null));
    SharedPreferences.setMockInitialValues({'heardy_library_root_uri': libraryRoot.path});

    final playlistId = const Uuid().v4();
    await db.insertPlaylist(
      Playlist(id: playlistId, name: 'Escritorio', creationDate: DateTime.now()),
    );

    final completed = <String>[];
    final provider = DownloadProvider(
      service: DownloadService(source: source),
      db: db,
      source: source,
      onDownloadComplete: (id) async => completed.add(id),
    );
    addTearDown(provider.dispose);

    await provider.enqueueTrack(
      const RemoteTrack(
        id: _videoId,
        title: 'titulo plano incorrecto',
        artist: 'Canal De Recopilaciones',
        album: null,
        durationSeconds: 0,
        thumbnailUrl: '',
        sourceUrl: _videoUrl,
      ),
      playlistId: playlistId,
      metadataComplete: false,
    );

    await provider.processQueue();

    expect(provider.failures, isEmpty,
        reason: 'fallo en vivo: ${provider.failures.map((f) => f.message).join("; ")}');
    expect(await db.getDownloadQueue(), isEmpty);
    expect(completed, [playlistId]);

    final songs = await db.getSongsForPlaylist(playlistId);
    expect(songs.length, 1);
    final song = songs.single;
    expect(song.title, isNot('titulo plano incorrecto'));
    expect(song.duration, greaterThan(0));
    expect(song.sourceUrl, contains(_videoId));
    expect(song.hashKind, 'mp4-mdat');
    expect(song.format, 'm4a');
    expect(song.fileSize, greaterThan(10000));

    // --- En escritorio, `uri` ES una ruta de archivo real: se puede abrir con
    // dart:io, cosa que en Android sería imposible.
    final playlistDir = Directory(join(libraryRoot.path, 'Escritorio'));
    expect(playlistDir.existsSync(), isTrue, reason: 'la carpeta de la playlist debe crearse sola');
    final files = playlistDir.listSync().whereType<File>().toList();
    expect(files.length, 1);
    expect(basename(files.single.path), endsWith('.m4a'));
    expect(files.single.lengthSync(), song.fileSize);
    expect(song.playablePath, files.single.path,
        reason: 'lo que se le pasa al reproductor tiene que ser el archivo que existe');

    // --- Los tags viajaron DENTRO del archivo, no sólo a SQLite.
    final tags = await MetadataService().extract(
      uri: files.single.path,
      fileName: basename(files.single.path),
      songId: 'verificacion-tags-escritorio',
    );
    expect(tags.title, song.title);
    expect(tags.artist, song.artist);

    // --- EL INVARIANTE DE LA RAMA, ahora también en escritorio: descargar y
    // reescanear no puede producir una canción nueva. Si esto falla, el
    // descargador y el escáner han divergido en el cálculo de identidad y cada
    // descarga futura se duplicará.
    final scan = await LibraryScanService().scan(libraryRoot.path);
    expect(scan.unchanged, 1);
    expect(scan.inserted, 0, reason: 'una descarga NO puede reaparecer como canción nueva');
    expect(scan.moved, 0);
    expect(scan.updated, 0);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
