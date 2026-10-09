// Cobertura de widgets del puente Spotify (Fase 8) dentro de ImportScreen.
//
// A diferencia de PlaylistDetailScreen/SearchScreen (Fases 6/7), ImportScreen
// no depende de un AudioPlayerHandler real, así que este flujo SÍ se puede
// probar de punta a punta. Lo único que hacía falta era poder sustituir
// SpotifyService — de ahí el parámetro inyectable añadido a ImportScreen en
// esta misma fase.
//
// Reutiliza el patrón de test/import_screen_test.dart: sqflite_common_ffi
// exige que TODO el cuerpo de cada test —pumps incluidos— viva dentro de un
// único `tester.runAsync`, con pumps de duración REAL en vez de
// `pumpAndSettle` (ver la nota larga en ese archivo y en CLAUDE.md).
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

import 'package:heardy/services/friendly_error.dart';
import 'package:heardy/models/playlist.dart';
import 'package:heardy/providers/auth_provider.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/providers/music_provider.dart';
import 'package:heardy/providers/settings_provider.dart';
import 'package:heardy/screens/import_screen.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/spotify_service.dart';
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
    (size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

Uint8List _buildM4a(Uint8List audio) {
  return Uint8List.fromList([
    ..._box('ftyp', 'M4A isomM4A mp42'.codeUnits),
    ..._box('moov', List.filled(64, 0x00)),
    ..._box('mdat', audio),
  ]);
}

/// SpotifyService falso: devuelve lo que el test configure para cada URL, en
/// vez de scrapear Spotify de verdad. `analyze` es un método de instancia
/// normal (no estático, no `final`), así que sustituirlo por herencia es
/// exactamente lo que ImportScreen ya soporta desde que ganó el parámetro
/// `spotifyService` inyectable.
class _FakeSpotifyService extends SpotifyService {
  SpotifyAnalysisResult? nextResult;
  Object? nextError;
  final List<String> analyzedUrls = [];

  @override
  Future<SpotifyAnalysisResult> analyze(String url) async {
    analyzedUrls.add(url);
    if (nextError != null) throw nextError!;
    return nextResult!;
  }
}

/// DownloadSource falso: `search` devuelve resultados por consulta exacta —
/// como matchSpotifyTrack arma la consulta como "artista título", cada
/// pista de Spotify necesita su propia entrada.
class _FakeDownloadSource implements DownloadSource {
  // Explorar no se usa en estos tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();


  final Map<String, List<RemoteTrack>> resultsByQuery = {};
  Uint8List audioBytes = _buildM4a(Uint8List.fromList(List.generate(4000, (i) => i % 256)));
  final List<String> fetchedIds = [];

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async => resultsByQuery[query] ?? const [];

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    fetchedIds.add(trackId);
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(audioBytes);
    onProgress?.call(audioBytes.length, audioBytes.length);
  }

  @override
  Future<RemoteTrack> resolve(String url) async {
    // DD6: el worker resuelve cada match antes de bajarlo (metadataComplete
    // es siempre false para resultados de /search). Como este fake no
    // distingue canal de artista real, basta con devolver el candidato que
    // ya se había encontrado para esa uri.
    for (final list in resultsByQuery.values) {
      for (final t in list) {
        if (t.sourceUrl == url) return t;
      }
    }
    throw StateError('sin candidato configurado para $url');
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) => throw UnimplementedError();
  @override
  Future<DownloadSourceStatus> probe() => throw UnimplementedError();
  @override
  Future<UsageStatus> usage() async => UsageStatus.disabled;
}

