import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'crossfade_logic.dart';
import 'crossfade_voice.dart';

/// Cuánto antes de [TransitionPlayback.clipStartInOutgoingSec] se prepara la
/// voz fantasma (carga del clip), y cuánto después de ese punto se da la
/// transición por perdida (el usuario saltó dentro de la cola de la pista).
const double transitionPrearmSec = 1.0;
const double transitionLateSec = 1.5;

/// La pista siguiente del reproductor principal arranca (en silencio) este
/// tiempo antes del traspaso, para que ya esté sonando a tiempo.
const double transitionAdvanceLeadSec = 1.5;

/// Un error de alineación mayor que esto entre el principal y el clip se
/// corrige con una búsqueda; con un error mayor que [transitionLooseAlignSec]
/// el traspaso usa un fundido largo de potencia constante.
const double transitionAlignToleranceSec = 0.025;
const double transitionLooseAlignSec = 0.04;

const Duration _handoverRamp = Duration(milliseconds: 50);
const Duration _looseHandoverRamp = Duration(milliseconds: 400);
const int _maxAlignAttempts = 40;
const Duration _startRamp = Duration(milliseconds: 30);
const Duration _rampStep = Duration(milliseconds: 10);

/// Lo que el manejador necesita para reproducir un clip de transición ya
/// renderizado. Todos los tiempos en segundos; los de la pista saliente y la
/// entrante son posiciones dentro de cada canción, los del clip, dentro del clip.
class TransitionPlayback {
  const TransitionPlayback({
    required this.clipPath,
    required this.clipSec,
    required this.clipStartInOutgoingSec,
    required this.handoverInClipSec,
    required this.handoverInIncomingSec,
    this.overlapStartInClipSec,
  });

  final String clipPath;
  final double clipSec;
  final double clipStartInOutgoingSec;
  final double handoverInClipSec;
  final double handoverInIncomingSec;

  /// Where the audible overlap starts in the clip; null when unknown (the UI
  /// then shows no overlap animation). It ends at [handoverInClipSec].
  final double? overlapStartInClipSec;

  /// Audible overlap length, or null when its start is unknown or unusable.
  double? get overlapSec {
    final start = overlapStartInClipSec;
    if (start == null || !start.isFinite) return null;
    final sec = handoverInClipSec - start;
    return sec.isFinite && sec > 0 ? sec : null;
  }

  bool get isUsable =>
      clipPath.isNotEmpty &&
      clipSec.isFinite &&
      clipSec > 0 &&
      clipStartInOutgoingSec.isFinite &&
      clipStartInOutgoingSec >= 0 &&
      handoverInClipSec.isFinite &&
      handoverInClipSec >= 0.2 &&
      handoverInClipSec < clipSec - 0.05 &&
      handoverInIncomingSec.isFinite &&
      handoverInIncomingSec >= 0;

  /// Posición de la pista entrante que corresponde al instante [clipSec] del clip.
  double incomingAtClip(double atClipSec) => handoverInIncomingSec + (atClipSec - handoverInClipSec);
}

/// Segundos que el reproductor principal arranca antes del traspaso: lo que
/// permita el punto de entrada (no puede empezar antes del inicio de la canción).
double transitionAdvanceLead(double handoverInIncomingSec) =>
    math.max(0.0, math.min(handoverInIncomingSec, transitionAdvanceLeadSec));

enum TransitionTriggerAction { none, start, missed }

/// Lead time the listener must have had before [TransitionPlayback.clipStartInOutgoingSec]: a transition only
/// fires when playback arrived at the song (natural start, seek, skip or resume) at least this far before the
/// clip starts. Otherwise the whole outgoing song plays as a normal queue item.
const double transitionMinLeadSec = 3.0;

/// Between two position updates the position may move this much backwards or forwards (tick jitter) and still
/// count as continuous playback; anything else is a seek.
const double transitionSeekBackSec = 0.5;
const double transitionSeekForwardSec = 1.5;

/// Decide cuándo se arranca la transición de la pista que suena. Se consulta
/// en cada tick de posición y dispara una sola vez por llegada. Una llegada es
/// la primera posición vista de la pista o la que sigue a una búsqueda
/// (detectada por un salto de posición); la transición sólo es elegible si la
/// llegada fue al menos [transitionMinLeadSec] antes del inicio del clip. Si
/// no, el par se da por perdido y la canción suena entera. Buscar hacia atrás,
/// a una posición con ese margen, la rearma.
class TransitionAutoTrigger {
  Object? _key;
  Object? _missed;
  double? _last;
  bool _eligible = false;
  bool _done = false;

