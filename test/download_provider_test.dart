// Verifica la cola persistente: el orquestador, no el "cómo" de la descarga
// (eso es download_service_test.dart).
//
// Lo que más importa aquí es la política de reintentos, porque decide qué se
// hace con el recurso escaso de todo el sistema: el presupuesto de peticiones
// por IP frente a YouTube. Gastar tres intentos en un vídeo borrado retrasa
// las canciones que sí se pueden bajar; descartar a la primera una canción
// buena por un corte de red de un segundo la pierde.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/models/song.dart';
import 'package:heardy/providers/download_provider.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/download_service.dart';
import 'package:heardy/services/download_source.dart';

/// DownloadService falso: registra qué se le pidió y con qué flags, y devuelve
/// lo que el test le diga. No toca ni red ni SAF.
class _FakeDownloadService implements DownloadService {
  _FakeDownloadService();

  /// Una entrada por llamada a download().
  final List<({RemoteTrack track, String? playlistId, bool resolveFirst})> calls = [];

  /// Errores del paso de /resolve, uno por llamada, en orden. Separado de
  /// [downloadErrors] a propósito: "el resolve falla" y "el resolve va bien
  /// pero falla la descarga" son casos distintos y el segundo es el que
  /// prueba que la metadata resuelta se persiste antes de bajar nada.
  final List<DownloadSourceException?> resolveErrors = [];

  /// Errores del paso de descarga, uno por llamada, en orden.
  final List<DownloadSourceException?> downloadErrors = [];

  /// Metadata que devuelve el /resolve simulado, por id de pista.
  final Map<String, RemoteTrack> resolveResults = {};

  int _callIndex = 0;

  DownloadSourceException? _at(List<DownloadSourceException?> list, int i) =>
      i < list.length ? list[i] : null;

