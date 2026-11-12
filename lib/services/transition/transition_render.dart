import 'dart:math' as math;
import 'dart:typed_data';

import '../mix/mix_dsp.dart';
import '../mix/mix_mastering.dart' show limit, truePeak;
import 'transition_model.dart';

const kTransitionLowCrossoverHz = 200.0;
const kTransitionHighCrossoverHz = 2500.0;

/// Share of the overlap, at its end, where a tempo-matched incoming song glides back to its own tempo.
const kTransitionTempoGlideFraction = 0.25;

const _ceilingDb = -1.5;
const _truePeakCeilingDb = -1.0;
const _block = 64;

enum TransitionRenderNote {
  /// The PCM given was shorter than the transition asked for; the overlap shrank.
  overlapShortened,

  /// matchIncoming was requested without both tempos.
  tempoMatchMissingBpm,

  /// matchIncoming was requested but the tempos are more than [kTransitionMaxTempoShift] apart.
  tempoMatchOutOfRange,

  /// The safety limiter had to act on the overlap.
  limited,
}

class TransitionRenderResult {
  const TransitionRenderResult({
    required this.pcm,
    required this.sampleRate,
    required this.clipStartInOutgoingSec,
    required this.overlapStartInClipSec,
    required this.overlapSec,
    required this.handoverInClipSec,
    required this.handoverInIncomingSec,
    required this.resumeInIncomingSec,
    required this.tempoRatio,
    required this.tempoMatchApplied,
    required this.peakDb,
    required this.notes,
  });

  /// Pre-roll of the outgoing song, the overlap, post-roll of the incoming song.
  final Clip pcm;
  final int sampleRate;

  /// Position in the outgoing song of the first sample of the clip.
  final double clipStartInOutgoingSec;
  final double overlapStartInClipSec;

  /// Overlap actually rendered (shorter than asked when the PCM ran out).
  final double overlapSec;

  /// Start of the post-roll: from here on the clip is the incoming song, untouched.
  final double handoverInClipSec;
  final double handoverInIncomingSec;

  /// Position in the incoming song that matches the end of the clip.
  final double resumeInIncomingSec;

  /// Speed applied to the incoming song at the start of the overlap (1 = untouched).
  final double tempoRatio;
  final bool tempoMatchApplied;

  /// True peak of the overlap, dBFS.
  final double peakDb;
  final Set<TransitionRenderNote> notes;

  double get clipSec => pcm.length / sampleRate;
}

/// Outgoing over incoming tempo, folded by octaves so that half/double-time readings compare. Null when a
/// tempo is missing or not usable.
double? transitionTempoRatio(double? outBpm, double? inBpm) {
  if (outBpm == null || inBpm == null || !outBpm.isFinite || !inBpm.isFinite || outBpm <= 0 || inBpm <= 0) {
    return null;
  }
  var r = outBpm / inBpm;
  while (r > 1.42) {
    r /= 2;
  }
  while (r < 0.71) {
    r *= 2;
  }
  return r;
}

Float32List _lr4(Float32List v, double fc, int sr, {required bool high}) {
  Biquad f() => high ? Biquad.highpass(fc, sr) : Biquad.lowpass(fc, sr);
  return f().apply(f().apply(v));
}

Float32List _sum(Float32List a, Float32List b) {
  final y = Float32List(a.length);
  for (var i = 0; i < a.length; i++) {
    y[i] = a[i] + b[i];
  }
  return y;
}

