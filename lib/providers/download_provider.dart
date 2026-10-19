import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/database_helper.dart';
import '../services/download_foreground_service.dart';
import '../services/download_service.dart';
import '../services/download_source.dart';
import '../services/spotify_match.dart' show maxMatchToleranceSeconds, pickClosestByDuration;

/// Destino centinela de `download_queue.playlistId` para canciones sueltas:
/// no es una playlist, el worker las descarga sin playlist y caen en la
/// Bandeja. Evita cambiar el esquema (la columna es NOT NULL).
const String inboxDownloadTarget = '__inbox__';

/// Un trabajo pendiente, tal como lo ve la UI.
class DownloadJob {
  final int queueId;
  final String sourceType;
  final String sourceId;
  final String sourceUrl;
  final String playlistId;
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String thumbnailUrl;
  final int? expectedOrderIndex;
  final int attempts;

  /// False mientras la metadata venga de `extract_flat` (búsqueda o expansión
  /// de playlist), donde `artist` es en realidad el nombre del canal.
  final bool metadataComplete;

  const DownloadJob({
    required this.queueId,
    required this.sourceType,
    required this.sourceId,
    required this.sourceUrl,
    required this.playlistId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.thumbnailUrl,
    required this.expectedOrderIndex,
    required this.attempts,
    required this.metadataComplete,
  });

  factory DownloadJob.fromRow(Map<String, dynamic> row) {
    final id = (row['sourceId'] ?? '').toString();
    return DownloadJob(
      queueId: row['id'] as int,
      sourceType: (row['sourceType'] ?? 'youtube').toString(),
      sourceId: id,
      sourceUrl: (row['sourceUrl'] ?? '').toString(),
      playlistId: (row['playlistId'] ?? '').toString(),
      title: (row['title'] ?? '').toString(),
      artist: (row['artist'] ?? '').toString(),
      album: row['album'] as String?,
      durationSeconds: (row['durationSeconds'] as int?) ?? 0,
      thumbnailUrl: (row['thumbnailUrl'] ?? '').toString(),
      expectedOrderIndex: row['expectedOrderIndex'] as int?,
      attempts: (row['attempts'] as int?) ?? 0,
      metadataComplete: ((row['metadataComplete'] as int?) ?? 0) != 0,
    );
  }

  RemoteTrack toRemoteTrack() => RemoteTrack(
        id: sourceId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
        thumbnailUrl: thumbnailUrl,
        sourceUrl: sourceUrl,
      );

  String get displayTitle => title.isEmpty ? sourceId : title;
}

/// Una URL pegada cuando el servidor ni siquiera respondió al /resolve
/// inicial — no hay título ni id todavía, sólo lo que el usuario pegó y a qué
/// playlist lo quería mandar. Se reintenta sola (ver [DownloadProvider.
/// retryPendingImports]) cuando el servidor vuelve a estar disponible.
class PendingImport {
  final int id;
  final bool isPlaylist;
  final String sourceUrl;
  final String playlistId;

  const PendingImport({
    required this.id,
    required this.isPlaylist,
    required this.sourceUrl,
    required this.playlistId,
  });

  factory PendingImport.fromRow(Map<String, dynamic> row) => PendingImport(
        id: row['id'] as int,
        isPlaylist: (row['kind'] ?? 'video') == 'playlist',
        sourceUrl: (row['sourceUrl'] ?? '').toString(),
        playlistId: (row['playlistId'] ?? '').toString(),
      );
}

/// Un trabajo que se dio por perdido, para que la UI pueda contarlo. También
/// se usa para avisar de una espera (ver [retryAfterSeconds]),
/// donde el trabajo NO se pierde — sigue en la cola y se reintentará solo.
class DownloadFailure {
  final String title;
  final String message;

  /// Error original cuando el fallo viene de la fuente de descargas: la UI lo
  /// usa para redactar el mensaje en el idioma elegido en vez de [message].
  final DownloadSourceException? error;

  /// True si el vídeo no va a poder descargarse nunca (borrado, privado, sin
  /// pista AAC). False si simplemente se agotaron los reintentos, o si es un
  /// aviso de espera ([retryAfterSeconds] no nulo) — en ese caso el trabajo
  /// sigue en la cola, no se descartó nada.
  final bool permanent;

