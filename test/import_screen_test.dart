// Cobertura de widgets de la Fase 6: ImportScreen y su flujo pegar URL →
// vista previa → elegir playlist → encolar.
//
// La aserción que más importa aquí es la del DD6: una descarga iniciada
// desde una URL suelta debe encolarse con metadataComplete=true, porque la
// vista previa YA viene de /resolve — repetirlo sería gastar presupuesto de
// IP para nada.
//
// NOTA SOBRE `runAsync`: `sqflite_common_ffi` habla con un isolate/proceso de
// verdad para ejecutar SQLite. Bajo `testWidgets`, cualquier `tester.pump()`
// que venga después de un acceso real a esa base de datos —incluso uno ya
// terminado— se cuelga para siempre si el acceso ocurrió fuera de
// `tester.runAsync()`. Probado empíricamente: abrir la base y consultarla
// dentro de `runAsync` funciona, pero el primer `pumpWidget` posterior FUERA
// de `runAsync` nunca vuelve. La única combinación estable encontrada es
// meter la interacción entera —pumps y consultas a la base— dentro de un
// mismo `runAsync`, con pumps acotados en vez de `pumpAndSettle` (que además
// no terminaría nunca mientras haya un spinner indeterminado en pantalla,
// como el de `DownloadProgressCard` mientras el servidor "resuelve").
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/providers/auth_provider.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/providers/music_provider.dart';
import 'package:heardy/providers/settings_provider.dart';
import 'package:heardy/screens/import_screen.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/library_scan_service.dart';
import 'package:heardy/theme/app_theme.dart';
import 'package:heardy/l10n/app_localizations.dart';

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

Uint8List _buildM4a(Uint8List audio, {int moovSize = 64}) {
  return Uint8List.fromList([
    ..._box('ftyp', 'M4A isomM4A mp42'.codeUnits),
    ..._box('moov', List.filled(moovSize, 0x00)),
    ..._box('mdat', audio),
  ]);
}

/// DownloadSource falso: sin red, sin servidor. Registra qué se le pidió.
class _FakeDownloadSource implements DownloadSource {
  // Explorar no se usa en estos tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();


  RemoteTrack? nextTrack;
  RemotePlaylist? nextPlaylist;
  DownloadSourceException? resolveError;

  final List<String> resolvedUrls = [];
  final List<String> fetchedIds = [];

  /// Bytes distintos por id, sembrados con su hash — para que varias
  /// entradas de una playlist no colapsen en la misma canción por hash de
  /// audio, como pasaría si todas compartieran el mismo payload de fixture.
  Uint8List _audioFor(String trackId) =>
      _buildM4a(Uint8List.fromList(List.generate(4000, (i) => (i + trackId.hashCode) % 256)));

  @override
  Future<RemoteTrack> resolve(String url) async {
    resolvedUrls.add(url);
    if (resolveError != null) throw resolveError!;
    if (nextTrack != null) return nextTrack!;
    // DD6: toda entrada con metadata plana (venida de una playlist) se
    // resuelve antes de descargarse, una vez por entrada — no hay un único
    // "próximo resultado" fijo posible cuando hay varias en juego. Este fake
    // simula esa resolución buscando la entrada por su sourceUrl, tal como
    // el servidor real la encontraría por el id de vídeo.
    final match = nextPlaylist?.entries.where((e) => e.sourceUrl == url);
    if (match != null && match.isNotEmpty) return match.first;
    throw StateError('_FakeDownloadSource.resolve: no hay pista configurada para $url');
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) async {
    resolvedUrls.add(url);
    if (resolveError != null) throw resolveError!;
    return nextPlaylist!;
  }

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async => const [];

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    fetchedIds.add(trackId);
    final bytes = _audioFor(trackId);
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<DownloadSourceStatus> probe() async => const DownloadSourceStatus(
        reachable: true,
        authenticated: true,
        version: 'fake',
        potProviderReachable: true,
        detail: 'ok',
      );

  @override
  Future<UsageStatus> usage() async => UsageStatus.disabled;
}