  @override
  Future<DownloadResult> download(
    RemoteTrack track, {
    String? playlistId,
    bool resolveFirst = false,
    Future<void> Function(RemoteTrack resolved)? onResolved,
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    calls.add((track: track, playlistId: playlistId, resolveFirst: resolveFirst));

    final callIndex = _callIndex++;

    var effective = track;
    if (resolveFirst) {
      // El resolve va primero: si falla, no se baja nada. Es la garantía de
      // que nunca se escriben tags a partir de metadata plana.
      final resolveError = _at(resolveErrors, callIndex);
      if (resolveError != null) throw resolveError;
      effective = resolveResults[track.id] ?? track;
      await onResolved?.call(effective);
    }

    final downloadError = _at(downloadErrors, callIndex);
    if (downloadError != null) throw downloadError;

    onProgress?.call(100, 100);

    final song = Song(
      id: 'hash-${effective.id}',
      title: effective.title,
      artist: effective.artist,
      duration: effective.durationSeconds,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime.now(),
      uri: 'fake://descargada/${effective.id}',
      fileHash: 'hash-${effective.id}',
      hashKind: 'mp4-mdat',
      fileSize: 1000,
      modifiedAt: 1,
      sourceUrl: effective.sourceUrl,
    );
    return DownloadResult(DownloadOutcome.inserted, song, effective);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// DownloadSource falso, sólo para lo que necesita [DownloadProvider] fuera
/// de [_FakeDownloadService]: resolver una URL de la lista de espera.
class _FakeDownloadSource implements DownloadSource {

  RemoteTrack? nextTrack;
  RemotePlaylist? nextPlaylist;
  DownloadSourceException? resolveError;
  final List<String> resolvedUrls = [];

  /// Resultados que devuelve [search], para probar el fallback de
  /// [DownloadProvider._tryFallbackSearch].
  List<RemoteTrack> searchResults = [];
  final List<String> searchQueries = [];

  @override
  Future<RemoteTrack> resolve(String url) async {
    resolvedUrls.add(url);
    if (resolveError != null) throw resolveError!;
    return nextTrack ?? _track('resuelto-de-espera');
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) async {
    resolvedUrls.add(url);
    if (resolveError != null) throw resolveError!;
    return nextPlaylist!;
  }

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    searchQueries.add(query);
    return searchResults;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RemoteTrack _track(String id, {String title = 'Título', String artist = 'Artista'}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: null,
    durationSeconds: 100,
    thumbnailUrl: '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

void main() {
  late DatabaseHelper db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbDir = Directory.systemTemp.createTempSync('heardy_queue_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));
    db = DatabaseHelper.instance;
  });

  setUp(() async {
    await db.clearDownloadQueue();
    await db.clearPendingImports();
  });

  Future<String> newPlaylist(String name) async {
    final id = const Uuid().v4();
    await db.insertPlaylist(Playlist(id: id, name: name, creationDate: DateTime.now()));
    return id;
  }

  DownloadProvider providerFor(
    _FakeDownloadService service, {
    List<String>? completed,
    DownloadSource? source,
    int? maxFreeReschedules,
    int? maxNetworkReschedules,
  }) {
    final provider = DownloadProvider(
      service: service,
      source: source ?? _FakeDownloadSource(),
      db: db,
      maxFreeReschedules: maxFreeReschedules ?? 40,
      maxNetworkReschedules: maxNetworkReschedules ?? 240,
      onDownloadComplete: (playlistId) async => completed?.add(playlistId),
    );
    // Sin esto, el temporizador de backoff de un trabajo fallido dispararía
    // otra pasada después de que el test terminara, contra una base que ya
    // no le corresponde.
    addTearDown(provider.dispose);
    return provider;
  }

  group('regla del /resolve', () {
    test('un trabajo con metadata plana se resuelve; uno ya resuelto no gasta la petición', () async {
      final service = _FakeDownloadService();
      final playlistId = await newPlaylist('Mezcla');
      final provider = providerFor(service);

      // De /search o de una playlist: artista = nombre del canal.
      await provider.enqueueTrack(
        _track('plano1', artist: 'Canal De Recopilaciones'),
        playlistId: playlistId,
        metadataComplete: false,
      );
      // De /resolve, en la vista previa de una URL suelta.
      await provider.enqueueTrack(
        _track('resuelto1', artist: 'Artista Real'),
        playlistId: playlistId,
        metadataComplete: true,
      );

      await provider.processQueue();

      expect(service.calls.length, 2);
      final plano = service.calls.firstWhere((c) => c.track.id == 'plano1');
      final resuelto = service.calls.firstWhere((c) => c.track.id == 'resuelto1');
      expect(plano.resolveFirst, isTrue, reason: 'metadata plana debe resolverse antes de bajar');
      expect(resuelto.resolveFirst, isFalse,
          reason: 'repetir el /resolve de una URL ya resuelta gasta presupuesto de IP para nada');
    });

    test('la metadata resuelta se persiste, así que un reintento no vuelve a resolver', () async {
      final service = _FakeDownloadService()
        ..resolveResults['plano2'] = _track('plano2', title: 'Título Real', artist: 'Artista Real')
        // El resolve va bien y la descarga falla, en la misma llamada: el
        // siguiente intento debe arrancar ya con la metadata definitiva.
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.extraction, 'IP bloqueada'),
        );
      final playlistId = await newPlaylist('Reintento');
      final provider = providerFor(service);

      await provider.enqueueTrack(
        _track('plano2', title: 'Nombre del canal', artist: 'Canal'),
        playlistId: playlistId,
        metadataComplete: false,
      );

      // Una pasada = un intento: el backoff deja el trabajo para la siguiente.
      await provider.processQueue();

      final rows = await db.getDownloadQueue();
      expect(rows.length, 1, reason: 'un error de extracción es reintentable, sigue en la cola');
      expect(rows.first['metadataComplete'], 1);
      expect(rows.first['title'], 'Título Real');
      expect(rows.first['artist'], 'Artista Real');
      expect(rows.first['attempts'], 1);
    });

    test('si el /resolve falla no se descarga con metadata plana como respaldo', () async {
      final service = _FakeDownloadService()
        ..resolveErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.network, 'sin red'),
        );
      final playlistId = await newPlaylist('SinRed');
      final provider = providerFor(service);

      await provider.enqueueTrack(
        _track('plano3', artist: 'Canal'),
        playlistId: playlistId,
        metadataComplete: false,
      );
      await provider.processQueue();

      // El fake lanza antes de llamar a onResolved, o sea antes de bajar nada.
      final rows = await db.getDownloadQueue();
      expect(rows.first['metadataComplete'], 0,
          reason: 'sin resolve con éxito, el trabajo sigue sin metadata definitiva');
      expect(await db.getSongs(), isEmpty);
    });
  });