/// Low, mid and high bands with Linkwitz-Riley 4th-order crossovers. The low band also goes through the upper
/// crossover as an all-pass, so the three bands add up to an all-pass of [x]: flat in level at every frequency.
(Clip, Clip, Clip) splitThreeBands(
  Clip x,
  int sr, {
  double lowHz = kTransitionLowCrossoverHz,
  double highHz = kTransitionHighCrossoverHz,
}) {
  (Float32List, Float32List, Float32List) one(Float32List v) {
    final low = _lr4(v, lowHz, sr, high: false);
    final rest = _lr4(v, lowHz, sr, high: true);
    return (
      _sum(_lr4(low, highHz, sr, high: false), _lr4(low, highHz, sr, high: true)),
      _lr4(rest, highHz, sr, high: false),
      _lr4(rest, highHz, sr, high: true),
    );
  }

  final l = one(x.l);
  final r = identical(x.l, x.r) ? l : one(x.r);
  return (Clip(l.$1, r.$1), Clip(l.$2, r.$2), Clip(l.$3, r.$3));
}

/// Per-sample automation: the curve is read every [_block] samples and joined with straight lines, so a step in
/// the curve becomes a ~1.5 ms ramp instead of a click.
Float32List _automation(int n, double Function(double x) at) {
  final out = Float32List(n);
  var a = at(0);
  for (var s = 0; s < n; s += _block) {
    final e = math.min(n, s + _block);
    final b = at(e / n);
    for (var j = s; j < e; j++) {
      out[j] = a + (b - a) * (j - s) / (e - s);
    }
    a = b;
  }
  return out;
}

/// Two cascaded state-variable filters (stable under modulation) swept by [amt]: below 0 a low-pass closing
/// from 20 kHz to 150 Hz, above 0 a high-pass opening from 20 Hz to 6 kHz. Exactly 0 leaves the sample as is.
void _sweepFilter(Float32List v, Float32List amt, int sr) {
  const k = 1.4142135623730951;
  var a1 = 0.0, a2 = 0.0, a3 = 0.0;
  var p1 = 0.0, p2 = 0.0, q1 = 0.0, q2 = 0.0;
  for (var i = 0; i < v.length; i++) {
    final a = amt[i];
    if (i % _block == 0) {
      final m = a.abs();
      final fc = a < 0 ? 20000 * math.pow(150 / 20000, m) : 20 * math.pow(6000 / 20, m);
      final g = math.tan(math.pi * math.min(fc, 0.45 * sr) / sr);
      a1 = 1 / (1 + g * (g + k));
      a2 = g * a1;
      a3 = g * a2;
    }
    final x = v[i];
    var v3 = x - p2;
    var v1 = a1 * p1 + a2 * v3;
    var v2 = p2 + a2 * p1 + a3 * v3;
    p1 = 2 * v1 - p1;
    p2 = 2 * v2 - p2;
    final y = a < 0 ? v2 : x - k * v1 - v2;
    v3 = y - q2;
    v1 = a1 * q1 + a2 * v3;
    v2 = q2 + a2 * q1 + a3 * v3;
    q1 = 2 * v1 - q1;
    q2 = 2 * v2 - q2;
    if (a == 0) continue;
    final z = a < 0 ? v2 : y - k * v1 - v2;
    final w = math.min(1.0, a.abs() / 0.02);
    v[i] = x + w * (z - x);
  }
}

double _echoDelaySec(double? bpm) {
  if (bpm == null || !bpm.isFinite || bpm < 30 || bpm > 400) return 0.3;
  var d = 30 / bpm;
  while (d < 0.18) {
    d *= 2;
  }
  while (d > 0.5) {
    d /= 2;
  }
  return d;
}

/// Feedback delay fed by [send]. Its return fades out over the last tenth of the overlap so that nothing rings
/// into the post-roll, which must stay identical to the source.
void _echo(Float32List l, Float32List r, Float32List send, int sr, double? bpm) {
  final n = l.length;
  final d = math.max(1, (_echoDelaySec(bpm) * sr).round());
  final bl = Float32List(d), br = Float32List(d);
  final tail = math.min(n, math.max((0.05 * sr).round(), n ~/ 10));
  var p = 0, dampL = 0.0, dampR = 0.0;
  for (var i = 0; i < n; i++) {
    final dl = bl[p], dr = br[p];
    dampL += 0.4 * (dl - dampL);
    dampR += 0.4 * (dr - dampR);
    bl[p] = l[i] * send[i] + 0.55 * dampL;
    br[p] = r[i] * send[i] + 0.55 * dampR;
    final ret = i < n - tail ? 1.0 : (n - i) / tail;
    l[i] += dl * ret;
    r[i] += dr * ret;
    p = p + 1 == d ? 0 : p + 1;
  }
}

