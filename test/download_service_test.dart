// El test de aceptación de toda la rama de descargas.
//
// La afirmación que se verifica aquí es la que define "integrado" frente a
// "dos sistemas conviviendo": después de descargar una canción, un escaneo
// inmediato debe clasificarla como `unchanged` — nunca `inserted`, nunca
// `moved`. Si eso falla, el descargador y el scanner no están de acuerdo
// sobre qué es una canción, y el síntoma en producción son filas duplicadas
// y pertenencias a playlists que desaparecen solas.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/library_scan_service.dart';
import 'package:heardy/services/storage_service.dart';

import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/saf_library_storage.dart';

import 'fake_saf.dart';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

/// `.m4a` mínimo pero con estructura de cajas válida, que es todo lo que
/// AudioIdentityService necesita recorrer para encontrar `mdat`.
Uint8List _buildM4a(Uint8List audio, {int moovSize = 64}) {
  return Uint8List.fromList([
    ..._box('ftyp', 'M4A isomM4A mp42'.codeUnits),
    ..._box('moov', List.filled(moovSize, 0x00)),
    ..._box('mdat', audio),
  ]);
}

/// DownloadSource falso: entrega bytes de fixture sin tocar la red.
class _FakeSource implements DownloadSource {
  // Explorar no se usa en estos tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();


  _FakeSource(this.audioByTrackId);

  final Map<String, Uint8List> audioByTrackId;
  final List<String> fetched = [];
  DownloadSourceException? failWith;

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    if (failWith != null) throw failWith!;
    final bytes = audioByTrackId[trackId];
    if (bytes == null) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.extraction,
        'sin fixture para ese id',
      );
    }
    fetched.add(trackId);
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<RemoteTrack> resolve(String url) => throw UnimplementedError();

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) => throw UnimplementedError();

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) =>
      throw UnimplementedError();

  @override
  Future<DownloadSourceStatus> probe() => throw UnimplementedError();

  @override
  Future<UsageStatus> usage() => throw UnimplementedError();
}

/// Cliente HTTP que solo sirve para la miniatura; devuelve 404 siempre, para
/// comprobar de paso que una descarga sin carátula sigue siendo válida.
class _NoThumbnailClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 404);
  }
}

RemoteTrack _track({
  required String id,
  String title = 'Título',
  String artist = 'Artista',
  String? album,
  String? sourceUrl,
}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: 180,
    thumbnailUrl: 'http://ejemplo/thumb.jpg',
    sourceUrl: sourceUrl ?? 'https://www.youtube.com/watch?v=$id',
  );
}

