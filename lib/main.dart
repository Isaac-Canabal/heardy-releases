import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'services/database_helper.dart';
import 'services/audio_effects_service.dart';
import 'services/audio_player_handler.dart';
import 'services/cloud_source.dart';
import 'services/download_service.dart';
import 'services/download_source.dart';
import 'services/explore_logic.dart';
import 'services/heardy_cloud_source.dart';
import 'services/official_server.dart';
import 'services/server_pool.dart';
import 'services/stream_resolver.dart';
import 'services/ytdlp_local_stream_resolver.dart';
import 'services/ytdlp_server_source.dart';
import 'services/system_notifications.dart';
import 'providers/auth_provider.dart';
import 'providers/download_provider.dart';
import 'providers/explore_provider.dart';
import 'providers/music_provider.dart';
import 'providers/notifications_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/sync_provider.dart';
import 'screens/legal_screen.dart';
import 'screens/main_shell_screen.dart';
import 'screens/playlist_detail_screen.dart';
import 'services/desktop_layout.dart';
import 'services/desktop_shortcuts.dart';
import 'services/desktop_taskbar_service.dart';
import 'services/desktop_title_bar.dart';
import 'services/desktop_tray_service.dart';
import 'theme/app_theme.dart';
import 'widgets/desktop_title_bar.dart';
import 'package:heardy/services/app_log.dart';

/// `true` en Windows/Linux/macOS. Todo lo que sólo existe en el APK Android
/// (SAF, notificación de reproducción, tarea en primer plano, cuenta vía
/// Firebase) se guarda detrás de este flag — ver el plan de escritorio,
/// fase W0/W2. La reproducción/base de datos/UI locales son Dart puro y no
/// necesitan ninguna de estas guardas.
bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Sólo Windows: botones de miniatura + teclas multimedia globales.
DesktopTaskbarService? taskbarService;

