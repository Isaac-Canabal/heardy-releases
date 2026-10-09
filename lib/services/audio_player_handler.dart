import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:saf_util/saf_util.dart';
import '../models/history_entry.dart';
import 'database_helper.dart';
import 'playback_state_service.dart';
import 'app_log.dart';
import 'download_source.dart';
import 'stream_queue_logic.dart';
import 'stream_resolver.dart';

final FlutterLocalNotificationsPlugin _errorNotification = FlutterLocalNotificationsPlugin();

/// Decisión pura de si una escucha cuenta para las estadísticas — extraída
/// para poder probarla sin `just_audio`, que no tiene doble de test en este
/// codebase. Umbral: 50% de la duración.
bool shouldRecordPlay({required Duration listened, required Duration duration}) {
  if (duration.inSeconds <= 0) return false;
  final threshold = (duration.inSeconds * 0.5).ceil();
  return listened.inSeconds >= threshold;
}

/// Lo que hace que valga la pena volver a escribir el estado de reproducción
/// a disco: la canción, si suena o no, o el tamaño de la cola. La posición
/// cambia todo el tiempo y sólo se refresca cada [minInterval].
class PlaybackSaveSnapshot {
  final String mediaId;
  final bool playing;
  final int queueLength;
  final DateTime savedAt;

  const PlaybackSaveSnapshot({
    required this.mediaId,
    required this.playing,
    required this.queueLength,
    required this.savedAt,
  });
}

bool shouldPersistPlaybackState({
  required PlaybackSaveSnapshot? previous,
  required PlaybackSaveSnapshot next,
  Duration minInterval = const Duration(seconds: 5),
}) {
  if (previous == null) return true;
  if (previous.mediaId != next.mediaId ||
      previous.playing != next.playing ||
      previous.queueLength != next.queueLength) {
    return true;
  }
  return next.savedAt.difference(previous.savedAt) >= minInterval;
}

