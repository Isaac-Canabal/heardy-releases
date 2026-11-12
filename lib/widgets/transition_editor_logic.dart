// Lógica pura del editor de transiciones: del tiempo al píxel y vuelta en las
// ondas ampliadas, arrastres con pegado al ritmo y límites, escala en dB, y
// puntos de las curvas (acertar, arrastrar, añadir, quitar). Sin widgets ni
// l10n, para probarla sin dibujar nada.
import 'dart:convert';
import 'dart:math' as math;

import '../services/mix/mix_analysis.dart' show SongAnalysis;
import '../services/transition/platform/transition_profile.dart';
import '../services/transition/transition_analysis.dart';
import '../services/transition/transition_model.dart';
import '../services/transition/transition_presets.dart';
import '../services/transition/transition_suggest.dart' show TransitionLengthOption;

// ---- Tiempo <-> píxel de una onda ampliada ----

/// Ventana de una onda: [startSec] está en x = 0 y [viewSec] cubre [widthPx].
class TransitionLaneView {
  const TransitionLaneView({required this.startSec, required this.viewSec, required this.widthPx});
  final double startSec, viewSec, widthPx;

  double get endSec => startSec + viewSec;
  double timeToX(double t) => viewSec <= 0 ? 0 : (t - startSec) / viewSec * widthPx;
  double xToTime(double x) => widthPx <= 0 ? startSec : startSec + x / widthPx * viewSec;
  double secToPx(double sec) => viewSec <= 0 ? 0 : sec / viewSec * widthPx;
  double pxToSec(double px) => widthPx <= 0 ? 0 : px / widthPx * viewSec;
}

/// Segundos de aire a cada lado de la mezcla en la onda ampliada.
double transitionLaneMargin(double lengthSec) => math.max(2.0, lengthSec * 0.5);

/// La onda se centra en la mezcla: el solape siempre cae en el mismo sitio y
/// lo que se mueve al arrastrar es la canción por debajo.
TransitionLaneView transitionLaneView({
  required double overlapStartSec,
  required double lengthSec,
  required double widthPx,
}) {
  final margin = transitionLaneMargin(lengthSec);
  return TransitionLaneView(startSec: overlapStartSec - margin, viewSec: lengthSec + 2 * margin, widthPx: widthPx);
}

/// Zona de píxeles que ocupa la mezcla: `left`..`left + width`.
({double left, double width}) overlapPixelRange({required double lengthSec, required double widthPx}) {
  final margin = transitionLaneMargin(lengthSec);
  final view = lengthSec + 2 * margin;
  return (left: margin / view * widthPx, width: lengthSec / view * widthPx);
}

// ---- Arrastre de una onda ----

enum TransitionSnap { bar, beat, free }

enum LaneLimit { none, start, end }

class LaneDragResult {
  const LaneDragResult(this.sec, this.limit, {this.snapped = false});
  final double sec;

  /// Qué borde se tocó (el valor pedido quedaba fuera), para avisarlo en vez de callar.
  final LaneLimit limit;
  final bool snapped;
}

/// Arrastrar la onda [dxPx] hacia la derecha trae un punto anterior de la
/// canción bajo la mezcla: el inicio retrocede. Acotado a [minSec]..[maxSec] y,
/// con ritmo detectado, pegado al pulso o al compás.
LaneDragResult dragLaneStart({
  required double startAtGrab,
  required double dxPx,
  required double viewSec,
  required double widthPx,
  required double minSec,
  required double maxSec,
  SongAnalysis? analysis,
  TransitionSnap snap = TransitionSnap.free,
}) {
  final hi = math.max(minSec, maxSec);
  if (!startAtGrab.isFinite || !dxPx.isFinite || widthPx <= 0) {
    return LaneDragResult(startAtGrab.isFinite ? startAtGrab.clamp(minSec, hi).toDouble() : minSec, LaneLimit.none);
  }
  final raw = startAtGrab - dxPx / widthPx * viewSec;
  final limit = raw < minSec - 1e-9 ? LaneLimit.start : (raw > hi + 1e-9 ? LaneLimit.end : LaneLimit.none);
  final clamped = raw.clamp(minSec, hi).toDouble();
  if (snap == TransitionSnap.free || analysis == null || !hasUsableTempo(analysis)) {
    return LaneDragResult(clamped, limit);
  }
  final s = snapToGrid(raw, analysis, downbeat: snap == TransitionSnap.bar, minSec: minSec, maxSec: hi);
  return LaneDragResult(s, limit, snapped: true);
}

/// Empujón fino, sin pegar a nada ("sin pegado": ±10 ms).
LaneDragResult nudgeLaneStart({required double sec, required double deltaSec, required double minSec, required double maxSec}) {
  final hi = math.max(minSec, maxSec);
  final raw = sec + deltaSec;
  final limit = raw < minSec - 1e-9 ? LaneLimit.start : (raw > hi + 1e-9 ? LaneLimit.end : LaneLimit.none);
  return LaneDragResult(raw.clamp(minSec, hi).toDouble(), limit);
}