  /// La transición de [key] no arrancará en esta llegada: la canción suena normal.
  bool isMissed(Object key) => _missed == key;

  void _arrive(Object key, double positionSec, double clipStartSec) {
    _eligible = positionSec <= clipStartSec - transitionMinLeadSec + 1e-9;
    _done = false;
    _missed = _eligible ? null : key;
  }

  TransitionTriggerAction evaluate({
    required Object key,
    required double positionSec,
    required double clipStartSec,
  }) {
    if (positionSec.isNaN || !clipStartSec.isFinite) return TransitionTriggerAction.none;
    final last = _last;
    _last = positionSec;
    if (_key != key) {
      _key = key;
      _arrive(key, positionSec, clipStartSec);
      if (!_eligible) {
        _done = true;
        return TransitionTriggerAction.missed;
      }
    } else if (last != null &&
        (positionSec < last - transitionSeekBackSec || positionSec > last + transitionSeekForwardSec)) {
      final wasMissed = _missed == key;
      _arrive(key, positionSec, clipStartSec);
      if (!_eligible) {
        _done = true;
        return wasMissed ? TransitionTriggerAction.none : TransitionTriggerAction.missed;
      }
    }
    if (_done || !_eligible) return TransitionTriggerAction.none;
    if (positionSec < clipStartSec - transitionPrearmSec) return TransitionTriggerAction.none;
    _done = true;
    if (positionSec > clipStartSec + transitionLateSec) {
      _missed = key;
      return TransitionTriggerAction.missed;
    }
    return TransitionTriggerAction.start;
  }
}

/// Voz fantasma que además informa de su posición, para alinear el traspaso.
abstract class ClipVoice extends GhostVoice {
  Duration get position;
}

class TransitionResult {
  final bool completed;
  final bool cancelled;
  final bool failed;
  final bool refusedBusy;

  /// El reproductor principal ya pasó a la pista siguiente.
  final bool advanced;

  const TransitionResult._({
    this.completed = false,
    this.cancelled = false,
    this.failed = false,
    this.refusedBusy = false,
    this.advanced = false,
  });
}

Duration _secs(double s) => Duration(microseconds: (s * 1e6).round());
double _toSec(Duration d) => d.inMicroseconds / 1e6;

/// Reproduce un clip de transición con una voz fantasma entre dos canciones
/// de la cola del reproductor principal:
///
/// 1. la fantasma carga el clip y, al llegar el principal a
///    `clipStartInOutgoingSec`, lo toma (fundido de 30 ms entre voces idénticas);
/// 2. poco antes del traspaso el principal avanza UNA vez a la pista siguiente,
///    en silencio, posicionado donde estará la entrante cuando el clip llegue a
///    `handoverInClipSec`; se corrige su alineación con la posición de la
///    fantasma;
/// 3. en el traspaso, un fundido corto sube el principal y baja la fantasma
///    (la cola del clip es idéntica a la canción, así que no se oye).
///
/// No conoce la cola ni el historial. Con una cancelación (pausa, salto,
/// búsqueda, parada) detiene la fantasma y devuelve el volumen al principal.
class TransitionPlaybackController {
  final ClipVoice Function() createVoice;
  final Future<void> Function(Duration) delay;

  /// Latencia estimada de una búsqueda con cambio de pista, para adelantarla.
  final Duration expectedSeekLatency;

  ClipVoice? _spare;
  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;

  TransitionPlaybackController({
    required this.createVoice,
    Future<void> Function(Duration)? delay,
    this.expectedSeekLatency = const Duration(milliseconds: 80),
  }) : delay = delay ?? Future<void>.delayed;

  bool get running => _running;

  /// Position of the clip while it plays, for the UI only; null otherwise.
  /// Reading it never changes playback.
  final ValueNotifier<double?> clipPositionSec = ValueNotifier<double?>(null);

  void _report(ClipVoice ghost) {
    if (_cancelRequested || _disposed) return;
    try {
      clipPositionSec.value = _toSec(ghost.position);
    } catch (_) {}
  }

  void cancel() {
    if (_running) _cancelRequested = true;
    if (!_disposed) clipPositionSec.value = null;
  }