RemoteTrack _track({
  String id = 'vid001',
  String title = 'Total Eclipse of the Heart',
  String artist = 'Bonnie Tyler',
}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: null,
    durationSeconds: 240,
    thumbnailUrl: '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

/// Pumps acotados en vez de `pumpAndSettle`: un spinner indeterminado (como
/// el de DownloadProgressCard mientras "resuelve") nunca deja de animar, así
/// que `pumpAndSettle` colgaría el test para siempre con la cola en marcha.
///
/// `tester.pump(duration)` sólo avanza el reloj FALSO del binding de test;
/// no cede tiempo real. `sqflite_common_ffi` habla con un isolate de verdad
/// para cada consulta, así que sin un `Future.delayed` real entre pumps (algo
/// que sólo funciona porque todo esto corre dentro de `tester.runAsync`) el
/// trabajo en curso —un enqueue, una descarga completa— nunca llega a
/// completarse antes de que la aserción se ejecute.
Future<void> _settle(WidgetTester tester, {int pumps = 40}) async {
  for (var i = 0; i < pumps; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Como [_settle], pero corta en cuanto [condition] se cumple en vez de
/// esperar siempre el presupuesto completo — para no atar cada test al peor
/// caso cuando lo que se espera (p. ej. "ya se pidió el audio") suele pasar
/// mucho antes.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxIterations = 100,
}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory sandbox;
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_import_screen_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;

    sandbox = Directory.systemTemp.createTempSync('heardy_import_screen_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
  });

  /// Deja la pantalla lista con carpeta de biblioteca y servidor "configurados"
  /// (aunque el servidor sea el fake), y limpia la cola entre tests. Puramente
  /// síncrono salvo `clearDownloadQueue`, así que se llama DENTRO de runAsync.
  Future<({FakeSafBackend backend, FakeDir root})> setUpEnvironment() async {
    await db.clearDownloadQueue();
    final backend = FakeSafBackend();
    final root = backend.addDir(null, 'Heardy');
    SafUtilPlatform.instance = FakeSafUtil(backend);
    SafStreamPlatform.instance = FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
    SharedPreferences.setMockInitialValues({
      'heardy_library_root_uri': root.uri,
      'download_server_url': 'http://127.0.0.1:8080',
      'download_server_api_key': 'clave-de-prueba',
    });
    return (backend: backend, root: root);
  }

  Future<void> pumpImportScreen(
    WidgetTester tester, {
    required _FakeDownloadSource source,
    required MusicProvider musicProvider,
    required DownloadProvider downloadProvider,
  }) async {
    final settingsProvider = SettingsProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settingsProvider),
          ChangeNotifierProvider.value(value: musicProvider),
          Provider<DownloadSource>.value(value: source),
          ChangeNotifierProvider.value(value: downloadProvider),
          // Fase 2 del plan de seguridad: ImportScreen ahora exige sesión
          // antes de mostrar el flujo de descarga. `.fake` nunca toca
          // FirebaseAuth.instance (que no está inicializado en un test), y
          // `isReady: true` deja el resto de estas pruebas exactamente como
          // estaban, ejercitando el flujo de descarga real.
          ChangeNotifierProvider<HeardyAuthProvider>.value(value: HeardyAuthProvider.fake()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: settingsProvider.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ImportScreen()),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<String> newPlaylist(String name) async {
    final id = const Uuid().v4();
    await db.insertPlaylist(Playlist(id: id, name: name, creationDate: DateTime.now()));
    return id;
  }

  testWidgets(
      'un servidor propio guardado por una versión anterior NO deja la pantalla '
      'inservible: sigue apareciendo el campo de URL', (tester) async {
    await tester.runAsync(() async {
      await db.clearDownloadQueue();
      final backend = FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      SafUtilPlatform.instance = FakeSafUtil(backend);
      SafStreamPlatform.instance = FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
      // La dirección del servidor ya no se configura desde la app: va
      // compilada en el binario (OfficialServer). Estas dos claves son restos
      // de cuando SÍ era editable, y el riesgo real de aquel cambio es que un
      // valor viejo —de un servidor que quizá ya no existe— siguiera mandando
      // sin ninguna UI para deshacerlo. Aquí se comprueba a nivel de pantalla,
      // que es donde el usuario lo sufriría: la de abajo es la más hostil de
      // las dos (dirección vacía = "no hay servidor").
      SharedPreferences.setMockInitialValues({
        'heardy_library_root_uri': root.uri,
        'download_server_url': '',
        'download_server_api_key': '',
      });

      final source = _FakeDownloadSource();
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      expect(find.byKey(const Key('import_url_field')), findsOneWidget);
      expect(find.text('No hay servidor de descargas configurado'), findsNothing);
    });
  });

  testWidgets('servidor configurado pero sin carpeta elegida, pide elegir carpeta primero', (tester) async {
    await tester.runAsync(() async {
      await db.clearDownloadQueue();
      SharedPreferences.setMockInitialValues({
        'download_server_url': 'http://127.0.0.1:8080',
        'download_server_api_key': 'clave',
      });

      final source = _FakeDownloadSource();
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      expect(find.text('Elige primero una carpeta de biblioteca'), findsOneWidget);
      expect(find.byKey(const Key('import_url_field')), findsNothing);
    });
  });

  testWidgets('analizar una URL de video muestra la vista previa con título, artista y duración', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final source = _FakeDownloadSource()..nextTrack = _track();
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://youtu.be/vid001');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(source.resolvedUrls, ['https://youtu.be/vid001']);
      expect(find.text('Total Eclipse of the Heart'), findsOneWidget);
      expect(find.text('Bonnie Tyler'), findsOneWidget);
      expect(find.byKey(const Key('download_track_button')), findsOneWidget);
    });
  });

  testWidgets('una URL con list= se analiza como playlist, no como video suelto', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final source = _FakeDownloadSource()
        ..nextPlaylist = RemotePlaylist(
          id: 'PL1',
          name: 'Mi playlist de YouTube',
          sourceUrl: 'https://youtube.com/playlist?list=PL1',
          entries: [_track(id: 'a'), _track(id: 'b'), _track(id: 'c')],
        );
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(
        find.byKey(const Key('import_url_field')),
        'https://youtube.com/playlist?list=PL1',
      );
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(find.text('Mi playlist de YouTube'), findsOneWidget);
      expect(find.text('3 videos'), findsOneWidget);
      expect(find.byKey(const Key('download_playlist_button')), findsOneWidget);
      expect(find.byKey(const Key('download_track_button')), findsNothing);
    });
  });

  testWidgets('un fallo del resolve muestra el mensaje del usuario en el banner de error', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final source = _FakeDownloadSource()
        ..resolveError = const DownloadSourceException(
          DownloadSourceErrorKind.notFound,
          'Video unavailable',
        );
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://youtu.be/borrado');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(
        find.textContaining('Ese contenido no se puede descargar (borrado, privado, restringido, en directo o demasiado largo)'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('download_track_button')), findsNothing);
    });
  });

  testWidgets(
    'descargar a una playlist existente encola con metadataComplete=true (DD6) y la canción llega a la biblioteca',
    (tester) async {
      await tester.runAsync(() async {
        final env = await setUpEnvironment();
        final playlistId = await newPlaylist('Favoritas');

        final source = _FakeDownloadSource()..nextTrack = _track();
        final musicProvider = MusicProvider();
        final downloadProvider = DownloadProvider(
          service: DownloadService(source: source),
          db: db,
          source: source,
          onDownloadComplete: (id) async {
            await musicProvider.loadPlaylists();
            await musicProvider.loadSongsForPlaylist(id, updateCurrent: false);
          },
        );
        addTearDown(downloadProvider.dispose);

        await pumpImportScreen(
            tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

        await tester.enterText(find.byKey(const Key('import_url_field')), 'https://youtu.be/vid001');
        await tester.tap(find.byKey(const Key('analyze_button')));
        await _settle(tester);

        await tester.tap(find.byKey(const Key('download_track_button')));
        await _settle(tester);

        // Se abrió el selector de playlist destino con la única existente.
        expect(find.byKey(Key('playlist_radio_$playlistId')), findsOneWidget);
        await tester.tap(find.byKey(Key('playlist_radio_$playlistId')));
        await _settle(tester, pumps: 5);
        await tester.tap(find.byKey(const Key('confirm_playlist_choice')));
        await _pumpUntil(tester, () => source.fetchedIds.isNotEmpty);
        // Deja que el resto de la tubería (tags, SAF, hash, insertSong,
        // quitar de la cola) termine tras el fetchAudio.
        await _settle(tester, pumps: 20);

        expect(source.fetchedIds, ['vid001'], reason: 'debe haber bajado el audio del vídeo analizado');
        expect(await db.getDownloadQueue(), isEmpty, reason: 'el trabajo debe salir de la cola al terminar');

        final songs = await db.getSongsForPlaylist(playlistId);
        expect(songs.length, 1);
        expect(songs.single.title, 'Total Eclipse of the Heart');
        expect(songs.single.artist, 'Bonnie Tyler');

        // El invariante de toda la rama: un reescaneo no debe ver esto como
        // nuevo. Si metadataComplete no hubiera sido true, esto seguiría
        // pasando igual (DD6 sólo afecta al número de peticiones, no a la
        // identidad) — pero lo verificamos junto porque ambas garantías
        // conviven en el mismo flujo de UI.
        final scan = await LibraryScanService().scan(env.root.uri);
        expect(scan.unchanged, 1);
        expect(scan.inserted, 0);
      });
    },
  );

  testWidgets('crear una playlist nueva desde la vista previa de un video la crea y encola ahí', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final source = _FakeDownloadSource()..nextTrack = _track(id: 'nueva1');
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://youtu.be/nueva1');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('download_track_button')));
      await _settle(tester);

      await tester.enterText(find.byKey(const Key('new_playlist_name_field')), 'Recién creada');
      await _settle(tester, pumps: 5);
      await tester.tap(find.byKey(const Key('confirm_playlist_choice')));

      await _pumpUntil(
        tester,
        () => musicProvider.playlists.any((p) => p.name == 'Recién creada'),
      );
      final created = musicProvider.playlists.firstWhere((p) => p.name == 'Recién creada');

      // Espera al estado final estable (descarga terminada) antes de salir:
      // dejar el bucle de descarga a medias es lo que filtraba trabajo de
      // una prueba a la siguiente cuando el tearDown cortaba el provider a
      // mitad de camino.
      await _pumpUntil(tester, () => source.fetchedIds.contains('nueva1'));
      await _settle(tester, pumps: 20);

      expect(await db.getDownloadQueue(), isEmpty);
      final songs = await db.getSongsForPlaylist(created.id);
      expect(songs.map((s) => s.title), ['Total Eclipse of the Heart']);
    });
  });

  testWidgets(
    'descargar una playlist de YouTube a una playlist nueva la crea, guarda originalUrl y encola cada entrada',
    (tester) async {
      await tester.runAsync(() async {
        await setUpEnvironment();
        // Títulos distintos por entrada: además de ser más realista (tres
        // vídeos de una playlist real nunca comparten título), esto es lo
        // que permite distinguir por qué fila quedó cada canción una vez
        // descargadas, en vez de una coincidencia ambigua "3 widgets con el
        // mismo texto".
        final entries = [
          _track(id: 'p1', title: 'Canción Uno'),
          _track(id: 'p2', title: 'Canción Dos'),
          _track(id: 'p3', title: 'Canción Tres'),
        ];
        final source = _FakeDownloadSource()
          ..nextPlaylist = RemotePlaylist(
            id: 'PL9',
            name: 'Lista importada',
            sourceUrl: 'https://youtube.com/playlist?list=PL9',
            entries: entries,
          );
        final musicProvider = MusicProvider();
        final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
        addTearDown(downloadProvider.dispose);

        await pumpImportScreen(
            tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

        await tester.enterText(
          find.byKey(const Key('import_url_field')),
          'https://youtube.com/playlist?list=PL9',
        );
        await tester.tap(find.byKey(const Key('analyze_button')));
        await _settle(tester);

        await tester.tap(find.byKey(const Key('download_playlist_button')));
        await _settle(tester);

        // El nombre sugerido ya viene precargado con el de la playlist remota.
        expect(find.text('Lista importada'), findsWidgets);
        await tester.tap(find.byKey(const Key('confirm_playlist_choice')));

        // Espera a que la playlist exista Y ya tenga originalUrl — se crea
        // primero sin él y se actualiza en un segundo paso (ver
        // _downloadPlaylist), así que "existe por nombre" no basta.
        await _pumpUntil(
          tester,
          () => musicProvider.playlists.any((p) => p.name == 'Lista importada' && p.originalUrl != null),
        );
        final created = musicProvider.playlists.firstWhere((p) => p.name == 'Lista importada');
        expect(created.originalUrl, 'https://youtube.com/playlist?list=PL9');

        // Espera a que las 3 se hayan pedido de verdad — no inspecciona la
        // cola a mitad de camino porque processQueue() (disparado sin esperar
        // por la propia pantalla) la va vaciando en paralelo; esperar el
        // estado FINAL estable evita una carrera contra ese consumo.
        await _pumpUntil(tester, () => source.fetchedIds.length == 3, maxIterations: 150);
        // Deja que la última termine de escribirse en SAF/SQLite antes de
        // salir del runAsync — así ningún trabajo queda a medias cuando el
        // tearDown dispose() corte el provider, que es justo lo que dejaba
        // basura de una prueba en la siguiente.
        await _settle(tester, pumps: 20);

        expect(await db.getDownloadQueue(), isEmpty);
        final songs = await db.getSongsForPlaylist(created.id);
        expect(songs.map((s) => s.title), ['Canción Uno', 'Canción Dos', 'Canción Tres'],
            reason: 'concurrencia 1 + orden FIFO deben preservar el orden de la playlist de origen');
      });
    },
  );

  testWidgets('cancelar un trabajo en cola lo quita de la lista y de la base', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final playlistId = await newPlaylist('ConCola');
      final source = _FakeDownloadSource();
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      // Encolamos directo por el provider (sin pasar por el flujo de
      // análisis ni disparar processQueue) para poner la cola en un estado
      // conocido y ESTABLE antes de pintar la pantalla.
      await downloadProvider.enqueueTrack(
        _track(id: 'quedará'),
        playlistId: playlistId,
        metadataComplete: true,
      );

      await pumpImportScreen(
          tester, source: source, musicProvider: musicProvider, downloadProvider: downloadProvider);

      expect(find.text('Total Eclipse of the Heart'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await _pumpUntil(tester, () => downloadProvider.pendingCount == 0);

      expect(await db.getDownloadQueue(), isEmpty);
      expect(downloadProvider.pendingCount, 0);
    });
  });
}