  /// No nulo solo para los avisos de espera (red caída, muro anti-bot):
  /// cuántos segundos exactos va a esperar el trabajo antes de reintentar
  /// solo. Distingue "estamos esperando nuestro turno" (esto) de "se rindió"
  /// (permanent) o "se agotaron los reintentos" (ninguno de los dos).
  final int? retryAfterSeconds;

  /// Código corto para reportar (`E-DL-503`); la UI lo enseña bajo [message].
  final String? code;

  final DateTime at;

  const DownloadFailure({
    required this.title,
    required this.message,
    this.error,
    this.code,
    required this.permanent,
    this.retryAfterSeconds,
    required this.at,
  });
}

/// En qué está el trabajo actual. La UI lo necesita porque `/audio` bloquea
/// mientras el servidor baja el vídeo: durante esos segundos no hay progreso
/// por bytes que enseñar, y una barra parada parece un cuelgue.
enum DownloadPhase { idle, resolving, preparing, downloading, saving }

/// Orquesta la cola persistente de descargas.
///
/// **Decide qué descargar y cuándo; el cómo es de [DownloadService].** No
/// conoce el servidor ni HTTP: todo pasa por [DownloadSource]. Cambiar de
/// proveedor no debería obligar a tocar este archivo.
class DownloadProvider extends ChangeNotifier {
  /// Presupuesto duro por trabajo. Vive en la base (`download_queue.attempts`)
  /// y no en memoria, para que reiniciar la app no lo regale.
  static const int maxAttempts = 3;

  /// Uno solo, deliberadamente. El muro de YouTube es un presupuesto
  /// acumulado por IP, no un límite de tasa: la concurrencia lo gasta más
  /// rápido sin dar throughput real. Ver docs/investigacion_muro_antibot.md.
  static const int maxConcurrent = 1;

  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  /// Cuánto esperar antes de reintentar un trabajo que falló por
  /// [DownloadSourceErrorKind.network] (el servidor no respondió en
  /// absoluto). El servidor oficial ahora vive en un PC de casa que no
  /// siempre está prendido (ver CLAUDE.md, sección "YouTube downloads" →
  /// Etapa 10), así que a diferencia de [_backoff] (pensado para un corte de
  /// red de segundos) esto no cuenta contra `maxAttempts`: el trabajo espera
  /// indefinidamente, igual que uno que espera una cuota.
  static const int _networkRetryWaitSeconds = 60;

  /// Si la próxima pasada programada está más cerca que esto, el foreground
  /// service (ver [_updateForegroundService]/[_stopForegroundServiceIfIdle])
  /// se queda prendido en vez de apagarse y volver a prenderse — evita que la
  /// notificación parpadee entre trabajos de la misma tanda (el backoff más
  /// largo entre reintentos normales es 45s). Para esperas más largas
  /// (cuota, muro anti-bot, servidor apagado) no vale la pena mantener vivo
  /// el proceso sólo para esperar: se apaga y el arranque en frío/la vuelta a
  /// primer plano ya se encargan de reintentar cuando corresponda.
  static const Duration _foregroundKeepAliveThreshold = Duration(seconds: 60);

  /// Cuánto esperar antes de reintentar un trabajo bloqueado por el muro
  /// anti-bot de YouTube específicamente ([DownloadSourceErrorKind.
  /// antiBotBlocked], HTTP 503 — no [DownloadSourceErrorKind.extraction]
  /// genérico, que sigue usando [_backoff]). La ventana medida es de
  /// 20-40+ minutos (`docs/investigacion_muro_antibot.md`); 30 minutos es un
  /// punto razonable dentro de ese rango, no una promesa exacta — si el
  /// bloqueo sigue vivo, el mismo mecanismo simplemente lo vuelve a esperar
  /// en la siguiente pasada. Tampoco cuenta contra `maxAttempts`: 3 intentos
  /// de 45 segundos se agotarían muchísimo antes de que esto se despeje,
  /// descartando de la cola canciones perfectamente descargables — que es
  /// justo el hueco que este valor viene a cerrar.
  static const int _antiBotBlockWaitSeconds = 1800;

