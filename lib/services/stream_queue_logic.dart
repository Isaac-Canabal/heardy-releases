import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'download_source.dart';
import 'explore_logic.dart';

/// Lógica pura de la cola de streaming efímera (E8). Vive aparte de
/// `AudioPlayerHandler` porque `just_audio` no tiene doble de test.

/// Fallos seguidos (resolver o cargar) tras los cuales la cola se detiene.
const int maxConsecutiveStreamFailures = 3;

/// Una pista que suena este rato sin error cuenta como éxito y reinicia el
/// contador de fallos seguidos.
const Duration streamPlayedOkThreshold = Duration(seconds: 10);

int? nextStreamIndex(int current, int length) {
  final next = current + 1;
  return next < length ? next : null;
}

int? previousStreamIndex(int current, int length) {
  final prev = current - 1;
  return prev >= 0 && prev < length ? prev : null;
}

/// Pista a resolver en segundo plano mientras suena [current]: sólo la
/// siguiente (la URL caduca en ~6 h, resolver más allá desperdicia trabajo).
int? streamPreResolveIndex(int current, int length) => nextStreamIndex(current, length);

bool prefetchMatches(String? prefetchedVideoId, String trackId) =>
    prefetchedVideoId != null && prefetchedVideoId == trackId;

bool shouldResetStreamFailures(Duration position) => position >= streamPlayedOkThreshold;

class StreamFailureDecision {
  /// Pista a la que saltar, o null si la cola debe detenerse.
  final int? nextIndex;

  /// Si hay que mostrar el aviso (a lo sumo uno por ejecución de la cola).
  final bool notify;

  const StreamFailureDecision({required this.nextIndex, required this.notify});
}

/// [consecutiveFailures] ya incluye el fallo actual.
StreamFailureDecision decideAfterStreamFailure({
  required int index,
  required int length,
  required int consecutiveFailures,
  required bool noticeAlreadyEmitted,
  int maxFailures = maxConsecutiveStreamFailures,
}) {
  final next = consecutiveFailures >= maxFailures ? null : nextStreamIndex(index, length);
  return StreamFailureDecision(nextIndex: next, notify: !noticeAlreadyEmitted);
}

class StreamQueueSeed {
  final List<RemoteTrack> tracks;
  final int startIndex;

  const StreamQueueSeed(this.tracks, this.startIndex);
}

/// Cola a reproducir: sin ids vacíos ni repetidos (se conserva la primera
/// aparición) y con el índice de [startId], o 0 si no está.
StreamQueueSeed buildStreamQueue(Iterable<RemoteTrack> tracks, String startId) {
  final seen = <String>{};
  final out = <RemoteTrack>[];
  for (final track in tracks) {
    if (track.id.isEmpty || !seen.add(track.id)) continue;
    out.add(track);
  }
  final start = out.indexWhere((t) => t.id == startId);
  return StreamQueueSeed(out, start == -1 ? 0 : start);
}

/// Entrada de la cola publicada para [track]; sin URL (se resuelve al sonar) y
/// sin rutas locales (la carátula va en `artUri`). [resolvedSeconds] > 0
/// manda sobre la duración del listado.
MediaItem streamMediaItem(RemoteTrack track, {int resolvedSeconds = 0}) {
  final seconds = resolvedSeconds > 0 ? resolvedSeconds : track.durationSeconds;
  final art = Uri.tryParse(upscaleThumbnail(track.thumbnailUrl, size: 544));
  return MediaItem(
    id: 'stream:${track.id}',
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: seconds > 0 ? Duration(seconds: seconds) : null,
    artUri: art != null && art.scheme == 'https' ? art : null,
    extras: {
      'isStream': true,
      'videoId': track.id,
      'filePath': '',
      'artPath': '',
    },
  );
}

/// Copia de [items] con [current] en [index] (p. ej. con la duración ya resuelta).
List<MediaItem> publishedStreamQueue(List<MediaItem> items, int index, MediaItem current) {
  final out = List<MediaItem>.of(items);
  if (index >= 0 && index < out.length) out[index] = current;
  return out;
}

/// Destino válido de un salto a una entrada de la cola publicada, o null.
int? streamJumpTarget(int index, int length) => index >= 0 && index < length ? index : null;

/// Índice a publicar en `playbackState.queueIndex`: el player sólo tiene una
/// fuente cargada, así que con una cola de streaming manda el de la cola.
int? streamIndexForPlayback({
  required bool streamQueueActive,
  required int streamIndex,
  required int? playerIndex,
}) =>
    streamQueueActive ? streamIndex : playerIndex;

/// URL de carátula remota a mostrar: sólo si el ítem no trae archivo local
/// ([artPath] vacío) y su [artUri] es http(s).
String? remoteArtUrlFor(String artPath, Uri? artUri) {
  if (artPath.isNotEmpty || artUri == null) return null;
  return artUri.scheme == 'https' || artUri.scheme == 'http' ? artUri.toString() : null;
}

/// Generación de carga: cada salto/siguiente/anterior/auto-avance la incrementa
/// y todo resultado de un `await` que pertenezca a una anterior se descarta.
class StreamLoadGeneration {
  int _value = 0;

  int begin() => ++_value;

  void invalidate() => _value++;

  bool isCurrent(int generation) => generation == _value;
}

/// Agrupa selecciones rápidas: sólo el último destino dispara tras [delay].
class StreamTargetDebouncer {
  final Duration delay;
  final void Function(int index) onFire;
  Timer? _timer;

  StreamTargetDebouncer(this.delay, this.onFire);

  bool get isPending => _timer?.isActive ?? false;

  void select(int index) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      onFire(index);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Si ya pasaron más de esto, "anterior" reinicia la pista en vez de retroceder.
const Duration streamRestartThreshold = Duration(seconds: 3);

class StreamPreviousDecision {
  /// Reiniciar la pista cargada (seek a 0).
  final bool restart;

  /// Pista a cargar, o null si sólo se reinicia.
  final int? target;

  const StreamPreviousDecision({required this.restart, required this.target});
}

/// [index] es la pista ya seleccionada (aunque aún cargue). Si no está
/// [loaded], [position] es de la pista anterior y no cuenta.
StreamPreviousDecision decideStreamPrevious({
  required int index,
  required int length,
  required Duration position,
  required bool loaded,
}) {
  if (loaded && position > streamRestartThreshold) {
    return const StreamPreviousDecision(restart: true, target: null);
  }
  final prev = previousStreamIndex(index, length);
  if (prev != null) return StreamPreviousDecision(restart: false, target: prev);
  if (loaded) return const StreamPreviousDecision(restart: true, target: null);
  return StreamPreviousDecision(restart: false, target: index);
}

/// La cola publicada sólo se vuelve a emitir si la duración resuelta cambia.
bool streamQueueNeedsRepublish(MediaItem published, MediaItem resolved) =>
    published.duration != resolved.duration;