  /// [mainPosition] es la posición del principal: de la pista saliente hasta
  /// [advanceMain] y de la entrante después. [advanceMain] debe ir a la pista
  /// siguiente en esa posición y volver cuando la búsqueda termine.
  Future<TransitionResult> run({
    required TransitionPlayback plan,
    required Object clipSource,
    required Duration Function() mainPosition,
    required double Function() masterVolume,
    required Future<void> Function(double) setMainVolume,
    required Future<void> Function(Duration) advanceMain,
    required Future<void> Function(Duration) seekMain,
    required Future<void> Function() restoreMainVolume,
  }) async {
    if (_running) return const TransitionResult._(refusedBusy: true);
    if (!plan.isUsable) return const TransitionResult._(failed: true);
    _running = true;
    _cancelRequested = false;
    final ghost = _spare ?? createVoice();
    _spare = null;
    var advanced = false;
    var started = false;
    try {
      try {
        await ghost.setVolume(0);
        await ghost.load(clipSource, Duration.zero);
      } catch (_) {
        await _keep(ghost);
        return const TransitionResult._(failed: true);
      }
      if (_cancelRequested) {
        await _keep(ghost);
        return const TransitionResult._(cancelled: true);
      }

      // Esperar a que el principal llegue al punto de entrada del clip.
      final startAt = plan.clipStartInOutgoingSec;
      var w = await _waitUntil(
        reached: () => _toSec(mainPosition()) >= startAt,
        remaining: () => startAt - _toSec(mainPosition()),
        maxWaitSec: transitionPrearmSec + transitionLateSec + 1,
      );
      if (w != _Wait.ok) return await _end(ghost, restoreMainVolume, w, advanced, started);

      // Tomar el relevo de la pista saliente.
      final offset = math.max(0.0, _toSec(mainPosition()) - startAt);
      await ghost.seek(_secs(offset));
      await ghost.play();
      started = true;
      _report(ghost);
      await delay(const Duration(milliseconds: 40));
      final syncErr = (_toSec(mainPosition()) - startAt) - _toSec(ghost.position);
      if (syncErr.abs() > 0.03) {
        await ghost.seek(_secs(math.max(0.0, _toSec(ghost.position) + syncErr)));
      }
      var ok = await _fade(_startRamp, (t) async {
        final master = masterVolume();
        await ghost.setVolume(master * t);
        await setMainVolume(master * (1 - t));
      });
      if (!ok) return await _end(ghost, restoreMainVolume, _Wait.cancelled, advanced, started);

      // Avanzar el principal a la pista siguiente, una sola vez.
      final lead = transitionAdvanceLead(plan.handoverInIncomingSec);
      final advanceAt = plan.handoverInClipSec - lead;
      w = await _waitUntil(
        reached: () => _toSec(ghost.position) >= advanceAt,
        remaining: () => advanceAt - _toSec(ghost.position),
        maxWaitSec: plan.clipSec + 1,
        onStep: () async {
          _report(ghost);
          await ghost.setVolume(masterVolume());
        },
      );
      if (w != _Wait.ok) return await _end(ghost, restoreMainVolume, w, advanced, started);

      final g0 = _toSec(ghost.position);
      final latency = _toSec(expectedSeekLatency);
      await advanceMain(_secs(math.max(0.0, plan.incomingAtClip(g0) + latency)));
      advanced = true;
      var measuredLatency = math.max(0.0, _toSec(ghost.position) - g0);

      // Alinear con la posición real de la fantasma.
      var err = 0.0;
      var attempts = 0;
      Future<bool> align(int maxAttempts) async {
        for (var i = 0; i < maxAttempts; i++) {
          if (_cancelRequested) return false;
          err = plan.incomingAtClip(_toSec(ghost.position)) - _toSec(mainPosition());
          if (err.abs() <= transitionAlignToleranceSec) return true;
          final before = _toSec(ghost.position);
          await seekMain(_secs(math.max(0.0, plan.incomingAtClip(before) + measuredLatency)));
          attempts++;
          measuredLatency = math.max(0.0, _toSec(ghost.position) - before);
        }
        err = plan.incomingAtClip(_toSec(ghost.position)) - _toSec(mainPosition());
        return true;
      }

      if (!await align(3)) {
        return await _end(ghost, restoreMainVolume, _Wait.cancelled, advanced, started);
      }

      // Traspaso a la pista entrante.
      w = await _waitUntil(
        reached: () => _toSec(ghost.position) >= plan.handoverInClipSec,
        remaining: () => plan.handoverInClipSec - _toSec(ghost.position),
        maxWaitSec: plan.clipSec + 1,
        onStep: () async {
          _report(ghost);
          await ghost.setVolume(masterVolume());
        },
      );
      if (w != _Wait.ok) return await _end(ghost, restoreMainVolume, w, advanced, started);

      // La cola del clip es la canción sin tocar: el traspaso vale en cualquier
      // punto de ella. Si el principal sigue mal alineado (p. ej. el motor
      // descartó las búsquedas mientras cargaba la pista), se sigue corrigiendo
      // en silencio mientras quede cola, en vez de subirlo desde un punto que
      // el clip ya sonó.
      final lastHandoverAt = plan.clipSec - _toSec(_looseHandoverRamp) - 0.15;
      while (err.abs() > transitionAlignToleranceSec &&
          _toSec(ghost.position) < lastHandoverAt &&
          attempts < _maxAlignAttempts) {
        if (!await align(1)) {
          return await _end(ghost, restoreMainVolume, _Wait.cancelled, advanced, started);
        }
        await ghost.setVolume(masterVolume());
        if (err.abs() > transitionAlignToleranceSec) await delay(const Duration(milliseconds: 40));
      }

      final loose = err.abs() > transitionLooseAlignSec;
      var ramp = loose ? _looseHandoverRamp : _handoverRamp;
      final postRoll = plan.clipSec - plan.handoverInClipSec - 0.02;
      if (_toSec(ramp) > postRoll) ramp = _secs(math.max(0.02, postRoll));
      ok = await _fade(ramp, (t) async {
        // Señales idénticas: la suma lineal no sube el nivel; con error de
        // alineación se usa potencia constante.
        final (out, inn) = loose ? crossfadeGains(t) : (1 - t, t);
        final master = masterVolume();
        await ghost.setVolume(master * out);
        await setMainVolume(master * inn);
      });
      if (ok) {
        // Última comprobación con el principal ya audible: nunca repetir lo que
        // el clip ya reprodujo.
        final g = _toSec(ghost.position);
        final tail = plan.incomingAtClip(g) - _toSec(mainPosition());
        if (tail.abs() > transitionAlignToleranceSec && g < plan.clipSec) {
          await seekMain(_secs(math.max(0.0, plan.incomingAtClip(g) + measuredLatency)))
              .catchError((Object _) {});
        }
      }
      return await _end(
        ghost,
        restoreMainVolume,
        ok ? _Wait.ok : _Wait.cancelled,
        advanced,
        started,
      );
    } catch (_) {
      await _settle(ghost, restoreMainVolume);
      return TransitionResult._(failed: true, advanced: advanced);
    } finally {
      _running = false;
      if (!_disposed) clipPositionSec.value = null;
    }
  }