RemoteTrack _yt(String id, {required int durationSeconds, String title = 'T', String artist = 'Canal'}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: null,
    durationSeconds: durationSeconds,
    thumbnailUrl: '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

SpotifyTrackInfo _spTrack({
  String title = 'Total Eclipse of the Heart',
  String artist = 'Bonnie Tyler',
  required int durationMs,
}) {
  return SpotifyTrackInfo(title: title, artist: artist, durationMs: durationMs);
}

Future<void> _settle(WidgetTester tester, {int pumps = 40}) async {
  for (var i = 0; i < pumps; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition, {int maxIterations = 100}) async {
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
    final dbDir = Directory.systemTemp.createTempSync('heardy_import_spotify_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;

    sandbox = Directory.systemTemp.createTempSync('heardy_import_spotify_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
  });

  Future<void> setUpEnvironment() async {
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
  }

  Future<void> pumpImportScreen(
    WidgetTester tester, {
    required _FakeDownloadSource source,
    required _FakeSpotifyService spotify,
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
          home: Scaffold(body: ImportScreen(spotifyService: spotify)),
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

  testWidgets('un enlace de Spotify se detecta como tal, no como video de YouTube', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final spotify = _FakeSpotifyService()
        ..nextResult = SpotifyAnalysisResult(
          type: 'track',
          name: 'Total Eclipse of the Heart',
          subtitle: 'Bonnie Tyler',
          tracks: [_spTrack(durationMs: 213000)],
        );
      final source = _FakeDownloadSource()
        ..resultsByQuery['Bonnie Tyler Total Eclipse of the Heart'] = [
          _yt('match1', durationSeconds: 214, title: 'Total Eclipse of the Heart', artist: 'Canal Oficial'),
        ];
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, spotify: spotify, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(
        find.byKey(const Key('import_url_field')),
        'https://open.spotify.com/track/2raNaXaFvxsEeSMJC0aXhL',
      );
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(spotify.analyzedUrls, ['https://open.spotify.com/track/2raNaXaFvxsEeSMJC0aXhL']);
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.byKey(const Key('download_track_button')), findsNothing,
          reason: 'un enlace de Spotify no debe caer en el camino de vídeo suelto de YouTube');
      expect(find.byKey(const Key('download_spotify_button')), findsOneWidget);
    });
  });

  testWidgets('una buena coincidencia se descarga con sourceType spotify y metadataComplete=false (DD6)',
      (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final playlistId = await newPlaylist('Favoritas de Spotify');

      final spotify = _FakeSpotifyService()
        ..nextResult = SpotifyAnalysisResult(
          type: 'track',
          name: 'Total Eclipse of the Heart',
          subtitle: 'Bonnie Tyler',
          tracks: [_spTrack(durationMs: 213000)],
        );
      final source = _FakeDownloadSource()
        ..resultsByQuery['Bonnie Tyler Total Eclipse of the Heart'] = [
          _yt('match1', durationSeconds: 214, title: 'Coincidencia Buena', artist: 'Canal Oficial'),
        ];
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, spotify: spotify, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(
        find.byKey(const Key('import_url_field')),
        'https://open.spotify.com/track/x',
      );
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(find.textContaining('Δ 1s'), findsOneWidget, reason: '214-213=1s, coincidencia buena');

      await tester.tap(find.byKey(const Key('download_spotify_button')));
      await _settle(tester);
      expect(find.byKey(Key('playlist_radio_$playlistId')), findsOneWidget);
      await tester.tap(find.byKey(Key('playlist_radio_$playlistId')));
      await _settle(tester, pumps: 5);
      await tester.tap(find.byKey(const Key('confirm_playlist_choice')));

      await _pumpUntil(tester, () => source.fetchedIds.isNotEmpty);
      await _settle(tester, pumps: 20);

      expect(source.fetchedIds, ['match1']);
      expect(await db.getDownloadQueue(), isEmpty);
      final songs = await db.getSongsForPlaylist(playlistId);
      expect(songs.single.title, 'Coincidencia Buena',
          reason: 'la metadata definitiva es la del /resolve del worker, no la de Spotify');
      expect(songs.single.sourceUrl, 'https://www.youtube.com/watch?v=match1');
    });
  });

  testWidgets('sin coincidencia aceptable, la pista se marca "no se descargará" y no se encola', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final spotify = _FakeSpotifyService()
        ..nextResult = SpotifyAnalysisResult(
          type: 'track',
          name: 'Rara Avis',
          subtitle: 'Artista Desconocido',
          tracks: [_spTrack(title: 'Rara Avis', artist: 'Artista Desconocido', durationMs: 200000)],
        );
      // El único resultado está a 187s de diferencia: por encima del
      // máximo tolerado (30s), así que no debe ofrecerse para descargar.
      final source = _FakeDownloadSource()
        ..resultsByQuery['Artista Desconocido Rara Avis'] = [
          _yt('lejano', durationSeconds: 13, title: 'Cover De Otra Cosa', artist: 'Canal'),
        ];
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, spotify: spotify, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://open.spotify.com/track/rara');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(find.text('no se descargará'), findsOneWidget);
      expect(find.text('Sin coincidencias descargables'), findsOneWidget);

      final button = tester.widget<ElevatedButton>(find.byKey(const Key('download_spotify_button')));
      expect(button.onPressed, isNull, reason: 'sin ninguna coincidencia aceptable, el botón debe estar deshabilitado');
      expect(source.fetchedIds, isEmpty);
    });
  });

  testWidgets('una colección mixta sólo encola las pistas con coincidencia aceptable', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final spotify = _FakeSpotifyService()
        ..nextResult = SpotifyAnalysisResult(
          type: 'playlist',
          name: 'Mi playlist de Spotify',
          subtitle: 'por Alguien',
          tracks: [
            _spTrack(title: 'Buena', artist: 'Artista A', durationMs: 200000), // match a 201s -> Δ1
            _spTrack(title: 'Sin Coincidencia', artist: 'Artista B', durationMs: 200000), // Δ187
          ],
        );
      final source = _FakeDownloadSource()
        ..resultsByQuery['Artista A Buena'] = [
          _yt('buena-yt', durationSeconds: 201, title: 'Buena (Video Oficial)', artist: 'Canal A'),
        ]
        ..resultsByQuery['Artista B Sin Coincidencia'] = [
          _yt('mala-yt', durationSeconds: 13, title: 'Otra Cosa', artist: 'Canal B'),
        ];
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, spotify: spotify, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://open.spotify.com/playlist/mix');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(find.text('Descargar 1 canción'), findsOneWidget);

      await tester.tap(find.byKey(const Key('download_spotify_button')));
      await _settle(tester);
      // Playlist nueva, sugerida con el nombre de la colección de Spotify.
      expect(find.text('Mi playlist de Spotify'), findsWidgets);
      await tester.tap(find.byKey(const Key('confirm_playlist_choice')));

      await _pumpUntil(tester, () => source.fetchedIds.isNotEmpty);
      await _settle(tester, pumps: 20);

      expect(source.fetchedIds, ['buena-yt'], reason: 'sólo la pista con buena coincidencia debe bajarse');

      final playlists = await db.getPlaylists();
      final created = playlists.firstWhere((p) => p.name == 'Mi playlist de Spotify');
      expect(created.originalUrl, isNull,
          reason: 'una colección de Spotify no es una playlist de YouTube: no hay nada que "actualizar" después');

      final songs = await db.getSongsForPlaylist(created.id);
      expect(songs.length, 1);
    });
  });

  testWidgets('un fallo al analizar el enlace muestra el mensaje sin el prefijo "Exception: "', (tester) async {
    await tester.runAsync(() async {
      await setUpEnvironment();
      final spotify = _FakeSpotifyService()
        ..nextError = const FriendlyException('Ese enlace de Spotify no es válido.', 'E-SP-URL');
      final source = _FakeDownloadSource();
      final musicProvider = MusicProvider();
      final downloadProvider = DownloadProvider(service: DownloadService(source: source), db: db, source: source);
      addTearDown(downloadProvider.dispose);

      await pumpImportScreen(
          tester, source: source, spotify: spotify, musicProvider: musicProvider, downloadProvider: downloadProvider);

      await tester.enterText(find.byKey(const Key('import_url_field')), 'https://open.spotify.com/track/roto');
      await tester.tap(find.byKey(const Key('analyze_button')));
      await _settle(tester);

      expect(find.textContaining('Ese enlace de Spotify no es válido.'), findsOneWidget);
      expect(find.textContaining('E-SP-URL'), findsOneWidget);
      expect(find.textContaining('Exception:'), findsNothing);
    });
  });
}