Clip _processSong(Clip x, TransitionLanes lanes, int sr, double? bpm) {
  final n = x.length;
  final l = Float32List.fromList(x.l), r = Float32List.fromList(x.r);
  // With a flat EQ the split is skipped: the song stays bit-exact instead of going through an all-pass.
  final eqFlat = lanes.lowDb.isConstant(0) && lanes.midDb.isConstant(0) && lanes.highDb.isConstant(0);
  if (!eqFlat) {
    final (lo, mid, hi) = splitThreeBands(x, sr);
    final gl = _automation(n, lanes.lowDb.gainAt);
    final gm = _automation(n, lanes.midDb.gainAt);
    final gh = _automation(n, lanes.highDb.gainAt);
    for (var i = 0; i < n; i++) {
      l[i] = lo.l[i] * gl[i] + mid.l[i] * gm[i] + hi.l[i] * gh[i];
      r[i] = lo.r[i] * gl[i] + mid.r[i] * gm[i] + hi.r[i] * gh[i];
    }
  }
  if (!lanes.filter.isConstant(0)) {
    final amt = _automation(n, (x) => lanes.filter.valueAt(x).clamp(-1.0, 1.0).toDouble());
    _sweepFilter(l, amt, sr);
    _sweepFilter(r, amt, sr);
  }
  if (!lanes.volumeDb.isConstant(0)) {
    final g = _automation(n, lanes.volumeDb.gainAt);
    for (var i = 0; i < n; i++) {
      l[i] *= g[i];
      r[i] *= g[i];
    }
  }
  if (!lanes.echo.isConstant(0)) {
    _echo(l, r, _automation(n, (x) => lanes.echo.valueAt(x).clamp(0.0, 1.0).toDouble()), sr, bpm);
  }
  return Clip(l, r);
}

/// WSOLA of mix_dsp.dart (same window, hop and search) with a variable read position: output sample o reads the
/// source around [srcPos](o). Copied here because the original only takes a constant ratio.
Clip _wsolaWarp(Clip x, int outLen, double Function(double o) srcPos) {
  const n = 2048, ho = n ~/ 2, search = 384;
  final win = Float32List(n);
  for (var i = 0; i < n; i++) {
    win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  final mono = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    mono[i] = x.l[i] + x.r[i];
  }
  double at(int i) => (i >= 0 && i < mono.length) ? mono[i] : 0.0;
  double corr(int a, int b, int len, int step) {
    var s = 0.0, e = 1e-9;
    for (var i = 0; i < len; i += step) {
      final y = at(b + i);
      s += at(a + i) * y;
      e += y * y;
    }
    return s / math.sqrt(e);
  }

  final ol = Float32List(outLen + n), or = Float32List(outLen + n);
  var prev = 0;
  for (var m = 0; m * ho < outLen; m++) {
    final nominal = srcPos((m * ho).toDouble()).round();
    var pos = nominal;
    if (m > 0) {
      final tmpl = prev + ho;
      var best = 0, bestC = -double.infinity;
      for (var d = -search; d <= search; d += 4) {
        final c = corr(tmpl, nominal + d, n ~/ 2, 4);
        if (c > bestC) {
          bestC = c;
          best = d;
        }
      }
      var fine = best;
      for (var d = best - 4; d <= best + 4; d++) {
        final c = corr(tmpl, nominal + d, n ~/ 2, 1);
        if (c > bestC) {
          bestC = c;
          fine = d;
        }
      }
      pos = nominal + fine;
    }
    final o = m * ho;
    for (var i = 0; i < n; i++) {
      final j = pos + i;
      if (j < 0 || j >= x.length) continue;
      ol[o + i] += x.l[j] * win[i];
      or[o + i] += x.r[j] * win[i];
    }
    prev = pos;
  }
  return Clip(Float32List.sublistView(ol, 0, outLen), Float32List.sublistView(or, 0, outLen));
}