  final DownloadService _service;
  final DatabaseHelper _db;
  final DownloadSource _source;

  /// Se llama tras cada descarga con éxito. Es cómo la biblioteca se entera,
  /// sin que este provider tenga que conocer a MusicProvider.
  final Future<void> Function(String playlistId)? onDownloadComplete;

  DownloadProvider({
    required DownloadService service,
    required DownloadSource source,
    DatabaseHelper? db,
    this.onDownloadComplete,
    this.maxFreeReschedules = 40,
    this.maxNetworkReschedules = 240,
  })  : _service = service,
        _source = source,
        _db = db ?? DatabaseHelper.instance;

  /// Tope de reprogramaciones "sin coste" (anti-bot, cupo corto, capacidad)
  /// acumuladas por trabajo; la red caída tiene el suyo, mucho más holgado
  /// (60 s por reintento). El cupo diario no cuenta: esperar al día siguiente
  /// es legítimo.
  final int maxFreeReschedules;
  final int maxNetworkReschedules;
  final Map<int, int> _freeReschedules = {};

  List<DownloadJob> _queue = const [];
  List<PendingImport> _pendingImports = const [];
  final List<DownloadFailure> _failures = [];
  DownloadJob? _current;
  DownloadPhase _phase = DownloadPhase.idle;
  double _progress = 0;
  bool _isProcessing = false;
  bool _cancelRequested = false;

  /// Cada worker captura el valor al empezar; si cambia, es que hubo una
  /// cancelación y el worker debe abandonar en vez de escribir en la
  /// biblioteca resultados de una tanda que el usuario ya dio por muerta.
  int _sessionId = 0;

  /// Backoff sólo en memoria, a propósito: el contador duro de intentos ya
  /// está en la base. Perder el backoff al reiniciar es lo deseable — si el
  /// usuario reabre la app, quiere que se reintente ya.
  final Map<int, DateTime> _retryAfter = {};

  /// `queueId`s para los que ya se intentó el fallback por búsqueda (ver
  /// [_tryFallbackSearch]) — como máximo una vez por trabajo, para no
  /// encadenar búsquedas si el reemplazo también falla. Sólo en memoria a
  /// propósito, igual que [_retryAfter]: perderlo al reiniciar cuesta como
  /// mucho un intento de más, nunca un bucle infinito dentro de una sesión.
  final Set<int> _fallbackAttempted = {};

  /// Programa la siguiente pasada cuando sólo quedan trabajos esperando su
  /// backoff. Ver [processQueue] para por qué no se duerme dentro del bucle.
  Timer? _retryTimer;

  List<DownloadJob> get queue => List.unmodifiable(_queue);
  List<PendingImport> get pendingImports => List.unmodifiable(_pendingImports);
  List<DownloadFailure> get failures => List.unmodifiable(_failures);
  DownloadJob? get current => _current;
  DownloadPhase get phase => _phase;
  bool get isProcessing => _isProcessing;
  int get pendingCount => _queue.length;

  /// 0..1 durante la transferencia. **-1 significa indeterminado**: el
  /// servidor está bajando el vídeo y todavía no hay bytes que contar.
  double get progress => _progress;

  // --- Encolar ---

  /// Encola una pista. [metadataComplete] debe ser true sólo si [track] viene
  /// de `/resolve`; false para resultados de búsqueda y entradas de playlist.
  Future<bool> enqueueTrack(
    RemoteTrack track, {
    required String playlistId,
    required bool metadataComplete,
    String sourceType = 'youtube',
    int? expectedOrderIndex,
  }) async {
    final added = await _db.enqueueDownload(
      sourceType: sourceType,
      sourceId: track.id,
      sourceUrl: track.sourceUrl,
      playlistId: playlistId,
      title: track.title,
      artist: track.artist,
      album: track.album,
      durationSeconds: track.durationSeconds,
      thumbnailUrl: track.thumbnailUrl,
      expectedOrderIndex: expectedOrderIndex,
      metadataComplete: metadataComplete,
    );
    await refreshQueue();
    return added;
  }