  Future<TransitionResult> _end(
    ClipVoice ghost,
    Future<void> Function() restoreMainVolume,
    _Wait how,
    bool advanced,
    bool started,
  ) async {
    if (started || how == _Wait.ok) {
      await _settle(ghost, restoreMainVolume);
    } else {
      await ghost.stop().catchError((Object _) {});
      await _keep(ghost);
      await restoreMainVolume().catchError((Object _) {});
    }
    switch (how) {
      case _Wait.ok:
        return TransitionResult._(completed: true, advanced: advanced);
      case _Wait.cancelled:
        return TransitionResult._(cancelled: true, advanced: advanced);
      case _Wait.timeout:
        return TransitionResult._(failed: true, advanced: advanced);
    }
  }

  Future<_Wait> _waitUntil({
    required bool Function() reached,
    required double Function() remaining,
    required double maxWaitSec,
    Future<void> Function()? onStep,
  }) async {
    var waited = 0.0;
    while (!reached()) {
      if (_cancelRequested) return _Wait.cancelled;
      if (waited > maxWaitSec) return _Wait.timeout;
      final step = math.min(0.04, math.max(0.005, remaining()));
      await delay(_secs(step));
      waited += step;
      await onStep?.call();
    }
    return _cancelRequested ? _Wait.cancelled : _Wait.ok;
  }

  /// Rampa lineal de 0 a 1 en pasos de 10 ms; false si se canceló.
  Future<bool> _fade(Duration total, Future<void> Function(double t) apply) async {
    final steps = math.max(2, total.inMilliseconds ~/ _rampStep.inMilliseconds);
    final stepDelay = Duration(microseconds: total.inMicroseconds ~/ steps);
    for (var i = 0; i <= steps; i++) {
      if (_cancelRequested) return false;
      await apply(i / steps);
      if (i < steps) await delay(stepDelay);
    }
    return true;
  }

  Future<void> _settle(ClipVoice ghost, Future<void> Function() restoreMainVolume) async {
    await ghost.stop().catchError((Object _) {});
    await _keep(ghost);
    await restoreMainVolume().catchError((Object _) {});
  }

  Future<void> _keep(ClipVoice ghost) async {
    if (_disposed) {
      await ghost.dispose().catchError((Object _) {});
    } else {
      _spare = ghost;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final spare = _spare;
    _spare = null;
    await spare?.dispose();
  }
}

enum _Wait { ok, cancelled, timeout }