/// `path_provider_windows` arma la carpeta de datos por usuario
/// (`getApplicationSupportDirectory`) como `%APPDATA%\<CompanyName>\
/// <ProductName>`, leyendo esos dos campos directamente del recurso
/// VERSIONINFO del propio `.exe` — ver `_getApplicationSpecificSubdirectory`
/// en el paquete. `windows/runner/Runner.rc` cambió esos valores (de
/// "com.heardy"/"heardy" a "Vainastech"/"Heardy") para corregir un falso
/// positivo de VirusTotal en el instalador; el efecto secundario, no
/// anticipado hasta que se reprodujo en vivo, es que cualquier build con esa
/// identidad nueva abre una carpeta completamente distinta la primera vez —
/// vacía — perdiendo en apariencia toda la biblioteca, ajustes e historial
/// del usuario (que siguen intactos en la carpeta vieja, sólo que la app ya
/// no mira ahí). Se corrige una sola vez por máquina: si la carpeta nueva
/// todavía no tiene el marcador de esta migración, se copia encima el
/// contenido de la carpeta vieja (si existe) antes de abrir la base de
/// datos — después de la primera vez, el marcador evita que una migración
/// tardía pise cambios reales ya hechos bajo la identidad nueva. No migra
/// las cachés de carátula/letra/traducción (`getApplicationDocumentsDirectory`):
/// son recalculables, no una pérdida real.
Future<void> _migrateLegacyWindowsDataDir(Directory newSupportDir) async {
  final marker = File(p.join(newSupportDir.path, '.legacy_migration_done'));
  if (await marker.exists()) return;

  final legacyDir = Directory(
    p.join(newSupportDir.parent.parent.path, 'com.heardy', 'heardy'),
  );
  if (await legacyDir.exists()) {
    await newSupportDir.create(recursive: true);
    await for (final entity in legacyDir.list()) {
      if (entity is File) {
        await entity.copy(p.join(newSupportDir.path, p.basename(entity.path)));
      }
    }
    appLog('Migración: copiados los datos de ${legacyDir.path} a ${newSupportDir.path}');
  }

  await newSupportDir.create(recursive: true);
  await marker.writeAsString(DateTime.now().toIso8601String());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // `sqflite` no tiene motor propio de base de datos en escritorio (a
  // diferencia de Android/iOS, que traen SQLite del sistema): hay que
  // sustituir `databaseFactory` por la implementación FFI antes de la
  // primera llamada a `DatabaseHelper` — ver W2 del plan de escritorio.
  if (_isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Sin esto, `getDatabasesPath()` por defecto de `sqflite_common_ffi`
    // resuelve relativo al directorio de trabajo actual
    // (`<cwd>/.dart_tool/sqflite_common_ffi/databases`) — inofensivo en
    // `flutter test`, pero un bug real en la app instalada: un `.exe`
    // lanzado desde `C:\Program Files\Heardy\` escribiría ahí (no
    // necesariamente escribible sin admin, y el desinstalador nunca lo ve
    // porque Inno Setup no sabe que existe). Verificado en vivo con un
    // instalar/desinstalar real (W4) — el archivo sobrevivía a la
    // desinstalación. `getApplicationSupportDirectory()` es la carpeta de
    // datos de la app por usuario (en Windows, `%APPDATA%\Heardy`).
    final supportDir = await getApplicationSupportDirectory();
    if (Platform.isWindows) await _migrateLegacyWindowsDataDir(supportDir);
    await databaseFactory.setDatabasesPath(supportDir.path);

    // Backend de reproducción de escritorio: libmpv vía just_audio_media_kit
    // (ver en pubspec.yaml por qué no just_audio_windows). Tiene que
    // registrarse antes de crear el primer `AudioPlayer`.
    JustAudioMediaKit.title = 'Heardy';
    JustAudioMediaKit.ensureInitialized();

    // Barra de título propia (widgets/desktop_title_bar.dart): se oculta
    // sólo la franja nativa de arriba, el marco se conserva (redimensionar
    // desde los bordes, ajustar a los lados y arrastrar siguen siendo del
    // sistema). La ventana se muestra cuando el primer frame está listo,
    // no antes, para no ver un rectángulo vacío mientras arranca Flutter.
    await windowManager.ensureInitialized();
    // El mínimo tiene que quedar claramente por encima de `desktopBreakpoint`
    // (900, en desktop_layout.dart): con los dos iguales, el ancho mínimo
    // permitido caía justo en el borde del quiebre de diseño y la ventana
    // más chica posible ya se veía apretada como el layout de teléfono en
    // vez del de tres columnas.
    const windowOptions = WindowOptions(
      title: 'Heardy',
      minimumSize: desktopMinimumWindowSize,
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // La bandeja del sistema (DesktopTrayService.init) se engancha en
    // main_shell_screen.dart, no acá: necesita un BuildContext para pedir los
    // textos ya traducidos del menú, y a esta altura del arranque todavía no
    // existe ninguno.
  }

  if (Platform.isAndroid) {
    // Requisito de flutter_foreground_task para poder mandar/recibir datos
    // entre el isolate del servicio y la UI — no se usa ese canal acá (el
    // TaskHandler de descargas no hace nada por sí mismo, ver
    // download_foreground_service.dart), pero hay que llamarlo igual antes de
    // arrancar cualquier servicio. El plugin no declara soporte de
    // escritorio: llamarlo ahí lanzaría en tiempo de ejecución.
    FlutterForegroundTask.initCommunicationPort();
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await DatabaseHelper.instance.database;

  if (Platform.isAndroid) {
    // Fase 2 del plan de seguridad: identidad por cuenta real (Firebase Auth)
    // en vez de la clave de API única compilada en el binario. Sin opciones
    // explícitas: app Android-only, `android/app/google-services.json` (vía
    // el plugin de Gradle) ya deja todo lo que el SDK necesita.
    //
    // Firebase Auth NO se usa en escritorio (Hallazgo 3 del plan de
    // escritorio: Google no lo considera apto para producción en Windows) —
    // la cuenta en el PC, cuando llegue (fase W5), hablará con la API REST
    // de Firebase Auth por HTTP en vez de este SDK, sin necesitar
    // `Firebase.initializeApp()` en absoluto.
    await Firebase.initializeApp();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    // A fresh instance is enough: flutter_local_notifications initializes the
    // plugin platform-wide, so any other instance (e.g. AudioPlayerHandler's
    // own for playback-error notifications) shares this same initialization.
    final localNotificationsPlugin = FlutterLocalNotificationsPlugin();
    await localNotificationsPlugin.initialize(
      initializationSettings,
      // Toque en primer plano, o que trae la app de fondo — cubre los
      // botones de "descargar"/"ver" de la notificación de versión nueva
      // (`NotificationsProvider`/`system_notifications.dart`), marcados
      // `showsUserInterface: true` justo para que este callback sea el que
      // siempre corre, nunca uno en un isolate de segundo plano.
      onDidReceiveNotificationResponse: (response) {
        handleSystemNotificationTap(response.actionId ?? response.payload);
      },
    );
    // El caso que el callback de arriba no cubre: la app estaba
    // completamente cerrada y el toque en la notificación es lo que la
    // arrancó. `initialize()` ya devolvió antes de que hubiera nada
    // escuchando, así que hay que revisar esto aparte.
    final launchDetails = await localNotificationsPlugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final response = launchDetails!.notificationResponse;
      handleSystemNotificationTap(response?.actionId ?? response?.payload);
    }
  }

  // `audio_service` no declara soporte de escritorio. `AudioService.init()`
  // es lo único de ese paquete que es específico de plataforma (notificación,
  // pantalla de bloqueo, sesión de medios) — `BaseAudioHandler`, `MediaItem`
  // y `PlaybackState` son Dart puro, así que en escritorio basta con
  // construir el handler directamente y perder los controles del sistema
  // operativo (recuperables más adelante con `smtc_windows`, fase W2+).
  final AudioPlayerHandler audioHandler = Platform.isAndroid
      ? await AudioService.init(
          builder: () => AudioPlayerHandler(),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.heardy.app.audio',
            androidNotificationChannelName: 'Heardy Playback',
            androidNotificationOngoing: true,
            androidShowNotificationBadge: true,
            artDownscaleWidth: 300,
            artDownscaleHeight: 300,
          ),
        )
      : AudioPlayerHandler();

  if (Platform.isWindows) {
    taskbarService = DesktopTaskbarService(playback: HandlerTaskbarPlayback(audioHandler));
    await taskbarService!.init();
  }

  if (Platform.isAndroid) {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  final musicProvider = MusicProvider();
  final settingsProvider = SettingsProvider();
  // Firebase Auth (el SDK) no corre en escritorio (Hallazgo 3 del plan de
  // escritorio) — `HeardyAuthProvider.rest()` habla la misma API por HTTP
  // (W5). La cuenta sigue siendo opcional ahí igual que en Android: las
  // únicas pantallas que la leen (Import/Search) ya saben quedarse
  // inactivas sin sesión.
  final authProvider =
      Platform.isAndroid ? HeardyAuthProvider() : HeardyAuthProvider.rest();

  // La fuente lee la configuración por closures, no por copia: cambiar la
  // dirección en Ajustes (o iniciar/cerrar sesión) tiene efecto inmediato,
  // sin reconstruir nada ni reiniciar la app. `authToken` reemplaza la clave
  // de API fija de antes (Fase 2 del plan de seguridad, cierra A1): sin
  // sesión, devuelve null y la llamada sale sin autenticar.
  final serverPool = ServerPool(OfficialServer.urls);
  final DownloadSource downloadSource = YtdlpServerSource(
    baseUrl: () => settingsProvider.downloadServerUrl,
    authToken: () => authProvider.idToken(),
    pool: serverPool,
  );
  final downloadProvider = DownloadProvider(
    service: DownloadService(source: downloadSource),
    source: downloadSource,
    // Así se entera la biblioteca de una descarga nueva sin que
    // DownloadProvider tenga que conocer a MusicProvider.
    onDownloadComplete: (playlistId) async {
      await musicProvider.loadPlaylists();
      await musicProvider.loadSongsForPlaylist(
        playlistId,
        updateCurrent: musicProvider.currentPlaylistId == playlistId,
      );
      await musicProvider.refreshInboxCount();
      musicProvider.notifyLibraryChanged();
    },
  );

  // Misma base/autenticación que el servidor de descargas — una sola
  // instancia del servidor, dos superficies (`DownloadSource`, `CloudSource`).
  final CloudSource cloudSource = HeardyCloudSource(
    baseUrl: () => settingsProvider.downloadServerUrl,
    authToken: () => authProvider.idToken(),
    pool: serverPool,
  );
  final syncProvider = SyncProvider(
    source: cloudSource,
    shareNowPlayingEnabled: () => settingsProvider.shareNowPlaying,
  );
  syncProvider.attachPlayback(audioHandler);
  final notificationsProvider = NotificationsProvider(
    cloudSource: cloudSource,
    language: () => settingsProvider.language,
  );
  final audioEffectsService = AudioEffectsService(audioHandler);

  final StreamResolver streamResolver;
  if (Platform.isWindows) {
    final ytdlpPath = await prepareWindowsYtdlp();
    configureWindowsStreaming(ytdlpPath);
    // -U compite por CPU/red con la primera resolución: se pospone.
    if (ytdlpPath != null) {
      unawaited(Future<void>.delayed(const Duration(minutes: 3), () => maybeUpdateYtdlp(ytdlpPath)));
    }
    streamResolver = CachingStreamResolver(WindowsYtdlpStreamResolver(ytdlpPath ?? ''));
  } else {
    streamResolver = defaultStreamResolver();
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<AudioPlayerHandler>.value(value: audioHandler),
        Provider<ServerPool>.value(value: serverPool),
        Provider<DownloadSource>.value(value: downloadSource),
        Provider<StreamResolver>.value(value: TimeoutStreamResolver(streamResolver)),
        Provider<CloudSource>.value(value: cloudSource),
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: musicProvider),
        ChangeNotifierProvider.value(value: downloadProvider),
        ChangeNotifierProvider.value(value: syncProvider),
        ChangeNotifierProvider.value(value: notificationsProvider),
        ChangeNotifierProvider.value(value: audioEffectsService),
        ChangeNotifierProvider(create: (_) => ExploreProvider(source: downloadSource)),
      ],
      child: const HeardyApp(),
    ),
  );

  // Restaurar estado de reproducción una vez que el primer frame ya se dibujó —
  // condición real (el widget tree y sus Providers ya existen), no un delay
  // arbitrario adivinado. `restorePlaybackState` es idempotente por estado
  // real (ver MusicProvider), así que no depende de correr en un momento exacto.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    musicProvider.restorePlaybackState(audioHandler);
    // Retoma una tanda que quedó a medias porque el proceso murió. La cola
    // vive en SQLite justamente para esto; si está vacía, processQueue sale
    // enseguida sin hacer nada.
    downloadProvider.processQueue();
    // El servidor oficial vive en un PC de casa, no siempre encendido: cada
    // arranque en frío es una oportunidad razonable de comprobar si ya volvió
    // y resolver solo lo que quedó en la lista de espera.
    downloadProvider.retryPendingImports();
    // Nunca `await`ado: un refresco de token de Firebase en el camino de
    // arranque no puede retrasar el primer fotograma ni la restauración de
    // la reproducción. Sin sesión, syncNow() falla con `unauthorized`
    // (capturado dentro del propio provider) y no hace nada más.
    syncProvider.syncNow();
    // Igual que syncNow(): nunca await'ado, y sin sesión simplemente no
    // encuentra solicitudes de amistad (ver NotificationsProvider).
    notificationsProvider.refresh();
  });
}