  /// Encola una playlist entera preservando su orden.
  ///
  /// Las entradas vienen de `extract_flat`, así que ninguna tiene metadata
  /// definitiva y todas pasarán por `/resolve` antes de bajarse.
  Future<int> enqueuePlaylist(
    RemotePlaylist playlist, {
    required String playlistId,
  }) async {
    var added = 0;
    for (var i = 0; i < playlist.entries.length; i++) {
      final entry = playlist.entries[i];
      final ok = await _db.enqueueDownload(
        sourceType: 'youtube',
        sourceId: entry.id,
        sourceUrl: entry.sourceUrl,
        playlistId: playlistId,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        durationSeconds: entry.durationSeconds,
        thumbnailUrl: entry.thumbnailUrl,
        expectedOrderIndex: i,
        metadataComplete: false,
      );
      if (ok) added++;
    }
    await refreshQueue();
    return added;
  }

  Future<void> refreshQueue() async {
    final rows = await _db.getDownloadQueue();
    _queue = rows.map(DownloadJob.fromRow).toList();
    notifyListeners();
  }

  // --- Lista de espera ---
  //
  // Antes de que exista un DownloadJob hace falta un /resolve (o /playlist)
  // que le dé título/id — y eso requiere que el servidor responda. Si no
  // responde en absoluto ([DownloadSourceErrorKind.network]), no hay nada
  // que encolar todavía: sólo la URL cruda y la playlist elegida quedan
  // guardadas aquí hasta que el servidor vuelva a estar disponible.

  Future<void> refreshPendingImports() async {
    final rows = await _db.getPendingImports();
    _pendingImports = rows.map(PendingImport.fromRow).toList();
    notifyListeners();
  }

  Future<bool> addPendingImport({
    required String sourceUrl,
    required String playlistId,
    required bool isPlaylist,
  }) async {
    final added = await _db.addPendingImport(
      kind: isPlaylist ? 'playlist' : 'video',
      sourceUrl: sourceUrl,
      playlistId: playlistId,
    );
    await refreshPendingImports();
    return added;
  }

  Future<void> removePendingImport(int id) async {
    await _db.removePendingImport(id);
    await refreshPendingImports();
  }

  /// Se llama cada vez que hay una señal razonable de que el servidor puede
  /// estar arriba de nuevo (arranque en frío, o justo después de que un
  /// `/resolve`/`/playlist` interactivo funcionó) — nunca por un polling
  /// propio: este proyecto ya evita temporizadores que solo existen para
  /// preguntar "¿ya volviste?" (ver `processQueue`).
  ///
  /// Se detiene en el primer [DownloadSourceErrorKind.network] o
  /// [DownloadSourceErrorKind.antiBotBlocked]: ambos significan "seguimos sin
  /// poder resolver nada de verdad todavía" (sin red, o el muro anti-bot de
  /// YouTube), así que insistir con el resto de la lista en la
  /// misma pasada sólo repetiría el mismo fallo. Cualquier otro error (404,
  /// formato no soportado, etc.) sí es definitivo para esa URL puntual — se
  /// descarta y se registra como un fallo más, igual que un trabajo de la
  /// cola normal.
  Future<void> retryPendingImports() async {
    await refreshPendingImports();
    if (_pendingImports.isEmpty) return;

    for (final pending in List<PendingImport>.of(_pendingImports)) {
      try {
        if (pending.isPlaylist) {
          final playlist = await _source.resolvePlaylist(pending.sourceUrl);
          await enqueuePlaylist(playlist, playlistId: pending.playlistId);
        } else {
          final track = await _source.resolve(pending.sourceUrl);
          await enqueueTrack(track, playlistId: pending.playlistId, metadataComplete: true);
        }
        await _db.removePendingImport(pending.id);
      } on DownloadSourceException catch (e) {
        if (e.kind == DownloadSourceErrorKind.network ||
            e.kind == DownloadSourceErrorKind.antiBotBlocked ||
            e.kind == DownloadSourceErrorKind.serviceUnavailable ||
            e.kind == DownloadSourceErrorKind.serverCapacityExhausted) {
          break;
        }
        await _db.removePendingImport(pending.id);
        _recordFailure(
          DownloadJob(
            queueId: -pending.id,
            sourceType: 'youtube',
            sourceId: pending.sourceUrl,
            sourceUrl: pending.sourceUrl,
            playlistId: pending.playlistId,
            title: pending.sourceUrl,
            artist: '',
            album: null,
            durationSeconds: 0,
            thumbnailUrl: '',
            expectedOrderIndex: null,
            attempts: 0,
            metadataComplete: false,
          ),
          e.userMessage,
          error: e,
          code: e.code,
          permanent: true,
        );
      }
    }

    await refreshPendingImports();
    // Se espera a que termine, a diferencia de cómo se llama a processQueue()
    // desde la UI (fire-and-forget): retryPendingImports() en sí ya se llama
    // sin esperar desde sus propios puntos de entrada (arranque en frío, el
    // botón "Reintentar ahora"), así que no hace falta que además deje un
    // processQueue() suelto corriendo por su cuenta.
    await processQueue();
  }