/// Dónde puede empezar la mezcla en la canción que sale: no pasa del final.
({double min, double max}) outgoingStartRange({required double outDurationSec, required double lengthSec}) =>
    (min: 0, max: math.max(0.0, outDurationSec - lengthSec));

/// En la que entra hace falta margen extra si se estira el tempo.
({double min, double max}) incomingStartRange({
  required double inDurationSec,
  required double lengthSec,
  TransitionTempoMatch tempoMatch = TransitionTempoMatch.none,
}) {
  final factor = tempoMatch == TransitionTempoMatch.matchIncoming ? 1 + kTransitionMaxTempoShift : 1.0;
  return (min: 0, max: math.max(0.0, inDurationSec - lengthSec * factor));
}

/// Cambia la duración manteniendo los dos inicios dentro de lo que cabe.
SongTransition transitionWithLength(SongTransition t, double lengthSec, {required double outDurationSec, required double inDurationSec}) {
  final len = lengthSec.clamp(kTransitionMinLengthSec, kTransitionMaxLengthSec).toDouble();
  final o = outgoingStartRange(outDurationSec: outDurationSec, lengthSec: len);
  final i = incomingStartRange(inDurationSec: inDurationSec, lengthSec: len, tempoMatch: t.tempoMatch);
  return t.copyWith(
    lengthSec: len,
    outStartSec: t.outStartSec.clamp(o.min, o.max).toDouble(),
    inStartSec: t.inStartSec.clamp(i.min, i.max).toDouble(),
  );
}

/// Dos transiciones iguales en todo lo que se guarda.
bool sameTransition(SongTransition? a, SongTransition? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return jsonEncode(a.toJson()) == jsonEncode(b.toJson());
}

/// Qué opción de la lista de duraciones es la actual (por cercanía), o -1.
int selectedLengthIndex(List<TransitionLengthOption> options, double lengthSec) {
  for (var i = 0; i < options.length; i++) {
    if ((options[i].seconds - lengthSec).abs() < 0.05) return i;
  }
  return -1;
}

/// `m:ss.d`.
String timeWithTenths(double sec) {
  final s = sec.isFinite && sec > 0 ? sec : 0.0;
  final tenths = (s * 10).round();
  final whole = tenths ~/ 10;
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}.${tenths % 10}';
}

// ---- Escala en dB y lectura de las ondas ----

const kTransitionWaveFloorDb = -48.0;
const kTransitionDbGridlines = [0.0, -6.0, -12.0, -24.0];

/// Fracción (0..1) de media altura que ocupa [db] en la escala de la onda.
double dbToFraction(double db, {double floorDb = kTransitionWaveFloorDb}) =>
    db.isFinite ? ((db - floorDb) / (0 - floorDb)).clamp(0.0, 1.0).toDouble() : 0;

double fractionToDb(double f, {double floorDb = kTransitionWaveFloorDb}) => floorDb + f.clamp(0.0, 1.0) * (0 - floorDb);

/// Y de [db] en la mitad de arriba de una onda con centro en [centerY] y media altura [halfH].
double dbToY(double db, {required double centerY, required double halfH, double floorDb = kTransitionWaveFloorDb}) =>
    centerY - dbToFraction(db, floorDb: floorDb) * halfH;

/// dB de la Y [y] (de la mitad de arriba o su espejo).
double yToDb(double y, {required double centerY, required double halfH, double floorDb = kTransitionWaveFloorDb}) =>
    halfH <= 0 ? floorDb : fractionToDb((centerY - y).abs() / halfH, floorDb: floorDb);

enum TransitionLevelKind { rms, peak, low, mid, high }

List<double> _levels(TransitionWaveform w, TransitionLevelKind k) => switch (k) {
      TransitionLevelKind.rms => w.rmsDb,
      TransitionLevelKind.peak => w.peakDb,
      TransitionLevelKind.low => w.lowDb,
      TransitionLevelKind.mid => w.midDb,
      TransitionLevelKind.high => w.highDb,
    };

/// Resumen de nivel que cubre [t0]..[t1]: el detalle (final o principio) si cabe, si no la vista general.
({TransitionWaveform wave, double offsetSec}) waveformSourceFor(TransitionSongProfile p, {required bool outgoing, required double t0, required double t1}) {
  final detail = outgoing ? p.outro : p.intro;
  final off = outgoing ? p.outroOffsetSec : 0.0;
  if (detail.length > 0 && t0 >= off - 1e-6 && t1 <= off + detail.durationSec + 1e-6) {
    return (wave: detail, offsetSec: off);
  }
  return (wave: p.overview, offsetSec: 0.0);
}