/// Source samples a tempo-matched overlap of [n] output samples consumes: speed [ratio] and then a linear
/// glide down to 1 over the last [kTransitionTempoGlideFraction].
double _warpedPos(double o, int n, double ratio) {
  final g0 = n * (1 - kTransitionTempoGlideFraction);
  if (o <= g0) return ratio * o;
  final u = o - g0, span = math.max(1.0, n - g0);
  if (o >= n) return ratio * g0 + (ratio + 1) / 2 * span + (o - n);
  return ratio * g0 + ratio * u + (1 - ratio) * u * u / (2 * span);
}

double _samplePeak(Float32List l, Float32List r, int a, int b) {
  var p = 0.0;
  for (var i = math.max(0, a); i < b && i < l.length; i++) {
    final v = math.max(l[i].abs(), r[i].abs());
    if (v > p) p = v;
  }
  return p;
}

/// Renders the transition offline. The clip is: untouched outgoing pre-roll, the overlap, untouched incoming
/// post-roll, so playback can swap to it and back with a short crossfade. [outgoing] and [incoming] are any
/// excerpts of the songs; the offsets say where each one starts inside its song. Never throws on finite PCM.
TransitionRenderResult renderTransition({
  required Clip outgoing,
  required double outgoingOffsetSec,
  required Clip incoming,
  required double incomingOffsetSec,
  required int sampleRate,
  required SongTransition transition,
  double preRollSec = 2,
  double postRollSec = 2,
  double? outBpm,
  double? inBpm,
}) {
  final sr = sampleRate;
  final notes = <TransitionRenderNote>{};
  double fin(double v) => v.isFinite ? v : 0;
  final outN = math.min(outgoing.l.length, outgoing.r.length);
  final inN = math.min(incoming.l.length, incoming.r.length);
  final oS = ((fin(transition.outStartSec) - fin(outgoingOffsetSec)) * sr).round().clamp(0, outN).toInt();
  final iS = ((fin(transition.inStartSec) - fin(incomingOffsetSec)) * sr).round().clamp(0, inN).toInt();
  final wantN = (transition.clampedLengthSec * sr).round();

  var ratio = 1.0;
  var matched = false;
  if (transition.tempoMatch == TransitionTempoMatch.matchIncoming) {
    final r = transitionTempoRatio(outBpm, inBpm);
    if (r == null) {
      notes.add(TransitionRenderNote.tempoMatchMissingBpm);
    } else if ((r - 1).abs() > kTransitionMaxTempoShift) {
      notes.add(TransitionRenderNote.tempoMatchOutOfRange);
    } else {
      matched = true;
      if ((r - 1).abs() > 1e-3) ratio = r;
    }
  }
  // Mean speed over the whole overlap, glide included.
  final meanRatio = ratio + (1 - ratio) * kTransitionTempoGlideFraction / 2;
  final n = math.max(0, math.min(wantN, math.min(outN - oS, ((inN - iS) / meanRatio).floor())));
  if (n < wantN) notes.add(TransitionRenderNote.overlapShortened);
  final srcN = ratio == 1 ? n : math.min(inN - iS, _warpedPos(n.toDouble(), n, ratio).round());
  final pre = math.min(math.max(0, (fin(preRollSec) * sr).round()), oS);
  final post = math.min(math.max(0, (fin(postRollSec) * sr).round()), inN - iS - srcN);
  final hand = iS + srcN;

  final l = Float32List(pre + n + post), r = Float32List(pre + n + post);
  l.setRange(0, pre, outgoing.l, oS - pre);
  r.setRange(0, pre, outgoing.r, oS - pre);
  l.setRange(pre + n, pre + n + post, incoming.l, hand);
  r.setRange(pre + n, pre + n + post, incoming.r, hand);

  var peakDb = dbOf(0);
  if (n > 0) {
    final outDry = slice(outgoing.l, outgoing.r, oS, oS + n);
    final inSrc = slice(incoming.l, incoming.r, iS, hand);
    final inAtTempo = ratio == 1 ? inSrc : _wsolaWarp(inSrc, n, (o) => _warpedPos(o, n, ratio));
    final ow = _processSong(outDry, transition.outLanes, sr, outBpm);
    final iw = _processSong(inAtTempo, transition.inLanes, sr, outBpm ?? inBpm);
    final ml = Float32List(n), mr = Float32List(n);
    for (var j = 0; j < n; j++) {
      final sumL = ow.l[j] + iw.l[j], sumR = ow.r[j] + iw.r[j];
      ml[j] = sumL.isFinite ? sumL : 0;
      mr[j] = sumR.isFinite ? sumR : 0;
    }

    // Safety: the overlap may not be louder than -1.5 dBFS, or than the songs themselves when they are hotter
    // than that (the pre-roll and post-roll are theirs and cannot be touched).
    final ceil = math.max(
      fromDb(_ceilingDb),
      math.max(
        _samplePeak(outgoing.l, outgoing.r, oS - pre, oS + n),
        _samplePeak(incoming.l, incoming.r, iS, hand + post),
      ),
    );
    final tpCeil = math.max(fromDb(_truePeakCeilingDb), ceil);
    final mixPeak = _samplePeak(ml, mr, 0, n);
    // truePeak oversamples every sample of a silent buffer, so silence is answered without it.
    if (mixPeak > ceil || (mixPeak > 0 && truePeak(ml, mr) > tpCeil)) {
      notes.add(TransitionRenderNote.limited);
      limit(ml, mr, sr, ceilingDb: dbOf(ceil));
      final after = truePeak(ml, mr);
      if (after > tpCeil) {
        for (var j = 0; j < n; j++) {
          ml[j] *= tpCeil / after;
          mr[j] *= tpCeil / after;
        }
      }
    }

    // Whatever the lanes say, both ends of the overlap must continue the untouched songs: the mix starts as the
    // dry outgoing song and ends as the dry incoming song, blended over 30 ms. Done after the limiter, so the
    // joints are exact and each sample stays between two signals that respect the ceiling.
    final blend = math.min((0.03 * sr).round(), n ~/ 2);
    for (var j = 0; j < blend; j++) {
      final t = j / blend;
      ml[j] = outDry.l[j] + (ml[j] - outDry.l[j]) * t;
      mr[j] = outDry.r[j] + (mr[j] - outDry.r[j]) * t;
      final k = n - 1 - j, src = hand - 1 - j;
      ml[k] = incoming.l[src] + (ml[k] - incoming.l[src]) * t;
      mr[k] = incoming.r[src] + (mr[k] - incoming.r[src]) * t;
    }
    final tp = _samplePeak(ml, mr, 0, n) == 0 ? 0.0 : truePeak(ml, mr);
    peakDb = dbOf(tp);
    l.setRange(pre, pre + n, ml);
    r.setRange(pre, pre + n, mr);
  }

  return TransitionRenderResult(
    pcm: Clip(l, r),
    sampleRate: sr,
    clipStartInOutgoingSec: fin(outgoingOffsetSec) + (oS - pre) / sr,
    overlapStartInClipSec: pre / sr,
    overlapSec: n / sr,
    handoverInClipSec: (pre + n) / sr,
    handoverInIncomingSec: fin(incomingOffsetSec) + hand / sr,
    resumeInIncomingSec: fin(incomingOffsetSec) + (hand + post) / sr,
    tempoRatio: ratio,
    tempoMatchApplied: matched,
    peakDb: peakDb,
    notes: notes,
  );
}