class HeardyApp extends StatelessWidget {
  const HeardyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        AppTheme.applyPreset(settings.preset);
        AppTheme.applyCustomColors(
          primary: settings.customPrimary,
          secondary: settings.customSecondary,
          combined: settings.customCombined,
        );
        return MaterialApp(
          navigatorKey: desktopRootNavigatorKey,
          title: 'Heardy',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          locale: settings.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          initialRoute: '/',
          onGenerateRoute: RouteGenerator.generateRoute,
          builder: (context, child) => child == null
              ? const SizedBox.shrink()
              : _DesktopPlaybackShortcuts(child: _DesktopWindowChrome(child: child)),
        );
      },
    );
  }
}

class RouteGenerator {
  static Route<dynamic> generateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case '/':
        return MaterialPageRoute(builder: (_) => const LegalGate(child: MainShellScreen()));
      case '/playlist':
        if (args is String) {
          return MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: args),
          );
        }
        return _errorRoute('ID de lista inválido');
      default:
        return _errorRoute('Ruta no encontrada');
    }
  }

  static Route<dynamic> _errorRoute(String message) {
    return MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Center(
          child: Text(
            message,
            style: const TextStyle(fontSize: 16, color: Colors.redAccent),
          ),
        ),
      ),
    );
  }
}