/// Nivel más alto (dB) entre [t0] y [t1] de la canción; `null` fuera de ella o sin datos.
double? waveformColumnDb(TransitionSongProfile p, {required bool outgoing, required double t0, required double t1, TransitionLevelKind kind = TransitionLevelKind.rms}) {
  if (t1 < 0 || t0 > p.durationSec) return null;
  final src = waveformSourceFor(p, outgoing: outgoing, t0: math.max(0.0, t0), t1: math.min(p.durationSec, t1));
  final list = _levels(src.wave, kind);
  if (list.isEmpty) return null;
  final pps = src.wave.pointsPerSecond;
  final a = ((math.max(0.0, t0) - src.offsetSec) * pps).floor().clamp(0, list.length - 1).toInt();
  final b = ((math.min(p.durationSec, t1) - src.offsetSec) * pps).floor().clamp(a, list.length - 1).toInt();
  var best = list[a];
  for (var i = a + 1; i <= b; i++) {
    if (list[i] > best) best = list[i];
  }
  return best;
}

// ---- Curvas: qué línea es cuál ----

enum TransitionCurveKind { volume, low, mid, high, filter, echo }

TransitionLaneGroup groupOfCurveKind(TransitionCurveKind k) => switch (k) {
      TransitionCurveKind.volume => TransitionLaneGroup.volume,
      TransitionCurveKind.low || TransitionCurveKind.mid || TransitionCurveKind.high => TransitionLaneGroup.eq,
      TransitionCurveKind.filter || TransitionCurveKind.echo => TransitionLaneGroup.effect,
    };

TransitionCurve curveOfKind(TransitionLanes l, TransitionCurveKind k) => switch (k) {
      TransitionCurveKind.volume => l.volumeDb,
      TransitionCurveKind.low => l.lowDb,
      TransitionCurveKind.mid => l.midDb,
      TransitionCurveKind.high => l.highDb,
      TransitionCurveKind.filter => l.filter,
      TransitionCurveKind.echo => l.echo,
    };

TransitionLanes lanesWithCurve(TransitionLanes l, TransitionCurveKind k, TransitionCurve c) => switch (k) {
      TransitionCurveKind.volume => l.copyWith(volumeDb: c),
      TransitionCurveKind.low => l.copyWith(lowDb: c),
      TransitionCurveKind.mid => l.copyWith(midDb: c),
      TransitionCurveKind.high => l.copyWith(highDb: c),
      TransitionCurveKind.filter => l.copyWith(filter: c),
      TransitionCurveKind.echo => l.copyWith(echo: c),
    };

bool curveKindIsDb(TransitionCurveKind k) => k != TransitionCurveKind.filter && k != TransitionCurveKind.echo;

({double min, double max}) curveKindRange(TransitionCurveKind k) => switch (k) {
      TransitionCurveKind.filter => (min: -1.0, max: 1.0),
      TransitionCurveKind.echo => (min: 0.0, max: 1.0),
      _ => (min: kTransitionMinDb, max: kTransitionMaxDb),
    };

/// Valor que dibuja la línea en [x] (0..1): dB reales, con el suelo de -60.
double curveDrawValue(TransitionCurve c, TransitionCurveKind k, double x) => curveKindIsDb(k) ? c.dbAt(x) : c.valueAt(x);

double curveValueToFraction(TransitionCurveKind k, double v) {
  final r = curveKindRange(k);
  return ((r.max - v) / (r.max - r.min)).clamp(0.0, 1.0).toDouble();
}

double fractionToCurveValue(TransitionCurveKind k, double f) {
  final r = curveKindRange(k);
  return r.max - f.clamp(0.0, 1.0) * (r.max - r.min);
}

/// Cerca de la unidad o del silencio el valor se pega, para que "sin cambio" y "apagado" sean fáciles de acertar.
double snapCurveValue(TransitionCurveKind k, double v) {
  final r = curveKindRange(k);
  final c = v.clamp(r.min, r.max).toDouble();
  switch (k) {
    case TransitionCurveKind.filter:
      return c.abs() < 0.04 ? 0 : c;
    case TransitionCurveKind.echo:
      return c < 0.03 ? 0 : (c > 0.97 ? 1 : c);
    default:
      if (c.abs() < 0.8) return 0;
      if (c < r.min + 1.5) return r.min;
      return c;
  }
}

/// El marco de píxeles donde se dibujan las curvas: la zona de la mezcla de una onda.
class CurveFrame {
  const CurveFrame({required this.left, required this.width, required this.height});
  final double left, width, height;

  double xOf(double x01) => left + x01 * width;
  double x01Of(double px) => width <= 0 ? 0 : ((px - left) / width).clamp(0.0, 1.0).toDouble();
  double yOf(TransitionCurveKind k, double v) => curveValueToFraction(k, v) * height;
  double valueOfY(TransitionCurveKind k, double y) => fractionToCurveValue(k, height <= 0 ? 0 : y / height);
}

