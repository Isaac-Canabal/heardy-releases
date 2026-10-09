// Validación de extremo a extremo de la Fase 5 contra el servidor REAL.
//
// A diferencia del resto de tests, aquí no hay fake de DownloadSource: se usa
// YtdlpServerSource contra el microservicio de server/, que a su vez habla con
// YouTube de verdad. Sólo el almacenamiento (SAF) sigue siendo falso, porque
// no existe fuera de Android.
//
// Eso hace que este test cubra dos cosas que ningún otro puede:
//   - que la cadena cola -> HTTP -> servidor -> yt-dlp -> SAF -> SQLite encaja;
//   - la escritura de tags con un MP4 real, que con el .m4a sintético de
//     download_service_test.dart siempre cae al camino de fallo.
//
// **Se salta solo si el servidor no responde**, así que `flutter test` sigue
// funcionando sin levantar nada. Para ejercitarlo:
//     cd server && run.bat
//     flutter test test/download_live_integration_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/library_scan_service.dart';
import 'package:heardy/services/metadata_service.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/saf_library_storage.dart';

import 'fake_saf.dart';

/// Primer vídeo público de YouTube: corto (19 s), estable desde 2005 y
/// perfecto como canario — gasta lo mínimo del presupuesto de peticiones por
/// IP, que es el recurso escaso de todo este montaje.
const _videoUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
const _videoId = 'jNQXAC9IVRw';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Lee la clave de server/.env, que es donde make-key.bat la deja.
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
  late DatabaseHelper db;
  late YtdlpServerSource source;
  String? apiKey;
  var serverReady = false;
  var skipReason = '';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_live_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;

    sandbox = Directory.systemTemp.createTempSync('heardy_live_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);

    apiKey = _readApiKey();
    source = YtdlpServerSource(
      baseUrl: () => 'http://127.0.0.1:8080',
      // Sin sesión de Firebase en este test: ejercita el mecanismo viejo
      // (X-Api-Key), que el servidor sigue aceptando para desarrollo local
      // (ver YtdlpServerSource, doc de `apiKey`).
      authToken: () async => null,
      apiKey: () => apiKey ?? '',
    );

    if (apiKey == null) {
      skipReason = 'no hay HEARDY_API_KEY en server/.env — ejecutá server\\make-key.bat';
      return;
    }
    final status = await source.probe();
    if (!status.reachable) {
      skipReason = 'el servidor no responde en 127.0.0.1:8080 — ejecutá server\\run.bat';
      return;
    }
    if (!status.authenticated) {
      skipReason = 'la clave de API no es válida: ${status.detail}';
      return;
    }
    if (!status.potProviderReachable) {
      skipReason = 'el proveedor de PO tokens no responde — ejecutá server\\run-pot.bat';
      return;
    }
    serverReady = true;
  });

  test('cola -> servidor real -> biblioteca, y un reescaneo lo ve como unchanged', () async {
    if (!serverReady) {
      markTestSkipped('Integración en vivo omitida: $skipReason');
      return;
    }

    final backend = FakeSafBackend();
    final root = backend.addDir(null, 'Heardy');
    SafUtilPlatform.instance = FakeSafUtil(backend);
    SafStreamPlatform.instance = FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
    SharedPreferences.setMockInitialValues({'heardy_library_root_uri': root.uri});

    final playlistId = const Uuid().v4();
    await db.insertPlaylist(
      Playlist(id: playlistId, name: 'EnVivo', creationDate: DateTime.now()),
    );

    final completed = <String>[];
    final provider = DownloadProvider(
      service: DownloadService(source: source),
      db: db,
      source: source,
      onDownloadComplete: (id) async => completed.add(id),
    );
    addTearDown(provider.dispose);

    // Se encola con metadata deliberadamente MALA y metadataComplete=false,
    // que es exactamente la forma en que llega un resultado de /search. Si la
    // regla del /resolve funciona, nada de esto debe sobrevivir.
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
    expect(await db.getDownloadQueue(), isEmpty, reason: 'el trabajo debe salir de la cola');
    expect(completed, [playlistId]);

    // --- La metadata es la definitiva, no la plana con la que se encoló.
    final songs = await db.getSongsForPlaylist(playlistId);
    expect(songs.length, 1);
    final song = songs.single;
    expect(song.title, isNot('titulo plano incorrecto'),
        reason: 'el /resolve previo debe haber sustituido la metadata plana');
    expect(song.artist, isNot('Canal De Recopilaciones'));
    expect(song.duration, greaterThan(0));
    expect(song.sourceUrl, contains(_videoId));
    expect(song.hashKind, 'mp4-mdat');
    expect(song.format, 'm4a');
    expect(song.filePath, '');
    expect(song.fileSize, greaterThan(10000));

    // --- El archivo está de verdad en la carpeta de la playlist.
    final folder = await FakeSafUtil(backend).child(root.uri, ['EnVivo']);
    expect(folder, isNotNull);
    final files = backend.dirs[folder!.uri]!.childUris.map((u) => backend.files[u]!).toList();
    expect(files.length, 1);
    expect(files.single.name, endsWith('.m4a'));
    expect(files.single.bytes.length, song.fileSize);

    // --- Los tags se escribieron DENTRO del archivo. Esto es lo que ningún
    // otro test puede comprobar: el .m4a sintético de download_service_test
    // no es parseable por audio_metadata_reader, así que allí siempre cae al
    // camino de fallo no fatal.
    final tags = await MetadataService().extract(
      uri: files.single.uri,
      fileName: files.single.name,
      songId: 'verificacion-tags',
    );
    expect(tags.title, song.title,
        reason: 'el archivo debe describirse a sí mismo en disco, no sólo en SQLite');
    expect(tags.artist, song.artist);

    // --- EL INVARIANTE DE LA RAMA.
    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.unchanged, 1);
    expect(scan.inserted, 0, reason: 'una descarga NO puede reaparecer como canción nueva');
    expect(scan.moved, 0);
    expect(scan.updated, 0);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('un vídeo borrado se descarta al primer intento y no gasta reintentos', () async {
    if (!serverReady) {
      markTestSkipped('Integración en vivo omitida: $skipReason');
      return;
    }

    final backend = FakeSafBackend();
    final root = backend.addDir(null, 'Heardy');
    SafUtilPlatform.instance = FakeSafUtil(backend);
    SafStreamPlatform.instance = FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
    SharedPreferences.setMockInitialValues({'heardy_library_root_uri': root.uri});

    final playlistId = const Uuid().v4();
    await db.insertPlaylist(
      Playlist(id: playlistId, name: 'Borrados', creationDate: DateTime.now()),
    );

    final provider = DownloadProvider(
      service: DownloadService(source: source),
      db: db,
      source: source,
    );
    addTearDown(provider.dispose);

    // Id con la forma correcta pero que no corresponde a ningún vídeo: el
    // servidor responde 404 (permanente), no 502 (temporal).
    await provider.enqueueTrack(
      const RemoteTrack(
        id: 'aaaaaaaaaaa',
        title: 'no existe',
        artist: 'nadie',
        album: null,
        durationSeconds: 0,
        thumbnailUrl: '',
        sourceUrl: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      ),
      playlistId: playlistId,
      metadataComplete: false,
    );

    await provider.processQueue();

    expect(await db.getDownloadQueue(), isEmpty,
        reason: 'un vídeo que no existe no debe quedarse consumiendo reintentos');
    expect(provider.failures.single.permanent, isTrue);
    expect(await db.getSongsForPlaylist(playlistId), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
