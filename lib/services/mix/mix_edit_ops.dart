// Operaciones puras del editor avanzado del Mix DJ sobre un [MixEditPlan]:
// mover, dividir, unir, quitar, duplicar, cambiar volumen, capa o canción de un
// tramo, añadir un fragmento y fijar el tono. Ninguna lanza: un índice o un
// valor fuera de rango deja el plan igual o lo acota. El editor es permisivo
// (puede dejar tramos que se pisan), y [validateEditPlan] avisa de ello.
import 'dart:math' as math;

import 'mix_edit_plan.dart';
import 'mix_types.dart';

/// Rango de volumen por tramo que ofrece el editor (dB).
const kEditMinGainDb = -24.0, kEditMaxGainDb = 12.0;

/// Tamaños de la rejilla del plan: compases de cada canción y de la línea de
/// tiempo (la de la canción base).
class MixEditBounds {
  const MixEditBounds({required this.barsA, required this.barsB, required this.timelineBars});

  factory MixEditBounds.of(MixEditPlan plan, {required int barsA, required int barsB}) =>
      MixEditBounds(barsA: barsA, barsB: barsB, timelineBars: plan.baseSong == 'b' ? barsB : barsA);

  final int barsA, barsB, timelineBars;

  int songBars(String song) => song == 'a' ? barsA : barsB;
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

bool _valid(MixEditPlan p, int i) => i >= 0 && i < p.segments.length;

MixEditPlan _replace(MixEditPlan p, int i, MixEditSegment s) {
  final segs = [...p.segments];
  segs[i] = s;
  return p.copyWith(segments: segs);
}

/// Índice del último tramo (con duración) que cubre el compás [bar] de salida, o -1.
int segmentAtBar(MixEditPlan p, int bar) {
  for (var i = p.segments.length - 1; i >= 0; i--) {
    final s = p.segments[i];
    if (s.bars > 0 && bar >= s.outBar && bar < s.endBar) return i;
  }
  return -1;
}

/// Mueve el tramo [i] [deltaBars] compases en la salida, sin salirse de la línea de tiempo.
MixEditPlan moveSegment(MixEditPlan p, int i, int deltaBars, MixEditBounds b) {
  if (!_valid(p, i)) return p;
  final s = p.segments[i];
  final out = _clampInt(s.outBar + deltaBars, 0, math.max(0, b.timelineBars - s.bars));
  return out == s.outBar ? p : _replace(p, i, s.copyWith(outBar: out));
}

/// Coloca el tramo [i] en el compás de salida [outBar] (arrastre), sin salirse de la línea de tiempo.
MixEditPlan moveSegmentTo(MixEditPlan p, int i, int outBar, MixEditBounds b) =>
    _valid(p, i) ? moveSegment(p, i, outBar - p.segments[i].outBar, b) : p;

/// Arrastre del borde derecho: el tramo [i] termina en [endBar]. Dura al menos
/// un compás y no pasa del final de su canción ni de la línea de tiempo.
MixEditPlan resizeSegmentEnd(MixEditPlan p, int i, int endBar, MixEditBounds b) {
  if (!_valid(p, i)) return p;
  final s = p.segments[i];
  final room = math.min(b.songBars(s.song) - s.sourceBar, b.timelineBars - s.outBar);
  final bars = _clampInt(endBar - s.outBar, 1, math.max(1, room));
  return bars == s.bars ? p : _replace(p, i, s.copyWith(bars: bars, toEnd: false));
}

/// Arrastre del borde izquierdo: el tramo [i] empieza en [outBar] y el audio
/// que ya sonaba se queda en su sitio (el origen se mueve lo mismo). No pasa del
/// inicio de la canción ni de la línea de tiempo, y deja al menos un compás.
MixEditPlan resizeSegmentStart(MixEditPlan p, int i, int outBar, MixEditBounds b) {
  if (!_valid(p, i)) return p;
  final s = p.segments[i];
  final delta = _clampInt(outBar - s.outBar, -math.min(s.sourceBar, s.outBar), s.bars - 1);
  if (delta == 0) return p;
  return _replace(p, i, s.copyWith(sourceBar: s.sourceBar + delta, outBar: s.outBar + delta, bars: s.bars - delta));
}

/// Parte el tramo [i] en el compás de salida [atBar] (debe quedar dentro del
/// tramo, ni en su primer compás ni fuera). El adelanto de voz se queda con la primera mitad.
MixEditPlan splitSegment(MixEditPlan p, int i, int atBar) {
  if (!_valid(p, i)) return p;
  final s = p.segments[i];
  if (atBar <= s.outBar || atBar >= s.endBar) return p;
  final k = atBar - s.outBar;
  final first = s.copyWith(bars: k, toEnd: false);
  final second = s.copyWith(sourceBar: s.sourceBar + k, outBar: atBar, bars: s.bars - k, leadInBars: 0);
  final segs = [...p.segments]..replaceRange(i, i + 1, [first, second]);
  return p.copyWith(segments: segs);
}

/// Tramo que continúa exactamente al [i] (misma canción y capa, pegado en la
/// salida y en el origen), o -1.
int mergeCandidate(MixEditPlan p, int i) {
  if (!_valid(p, i)) return -1;
  final s = p.segments[i];
  for (var j = 0; j < p.segments.length; j++) {
    final n = p.segments[j];
    if (j != i && n.song == s.song && n.layer == s.layer && n.outBar == s.endBar && n.sourceBar == s.sourceBar + s.bars) {
      return j;
    }
  }
  return -1;
}

/// Une el tramo [i] con el que lo continúa ([mergeCandidate]); sin candidato no hace nada.
MixEditPlan mergeSegment(MixEditPlan p, int i) {
  final j = mergeCandidate(p, i);
  if (j < 0) return p;
  final s = p.segments[i], n = p.segments[j];
  final merged = s.copyWith(bars: s.bars + n.bars, toEnd: n.toEnd);
  final segs = [...p.segments];
  segs[i] = merged;
  segs.removeAt(j);
  return p.copyWith(segments: segs);
}

MixEditPlan deleteSegment(MixEditPlan p, int i) {
  if (!_valid(p, i)) return p;
  return p.copyWith(segments: [...p.segments]..removeAt(i));
}

/// Copia el tramo [i] justo a continuación (o lo más tarde que quepa) y la deja detrás del original.
MixEditPlan duplicateSegment(MixEditPlan p, int i, MixEditBounds b) {
  if (!_valid(p, i)) return p;
  final s = p.segments[i];
  final out = _clampInt(s.endBar, 0, math.max(0, b.timelineBars - s.bars));
  final copy = s.copyWith(outBar: out, leadInBars: 0);
  return p.copyWith(segments: [...p.segments]..insert(i + 1, copy));
}

MixEditPlan setSegmentGain(MixEditPlan p, int i, double db) {
  if (!_valid(p, i) || !db.isFinite) return p;
  return _replace(p, i, p.segments[i].copyWith(gainDb: db.clamp(kEditMinGainDb, kEditMaxGainDb).toDouble()));
}

MixEditPlan setSegmentLayer(MixEditPlan p, int i, MixLayer layer) {
  if (!_valid(p, i) || p.segments[i].layer == layer) return p;
  return _replace(p, i, p.segments[i].copyWith(layer: layer));
}

/// Cambia la canción de origen del tramo [i]; acota el compás de origen y la
/// duración a lo que tiene esa canción.
MixEditPlan setSegmentSong(MixEditPlan p, int i, String song, MixEditBounds b) {
  if (!_valid(p, i) || (song != 'a' && song != 'b') || p.segments[i].song == song) return p;
  final s = p.segments[i];
  final sb = b.songBars(song);
  if (sb <= 0) return p;
  final src = _clampInt(s.sourceBar, 0, sb - 1);
  return _replace(p, i, s.copyWith(song: song, sourceBar: src, bars: math.min(s.bars, sb - src), toEnd: false));
}

/// Añade al final de la lista un fragmento de [song]: [bars] compases desde
/// [fromBar] de la canción, colocado en el compás [atBar] de la salida. Todo se
/// acota a la canción y a la línea de tiempo.
MixEditPlan addFragment(
  MixEditPlan p, {
  required String song,
  required MixLayer layer,
  required int fromBar,
  required int bars,
  required int atBar,
  required MixEditBounds b,
}) {
  if (song != 'a' && song != 'b') return p;
  final sb = b.songBars(song);
  if (sb <= 0 || b.timelineBars <= 0) return p;
  final from = _clampInt(fromBar, 0, sb - 1);
  final n = _clampInt(bars, 1, math.min(sb - from, b.timelineBars));
  final at = _clampInt(atBar, 0, b.timelineBars - n);
  final seg = MixEditSegment(song: song, layer: layer, sourceBar: from, outBar: at, bars: n);
  return p.copyWith(segments: [...p.segments, seg]);
}

/// Compás de salida donde poner un fragmento nuevo: detrás del tramo
/// [selected] si lo hay, y si no al final del último tramo.
int nextFragmentBar(MixEditPlan p, int selected) {
  if (_valid(p, selected)) return p.segments[selected].endBar;
  return p.segments.fold(0, (m, s) => math.max(m, s.endBar));
}

MixEditPlan setSemitones(MixEditPlan p, String song, int semitones) {
  final v = _clampInt(semitones, -kMixMaxSemitones, kMixMaxSemitones);
  return switch (song) {
    'a' => v == p.semitonesA ? p : p.copyWith(semitonesA: v),
    'b' => v == p.semitonesB ? p : p.copyWith(semitonesB: v),
    _ => p,
  };
}