  group('política de reintentos', () {
    test('un error definitivo sale de la cola al primer intento, sin gastar reintentos', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.notFound, 'Video unavailable'),
        );
      final playlistId = await newPlaylist('Borrados');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('borrado'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      expect(await db.getDownloadQueue(), isEmpty);
      expect(service.calls.length, 1, reason: 'no debe reintentarse un vídeo que ya no existe');
      expect(provider.failures.single.permanent, isTrue);
      expect(provider.failures.single.message, contains('no se puede descargar'));
    });

    test('un vídeo sin pista AAC tampoco se reintenta', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, 'sin AAC'),
        );
      final playlistId = await newPlaylist('SinAac');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('sinaac'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      expect(await db.getDownloadQueue(), isEmpty);
      expect(service.calls.length, 1);
      expect(provider.failures.single.permanent, isTrue);
    });

    test('un error temporal deja el trabajo en la cola y cuenta un intento', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.extraction, 'IP bloqueada'),
        );
      final playlistId = await newPlaylist('Temporal');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('temp'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      final rows = await db.getDownloadQueue();
      expect(rows.length, 1, reason: 'reintentable: no se descarta');
      expect(rows.first['attempts'], 1);
      expect(rows.first['lastError'], 'IP bloqueada');
      expect(provider.failures, isEmpty, reason: 'todavía le quedan intentos');
    });

    test('el contador de intentos vive en la base: reiniciar la app no regala presupuesto', () async {
      final playlistId = await newPlaylist('Presupuesto');

      // Dos fallos temporales en dos "arranques" distintos del provider.
      for (var i = 0; i < 2; i++) {
        final service = _FakeDownloadService()
          ..downloadErrors.add(
            const DownloadSourceException(DownloadSourceErrorKind.extraction, 'IP bloqueada'),
          );
        final provider = providerFor(service);
        if (i == 0) {
          await provider.enqueueTrack(_track('persistente'),
              playlistId: playlistId, metadataComplete: true);
        }
        await provider.processQueue();
      }

      expect((await db.getDownloadQueue()).first['attempts'], 2,
          reason: 'los intentos se acumulan entre arranques, no se reinician');

      // Tercer arranque: se agota el presupuesto y el trabajo se descarta.
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.extraction, 'IP bloqueada'),
        );
      final provider = providerFor(service);
      await provider.processQueue();

      expect(await db.getDownloadQueue(), isEmpty);
      expect(provider.failures.single.permanent, isFalse,
          reason: 'se agotaron los reintentos, pero el vídeo no es imposible');
    });
  });

  group('fallback por búsqueda cuando un vídeo está bloqueado', () {
    // Motivado por un caso medido: YouTube bloquea a nivel de contenido los
    // tracks de canales "- Topic" (audio oficial con licencia) para
    // cualquier cliente de reproducción programático — 36 de 37 en una
    // playlist real, 0 de 31 "Music Clip" del mismo canal. Reintentar el
    // MISMO vídeo nunca lo arregla; lo único que funciona es bajar uno
    // distinto, casi siempre presente en la propia playlist.
    test('sin reintentos disponibles (404) pero con reemplazo de duración parecida: sustituye en vez de descartar',
        () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.notFound, 'Video unavailable'),
        );
      final source = _FakeDownloadSource()
        ..searchResults = [_track('reemplazo', title: 'Título', artist: 'Canal Oficial')];
      final playlistId = await newPlaylist('Bloqueados');
      final provider = providerFor(service, source: source);

      await provider.enqueueTrack(
        _track('bloqueada', title: 'Título', artist: 'Artista'),
        playlistId: playlistId,
        metadataComplete: true,
      );
      await provider.processQueue();

      expect(service.calls.length, 2, reason: 'un intento con el original, otro con el reemplazo');
      expect(service.calls[1].track.id, 'reemplazo');
      expect(source.searchQueries, ['Artista Título']);
      expect(await db.getDownloadQueue(), isEmpty, reason: 'el reemplazo se descargó, no quedó pendiente');
      expect(provider.failures, isEmpty, reason: 'el fallback tuvo éxito, no es un fallo');
    });

    test('sin ningún candidato de duración parecida: se descarta como antes, sin reemplazo forzado', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.notFound, 'Video unavailable'),
        );
      final source = _FakeDownloadSource()
        // 400s de diferencia con el original (100s) — muy por encima de los
        // 30s de tolerancia: podría ser un cover, un remix, un directo.
        ..searchResults = [
          RemoteTrack(
            id: 'parecido-pero-no',
            title: 'Título',
            artist: 'Canal',
            album: null,
            durationSeconds: 500,
            thumbnailUrl: '',
            sourceUrl: 'https://www.youtube.com/watch?v=parecido-pero-no',
          ),
        ];
      final playlistId = await newPlaylist('SinReemplazo');
      final provider = providerFor(service, source: source);

      await provider.enqueueTrack(
        _track('bloqueada2', title: 'Título', artist: 'Artista'),
        playlistId: playlistId,
        metadataComplete: true,
      );
      await provider.processQueue();

      expect(await db.getDownloadQueue(), isEmpty);
      expect(service.calls.length, 1, reason: 'nunca se llegó a intentar el candidato malo');
      expect(provider.failures.single.permanent, isTrue);
    });

    test('si el reemplazo también falla, no se encadena una segunda búsqueda', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.notFound, 'Video unavailable'),
        )
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.notFound, 'Video unavailable'),
        );
      final source = _FakeDownloadSource()
        ..searchResults = [_track('tambien-bloqueado', title: 'Título', artist: 'Canal')];
      final playlistId = await newPlaylist('DobleBloqueo');
      final provider = providerFor(service, source: source);

      await provider.enqueueTrack(
        _track('bloqueada3', title: 'Título', artist: 'Artista'),
        playlistId: playlistId,
        metadataComplete: true,
      );
      await provider.processQueue();

      expect(service.calls.length, 2, reason: 'original + un reemplazo, nunca un segundo reemplazo');
      expect(source.searchQueries.length, 1, reason: 'la búsqueda de fallback sólo se intenta una vez por trabajo');
      expect(await db.getDownloadQueue(), isEmpty);
      expect(provider.failures.single.permanent, isTrue);
    });
  });

  group('servidor apagado (error de red)', () {
    test('un error de red no cuenta como intento y se reintenta indefinidamente', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.network, 'no se pudo contactar'),
        );
      final playlistId = await newPlaylist('ServidorApagado');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('pc-apagada'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      final rows = await db.getDownloadQueue();
      expect(rows.length, 1, reason: 'el trabajo nunca se descarta porque el servidor no respondió');
      expect(rows.first['attempts'], 0,
          reason: 'un servidor apagado no es un fallo del trabajo: no debe gastar el presupuesto de reintentos');
      expect(provider.failures.single.permanent, isFalse);
      expect(provider.failures.single.retryAfterSeconds, isNotNull);
    });
  });

  group('muro anti-bot (503)', () {
    test('un bloqueo del muro no cuenta como intento y se reintenta con espera larga, no el backoff corto', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, "Sign in to confirm you're not a bot"),
        );
      final playlistId = await newPlaylist('MuroAntibot');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('bloqueada'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      final rows = await db.getDownloadQueue();
      expect(rows.length, 1, reason: 'el muro anti-bot no descarta la canción, sólo hay que esperar más');
      expect(rows.first['attempts'], 0,
          reason: 'igual que quotaExceeded/network, no es un fallo del trabajo: no gasta presupuesto de reintentos');
      expect(provider.failures.single.permanent, isFalse);
      expect(provider.failures.single.retryAfterSeconds, 1800,
          reason: 'espera fija de 30 min, no el backoff de 5/15/45s pensado para un 502 cualquiera');
      expect(provider.failures.single.message, contains('20 y 40 minutos'));

      // Una segunda pasada inmediata no debe reintentar: sigue dentro de la
      // ventana de 30 minutos.
      await provider.processQueue();
      expect(service.calls.length, 1);
    });
  });

  group('lista de espera', () {
    test('una URL guardada se resuelve, se encola y se descarga en cuanto el servidor responde', () async {
      final playlistId = await newPlaylist('Espera');
      final source = _FakeDownloadSource()..nextTrack = _track('resuelta');
      final service = _FakeDownloadService();
      final provider = providerFor(service, source: source);

      final added = await provider.addPendingImport(
        sourceUrl: 'https://youtu.be/resuelta',
        playlistId: playlistId,
        isPlaylist: false,
      );
      expect(added, isTrue);
      expect(provider.pendingImports, hasLength(1));

      // retryPendingImports() resuelve, encola Y procesa la cola de punta a
      // punta — por eso, con el fake de descarga en su modo por defecto (sin
      // errores configurados), la cola termina vacía: el trabajo no se quedó
      // esperando, se completó.
      await provider.retryPendingImports();

      expect(provider.pendingImports, isEmpty, reason: 'ya se resolvió, no debe quedar en espera');
      expect(await db.getDownloadQueue(), isEmpty, reason: 'la descarga se completó, no quedó pendiente');
      expect(service.calls.single.track.id, 'resuelta');
      expect(service.calls.single.resolveFirst, isFalse,
          reason: '/resolve ya dio la metadata definitiva, no hace falta repetirlo (DD6)');
    });

    test('si el servidor sigue sin responder, la URL se queda en la lista de espera', () async {
      final playlistId = await newPlaylist('SigueApagado');
      final source = _FakeDownloadSource()
        ..resolveError = const DownloadSourceException(DownloadSourceErrorKind.network, 'sigue apagado');
      final provider = providerFor(_FakeDownloadService(), source: source);

      await provider.addPendingImport(
        sourceUrl: 'https://youtu.be/todavia-no',
        playlistId: playlistId,
        isPlaylist: false,
      );
      await provider.retryPendingImports();

      expect(provider.pendingImports, hasLength(1), reason: 'sigue sin poder resolverse, no se descarta');
      expect(await db.getDownloadQueue(), isEmpty);
    });

    test('un fallo definitivo (no de red) se descarta de la lista de espera', () async {
      final playlistId = await newPlaylist('UrlRota');
      final source = _FakeDownloadSource()
        ..resolveError = const DownloadSourceException(DownloadSourceErrorKind.notFound, 'ya no existe');
      final provider = providerFor(_FakeDownloadService(), source: source);

      await provider.addPendingImport(
        sourceUrl: 'https://youtu.be/borrado-hace-rato',
        playlistId: playlistId,
        isPlaylist: false,
      );
      await provider.retryPendingImports();

      expect(provider.pendingImports, isEmpty,
          reason: 'un 404 no se arregla con que el servidor vuelva: no tiene sentido dejarlo esperando para siempre');
      expect(provider.failures.single.permanent, isTrue);
    });
  });

  group('cuota del servidor (429)', () {
    test('un aviso de cuota no cuenta como intento y no descarta el trabajo', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(
            DownloadSourceErrorKind.quotaExceeded,
            'límite alcanzado (per-key)',
            retryAfterSeconds: 60,
          ),
        );
      final playlistId = await newPlaylist('Cuota');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('con-cuota'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      final rows = await db.getDownloadQueue();
      expect(rows.length, 1, reason: 'el trabajo nunca se descarta por una cuota');
      expect(rows.first['attempts'], 0,
          reason: 'la cuota no es un fallo del trabajo, no debe gastar presupuesto de reintentos');
      expect(provider.failures.single.permanent, isFalse);
      expect(provider.failures.single.retryAfterSeconds, 60);
      expect(provider.failures.single.message, contains('minuto'));
    });

    test('reprograma exactamente al retryAfterSeconds del servidor, no a la tabla de backoff fija', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(
            DownloadSourceErrorKind.quotaExceeded,
            'límite alcanzado',
            retryAfterSeconds: 3600, // fuera del rango de _backoff (5/15/45s)
          ),
        );
      final playlistId = await newPlaylist('CuotaLarga');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('cuota-larga'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      // No hay forma directa de leer _retryAfter desde fuera, pero se puede
      // observar por su efecto: una segunda pasada inmediata no debe volver
      // a intentar el trabajo (seguiría esperando su hora).
      await provider.processQueue();
      expect(service.calls.length, 1, reason: 'todavía dentro de la ventana de espera de una hora');
    });

    test('sin Retry-After del servidor, usa un valor por defecto en vez de reventar', () async {
      final service = _FakeDownloadService()
        ..downloadErrors.add(
          const DownloadSourceException(DownloadSourceErrorKind.quotaExceeded, 'límite alcanzado'),
        );
      final playlistId = await newPlaylist('CuotaSinHeader');
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('sin-header'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      expect(await db.getDownloadQueue(), hasLength(1));
      expect(provider.failures.single.retryAfterSeconds, isNotNull);
    });
  });

  group('cola', () {
    test('sobrevive al cierre de la app: un provider nuevo retoma lo pendiente', () async {
      final playlistId = await newPlaylist('Persistente');

      // "Sesión 1": encola tres y se muere sin procesar.
      final primero = providerFor(_FakeDownloadService());
      for (final id in ['a', 'b', 'c']) {
        await primero.enqueueTrack(_track(id), playlistId: playlistId, metadataComplete: true);
      }
      expect(primero.pendingCount, 3);

      // "Sesión 2": provider nuevo, misma base.
      final service = _FakeDownloadService();
      final segundo = providerFor(service);
      await segundo.refreshQueue();
      expect(segundo.pendingCount, 3, reason: 'la cola vive en SQLite, no en memoria');

      await segundo.processQueue();
      expect(service.calls.map((c) => c.track.id), ['a', 'b', 'c']);
      expect(await db.getDownloadQueue(), isEmpty);
    });

    test('encolar una playlist preserva el orden y marca todo como metadata plana', () async {
      final playlistId = await newPlaylist('DesdeYouTube');
      final provider = providerFor(_FakeDownloadService());

      final playlist = RemotePlaylist(
        id: 'PL1',
        name: 'Mi lista',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: [_track('p1'), _track('p2'), _track('p3')],
      );
      final added = await provider.enqueuePlaylist(playlist, playlistId: playlistId);

      expect(added, 3);
      final rows = await db.getDownloadQueue();
      expect(rows.map((r) => r['expectedOrderIndex']), [0, 1, 2]);
      expect(rows.every((r) => r['metadataComplete'] == 0), isTrue,
          reason: 'extract_flat nunca da metadata definitiva');
    });

    test('encolar dos veces lo mismo en la misma playlist no duplica; en otra sí', () async {
      final primera = await newPlaylist('Primera');
      final segunda = await newPlaylist('Segunda');
      final provider = providerFor(_FakeDownloadService());

      expect(await provider.enqueueTrack(_track('dup'), playlistId: primera, metadataComplete: true),
          isTrue);
      expect(await provider.enqueueTrack(_track('dup'), playlistId: primera, metadataComplete: true),
          isFalse, reason: 'el índice único dedupe en la propia base');
      expect(await provider.enqueueTrack(_track('dup'), playlistId: segunda, metadataComplete: true),
          isTrue, reason: 'la misma canción en dos playlists es legítimo');

      expect((await db.getDownloadQueue()).length, 2);
    });

    test('cancelar vacía la cola y para el bucle', () async {
      final playlistId = await newPlaylist('Cancelada');
      final provider = providerFor(_FakeDownloadService());
      for (final id in ['x', 'y', 'z']) {
        await provider.enqueueTrack(_track(id), playlistId: playlistId, metadataComplete: true);
      }

      await provider.cancelAll();

      expect(await db.getDownloadQueue(), isEmpty);
      expect(provider.pendingCount, 0);
      expect(provider.isProcessing, isFalse);
    });

    test('si la playlist destino se borró, el trabajo se descarta sin llevarse la tanda', () async {
      final viva = await newPlaylist('Viva');
      final condenada = await newPlaylist('Condenada');
      final service = _FakeDownloadService();
      final provider = providerFor(service);

      await provider.enqueueTrack(_track('huerfana'),
          playlistId: condenada, metadataComplete: true);
      await provider.enqueueTrack(_track('superviviente'),
          playlistId: viva, metadataComplete: true);

      // El usuario borra una playlist con la tanda a medias. La cola no tiene
      // FK a propósito, para que esto no se lleve el trabajo por cascada.
      await db.deletePlaylist(condenada);

      await provider.processQueue();

      expect(service.calls.map((c) => c.track.id), ['superviviente'],
          reason: 'el huérfano se descarta, el otro se descarga igual');
      expect(await db.getDownloadQueue(), isEmpty);
      expect(provider.failures.single.permanent, isTrue);
      expect(provider.failures.single.message, contains('playlist'));
    });

    test('avisa a la biblioteca una vez por descarga con éxito', () async {
      final playlistId = await newPlaylist('Avisos');
      final completed = <String>[];
      final service = _FakeDownloadService();
      final provider = providerFor(service, completed: completed);

      await provider.enqueueTrack(_track('n1'), playlistId: playlistId, metadataComplete: true);
      await provider.enqueueTrack(_track('n2'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();

      expect(completed, [playlistId, playlistId]);
    });

    test('processQueue es seguro llamándolo de más', () async {
      final playlistId = await newPlaylist('Reentrante');
      final service = _FakeDownloadService();
      final provider = providerFor(service);
      await provider.enqueueTrack(_track('unico'), playlistId: playlistId, metadataComplete: true);

      await Future.wait([provider.processQueue(), provider.processQueue()]);

      expect(service.calls.length, 1, reason: 'un solo bucle, una sola descarga');
    });
  });

  group('tope de reprogramaciones acumuladas', () {
    Future<DownloadProvider> failingOnce(
      DownloadSourceException error, {
      int free = 40,
      int network = 240,
    }) async {
      final service = _FakeDownloadService()..downloadErrors.add(error);
      final playlistId = await newPlaylist('Tope');
      final provider = providerFor(
        service,
        maxFreeReschedules: free,
        maxNetworkReschedules: network,
      );
      await provider.enqueueTrack(_track('tope'), playlistId: playlistId, metadataComplete: true);
      await provider.processQueue();
      return provider;
    }

    test('dentro del tope el trabajo se reprograma y se conserva', () async {
      await failingOnce(
        const DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, 'x'),
        free: 1,
      );
      expect(await db.getDownloadQueue(), hasLength(1));
    });

    test('superado el tope, anti-bot pasa a fallido y sale de la cola', () async {
      final provider = await failingOnce(
        const DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, 'x'),
        free: 0,
      );
      expect(await db.getDownloadQueue(), isEmpty);
      expect(provider.failures.single.retryAfterSeconds, isNull);
    });

    test('superado el tope, la red caída también pasa a fallido', () async {
      await failingOnce(
        const DownloadSourceException(DownloadSourceErrorKind.network, 'x'),
        network: 0,
      );
      expect(await db.getDownloadQueue(), isEmpty);
    });

    test('el cupo diario nunca se descarta por el tope: espera al día siguiente', () async {
      final provider = await failingOnce(
        const DownloadSourceException(
          DownloadSourceErrorKind.dailyQuotaExceeded,
          'x',
          retryAfterSeconds: 7200,
        ),
        free: 0,
        network: 0,
      );
      expect(await db.getDownloadQueue(), hasLength(1));
      expect(provider.failures.single.retryAfterSeconds, 7200);
    });
  });

  group('tope de batch de playlists', () {
    test('exceedsPlaylistBatch solo por encima de 150', () {
      expect(maxPlaylistBatch, 150);
      expect(exceedsPlaylistBatch(150), isFalse);
      expect(exceedsPlaylistBatch(151), isTrue);
    });

    test('enqueuePlaylist encola como máximo maxPlaylistBatch pistas', () async {
      final playlistId = await newPlaylist('Enorme');
      final provider = providerFor(_FakeDownloadService());
      final entries = [
        for (var i = 0; i < maxPlaylistBatch + 20; i++) _track('e$i'),
      ];
      final added = await provider.enqueuePlaylist(
        RemotePlaylist(id: 'pl', name: 'Enorme', sourceUrl: '', entries: entries),
        playlistId: playlistId,
      );
      expect(added, maxPlaylistBatch);
    });
  });
}
