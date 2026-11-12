import 'dart:math' as math;
import 'dart:typed_data';

import '../mix/mix_analysis.dart' show SongAnalysis;
import '../mix/mix_dsp.dart';
import 'transition_render.dart' show kTransitionHighCrossoverHz, kTransitionLowCrossoverHz;

const kTransitionWaveformFloorDb = -90.0;

/// Levels of an excerpt for drawing: one value per point, all in dBFS, floored at -90.
class TransitionWaveform {
  const TransitionWaveform({
    required this.pointsPerSecond,
    required this.durationSec,
    required this.rmsDb,
    required this.peakDb,
    required this.lowDb,
    required this.midDb,
    required this.highDb,
  });
  final int pointsPerSecond;
  final double durationSec;

  /// RMS and sample peak of the full signal.
  final List<double> rmsDb, peakDb;

  /// RMS of each band (same crossovers as the renderer's EQ lanes).
  final List<double> lowDb, midDb, highDb;

  int get length => rmsDb.length;
}

double _db(double x) => x <= 0 ? kTransitionWaveformFloorDb : math.max(kTransitionWaveformFloorDb, dbOf(x));

TransitionWaveform analyzeForTransition(Clip pcm, int sampleRate, {int pointsPerSecond = 20}) {
  final pps = math.max(1, pointsPerSecond);
  final n = math.min(pcm.l.length, pcm.r.length);
  final hop = math.max(1, (sampleRate / pps).round());
  final count = (n / hop).ceil();
  final mono = Float32List(n);
  for (var i = 0; i < n; i++) {
    mono[i] = 0.5 * (pcm.l[i] + pcm.r[i]);
  }
  Float32List lr4(Float32List v, double fc, bool high) {
    Biquad f() => high ? Biquad.highpass(fc, sampleRate) : Biquad.lowpass(fc, sampleRate);
    return f().apply(f().apply(v));
  }

  final low = lr4(mono, kTransitionLowCrossoverHz, false);
  final rest = lr4(mono, kTransitionLowCrossoverHz, true);
  final mid = lr4(rest, kTransitionHighCrossoverHz, false);
  final high = lr4(rest, kTransitionHighCrossoverHz, true);
  final rms = Float32List(count), peak = Float32List(count);
  final lo = Float32List(count), mi = Float32List(count), hi = Float32List(count);
  for (var k = 0; k < count; k++) {
    final a = k * hop, b = math.min(n, a + hop);
    var e = 0.0, p = 0.0, el = 0.0, em = 0.0, eh = 0.0;
    for (var i = a; i < b; i++) {
      final x = pcm.l[i], y = pcm.r[i];
      e += x * x + y * y;
      p = math.max(p, math.max(x.abs(), y.abs()));
      el += low[i] * low[i];
      em += mid[i] * mid[i];
      eh += high[i] * high[i];
    }
    final m = b - a;
    rms[k] = _db(math.sqrt(e / (2 * m)));
    peak[k] = _db(p);
    lo[k] = _db(math.sqrt(el / m));
    mi[k] = _db(math.sqrt(em / m));
    hi[k] = _db(math.sqrt(eh / m));
  }
  return TransitionWaveform(
    pointsPerSecond: pps,
    durationSec: n / sampleRate,
    rmsDb: rms,
    peakDb: peak,
    lowDb: lo,
    midDb: mi,
    highDb: hi,
  );
}

/// Beats and bar starts of a song inside a time window.
class TransitionBeatGrid {
  const TransitionBeatGrid({required this.beats, required this.downbeats, required this.beatSec, required this.barSec});
  static const empty = TransitionBeatGrid(beats: [], downbeats: [], beatSec: 0, barSec: 0);

  /// Every beat in the window, downbeats included.
  final List<double> beats;
  final List<double> downbeats;
  final double beatSec, barSec;
}

bool hasUsableTempo(SongAnalysis a) => a.bpm.isFinite && a.bpm >= 30 && a.bpm <= 400 && a.downbeatSec.isFinite;

/// The grid of [a] between [startSec] and [endSec] (4 beats per bar). It extends before the first detected
/// downbeat, never before 0. Empty when the tempo is unusable.
TransitionBeatGrid beatGridInWindow(SongAnalysis a, double startSec, double endSec) {
  if (!hasUsableTempo(a) || !startSec.isFinite || !endSec.isFinite || endSec < startSec) {
    return TransitionBeatGrid.empty;
  }
  final beat = 60 / a.bpm;
  final from = math.max(0.0, startSec);
  final beats = <double>[], downbeats = <double>[];
  for (var k = ((from - a.downbeatSec) / beat).ceil(); beats.length < 4000; k++) {
    final t = a.downbeatSec + k * beat;
    if (t > endSec + 1e-9) break;
    if (t < from - 1e-9) continue;
    beats.add(t);
    if (k % 4 == 0) downbeats.add(t);
  }
  return TransitionBeatGrid(beats: beats, downbeats: downbeats, beatSec: beat, barSec: 4 * beat);
}

/// [sec] moved to the nearest beat, or downbeat, of [a] inside [minSec]..[maxSec]. Returns [sec] (clamped) when
/// the tempo is unusable or no grid line fits the range.
double snapToGrid(double sec, SongAnalysis a, {bool downbeat = false, double minSec = 0, double? maxSec}) {
  final hi = maxSec ?? double.infinity;
  final safe = sec.isFinite ? sec : minSec;
  final clamped = hi < minSec ? minSec : safe.clamp(minSec, hi).toDouble();
  if (!hasUsableTempo(a)) return clamped;
  final step = (downbeat ? 240 : 60) / a.bpm;
  var k = ((clamped - a.downbeatSec) / step).round();
  if (a.downbeatSec + k * step < minSec - 1e-9) k = ((minSec - a.downbeatSec) / step).ceil();
  if (a.downbeatSec + k * step > hi + 1e-9) k = ((hi - a.downbeatSec) / step).floor();
  final t = a.downbeatSec + k * step;
  return t < minSec - 1e-9 || t > hi + 1e-9 ? clamped : t;
}