  // --- Cancelar ---

  /// Cancela la tanda entera y vacía la cola.
  Future<void> cancelAll() async {
    _cancelRequested = true;
    _sessionId++;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _db.clearDownloadQueue();
    _retryAfter.clear();
    _freeReschedules.clear();
    await refreshQueue();
    // Si processQueue() sigue corriendo, su propio finally ya la apaga al ver
    // _cancelRequested; esto cubre el caso en que no había ningún worker
    // activo (por ejemplo, esperando el backoff) y la notificación de
    // "esperando para reintentar" se había quedado prendida.
    unawaited(stopDownloadForegroundNotification());
    // No se espera a que el worker en curso termine: comprueba `_isStale` en
    // cada paso y abandonará solo. Bloquear aquí congelaría la UI durante la
    // transferencia que se acaba de cancelar.
  }

  Future<void> cancelJob(int queueId) async {
    if (_current?.queueId == queueId) {
      _cancelRequested = true;
      _sessionId++;
    }
    await _db.removeFromDownloadQueue(queueId);
    _retryAfter.remove(queueId);
    await refreshQueue();
  }

  Future<void> cancelPlaylist(String playlistId) async {
    if (_current?.playlistId == playlistId) {
      _cancelRequested = true;
      _sessionId++;
    }
    await _db.clearDownloadQueueForPlaylist(playlistId);
    await refreshQueue();
  }

  void clearFailures() {
    _failures.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

  // --- Procesar ---

  /// Procesa **lo que se puede procesar ahora**, uno cada vez, y vuelve.
  ///
  /// Los trabajos que están esperando su backoff no se esperan dentro del
  /// bucle: se programa un temporizador que vuelve a llamar aquí cuando toque.
  /// Dormir dentro del bucle dejaría `isProcessing` en true durante hasta 45
  /// segundos sin que pase nada —la UI diría "descargando" con todo parado— y
  /// haría que `cancelAll` no pudiera interrumpir el `Future.delayed`.
  ///
  /// Es seguro llamarlo de más: si ya hay un bucle andando, no hace nada.
  Future<void> processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _cancelRequested = false;
    final sessionId = _sessionId;
    _retryTimer?.cancel();
    _retryTimer = null;
    notifyListeners();

    try {
      while (true) {
        if (_isStale(sessionId)) break;

        await refreshQueue();
        final job = _nextRunnable();
        if (job == null) break;

        await _runJob(job, sessionId);
      }
    } finally {
      // Un único finally: con varias salidas tempranas, resetear en cada una
      // es exactamente cómo se acaba con la UI bloqueada en un camino que
      // nadie probó.
      _isProcessing = false;
      _current = null;
      _phase = DownloadPhase.idle;
      _progress = 0;
      if (!_cancelRequested && sessionId == _sessionId) _scheduleRetryPass();

      final wait = _shortestWait();
      if (_cancelRequested || wait == null || wait > _foregroundKeepAliveThreshold) {
        unawaited(stopDownloadForegroundNotification());
      } else {
        unawaited(startOrUpdateDownloadForegroundNotification(
          title: 'Heardy',
          text: 'Esperando para reintentar…',
        ));
      }
      notifyListeners();
    }
  }