/// Normaliza un volumen a [0, 1]; un valor no finito (un preference
/// corrupto, una división rara) vuelve al máximo en vez de dejar la app muda.
double clampVolume(double value) {
  if (value.isNaN || value.isInfinite) return 1.0;
  return value.clamp(0.0, 1.0).toDouble();
}

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  // Efectos de Android (ecualizador, estabilizador de volumen): tienen que
  // pasarse en el momento de construir el AudioPlayer, no se pueden agregar
  // después — ver audio_effects_service.dart, que es quien realmente los
  // controla. **Sólo se agregan al pipeline si `Platform.isAndroid`**: a
  // pesar de que `just_audio` sí filtra `androidAudioEffects` por
  // plataforma en su propio `InitRequest`, el propio `AudioPlayer` activa
  // *todos* los efectos del `AudioPipeline` sin ese filtro (`for (var
  // audioEffect in _audioPipeline._audioEffects) await audioEffect
  // ._activate(platform)`, en `just_audio.dart`), y `AndroidEqualizer
  // ._activate()` llama a un método (`androidEqualizerGetParameters`) que
  // sólo la implementación real de Android tiene — en cualquier otra
  // (`just_audio_media_kit` en Windows incluido) lanza `UnimplementedError`
  // sin capturar, dejando el reproductor entero sin arrancar. Reproducido
  // en vivo: sin este guard, Heardy no suena nada en Windows.
  final AndroidEqualizer _androidEqualizer = AndroidEqualizer();
  final AndroidLoudnessEnhancer _androidLoudnessEnhancer = AndroidLoudnessEnhancer();
  late final AudioPlayer _player = AudioPlayer(
    audioPipeline: Platform.isAndroid
        ? AudioPipeline(androidAudioEffects: [_androidLoudnessEnhancer, _androidEqualizer])
        : AudioPipeline(),
  );
  final SafUtil _safUtil = SafUtil();

  // Store the last emitted PlaybackEvent so we can rebuild state on shuffle/loop changes
  PlaybackEvent _lastEvent = PlaybackEvent();

  String? _trackingSongId;
  MediaItem? _trackingMediaItem;
  Duration _trackingMaxPosition = Duration.zero;
  bool _hasRecordedCurrentTrack = false;

  // "Reproducir a continuación": posición donde cae la próxima inserción vía
  // insertPlayNext. null = sin lote en curso, se recalcula desde el índice
  // actual. Se incrementa tras cada inserción para que las canciones
  // encoladas mantengan orden FIFO entre sí (no cada una salta a currentIndex+1,
  // sino que se van agregando al final del tramo ya encolado).
  int? _playNextInsertIndex;

  AudioPlayer get player => _player;
  AndroidEqualizer get androidEqualizer => _androidEqualizer;
  AndroidLoudnessEnhancer get androidLoudnessEnhancer => _androidLoudnessEnhancer;

  // --- VOLUMEN ---
  // El volumen elegido por el usuario (escritorio: el slider de la barra de
  // reproducción). Se guarda aparte del volumen real de `_player` porque el
  // fade-out del temporizador de sueño baja ese último a cero paso a paso y
  // después tiene que volver exactamente a este valor, no a 1.0.
  final ValueNotifier<double> volume = ValueNotifier<double>(1.0);

  Future<void> setVolume(double value) async {
    final v = clampVolume(value);
    volume.value = v;
    if (!_sleepFading) {
      try {
        await _player.setVolume(v);
      } catch (e) {
        print('Error ajustando el volumen: $e');
      }
    }
    PlaybackStateService.saveVolume(v);
  }

  Future<void> _restoreVolume() async {
    final raw = await PlaybackStateService.restoreVolume();
    if (raw == null) return;
    final saved = clampVolume(raw);
    volume.value = saved;
    try {
      await _player.setVolume(saved);
    } catch (e) {
      print('Error restaurando el volumen: $e');
    }
  }

  // --- SLEEP TIMER ---
  // In-memory only, by design: a sleep timer that survives a full app kill
  // and fires the next time the app is opened would be a bug, not a feature.
  static const Duration _sleepFadeDuration = Duration(seconds: 6);
  Timer? _sleepFireTimer;
  Timer? _sleepFadeTicker;
  Timer? _sleepTickTimer;
  DateTime? _sleepEndTime;
  bool _sleepFading = false;
  bool _pausingFromSleepFade = false;
  final StreamController<Duration?> _sleepTimerController =
      StreamController<Duration?>.broadcast();

  /// Emits the remaining time on every tick, and `null` when no timer is active.
  Stream<Duration?> get sleepTimerStream => _sleepTimerController.stream;

  /// Synchronous snapshot, for `initialData` on a StreamBuilder.
  Duration? get sleepTimerRemainingNow {
    if (_sleepEndTime == null) return null;
    final remaining = _sleepEndTime!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isSleepTimerActive => _sleepEndTime != null;

  void startSleepTimer(Duration duration) {
    _cleanupSleepTimerOnly();
    _sleepEndTime = DateTime.now().add(duration);
    final fadeStart = duration - _sleepFadeDuration;
    _sleepFireTimer = Timer(
      fadeStart.isNegative ? Duration.zero : fadeStart,
      _beginSleepFade,
    );
    _sleepTickTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _emitSleepRemaining(),
    );
    _emitSleepRemaining();
  }

  /// User-initiated cancel. If a fade-out is mid-flight, restores volume and
  /// keeps the song playing (case: cancel during fade-out).
  Future<void> cancelSleepTimer() async {
    if (_sleepEndTime == null) return;
    if (_sleepFading) {
      await _abortSleepFadeAndCleanup();
    } else {
      _cleanupSleepTimerOnly();
    }
  }

  void _emitSleepRemaining() {
    _sleepTimerController.add(sleepTimerRemainingNow);
  }

  Future<void> _beginSleepFade() async {
    if (_sleepEndTime == null) return; // cancelled before firing
    if (!_player.playing) {
      // Timer fired but the user had already paused manually: nothing to fade,
      // just clear the (now pointless) timer state.
      _cleanupSleepTimerOnly();
      return;
    }

    _sleepFading = true;
    const steps = 30;
    final stepDuration = Duration(
      milliseconds: _sleepFadeDuration.inMilliseconds ~/ steps,
    );
    var stepsLeft = steps;

    _sleepFadeTicker = Timer.periodic(stepDuration, (timer) async {
      stepsLeft--;
      try {
        await _player.setVolume(
          (stepsLeft / steps).clamp(0.0, 1.0) * volume.value,
        );
      } catch (e) {
        print('Error ajustando volumen durante fade-out: $e');
      }
      if (stepsLeft <= 0) {
        timer.cancel();
        await _finishSleepFade();
      }
    });
  }

  /// Natural end of the fade-out: pauses playback, then always restores
  /// the user's volume in a `finally` — if `pause()` throws, the app must not be
  /// left silently muted.
  Future<void> _finishSleepFade() async {
    _pausingFromSleepFade = true;
    try {
      await pause();
    } finally {
      _pausingFromSleepFade = false;
      try {
        await _player.setVolume(volume.value);
      } catch (e) {
        print('Error restaurando volumen tras el fade-out: $e');
      } finally {
        _cleanupSleepTimerOnly();
      }
    }
  }

  /// Aborts an in-progress fade (manual pause or explicit cancel mid fade-out)
  /// and restores volume in a `finally` so a half-finished fade can never
  /// leave the app muted.
  Future<void> _abortSleepFadeAndCleanup() async {
    _sleepFadeTicker?.cancel();
    _sleepFadeTicker = null;
    _sleepFading = false;
    try {
      await _player.setVolume(volume.value);
    } catch (e) {
      print('Error restaurando volumen al abortar fade-out: $e');
    } finally {
      _cleanupSleepTimerOnly();
    }
  }

  void _cleanupSleepTimerOnly() {
    _sleepFireTimer?.cancel();
    _sleepFadeTicker?.cancel();
    _sleepTickTimer?.cancel();
    _sleepFireTimer = null;
    _sleepFadeTicker = null;
    _sleepTickTimer = null;
    _sleepEndTime = null;
    _sleepFading = false;
    _sleepTimerController.add(null);
  }

  final StreamController<StreamPlaybackError> _streamErrorController =
      StreamController<StreamPlaybackError>.broadcast();

  /// Errores del reproductor ocurridos con una pista en streaming ya cargada
  /// (p. ej. 403 al saltar, URL caducada); a lo sumo uno por reproducción.
  /// Los fallos al resolver/cargar los reporta `playStream` con `rethrow`.
  Stream<StreamPlaybackError> get streamErrors => _streamErrorController.stream;

  // Un error durante la carga de `playStream` llega con `mediaItem` aún apuntando
  // al ítem anterior; sólo se atribuye a la pista una vez publicada.
  bool _streamReady = false;
  String? _streamErrorReportedFor;

  void _reportStreamError() {
    if (!_streamReady) return;
    final id = streamErrorVideoIdToEmit(mediaItem.value?.extras, _streamErrorReportedFor);
    if (id == null) return;
    _streamErrorReportedFor = id;
    _streamErrorController.add(StreamPlaybackError(id));
  }

  // --- COLA DE STREAMING (E8) ---
  // Diseño: el handler administra la cola y mantiene UNA sola fuente cargada
  // en el player (la pista actual); al terminar o saltar, carga la siguiente.
  // Se descartó una ConcatenatingAudioSource con todas las pistas: la URL de
  // cada una hay que resolverla en el dispositivo (1-3 s) y caduca, y just_audio
  // no tiene fuentes perezosas, así que habría que mantener alineados los
  // índices del player con los de la cola al saltar pistas fallidas — frágil
  // sin poder probarlo con un fake. Coste: un hueco de ~100-300 ms entre
  // pistas, porque la siguiente ya viene resuelta pero se abre en ese momento.
  // `queue` publica TODAS las pistas (sin URL, se resuelven al sonar) y
  // `queueIndex`/`mediaItem` apuntan a la actual; como el player sólo tiene una
  // fuente, su `currentIndex` (siempre 0) se ignora y manda `_streamIndex`.
  // Tocar una entrada salta a ella resolviéndola en el momento. Es efímera:
  // sin restauración ni fila en `songs` (sólo una entrada en `stream_history`).
  List<RemoteTrack>? _streamTracks;
  List<MediaItem> _streamItems = const [];
  int _streamIndex = 0;
  int _streamFailures = 0;
  bool _streamNoticeEmitted = false;
  // Invalida las cargas en vuelo cuando la cola cambia, se salta o se cancela.
  final StreamLoadGeneration _streamGen = StreamLoadGeneration();
  // Agrupa toques rápidos: la UI cambia al instante, sólo el último destino resuelve.
  late final StreamTargetDebouncer _streamDebouncer = StreamTargetDebouncer(
    const Duration(milliseconds: 200),
    (index) => _loadStreamQueueFrom(index),
  );
  StreamResolver? _streamResolver;
  String? _prefetchVideoId;
  Future<StreamInfo>? _prefetch;
  bool get isStreamQueueActive => _streamTracks != null;

  void _cancelStreamQueue() {
    _streamGen.invalidate();
    _streamDebouncer.cancel();
    if (_streamTracks != null) {
      // La cola completa deja de valer: queda sólo la pista actual, como un stream suelto.
      final current = mediaItem.value;
      if (_isStreamItem(current)) queue.add([current!]);
    }
    _streamItems = const [];
    _streamTracks = null;
    _streamIndex = 0;
    _streamFailures = 0;
    _streamNoticeEmitted = false;
    _streamResolver = null;
    _prefetchVideoId = null;
    _prefetch = null;
  }

  /// Reproduce [tracks] como cola efímera empezando por [startId]. Resuelve la
  /// pista actual y pre-resuelve la siguiente mientras suena. Los fallos por
  /// pista no lanzan: saltan a la siguiente y se avisan por [streamErrors].
  Future<void> playStreamQueue(
    List<RemoteTrack> tracks,
    String startId,
    StreamResolver resolver,
  ) async {
    final seed = buildStreamQueue(tracks, startId);
    if (seed.tracks.isEmpty) return;

    await _finalizePlay();
    _resetTracking();
    _cancelStreamQueue();
    _streamReady = false;
    _streamErrorReportedFor = null;
    if (_player.loopMode != LoopMode.off) {
      await _player.setLoopMode(LoopMode.off);
    }
    _streamTracks = seed.tracks;
    _streamItems = [for (final t in seed.tracks) streamMediaItem(t)];
    _streamIndex = seed.startIndex;
    queue.add(_streamItems);
    _streamResolver = resolver;
    await _loadStreamQueueFrom(seed.startIndex);
  }

  /// Selecciona [index] ya (UI y audio coherentes: se silencia el audio viejo y
  /// se muestra "cargando") y carga tras una ventana corta que agrupa toques
  /// rápidos. Cualquier carga en vuelo de un destino anterior queda descartada.
  void _selectStreamTarget(int index) {
    if (_streamTracks == null) return;
    _streamGen.invalidate();
    _streamReady = false;
    _streamIndex = index;
    mediaItem.add(_streamItems[index]);
    _player.pause().catchError((Object _) {});
    playbackState.add(_buildPlaybackState(_lastEvent));
    _streamDebouncer.select(index);
  }

  Future<StreamInfo> _resolveQueueTrack(RemoteTrack track, StreamResolver resolver) async {
    final pending = _prefetch;
    if (pending != null && prefetchMatches(_prefetchVideoId, track.id)) {
      _prefetch = null;
      _prefetchVideoId = null;
      try {
        return await pending;
      } catch (_) {
        // La resolución adelantada falló (red intermitente): se reintenta una vez
        // en directo antes de dar la pista por perdida.
      }
    }
    return resolver.resolve(track.id);
  }

  /// Carga y arranca la pista [index]; si falla, salta a las siguientes según
  /// [decideAfterStreamFailure] (aviso una vez, tope de fallos seguidos).
  Future<void> _loadStreamQueueFrom(int index) async {
    final token = _streamGen.begin();
    var i = index;
    while (true) {
      final tracks = _streamTracks;
      final resolver = _streamResolver;
      if (tracks == null || resolver == null || !_streamGen.isCurrent(token)) return;
      final track = tracks[i];
      try {
        _streamReady = false;
        // La UI marca ya la pista pedida mientras se resuelve.
        _streamIndex = i;
        mediaItem.add(_streamItems[i]);
        // El audio viejo no debe seguir sonando bajo la pista nueva.
        await _player.pause();
        if (!_streamGen.isCurrent(token)) return;
        playbackState.add(_buildPlaybackState(_lastEvent));
        final info = await _resolveQueueTrack(track, resolver);
        if (!_streamGen.isCurrent(token)) return;
        final item = streamMediaItem(track, resolvedSeconds: info.durationSeconds);
        if (streamQueueNeedsRepublish(_streamItems[i], item)) {
          _streamItems = publishedStreamQueue(_streamItems, i, item);
          queue.add(_streamItems);
        }
        _playlistSource = ConcatenatingAudioSource(children: [
          AudioSource.uri(Uri.parse(info.url), headers: info.httpHeaders, tag: item),
        ]);
        await _player
            .setAudioSource(_playlistSource!, initialIndex: 0, initialPosition: Duration.zero)
            .timeout(const Duration(seconds: 45));
        if (!_streamGen.isCurrent(token)) return;
        mediaItem.add(item);
        playbackState.add(_buildPlaybackState(_lastEvent));
        _recordStreamHistory(track, info.durationSeconds);
        _streamReady = true;
        // play() de just_audio no vuelve hasta que la pista termina o se pausa.
        _player.play().catchError((Object _) {});
        _prefetchNext(token, i);
        return;
      } catch (e) {
        if (!_streamGen.isCurrent(token)) return;
        // Sólo el tipo: el texto de un error de carga puede citar la URL firmada.
        appLog('Error en la cola de streaming con ${track.id} (${e.runtimeType})');
        final next = _onStreamQueueFailure(i, track.id);
        if (next == null) {
          await _endStreamQueue();
          return;
        }
        i = next;
      }
    }
  }

  /// Registra un fallo de la pista [index] y devuelve la siguiente a intentar,
  /// o null si la cola debe detenerse.
  int? _onStreamQueueFailure(int index, String videoId) {
    final tracks = _streamTracks;
    if (tracks == null) return null;
    _streamFailures++;
    final decision = decideAfterStreamFailure(
      index: index,
      length: tracks.length,
      consecutiveFailures: _streamFailures,
      noticeAlreadyEmitted: _streamNoticeEmitted,
    );
    if (decision.notify) {
      _streamNoticeEmitted = true;
      _streamErrorController.add(StreamPlaybackError(videoId, skipped: true));
    }
    return decision.nextIndex;
  }

  Future<void> _endStreamQueue() async {
    _cancelStreamQueue();
    _streamReady = false;
    try {
      await stop();
    } catch (e) {
      appLog('Error deteniendo la cola de streaming (${e.runtimeType})');
    }
  }

  void _prefetchNext(int token, int current) {
    final tracks = _streamTracks;
    final resolver = _streamResolver;
    if (tracks == null || resolver == null) return;
    final nextIndex = streamPreResolveIndex(current, tracks.length);
    if (nextIndex == null) return;
    final next = tracks[nextIndex];
    if (prefetchMatches(_prefetchVideoId, next.id)) return;
    final future = resolver.resolve(next.id);
    // Si nadie la espera todavía, su error no debe quedar sin manejar.
    future.then<void>((_) {}, onError: (Object _) {});
    _prefetchVideoId = next.id;
    _prefetch = future;
  }

  /// La pista actual de la cola terminó sola.
  Future<void> _onStreamQueueTrackCompleted() async {
    final tracks = _streamTracks;
    // Un `completed` de la fuente vieja durante una carga no debe avanzar la cola.
    if (tracks == null || !_streamReady) return;
    _streamReady = false;
    final next = nextStreamIndex(_streamIndex, tracks.length);
    if (next == null) {
      await _endStreamQueue();
      return;
    }
    _streamFailures = 0;
    await _loadStreamQueueFrom(next);
  }

  /// Error del reproductor con la pista actual de la cola ya sonando.
  Future<void> _onStreamQueueTrackError() async {
    if (!_streamReady) return;
    _streamReady = false;
    final next = _onStreamQueueFailure(_streamIndex, _streamTracks?[_streamIndex].id ?? '');
    if (next == null) {
      await _endStreamQueue();
      return;
    }
    await _loadStreamQueueFrom(next);
  }

  AudioPlayerHandler() {
    _initAudioSession();
    // Intentar restaurar estado guardado al iniciar
    _restoreSavedState();
    _restoreVolume();
    
    // Pipe just_audio events to audio_service's playbackState stream
    _player.playbackEventStream.listen((event) {
      _lastEvent = event;
      playbackState.add(_buildPlaybackState(event));
      // Guardar estado cuando cambia la reproducción
      _saveCurrentState();
    }, onError: (Object e, StackTrace stackTrace) {
      print('A stream error occurred: $e');
      if (_streamTracks != null) {
        // En la cola de streaming el error avanza a la siguiente pista (y avisa
        // una vez); sin notificación del sistema para no citar la URL firmada.
        _onStreamQueueTrackError();
        return;
      }
      _reportStreamError();
      // El plugin de notificaciones sólo se inicializa en Android (main.dart);
      // en escritorio `show()` lanza y convierte un error de carga
      // recuperable en una excepción sin capturar.
      if (!Platform.isAndroid) return;
      _errorNotification.show(
        999,
        'Error de Reproducción',
        e.toString(),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'com.heardy.app.audio.errors',
            'Errores de Reproducción',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    });

    // Synchronize mediaItem updates when active track index changes
    _player.currentIndexStream.listen((index) async {
      await _finalizePlay();
      if (_streamTracks != null) {
        // Fuente única: el índice del player no es el de la cola publicada.
        _playNextInsertIndex = null;
        return;
      }
      final playlistQueue = queue.value;
      if (index != null && playlistQueue.isNotEmpty && index < playlistQueue.length) {
        mediaItem.add(playlistQueue[index]);
        _startTracking(playlistQueue[index]);
      } else {
        _resetTracking();
      }
      // La canción actual cambió: el próximo lote de "reproducir a
      // continuación" vuelve a calcularse desde aquí.
      _playNextInsertIndex = null;
    });

    // Force playbackState update when SHUFFLE mode changes (just_audio doesn't emit PlaybackEvent for this)
    _player.shuffleModeEnabledStream.listen((_) {
      playbackState.add(_buildPlaybackState(_lastEvent));
    });

    // Force playbackState update when LOOP/REPEAT mode changes
    _player.loopModeStream.listen((_) {
      playbackState.add(_buildPlaybackState(_lastEvent));
    });

    // Monitor track completion to trigger automatic next track
    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (_streamTracks != null) {
          await _onStreamQueueTrackCompleted();
          return;
        }
        final duration = _trackingMediaItem?.duration ?? _player.duration;
        if (duration != null && duration > Duration.zero) {
          _trackingMaxPosition = duration;
        }
        await _finalizePlay();

        // LoopMode.one is handled internally by just_audio (it repeats automatically,
        // sin cambiar currentIndex — así que currentIndexStream nunca vuelve a llamar
        // _startTracking). Re-armamos el tracking manualmente para que una repetición
        // que vuelva a pasar del 50% cuente como una escucha nueva.
        if (_player.loopMode == LoopMode.one && _trackingMediaItem != null) {
          _startTracking(_trackingMediaItem!);
        }

        // LoopMode.all: wrap around to first track after the last one.
        // LoopMode.off: stop naturally at end.
        if (_player.loopMode == LoopMode.all) {
          if (_player.hasNext) {
            skipToNext();
          } else {
            // Last song in playlist → wrap to first
            _player.seek(Duration.zero, index: 0).then((_) => _player.play());
          }
        } else if (_player.loopMode == LoopMode.off) {
          if (_player.hasNext) {
            skipToNext();
          } else {
            // Stop at end of playlist
            stop();
          }
        }
      }
    });

    // Muestreo dedicado de posición para las estadísticas de reproducción:
    // `playbackEventStream` sólo emite en eventos discretos (carga, buffer,
    // cambio de pista), no periódicamente, así que con un archivo local ya
    // cargado dejaba de emitir a los pocos segundos y `_trackingMaxPosition`
    // se quedaba congelado cerca de 0 — la inmensa mayoría de escuchas nunca
    // llegaban al umbral. Este stream sí es periódico.
    _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 800),
          maxPeriod: const Duration(seconds: 1),
        )
        .listen(_onTrackingPosition);
  }

  /// Actualiza el máximo alcanzado y detecta una vuelta de repetición en
  /// `LoopMode.one`, que just_audio maneja internamente sin pasar nunca por
  /// `ProcessingState.completed` ni cambiar `currentIndex` — sin esto una
  /// canción en bucle único no contaba jamás, por muchas vueltas que diera.
  void _onTrackingPosition(Duration position) {
    if (_streamTracks != null && _streamFailures > 0 && shouldResetStreamFailures(position)) {
      _streamFailures = 0;
    }
    if (_trackingSongId == null) return;
    if (mediaItem.value?.id != _trackingSongId) return;

    final duration = _trackingMediaItem?.duration ?? _player.duration;
    if (_player.loopMode == LoopMode.one &&
        duration != null &&
        duration > Duration.zero &&
        position < const Duration(seconds: 1) &&
        _trackingMaxPosition >= duration - const Duration(seconds: 2)) {
      _finalizePlay();
      _startTracking(_trackingMediaItem!);
      return;
    }

    if (position > _trackingMaxPosition) {
      _trackingMaxPosition = position;
    }
  }

  /// Builds a PlaybackState from a PlaybackEvent, reading the current player properties.
  PlaybackState _buildPlaybackState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setShuffleMode,
        MediaAction.setRepeatMode,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: _streamTracks != null && !_streamReady
          ? AudioProcessingState.loading
          : const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState] ??
          AudioProcessingState.idle,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: streamIndexForPlayback(
        streamQueueActive: _streamTracks != null,
        streamIndex: _streamIndex,
        playerIndex: event.currentIndex,
      ),
      repeatMode: const {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[_player.loopMode] ??
          AudioServiceRepeatMode.none,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
  }

  // --- AUDIO SERVICE CALLBACK OVERRIDES ---

  @override
  Future<void> play() {
    // Durante la carga de una pista de la cola, `play` reanudaría el audio viejo;
    // la carga arranca la reproducción al terminar.
    if (_streamTracks != null && !_streamReady) return Future.value();
    return _player.play();
  }

  @override
  Future<void> pause() async {
    if (_sleepFading && !_pausingFromSleepFade) {
      // Manual pause mid fade-out: abort the fade and restore volume so the
      // app isn't left silently muted, but let the pause the user asked for
      // go through normally.
      await _abortSleepFadeAndCleanup();
    }
    await _player.pause();
    // Si ya se llegó al umbral pero la canción nunca termina (el usuario
    // pausa y sale de la app, y el SO mata el proceso más tarde) la escucha
    // no debe perderse — registrarla ya en cuanto se pausa es idempotente
    // gracias a `_hasRecordedCurrentTrack`.
    await _finalizePlay();
  }

  @override
  Future<void> stop() async {
    _cancelStreamQueue();
    await _finalizePlay();
    await _player.stop();
    _resetTracking();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) {
    // Si ya contamos esta canción como escuchada y el usuario rebobina
    // manualmente cerca del inicio, re-armamos el tracking: una repetición
    // manual que vuelva a pasar del 50% también cuenta como escucha nueva.
    if (_hasRecordedCurrentTrack &&
        position.inSeconds < 3 &&
        _trackingMaxPosition.inSeconds > 10) {
      _trackingMaxPosition = position;
      _hasRecordedCurrentTrack = false;
    } else if (mediaItem.value?.id == _trackingSongId &&
        position > _trackingMaxPosition) {
      // Adelantar (arrastrar la barra, botón +10s) debe contar hacia el
      // umbral igual que escuchar seguido — no esperar al próximo tick del
      // stream de posición para que un salto justo antes de cambiar de
      // canción no se pierda.
      _trackingMaxPosition = position;
    }
    return _player.seek(position);
  }

  Future<void> seekRelative(Duration offset) async {
    final duration = _player.duration ?? Duration.zero;
    var newPosition = _player.position + offset;
    if (newPosition < Duration.zero) newPosition = Duration.zero;
    if (duration > Duration.zero && newPosition > duration) {
      newPosition = duration;
    }
    await seek(newPosition);
  }

  @override
  Future<void> skipToNext() async {
    final tracks = _streamTracks;
    if (tracks != null) {
      final next = nextStreamIndex(_streamIndex, tracks.length);
      if (next != null) _selectStreamTarget(next);
      return;
    }
    if (_player.hasNext) {
      await _player.seekToNext();
    } else if (_player.loopMode == LoopMode.all && queue.value.isNotEmpty) {
      // Wrap to first track
      await _player.seek(Duration.zero, index: 0);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final streamTracks = _streamTracks;
    if (streamTracks != null) {
      final decision = decideStreamPrevious(
        index: _streamIndex,
        length: streamTracks.length,
        position: _player.position,
        loaded: _streamReady,
      );
      if (decision.restart) {
        await _player.seek(Duration.zero);
      } else if (decision.target != null) {
        _selectStreamTarget(decision.target!);
      }
      return;
    }
    // If more than 3 seconds in, restart current track instead of going back
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_streamTracks != null) {
      final target = streamJumpTarget(index, _streamTracks!.length);
      if (target != null) {
        _streamFailures = 0;
        _selectStreamTarget(target);
      }
      return;
    }
    if (index >= 0 && index < queue.value.length) {
      await _player.seek(Duration.zero, index: index);
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final index = queue.value.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      await skipToQueueItem(index);
      if (!isStreamQueueActive) await _player.play();
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _player.setShuffleModeEnabled(enabled);
    // shuffleModeEnabledStream listener will update playbackState
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    LoopMode mode;
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
      case AudioServiceRepeatMode.group:
        mode = LoopMode.off;
        break;
      case AudioServiceRepeatMode.one:
        mode = LoopMode.one;
        break;
      case AudioServiceRepeatMode.all:
        // Con una sola fuente cargada, `all` repetiría la pista actual en vez
        // de la cola de streaming.
        mode = _streamTracks != null ? LoopMode.off : LoopMode.all;
        break;
    }
    await _player.setLoopMode(mode);
    // loopModeStream listener will update playbackState
  }

  bool _isSafUri(String pathOrUri) => pathOrUri.contains('://');

  /// True if [pathOrUri] can actually be handed to just_audio right now.
  /// Legacy downloads are plain filesystem paths (`File.existsSync`, cheap
  /// and synchronous). SAF-imported songs are `content://` uris — those
  /// can't be checked with `File`, so this asks the SAF provider directly
  /// via a metadata-only query (`SafUtil.exists`, no bytes read). If the
  /// user has revoked the folder permission (or unmounted the volume, or
  /// the provider is otherwise gone), that query throws rather than
  /// returning false — caught here and treated the same as "not playable",
  /// so a revoked permission skips the song instead of crashing playback.
  Future<bool> _isPlayable(String pathOrUri) async {
    if (pathOrUri.isEmpty) return false;
    if (_isSafUri(pathOrUri)) {
      try {
        return await _safUtil.exists(pathOrUri, false);
      } catch (e) {
        appLog('Uri SAF no verificable (¿permiso revocado?) $pathOrUri: $e');
        return false;
      }
    }
    return File(pathOrUri).existsSync();
  }

  Uri _sourceUriFor(String pathOrUri) =>
      _isSafUri(pathOrUri) ? Uri.parse(pathOrUri) : Uri.file(pathOrUri);

  /// Runs [_isPlayable] over every item in parallel — these are local
  /// existence checks (filesystem or SAF), not network calls, so there's no
  /// concurrency concern like the download engine's circuit breaker.
  Future<List<MediaItem>> _filterPlayable(List<MediaItem> items) async {
    final flags = await Future.wait(items.map(
      (item) => _isPlayable(item.extras?['filePath'] as String? ?? ''),
    ));
    return [
      for (var i = 0; i < items.length; i++)
        if (flags[i]) items[i],
    ];
  }

  ConcatenatingAudioSource? _playlistSource;

  /// Sets the queue, initial index, and starts playing.
  Future<void> playPlaylist(List<MediaItem> items, String targetMediaId) async {
    // Filter out items whose file/uri isn't actually reachable right now,
    // to prevent loading failures (works for both legacy paths and SAF uris).
    final validItems = await _filterPlayable(items);

    if (validItems.isEmpty) return;
    _cancelStreamQueue();

    final targetIndex = validItems.indexWhere((item) => item.id == targetMediaId);
    final initialIndex = targetIndex != -1 ? targetIndex : 0;

    // Check if the current queue is exactly the same
    bool isSameQueue = false;
    final currentQueue = queue.value;
    if (currentQueue.length == validItems.length) {
      isSameQueue = true;
      for (int i = 0; i < currentQueue.length; i++) {
        if (currentQueue[i].id != validItems[i].id) {
          isSameQueue = false;
          break;
        }
      }
    }

    if (isSameQueue) {
      // Just seek and play if it's the same playlist
      if (_player.currentIndex != initialIndex) {
        await skipToQueueItem(initialIndex);
      }
      _startTracking(validItems[initialIndex]);
      if (!_player.playing) {
        await _player.play();
      }
      return;
    }

    // Cola realmente nueva (otra playlist, o la misma con canciones
    // distintas): el bucle no debe sobrevivir el cambio, así que se apaga
    // aquí. La rama `isSameQueue` de arriba no pasa por este punto, así que
    // reanudar la lista que ya sonaba no lo apaga.
    if (_player.loopMode != LoopMode.off) {
      await _player.setLoopMode(LoopMode.off);
    }

    queue.add(validItems);

    final sources = validItems.map((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return AudioSource.uri(_sourceUriFor(path), tag: item);
    }).toList();

    _playlistSource = ConcatenatingAudioSource(children: sources);

    // Pass initial index to avoid the need to seek immediately after setAudioSource
    await _player.setAudioSource(
      _playlistSource!,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    mediaItem.add(validItems[initialIndex]);
    _startTracking(validItems[initialIndex]);
    await _player.play();
  }

  /// Anota la pista en el historial de streaming (sólo local); no bloquea ni
  /// lanza.
  void _recordStreamHistory(RemoteTrack track, int resolvedSeconds) {
    DatabaseHelper.instance
        .recordStreamPlay(HistoryEntry(
          isStream: true,
          videoId: track.id,
          title: track.title,
          artist: track.artist,
          artUrl: track.thumbnailUrl,
          durationSeconds: resolvedSeconds > 0 ? resolvedSeconds : track.durationSeconds,
          playedAt: DateTime.now(),
        ))
        .catchError((Object e) => appLog('Historial de streaming no guardado (${e.runtimeType})'));
  }

  /// Reproduce una pista remota por su URL directa, sin descargarla.
  ///
  /// Es efímera: cola de un solo elemento que no pasa por `_filterPlayable`
  /// (no es un archivo), no cuenta como escucha en estadísticas (sólo deja una entrada en
  /// `stream_history`) y no se guarda para
  /// restaurar (ver `_saveCurrentState`). La URL nunca va al log.
  Future<void> playStream(RemoteTrack track, StreamInfo info) async {
    final item = streamMediaItem(track, resolvedSeconds: info.durationSeconds);

    try {
      _cancelStreamQueue();
      _streamReady = false;
      _streamErrorReportedFor = null;
      await _finalizePlay();
      _resetTracking();
      if (_player.loopMode != LoopMode.off) {
        await _player.setLoopMode(LoopMode.off);
      }

      queue.add([item]);
      _playlistSource = ConcatenatingAudioSource(children: [
        AudioSource.uri(Uri.parse(info.url), headers: info.httpHeaders, tag: item),
      ]);

      await _player
          .setAudioSource(
            _playlistSource!,
            initialIndex: 0,
            initialPosition: Duration.zero,
          )
          .timeout(const Duration(seconds: 45));

      mediaItem.add(item);
      _recordStreamHistory(track, info.durationSeconds);
      _streamReady = true;
      // play() de just_audio no vuelve hasta que la pista termina o se pausa:
      // esperarlo dejaba a quien llamó (y su "cargando") bloqueado toda la
      // canción. Los errores de reproducción llegan por el stream de errores.
      _player.play().catchError((Object _) {});
    } catch (e) {
      // Sólo el tipo: el texto de un error de carga puede citar la URL firmada.
      appLog('Error reproduciendo el stream de ${track.id} (${e.runtimeType})');
      rethrow;
    }
  }

  /// Loads a playlist and seeks to a position WITHOUT auto-playing.
  /// Used to restore a paused state on app restart.
  Future<void> restorePlaylist(
    List<MediaItem> items,
    String targetMediaId,
    Duration position,
  ) async {
    final validItems = await _filterPlayable(items);

    if (validItems.isEmpty) return;
    _cancelStreamQueue();

    final targetIndex = validItems.indexWhere((item) => item.id == targetMediaId);
    final initialIndex = targetIndex != -1 ? targetIndex : 0;

    queue.add(validItems);

    final sources = validItems.map((item) {
      final path = item.extras?['filePath'] as String? ?? '';
      return AudioSource.uri(_sourceUriFor(path), tag: item);
    }).toList();

    _playlistSource = ConcatenatingAudioSource(children: sources);

    await _player.setAudioSource(
      _playlistSource!,
      initialIndex: initialIndex,
      initialPosition: position,
    );

    mediaItem.add(validItems[initialIndex]);
    _startTracking(validItems[initialIndex]);
    // Do NOT call _player.play() — restore paused state
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    if (_streamTracks != null) return; // la cola de streaming no mezcla pistas locales
    try {
      final path = mediaItem.extras?['filePath'] as String? ?? '';
      if (path.isEmpty) {
        print('Error: path vacío para mediaItem ${mediaItem.id}');
        return;
      }

      if (!await _isPlayable(path)) {
        appLog('Error: archivo/uri no disponible para mediaItem ${mediaItem.id}: $path');
        return;
      }

      final currentQueue = queue.value;
      if (currentQueue.any((item) => item.id == mediaItem.id)) return;

      queue.add([...currentQueue, mediaItem]);

      if (_playlistSource != null) {
        try {
          await _playlistSource!.add(AudioSource.uri(_sourceUriFor(path), tag: mediaItem));
        } on PlatformException catch (e) {
          appLog('Error PlatformException en addQueueItem: ${e.message}');
          appLog('Detalles: ${e.details}');
          // Quitar el item de la queue si falló cargar
          queue.add(currentQueue);
        }
      }
    } catch (e) {
      print('Error agregando item a la queue: $e');
    }
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    if (_streamTracks != null) return;
    try {
      final validItems = await _filterPlayable(mediaItems);

      if (validItems.isEmpty) return;

      final currentQueue = queue.value;
      final existingIds = currentQueue.map((i) => i.id).toSet();
      final newItems = validItems.where((item) => !existingIds.contains(item.id)).toList();

      if (newItems.isEmpty) return;

      queue.add([...currentQueue, ...newItems]);

      if (_playlistSource != null) {
        try {
          final sources = newItems.map((item) {
            final path = item.extras!['filePath'] as String;
            return AudioSource.uri(_sourceUriFor(path), tag: item);
          }).toList();
          await _playlistSource!.addAll(sources);
        } on PlatformException catch (e) {
          appLog('Error PlatformException en addQueueItems: ${e.message}');
          appLog('Detalles: ${e.details}');
          queue.add(currentQueue);
        }
      }
    } catch (e) {
      print('Error agregando items a la queue: $e');
    }
  }

  /// Inserta [item] para que se reproduzca justo después de la canción
  /// actual, o después de la última canción ya insertada de esta forma
  /// (cola FIFO: lo primero que se encola es lo primero en sonar de las
  /// "próximas", no siempre pega un salto a la posición actual+1).
  Future<void> insertPlayNext(MediaItem item) async {
    if (_streamTracks != null) return;
    try {
      final path = item.extras?['filePath'] as String? ?? '';
      if (path.isEmpty || !await _isPlayable(path)) {
        print('Error: item no reproducible para insertPlayNext: ${item.id}');
        return;
      }

      final currentQueue = queue.value;
      if (_playlistSource == null || currentQueue.isEmpty) {
        // Nada sonando ahora mismo: "reproducir después de la actual" no
        // aplica, así que directamente la reproducimos.
        await playPlaylist([item], item.id);
        return;
      }

      final currentIndex = _player.currentIndex;
      final existingIndex = currentQueue.indexWhere((existing) => existing.id == item.id);

      // Ya es la canción actual: no hay "después de la actual" que aplicar.
      if (existingIndex != -1 && existingIndex == currentIndex) return;

      _playNextInsertIndex ??= (currentIndex ?? -1) + 1;
      final target = _playNextInsertIndex!.clamp(0, currentQueue.length);

      if (existingIndex != -1) {
        // Caso normal: la canción deslizada ya está en la playlist que se
        // está reproduciendo (es la MISMA cola) — antes esto se descartaba
        // en silencio por el chequeo de duplicados, que era el bug real:
        // "reproducir a continuación" nunca hacía nada sobre una canción de
        // la propia playlist. Se MUEVE a la posición calculada en vez de
        // insertar un duplicado; moveQueueItem ya resuelve el ajuste de
        // índice cuando existingIndex < target (misma convención que
        // ReorderableListView.onReorder).
        await moveQueueItem(existingIndex, target);
        _playNextInsertIndex = existingIndex < target ? target : target + 1;
        return;
      }

      final newQueue = List<MediaItem>.from(currentQueue)..insert(target, item);
      queue.add(newQueue);

      try {
        await _playlistSource!.insert(target, AudioSource.uri(_sourceUriFor(path), tag: item));
        _playNextInsertIndex = target + 1;
      } on PlatformException catch (e) {
        appLog('Error PlatformException en insertPlayNext: ${e.message}');
        queue.add(currentQueue);
      }
    } catch (e) {
      print('Error insertando "reproducir a continuación": $e');
    }
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    if (_streamTracks != null) return; // la cola de streaming no se edita
    final currentQueue = queue.value;
    final index = currentQueue.indexWhere((item) => item.id == mediaItem.id);
    if (index == -1) return;

    final newQueue = List<MediaItem>.from(currentQueue)..removeAt(index);
    queue.add(newQueue);

    if (_playlistSource != null && index < _playlistSource!.length) {
      await _playlistSource!.removeAt(index);
    }
  }

  /// Reorders a queue item at oldIndex to newIndex, updating both the AudioService queue and the just_audio playlist source
  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    if (_streamTracks != null) return; // la cola de streaming no se edita
    final currentQueue = queue.value;
    if (oldIndex < 0 || oldIndex >= currentQueue.length || newIndex < 0 || newIndex > currentQueue.length) return;

    int targetIndex = newIndex;
    if (oldIndex < newIndex) {
      targetIndex = newIndex - 1;
    }

    final newQueue = List<MediaItem>.from(currentQueue);
    final item = newQueue.removeAt(oldIndex);
    newQueue.insert(targetIndex, item);
    queue.add(newQueue);

    if (_playlistSource != null && oldIndex < _playlistSource!.length && targetIndex < _playlistSource!.length) {
      await _playlistSource!.move(oldIndex, targetIndex);
    }
  }

  /// Gracefully terminates background play state when swipe-closing the application.

  @override
  Future<void> onTaskRemoved() async {
    try {
      // `stop()` sí, `dispose()` NO. `_player` es `final` (ver arriba), así que
      // destruirlo es irreversible: no hay forma de recrearlo en este proceso.
      //
      // Aquí había un `dispose()`, y sólo era inocuo si el proceso moría justo
      // después. Pero con `androidNotificationOngoing: true` (main.dart) el
      // servicio está en foreground y el proceso suele sobrevivir a que el
      // usuario deslice la app fuera de recientes — que es exactamente cuando
      // salta este callback. En ese caso reabrir la app daba un reproductor
      // muerto hasta forzar el cierre.
      //
      // **2026-08-03: `stop()` (el método de este handler), no
      // `_player.stop()` directo.** Llamar sólo al player saltaba
      // `super.stop()` — el propio `stop()` de audio_service, que es quien
      // realmente da de baja la sesión de medios y el servicio en foreground
      // ante Android. Sospecha fundada, no confirmada en un dispositivo real
      // todavía: sin ese aviso, la sesión de medios puede quedar registrada
      // como "activa" incluso si el proceso muere después — y si Android no
      // la limpia a tiempo, el siguiente arranque en frío puede colgarse
      // esperando a `AudioService.init()` mientras intenta crear una sesión
      // nueva sobre una que el sistema todavía cree viva. Coincide con el
      // síntoma reportado: la app se congela al iniciar y sólo se resuelve
      // forzando el cierre (que sí mata el proceso viejo de verdad) y
      // reabriendo. Pendiente de confirmar en hardware real.
      await stop();
    } catch (e) {
      print("Error stopping player on task remove: $e");
    }
    // Igual que fullRepair(): sin esto, si el proceso sobrevive al swipe (caso de
    // arriba), `queue`/`mediaItem` quedan apuntando a una fuente que el player ya
    // liberó — la UI muestra la última canción como si nada, pero play() actúa
    // sobre un reproductor sin fuente cargada. hasLoadedSource (ver abajo) detecta
    // y corrige esto igual si el proceso muere del todo y este callback ni corre.
    _playlistSource = null;
    queue.add([]);
    mediaItem.add(null);
    await super.onTaskRemoved();
  }

  /// True si hay una fuente realmente cargada en el player, no solo metadata en
  /// `queue`/`mediaItem`. Lo usa `MusicProvider.restorePlaybackState` para saber
  /// si hace falta restaurar algo, en vez de un guard de "ya corrí una vez".
  bool get hasLoadedSource =>
      _playlistSource != null &&
      queue.value.isNotEmpty &&
      mediaItem.value != null &&
      _player.processingState != ProcessingState.idle;

  /// Resets the player state if it gets corrupted. Call this if playback stops working.
  Future<void> resetPlayerState() async {
    try {
      print('Resetting player state...');
      _cancelStreamQueue();
      await _player.stop();
      _playlistSource = null;
      queue.add([]);
      mediaItem.add(null);
      await Future.delayed(const Duration(milliseconds: 200));
      // Limpiar estado guardado al resetear
      await PlaybackStateService.clearState();
      print('Player state reset complete');
    } catch (e) {
      print('Error resetting player state: $e');
    }
  }

  /// Reproduce una URL directamente (para streaming temporal)
  Future<void> playUrl(String url, MediaItem item) async {
    try {
      _cancelStreamQueue();
      _resetTracking();
      // Resetear el reproductor antes de cargar nueva URL
      await _player.stop();
      
      // Cargar la URL con timeout
      await _player.setUrl(url).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout cargando URL de audio');
        },
      );
      
      mediaItem.add(item);
      playbackState.add(_buildPlaybackState(
        PlaybackEvent(
          processingState: ProcessingState.ready,
          updateTime: DateTime.now(),
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          duration: item.duration,
          currentIndex: 0,
        ),
      ));
      await _player.play();
    } on PlatformException catch (e) {
      appLog('Error de plataforma reproduciendo URL: ${e.message}');
      appLog('Detalles: ${e.details}');
      throw Exception('Error al cargar audio: ${e.message}');
    } catch (e) {
      print('Error reproduciendo URL directa: $e');
      rethrow;
    }
  }

  /// Reparación completa del reproductor para problemas de corrupción
  Future<String> fullRepair() async {
    try {
      print('Iniciando reparación completa...');
      _cancelStreamQueue();

      // 1. Detener y limpiar el reproductor completamente
      await _player.stop();
      
      // 2. Limpiar estados
      _playlistSource = null;
      queue.add([]);
      mediaItem.add(null);
      
      // 3. Esperar para asegurar liberación de recursos
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 4. Limpiar cualquier cache interno
      try {
        // Limpiar buffer de audio forzando speed reset
        await _player.setSpeed(1.0);
        // Seek al inicio para limpiar buffer
        await _player.seek(Duration.zero);
      } catch (e) {
        print('Error limpiando buffer: $e');
      }
      
      print('Reparación completa finalizada');
      return 'Reparación completada exitosamente';
    } catch (e) {
      print('Error en reparación completa: $e');
      return 'Error durante la reparación: $e';
    }
  }

  static bool _isStreamItem(MediaItem? item) => item?.extras?['isStream'] == true;

  void _startTracking(MediaItem item) {
    final filePath = item.extras?['filePath'] as String?;
    if (_isStreamItem(item) || filePath == null || filePath.isEmpty) {
      _resetTracking();
      return;
    }

    _trackingSongId = item.id;
    _trackingMediaItem = item;
    _trackingMaxPosition = Duration.zero;
    _hasRecordedCurrentTrack = false;
  }

  void _resetTracking() {
    _trackingSongId = null;
    _trackingMediaItem = null;
    _trackingMaxPosition = Duration.zero;
    _hasRecordedCurrentTrack = false;
  }

  Future<void> _finalizePlay() async {
    if (_hasRecordedCurrentTrack ||
        _trackingSongId == null ||
        _trackingMediaItem == null) {
      return;
    }

    final duration = _trackingMediaItem!.duration ??
        _player.duration ??
        Duration.zero;

    if (!shouldRecordPlay(
      listened: _trackingMaxPosition,
      duration: duration,
    )) {
      return;
    }

    try {
      await DatabaseHelper.instance.recordPlay(
        _trackingSongId!,
        _trackingMaxPosition.inSeconds,
      );
      _hasRecordedCurrentTrack = true;
    } catch (e) {
      print('Error registrando reproducción: $e');
    }
  }

  PlaybackSaveSnapshot? _lastSavedSnapshot;

  /// Guarda el estado actual de reproducción
  Future<void> _saveCurrentState() async {
    try {
      final mediaItemValue = mediaItem.value;
      final queueValue = queue.value;

      if (mediaItemValue == null || queueValue.isEmpty) {
        return;
      }

      // Un stream es efímero: no se restaura al reiniciar. No se guarda nada
      // mientras suena, así que lo último persistido sigue siendo la última
      // cola real de la biblioteca.
      if (_isStreamItem(mediaItemValue)) return;
      final persistableQueue = queueValue.where((i) => !_isStreamItem(i)).toList();
      if (persistableQueue.isEmpty) return;

      // En escritorio (libmpv) `playbackEventStream` emite decenas de veces
      // por segundo mientras suena — cada una escribía SharedPreferences a
      // disco. ExoPlayer sólo emite en eventos discretos, así que en Android
      // se deja tal cual.
      if (!Platform.isAndroid) {
        final snapshot = PlaybackSaveSnapshot(
          mediaId: mediaItemValue.id,
          playing: _player.playing,
          queueLength: persistableQueue.length,
          savedAt: DateTime.now(),
        );
        if (!shouldPersistPlaybackState(previous: _lastSavedSnapshot, next: snapshot)) {
          return;
        }
        _lastSavedSnapshot = snapshot;
      }

      await PlaybackStateService.saveState(
        isPlaying: _player.playing,
        currentMediaId: mediaItemValue.id,
        position: _player.position,
        queue: persistableQueue,
        shuffleMode: playbackState.value.shuffleMode,
        speed: _player.speed,
        playlistId: mediaItemValue.extras?['playlist_id'] as String?,
      );
    } catch (e) {
      print('Error guardando estado actual: $e');
    }
  }

  /// Restaura el estado guardado de reproducción
  Future<void> _restoreSavedState() async {
    try {
      final savedState = await PlaybackStateService.restoreState();
      if (savedState == null) {
        print('No hay estado guardado para restaurar');
        return;
      }
      
      // Notificar que estamos restaurando
      print('Estado guardado detectado, esperando a MusicProvider para restauración...');
      
      // La restauración real se hará en MusicProvider después de cargar las playlists
      // Aquí solo verificamos que haya estado guardado
    } catch (e) {
      print('Error restaurando estado guardado: $e');
    }
  }

  /// Inicializa la sesión de audio para el manejo de foco de audio del SO
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      print('Sesión de audio inicializada exitosamente.');
    } catch (e) {
      print('Error inicializando la sesión de audio: $e');
    }
  }
}