/// Radio (px) en el que un toque agarra un punto.
const kCurvePointHitRadius = 20.0;

/// Punto de [c] más cercano a ([px], [py]) dentro del radio, o -1.
int hitTestCurvePoint(TransitionCurve c, TransitionCurveKind k, CurveFrame f, double px, double py, {double radius = kCurvePointHitRadius}) {
  var best = -1;
  var bestD = radius * radius;
  for (var i = 0; i < c.points.length; i++) {
    final p = c.points[i];
    final dx = f.xOf(p.x) - px, dy = f.yOf(k, p.value) - py;
    final d = dx * dx + dy * dy;
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/// La curva con su forma convertida en puntos que la dibujan igual: así, al editar a mano una forma con nombre, no pega un salto.
TransitionCurve bakeCurve(TransitionCurve c, TransitionCurveKind k, {int samples = 7}) {
  if (c.shape == TransitionCurveShape.linear) return c;
  return TransitionCurve([
    for (var i = 0; i < samples; i++) TransitionPoint(i / (samples - 1), curveDrawValue(c, k, i / (samples - 1))),
  ]);
}

/// Mueve el punto [index] a la posición de píxel ([px], [py]): su x no cruza a los vecinos y el valor se acota y se pega.
TransitionCurve dragCurvePoint(TransitionCurve c, int index, TransitionCurveKind k, CurveFrame f, double px, double py) {
  if (index < 0 || index >= c.points.length) return c;
  final pts = [...c.points];
  final lo = index == 0 ? 0.0 : pts[index - 1].x;
  final hi = index == pts.length - 1 ? 1.0 : pts[index + 1].x;
  final x = f.x01Of(px).clamp(lo, hi).toDouble();
  pts[index] = TransitionPoint(x, snapCurveValue(k, f.valueOfY(k, py)));
  return TransitionCurve(pts);
}

/// Añade un punto en [x01] con el valor que la línea ya tenía allí.
TransitionCurve addCurvePoint(TransitionCurve c, TransitionCurveKind k, double x01) {
  final base = bakeCurve(c, k);
  final x = x01.clamp(0.0, 1.0).toDouble();
  return TransitionCurve([...base.points, TransitionPoint(x, curveDrawValue(base, k, x))]);
}

/// Quita el punto [index]; una línea conserva al menos dos.
TransitionCurve removeCurvePoint(TransitionCurve c, int index) {
  if (c.points.length <= 2 || index < 0 || index >= c.points.length) return c;
  return TransitionCurve([for (var i = 0; i < c.points.length; i++) if (i != index) c.points[i]]);
}

/// [t] con la línea [k] de la canción que sale o la que entra cambiada a mano.
SongTransition transitionWithCurve(SongTransition t, {required bool outgoing, required TransitionCurveKind k, required TransitionCurve curve}) {
  final next = outgoing
      ? t.copyWith(outLanes: lanesWithCurve(t.outLanes, k, curve))
      : t.copyWith(inLanes: lanesWithCurve(t.inLanes, k, curve));
  return markLaneEdited(groupOfCurveKind(k), next);
}

// ---- Escucha: dónde va la reproducción ----

/// Por dónde va el clip dentro de la mezcla: 0 al empezar el solape y 1 al acabar (sin acotar).
double playheadFraction({required double positionSec, required double overlapStartInClipSec, required double overlapSec}) =>
    overlapSec <= 0 ? 0 : (positionSec - overlapStartInClipSec) / overlapSec;

/// X de la línea de reproducción en una onda de [laneWidthPx], acotada a la onda.
double playheadX(double fraction, {required double lengthSec, required double laneWidthPx}) {
  final r = overlapPixelRange(lengthSec: lengthSec, widthPx: laneWidthPx);
  return (r.left + fraction * r.width).clamp(0.0, laneWidthPx).toDouble();
}

// ---- Deshacer ----

/// Pila de estados anteriores del borrador. Un gesto largo (arrastrar) guarda un solo paso.
class TransitionDraftHistory {
  TransitionDraftHistory({this.limit = 60});
  final int limit;
  final _stack = <SongTransition>[];

  bool get canUndo => _stack.isNotEmpty;
  int get length => _stack.length;
  SongTransition? get last => _stack.isEmpty ? null : _stack.last;

  void push(SongTransition t) {
    _stack.add(t);
    if (_stack.length > limit) _stack.removeAt(0);
  }

  SongTransition? pop() => _stack.isEmpty ? null : _stack.removeLast();

  void clear() => _stack.clear();
}

/// Estilo elegido, o `null` si se tocó algo a mano.
String? presetIdOf(SongTransition t) => transitionPresetById(t.presetId) == null ? null : t.presetId;