void main() {
  late Directory sandbox;
  late FakeSafBackend backend;
  late FakeDir root;
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Directorio de bases propio: `flutter test` corre los archivos de test
    // en paralelo y los otros también crean y borran `heardy.db`.
    final dbDir = Directory.systemTemp.createTempSync('heardy_download_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));

    sandbox = Directory.systemTemp.createTempSync('heardy_download_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    backend = FakeSafBackend();
    root = backend.addDir(null, 'Heardy');
    SafUtilPlatform.instance = FakeSafUtil(backend);
    SafStreamPlatform.instance = FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
    SharedPreferences.setMockInitialValues({'heardy_library_root_uri': root.uri});
  });

  Future<String> newPlaylist(String name) async {
    final id = const Uuid().v4();
    await db.insertPlaylist(Playlist(id: id, name: name, creationDate: DateTime.now()));
    return id;
  }

  DownloadService serviceFor(_FakeSource source) => DownloadService(
        source: source,
        clientFactory: () => _NoThumbnailClient(),
      );

  test('descargar y reescanear: el escaneo lo ve como unchanged, no como una canción nueva', () async {
    final audio = Uint8List.fromList(List.generate(9000, (i) => (i * 17 + 3) % 256));
    final source = _FakeSource({'vid001': _buildM4a(audio)});
    final playlistId = await newPlaylist('Descargas');

    final result = await serviceFor(source).download(_track(id: 'vid001'), playlistId: playlistId);

    // --- El archivo aterrizó en la carpeta de la playlist, con nombre legible.
    expect(result.outcome, DownloadOutcome.inserted);
    final folder = await FakeSafUtil(backend).child(root.uri, ['Descargas']);
    expect(folder, isNotNull, reason: 'debe haberse creado la carpeta de la playlist');
    final written = backend.dirs[folder!.uri]!.childUris.map((u) => backend.files[u]!).toList();
    expect(written.single.name, 'Artista - Título.m4a');

    // --- La fila tiene todo lo que el scanner va a comparar.
    final song = result.song;
    expect(song.id, song.fileHash, reason: 'las canciones importadas se direccionan por su hash');
    expect(song.hashKind, 'mp4-mdat');
    expect(song.uri, written.single.uri);
    expect(song.filePath, '');
    expect(song.format, 'm4a');
    expect(song.sourceUrl, 'https://www.youtube.com/watch?v=vid001');
    expect(song.fileSize, written.single.bytes.length);
    expect(song.modifiedAt, written.single.mtime);
    expect((await db.getSongsForPlaylist(playlistId)).map((s) => s.id), [song.id]);

    // --- LA ASERCIÓN QUE IMPORTA.
    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.unchanged, 1);
    expect(scan.inserted, 0, reason: 'una descarga NO puede reaparecer como canción nueva');
    expect(scan.moved, 0);
    expect(scan.updated, 0);

    // Y sigue siendo la misma fila, en la misma playlist.
    final afterScan = await db.getSongById(song.id);
    expect(afterScan, isNotNull);
    expect(afterScan!.missing, isFalse);
    expect((await db.getSongsForPlaylist(playlistId)).map((s) => s.id), [song.id]);
  });

  test('la misma canción a una segunda playlist no duplica bytes ni filas', () async {
    final audio = Uint8List.fromList(List.generate(8000, (i) => (i * 23 + 5) % 256));
    final source = _FakeSource({'vid002': _buildM4a(audio)});
    final service = serviceFor(source);

    final primera = await newPlaylist('Primera');
    final segunda = await newPlaylist('Segunda');

    final first = await service.download(_track(id: 'vid002'), playlistId: primera);
    final second = await service.download(_track(id: 'vid002'), playlistId: segunda);

    expect(first.outcome, DownloadOutcome.inserted);
    expect(second.outcome, DownloadOutcome.alreadyInLibrary,
        reason: 'mismo audio = misma canción, aunque se pida otra vez');
    expect(second.song.id, first.song.id);

    // Un solo archivo en disco, en la carpeta de la primera playlist.
    final total = backend.files.values.where((f) => f.name.endsWith('.m4a')).length;
    expect(total, 1, reason: 'no se duplican bytes: una canción, varias playlists (D3)');

    expect((await db.getSongsForPlaylist(primera)).map((s) => s.id), [first.song.id]);
    expect((await db.getSongsForPlaylist(segunda)).map((s) => s.id), [first.song.id]);

    // Y el escaneo sigue sin ver nada nuevo.
    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.inserted, 0);
    expect(scan.unchanged, 1);
  });

  test('la rama de duplicado rellena sourceUrl si la fila existente no tenía y nunca lo pisa', () async {
    final audio = Uint8List.fromList(List.generate(5200, (i) => (i * 7 + 11) % 256));
    final source = _FakeSource({'vid005': _buildM4a(audio)});
    final service = serviceFor(source);

    final first = await service.download(_track(id: 'vid005', sourceUrl: ''));
    expect((await db.getSongById(first.song.id))!.sourceUrl, isNull);

    await service.download(_track(id: 'vid005'));
    expect((await db.getSongById(first.song.id))!.sourceUrl, 'https://www.youtube.com/watch?v=vid005');

    await service.download(_track(id: 'vid005', sourceUrl: 'https://youtu.be/otroOtroOtr'));
    expect((await db.getSongById(first.song.id))!.sourceUrl, 'https://www.youtube.com/watch?v=vid005');
  });

  test('sin playlist destino la descarga cae en la bandeja, como cualquier archivo suelto', () async {
    final audio = Uint8List.fromList(List.generate(7000, (i) => (i * 31 + 9) % 256));
    final source = _FakeSource({'vid003': _buildM4a(audio)});

    final result = await serviceFor(source).download(_track(id: 'vid003'));

    final inbox = await db.getInboxSongs();
    expect(inbox.map((s) => s.id), contains(result.song.id));

    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.inserted, 0);
    expect(scan.unchanged, 1);
  });

  test('mover el archivo a otra carpeta después: el escaneo lo reconoce por hash y conserva la playlist', () async {
    final audio = Uint8List.fromList(List.generate(6000, (i) => (i * 41 + 13) % 256));
    final source = _FakeSource({'vid004': _buildM4a(audio)});
    final origen = await newPlaylist('Origen');
    final otra = await newPlaylist('Otra');

    final result = await serviceFor(source).download(_track(id: 'vid004'), playlistId: origen);

    // El usuario mueve el archivo a mano desde el explorador. SAF le da una
    // uri de documento NUEVA al moverlo, así que el matcher por uri no lo va
    // a encontrar y solo el hash del payload puede rescatarlo.
    final origenDir = backend.dirs[(await FakeSafUtil(backend).child(root.uri, ['Origen']))!.uri]!;
    final otraDir = await FakeSafUtil(backend).mkdirp(root.uri, ['Otra']);
    final original = backend.files[result.song.uri!]!;
    backend.unlink(origenDir, original.uri);
    backend.addFile(backend.dirs[otraDir.uri]!, original.name, original.bytes, original.mtime);

    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.moved, 1);
    expect(scan.inserted, 0, reason: 'moverlo no lo convierte en otra canción');

    // La carpeta solo asigna playlist en el primer import, nunca después.
    expect((await db.getSongsForPlaylist(origen)).map((s) => s.id), [result.song.id]);
    expect(await db.getSongsForPlaylist(otra), isEmpty);
  });

  test('un nombre de archivo ya ocupado no pisa el existente ni rompe la identidad', () async {
    // Dos pistas distintas con el mismo artista y título: el proveedor de
    // documentos desambigua el nombre por su cuenta, y el código debe usar la
    // uri devuelta en vez de la que pidió.
    final source = _FakeSource({
      'vidA': _buildM4a(Uint8List.fromList(List.generate(5000, (i) => i % 256))),
      'vidB': _buildM4a(Uint8List.fromList(List.generate(5000, (i) => (i * 3) % 256))),
    });
    final service = serviceFor(source);
    final playlistId = await newPlaylist('Colisiones');

    final a = await service.download(_track(id: 'vidA', title: 'Mismo', artist: 'Igual'),
        playlistId: playlistId);
    final b = await service.download(_track(id: 'vidB', title: 'Mismo', artist: 'Igual'),
        playlistId: playlistId);

    expect(b.outcome, DownloadOutcome.inserted);
    expect(a.song.id, isNot(b.song.id));
    expect(a.song.uri, isNot(b.song.uri));

    final folder = await FakeSafUtil(backend).child(root.uri, ['Colisiones']);
    final names = backend.dirs[folder!.uri]!.childUris.map((u) => backend.files[u]!.name).toList();
    expect(names, ['Igual - Mismo.m4a', 'Igual - Mismo (1).m4a']);

    final scan = await LibraryScanService().scan(root.uri);
    expect(scan.unchanged, 2);
    expect(scan.inserted, 0);
  });

  test('un fallo de descarga no deja ni archivo ni fila a medias', () async {
    final source = _FakeSource({})
      ..failWith = const DownloadSourceException(
        DownloadSourceErrorKind.unsupportedMedia,
        'sin pista AAC',
      );
    final playlistId = await newPlaylist('Fallidas');

    await expectLater(
      serviceFor(source).download(_track(id: 'vidX'), playlistId: playlistId),
      throwsA(isA<DownloadSourceException>()
          .having((e) => e.kind, 'kind', DownloadSourceErrorKind.unsupportedMedia)),
    );

    expect(await db.getSongsForPlaylist(playlistId), isEmpty);
    expect(backend.files.values.where((f) => f.name.endsWith('.m4a')), isEmpty);
    // Y no queda basura en el directorio temporal.
    final leftovers = sandbox.listSync().whereType<File>().where(
          (f) => f.path.contains('heardy_dl_'),
        );
    expect(leftovers, isEmpty);
  });

  test(
      'con carpeta guardada pero el permiso SAF ya revocado (p. ej. tras reinstalar), '
      'el error es accionable y no un SecurityException crudo', () async {
    final source = _FakeSource({'vid006': _buildM4a(Uint8List.fromList(List.filled(4000, 1)))});
    // Android revoca el grant al desinstalar la app. La uri sigue guardada
    // (setUp ya la puso vía SharedPreferences.setMockInitialValues) porque
    // el Auto Backup de Android puede restaurarla en la reinstalación —
    // pero el permiso real sobre ella, no.
    backend.revokedPermissionUris.add(root.uri);

    await expectLater(
      serviceFor(source).download(_track(id: 'vid006')),
      throwsA(isA<DownloadSourceException>()
          .having((e) => e.kind, 'kind', DownloadSourceErrorKind.notConfigured)),
    );
  });

  test('sin carpeta de biblioteca elegida el error es accionable, no un fallo genérico', () async {
    SharedPreferences.setMockInitialValues({});
    final source = _FakeSource({'vid005': _buildM4a(Uint8List.fromList(List.filled(4000, 1)))});

    await expectLater(
      serviceFor(source).download(_track(id: 'vid005')),
      throwsA(isA<DownloadSourceException>()
          .having((e) => e.kind, 'kind', DownloadSourceErrorKind.notConfigured)),
    );
  });

  test('sanitizeFolderName no deja nunca una carpeta sin nombre', () {
    expect(StorageService.sanitizeFolderName('Rock/Pop: lo "mejor"'), 'RockPop lo mejor');
    expect(StorageService.sanitizeFolderName('///'), 'Sin nombre');
    expect(StorageService.sanitizeFolderName('  Con espacios  '), 'Con espacios');
    expect(StorageService.sanitizeFolderName('Termina en punto...'), 'Termina en punto');
  });
}