  /// Programa otra pasada para cuando venza el backoff más próximo.
  void _scheduleRetryPass() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wait = _shortestWait();
    if (wait == null) return;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      processQueue();
    });
  }

  bool _isStale(int sessionId) => _cancelRequested || sessionId != _sessionId;

  DownloadJob? _nextRunnable() {
    final now = DateTime.now();
    for (final job in _queue) {
      final after = _retryAfter[job.queueId];
      if (after != null && after.isAfter(now)) continue;
      return job;
    }
    return null;
  }

  Duration? _shortestWait() {
    final now = DateTime.now();
    Duration? shortest;
    for (final job in _queue) {
      final after = _retryAfter[job.queueId];
      if (after == null || !after.isAfter(now)) continue;
      final wait = after.difference(now);
      if (shortest == null || wait < shortest) shortest = wait;
    }
    return shortest;
  }

  Future<void> _runJob(DownloadJob job, int sessionId) async {
    _current = job;
    _phase = job.metadataComplete ? DownloadPhase.preparing : DownloadPhase.resolving;
    _progress = -1;
    notifyListeners();

    // Uno por trabajo alcanza: lo que mantiene vivo el proceso es que el
    // foreground service esté prendido, no que la notificación refleje cada
    // sub-fase — eso ya lo muestra la UI en pantalla.
    final remaining = _queue.length;
    unawaited(startOrUpdateDownloadForegroundNotification(
      title: 'Descargando en Heardy',
      text: remaining > 1
          ? '${job.displayTitle} · $remaining en cola'
          : job.displayTitle,
    ));

    // La playlist destino puede haber desaparecido mientras el trabajo
    // esperaba: la cola no tiene FK a propósito, para que eso falle como un
    // trabajo y no se lleve la tanda por delante en cascada.
    final toInbox = job.playlistId == inboxDownloadTarget;
    if (!toInbox && await _db.getPlaylistById(job.playlistId) == null) {
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, 'La playlist de destino ya no existe.', code: 'E-DL-PLAYLIST', permanent: true);
      return;
    }

    try {
      final result = await _service.download(
        job.toRemoteTrack(),
        playlistId: toInbox ? null : job.playlistId,
        resolveFirst: !job.metadataComplete,
        onResolved: (resolved) async {
          // Se persiste ANTES de bajar un byte: si la descarga falla y el
          // trabajo se reintenta, el resolve no se repite.
          await _db.markDownloadMetadataResolved(
            job.queueId,
            sourceId: resolved.id,
            title: resolved.title,
            artist: resolved.artist,
            album: resolved.album,
            durationSeconds: resolved.durationSeconds,
            thumbnailUrl: resolved.thumbnailUrl,
            sourceUrl: resolved.sourceUrl.isEmpty ? null : resolved.sourceUrl,
          );
          if (_isStale(sessionId)) return;
          _phase = DownloadPhase.preparing;
          _current = job;
          notifyListeners();
        },
        onProgress: (received, total) {
          if (_isStale(sessionId)) return;
          _phase = DownloadPhase.downloading;
          _progress = (total == null || total <= 0) ? -1 : received / total;
          notifyListeners();
        },
        isCancelled: () => _isStale(sessionId),
      );

      if (_isStale(sessionId)) return;

      _phase = DownloadPhase.saving;
      notifyListeners();

      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      await onDownloadComplete?.call(job.playlistId);

      if (result.outcome == DownloadOutcome.alreadyInLibrary) {
        // No es un fallo, pero merece decirlo: el usuario pidió N canciones y
        // en la playlist aparecerán N aunque alguna no se haya bajado.
        debugPrint(
          'DownloadProvider: "${result.track.title}" ya estaba en la biblioteca, '
          'sólo se añadió a la playlist',
        );
      }
    } on DownloadSourceException catch (e) {
      if (_isStale(sessionId)) return;
      await _handleFailure(job, e);
    } catch (e) {
      if (_isStale(sessionId)) return;
      // Cualquier cosa inesperada se trata como reintentable: es preferible
      // gastar dos intentos de más que descartar en silencio una canción por
      // un fallo que nadie previó. El texto crudo va al log y a `lastError`;
      // la UI sólo ve la frase fija y el código.
      debugPrint('DownloadProvider: fallo inesperado (${e.runtimeType}) -> $e');
      await _handleFailure(
        job,
        DownloadSourceException(
          e is SocketException || e is TimeoutException
              ? DownloadSourceErrorKind.network
              : DownloadSourceErrorKind.extraction,
          e.toString(),
        ),
      );
    }
  }

  Future<void> _handleFailure(DownloadJob job, DownloadSourceException error) async {
    if (error.kind == DownloadSourceErrorKind.cancelled) return;

    final rescheduleCap = switch (error.kind) {
      DownloadSourceErrorKind.network => maxNetworkReschedules,
      DownloadSourceErrorKind.antiBotBlocked ||
      DownloadSourceErrorKind.serviceUnavailable ||
      DownloadSourceErrorKind.serverCapacityExhausted =>
        maxFreeReschedules,
      _ => null,
    };
    if (rescheduleCap != null) {
      final count = (_freeReschedules[job.queueId] ?? 0) + 1;
      _freeReschedules[job.queueId] = count;
      if (count > rescheduleCap) {
        _freeReschedules.remove(job.queueId);
        await _db.removeFromDownloadQueue(job.queueId);
        _retryAfter.remove(job.queueId);
        _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false);
        return;
      }
    }

    if (error.kind == DownloadSourceErrorKind.network) {
      // El servidor oficial ahora vive en un PC de casa que puede estar
      // apagado durante horas — muy por encima de lo que [_backoff] (pensado
      // para un corte de red de segundos) puede cubrir sin gastar
      // `maxAttempts`. Igual que una espera de cuota, esto no es un fallo del
      // trabajo: se reintenta solo, indefinidamente, hasta que el servidor
      // vuelva a responder.
      final wait = const Duration(seconds: _networkRetryWaitSeconds);
      _retryAfter[job.queueId] = DateTime.now().add(wait);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false, retryAfterSeconds: wait.inSeconds);
      await refreshQueue();
      return;
    }

    if (error.kind == DownloadSourceErrorKind.antiBotBlocked) {
      // Mismo trato que `network`: no es un fallo del
      // trabajo, así que no gasta `attempts`. La diferencia con `network` es
      // sólo cuánto se espera — ver _antiBotBlockWaitSeconds.
      final wait = const Duration(seconds: _antiBotBlockWaitSeconds);
      _retryAfter[job.queueId] = DateTime.now().add(wait);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false, retryAfterSeconds: wait.inSeconds);
      await refreshQueue();
      return;
    }

    if (error.kind == DownloadSourceErrorKind.serviceUnavailable) {
      final wait = Duration(seconds: (error.retryAfterSeconds ?? 60).clamp(5, 300));
      _retryAfter[job.queueId] = DateTime.now().add(wait);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false, retryAfterSeconds: wait.inSeconds);
      await refreshQueue();
      return;
    }

    if (error.kind == DownloadSourceErrorKind.serverCapacityExhausted) {
      // Sin ancho de banda hasta el mes siguiente: no es un fallo del trabajo.
      // El reintento es barato (con todos los servidores agotados el cliente
      // responde sin tocar la red, y sondea uno cada tanto por si se amplió
      // la cuota antes), así que basta una espera corta.
      const wait = Duration(minutes: 15);
      _retryAfter[job.queueId] = DateTime.now().add(wait);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false, retryAfterSeconds: wait.inSeconds);
      await refreshQueue();
      return;
    }

    // Un fallo definitivo sale de la cola en el primer intento. Gastar tres
    // reintentos en un vídeo borrado es tiempo y presupuesto de IP tirados, y
    // encima retrasa las canciones que sí se pueden bajar.
    if (!error.isRetryable) {
      // `notConfigured` es local, no del vídeo (sin carpeta elegida, o su
      // permiso SAF ya no es válido) — buscar un reemplazo no arregla nada
      // aquí, y como TODO trabajo fallaría por la misma razón, sería una
      // búsqueda desperdiciada por cada canción de la tanda.
      //
      // `blockedLegal` tampoco busca reemplazo: otra subida de la misma obra
      // eludiría el retiro.
      if (error.kind != DownloadSourceErrorKind.notConfigured &&
          error.kind != DownloadSourceErrorKind.blockedLegal &&
          await _tryFallbackSearch(job)) {
        await refreshQueue();
        return;
      }
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: true);
      return;
    }

    await _db.markDownloadAttempt(job.queueId, error.message);
    final attempts = job.attempts + 1;

    if (attempts >= maxAttempts) {
      if (await _tryFallbackSearch(job)) {
        await refreshQueue();
        return;
      }
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, error.userMessage, error: error, code: error.code, permanent: false);
      return;
    }

    final delay = _backoff[(attempts - 1).clamp(0, _backoff.length - 1)];
    _retryAfter[job.queueId] = DateTime.now().add(delay);
    await refreshQueue();
  }

  /// Antes de dar un trabajo por perdido, busca en YouTube el mismo tema por
  /// artista+título y, si encuentra un candidato con duración parecida,
  /// redirige el trabajo hacia ese vídeo en vez de descartarlo.
  ///
  /// Motivado por un caso medido, no supuesto: YouTube bloquea a nivel de
  /// contenido los tracks de canales auto-generados "- Topic" (audio
  /// oficial con licencia) para clientes de reproducción programáticos —
  /// probado contra los 6 tipos de cliente de yt-dlp, los 6 fallan igual, y
  /// confirmado con la API de YouTube directamente (sin nuestro servidor de
  /// por medio). En una playlist real de 68 vídeos, 36 de 37 tracks "- Topic"
  /// fallaron así; 0 de 31 "Music Clip" del mismo canal fallaron — y casi
  /// cada track "- Topic" bloqueado tiene su "Music Clip" oficial de la
  /// misma canción en la propia playlist. Reintentar el MISMO vídeo nunca
  /// arregla esto (es determinista, no un bloqueo de IP pasajero como
  /// [DownloadSourceErrorKind.antiBotBlocked]); lo único que funciona es
  /// bajar un vídeo distinto.
  ///
  /// Reutiliza la misma regla de emparejamiento del puente de Spotify
  /// ([pickClosestByDuration]) — nunca por similitud de título/artista, sólo
  /// por duración — y el mismo margen de tolerancia
  /// ([maxMatchToleranceSeconds]), para no sustituir por una versión en vivo,
  /// cover o remix sin que quede claro que es una sustitución razonable.
  Future<bool> _tryFallbackSearch(DownloadJob job) async {
    if (_fallbackAttempted.contains(job.queueId)) return false;
    _fallbackAttempted.add(job.queueId);

    // Sin duración conocida no hay nada fiable que comparar — y
    // [pickClosestByDuration] compararía todo candidato contra 0, así que
    // cualquier resultado corto (un short, un anuncio) "encajaría" dentro
    // de la tolerancia sin que eso signifique nada.
    if (job.durationSeconds <= 0) return false;

    final query = '${job.artist} ${job.title}'.trim();
    if (query.isEmpty) return false;

    List<RemoteTrack> results;
    try {
      results = await _source.search(query, limit: 8);
    } catch (_) {
      return false;
    }

    final candidates = results.where((r) => r.id != job.sourceId).toList();
    final match = pickClosestByDuration(candidates, job.durationSeconds);
    if (match == null) return false;
    if ((match.durationSeconds - job.durationSeconds).abs() > maxMatchToleranceSeconds) {
      return false;
    }

    await _db.retargetDownloadQueueJob(
      job.queueId,
      sourceId: match.id,
      sourceUrl: match.sourceUrl,
      title: match.title,
      artist: match.artist,
      album: match.album,
      durationSeconds: match.durationSeconds,
      thumbnailUrl: match.thumbnailUrl,
    );
    debugPrint(
      'DownloadProvider: "${job.displayTitle}" no se pudo bajar; '
      'sustituida por "${match.title}" (mismo tema, vídeo distinto)',
    );
    return true;
  }

  void _recordFailure(
    DownloadJob job,
    String message, {
    String? code,
    required bool permanent,
    int? retryAfterSeconds,
    DownloadSourceException? error,
  }) {
    _failures.insert(
      0,
      DownloadFailure(
        title: job.displayTitle,
        message: message,
        error: error,
        code: code,
        permanent: permanent,
        retryAfterSeconds: retryAfterSeconds,
        at: DateTime.now(),
      ),
    );
    // Acotado: es un registro para enseñar, no un log.
    if (_failures.length > 50) _failures.removeRange(50, _failures.length);
    notifyListeners();
  }
}