/// Atajos de teclado de escritorio (W3 del plan de escritorio): espacio =
/// pausa/reproduce, flechas izquierda/derecha = retroceder/adelantar 10s,
/// flechas arriba/abajo = volumen. Sólo si no hay un
/// campo de texto con foco — si no, escribir un espacio en el buscador o al
/// renombrar una playlist activaría play/pause en vez de escribir.
/// `desktopShortcutFor` (services/desktop_shortcuts.dart) es la única parte
/// realmente probada; esto es sólo el cableado.
class _DesktopPlaybackShortcuts extends StatelessWidget {
  final Widget child;
  const _DesktopPlaybackShortcuts({required this.child});

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final focusedContext = FocusManager.instance.primaryFocus?.context;
        if (focusedContext != null && focusedContext.findAncestorWidgetOfExactType<EditableText>() != null) {
          return KeyEventResult.ignored;
        }
        final audioHandler = Provider.of<AudioPlayerHandler>(context, listen: false);
        switch (desktopShortcutFor(event.logicalKey)) {
          case DesktopPlaybackShortcut.playPause:
            audioHandler.playbackState.value.playing ? audioHandler.pause() : audioHandler.play();
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.seekBack:
            audioHandler.seekRelative(const Duration(seconds: -10));
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.seekForward:
            audioHandler.seekRelative(const Duration(seconds: 10));
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.volumeUp:
            audioHandler.setVolume(steppedVolume(audioHandler.volume.value, up: true));
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.volumeDown:
            audioHandler.setVolume(steppedVolume(audioHandler.volume.value, up: false));
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.mediaPlayPause:
          case DesktopPlaybackShortcut.next:
          case DesktopPlaybackShortcut.previous:
            if (!shouldHandleMediaKeyInApp(taskbarService?.nativeHotkeysActive ?? false)) {
              return KeyEventResult.ignored;
            }
            final s = desktopShortcutFor(event.logicalKey);
            if (s == DesktopPlaybackShortcut.next) {
              audioHandler.skipToNext();
            } else if (s == DesktopPlaybackShortcut.previous) {
              audioHandler.skipToPrevious();
            } else {
              audioHandler.playbackState.value.playing ? audioHandler.pause() : audioHandler.play();
            }
            return KeyEventResult.handled;
          case DesktopPlaybackShortcut.none:
            return KeyEventResult.ignored;
        }
      },
      child: child,
    );
  }
}

/// En escritorio, la barra de título propia va por encima de TODO el
/// `Navigator` raíz: así también queda arriba en las pantallas que se abren
/// a pantalla completa fuera del shell (login, ajustes, restaurar desde la
/// cuenta, perfil de un amigo…), que si no dejarían la ventana sin forma de
/// moverse o cerrarse. El `MediaQuery` se recorta a la altura que de verdad
/// queda debajo, para que nada calcule con los 40 px que ya no tiene. En
/// Android devuelve el hijo tal cual.
class _DesktopWindowChrome extends StatelessWidget {
  final Widget child;
  const _DesktopWindowChrome({required this.child});

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    final mq = MediaQuery.of(context);
    final height = (mq.size.height - desktopTitleBarHeight).clamp(0.0, double.infinity);
    return Column(
      children: [
        const DesktopTitleBar(),
        Expanded(
          child: MediaQuery(
            data: mq.copyWith(size: Size(mq.size.width, height)),
            child: child,
          ),
        ),
      ],
    );
  }
}
