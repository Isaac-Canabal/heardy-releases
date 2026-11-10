// Análisis del Mix DJ, portado del spike (tool/mix_spike/lib/analysis.dart):
// BPM por autocorrelación de onsets, rejilla de compases, tonalidad (croma +
// Krumhansl-Schmuckler) con su confianza r, energía por compás, secciones por
// novedad de autosimilitud y presencia de voz a partir del stem de voces.
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_fft.dart';

const kKeyNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const _ksMajor = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const _ksMinor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

/// Avance de una etapa larga (0..1). Puede lanzar para cancelar.
typedef MixTick = void Function(double fraction);

/// Resultado del análisis de una canción.
class SongAnalysis {
  const SongAnalysis({
    required this.bpm,
    required this.downbeatSec,
    required this.keyRoot,
    required this.keyMinor,
    required this.keyScore,
    required this.barEnergy,
    required this.boundaries,
    required this.barVocal,
  });

  final double bpm;
  final double downbeatSec;
  final int keyRoot;
  final bool keyMinor;

  /// Correlación de Krumhansl (r): confianza de la tonalidad.
  final double keyScore;
  final List<double> barEnergy;

  /// Inicios de sección, en compases.
  final List<int> boundaries;

  /// RMS del stem de voces / RMS de la mezcla, por compás.
  final List<double> barVocal;

  double get barSec => 240 / bpm;
  String get keyName => '${kKeyNames[keyRoot]} ${keyMinor ? 'minor' : 'major'}';
  String get camelot => camelotOf(keyRoot, keyMinor);

  Map<String, dynamic> toJson() => {
        'bpm': bpm,
        'downbeatSec': downbeatSec,
        'keyRoot': keyRoot,
        'keyMinor': keyMinor,
        'keyScore': keyScore,
        'barEnergy': barEnergy,
        'boundaries': boundaries,
        'barVocal': barVocal,
      };

  factory SongAnalysis.fromJson(Map<String, dynamic> j) => SongAnalysis(
        bpm: (j['bpm'] as num).toDouble(),
        downbeatSec: (j['downbeatSec'] as num).toDouble(),
        keyRoot: j['keyRoot'] as int,
        keyMinor: j['keyMinor'] as bool,
        keyScore: (j['keyScore'] as num).toDouble(),
        barEnergy: [for (final v in j['barEnergy'] as List) (v as num).toDouble()],
        boundaries: [for (final v in j['boundaries'] as List) v as int],
        barVocal: [for (final v in j['barVocal'] as List) (v as num).toDouble()],
      );
}

/// Camelot: número 1-12 y letra A (menor) / B (mayor).
String camelotOf(int root, bool minor) {
  // Mayor: C=8B, G=9B...; menor: A=8A, E=9A...
  final rel = minor ? (root + 3) % 12 : root;
  final n = ((rel * 7) % 12 + 7) % 12 + 1;
  return '$n${minor ? 'A' : 'B'}';
}

class _Frames {
  _Frames(this.mags, this.hop, this.sr, this.fftSize);
  final List<Float64List> mags;
  final int hop;
  final int sr;
  final int fftSize;
}

Float32List _decimate2(Float32List x) {
  final y = Float32List(x.length ~/ 2);
  for (var i = 0; i < y.length; i++) {
    y[i] = 0.25 * x[2 * i] + 0.5 * x[2 * i + 1] + 0.25 * (2 * i + 2 < x.length ? x[2 * i + 2] : 0);
  }
  return y;
}

_Frames _stft(Float32List x, int sr, int n, int hop, [MixTick? tick]) {
  final fft = RealFft(n);
  final win = hannWindow(n);
  final frames = <Float64List>[];
  final buf = Float64List(n);
  final total = math.max(1, (x.length - n) ~/ hop + 1);
  for (var s = 0; s + n <= x.length; s += hop) {
    for (var i = 0; i < n; i++) {
      buf[i] = x[s + i] * win[i];
    }
    frames.add(fft.magnitudes(buf));
    if (tick != null && frames.length % 256 == 0) tick(frames.length / total);
  }
  return _Frames(frames, hop, sr, n);
}

/// BPM por autocorrelación del flujo espectral. Devuelve (bpm, envolvente, hopSec).
(double, Float64List, double) _estimateTempo(_Frames f) {
  final nf = f.mags.length;
  final env = Float64List(nf);
  for (var t = 1; t < nf; t++) {
    var s = 0.0;
    final a = f.mags[t], b = f.mags[t - 1];
    for (var k = 1; k < a.length; k++) {
      final d = math.log(1 + 100 * a[k]) - math.log(1 + 100 * b[k]);
      if (d > 0) s += d;
    }
    env[t] = s;
  }
  final mean = env.reduce((p, q) => p + q) / nf;
  for (var t = 0; t < nf; t++) {
    env[t] = math.max(0, env[t] - mean);
  }
  final hopSec = f.hop / f.sr;
  final minLag = (60 / 180 / hopSec).floor(), maxLag = (60 / 70 / hopSec).ceil();
  final ac = Float64List(2 * maxLag + 4);
  for (var lag = minLag ~/ 2 - 1; lag <= 2 * maxLag + 2; lag++) {
    var s = 0.0;
    for (var t = lag; t < nf; t++) {
      s += env[t] * env[t - lag];
    }
    ac[lag] = s / (nf - lag);
  }
  var best = minLag;
  var bestScore = -1.0;
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60 / (lag * hopSec);
    // Prior log-gaussiano centrado en 120 BPM para elegir octava.
    final w = math.exp(-0.5 * math.pow(math.log(bpm / 120) / math.log(2) / 0.9, 2));
    // Apoyo armónico: el pulso real también correlaciona a la mitad y al doble
    // del periodo; una confusión 2/3 (p. ej. 116 en un DnB de 174) no.
    final sc = (ac[lag] + 0.5 * ac[2 * lag] + 0.5 * ac[lag ~/ 2]) * w;
    if (sc > bestScore) {
      bestScore = sc;
      best = lag;
    }
  }
  final y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1];
  final denom = y0 - 2 * y1 + y2;
  final delta = denom.abs() < 1e-12 ? 0.0 : 0.5 * (y0 - y2) / denom;
  final lag = best + delta;
  // Refinamiento: el periodo de compás (4 tiempos) tiene más resolución.
  final barLag0 = lag * 4;
  var bestBar = barLag0, bestBarScore = -1.0;
  for (var l = barLag0 - 3; l <= barLag0 + 3; l += 0.05) {
    var s = 0.0;
    final li = l.floor(), fr = l - li;
    for (var t = li + 1; t < nf; t++) {
      s += env[t] * (env[t - li] * (1 - fr) + env[t - li - 1] * fr);
    }
    if (s > bestBarScore) {
      bestBarScore = s;
      bestBar = l;
    }
  }
  return (60 / (bestBar / 4 * hopSec), env, hopSec);
}

/// Rejilla de compás: busca a la vez periodo (±0.6 % alrededor de [bpm0]) y
/// fase que maximizan la energía de onsets en los tiempos, ponderando el tiempo
/// 1 y los graves (bombo), más el cambio armónico [harm] en el tiempo 1 (sin
/// eso, 1 y 3 son indistinguibles). Un error de 0.1 % en el tempo ya desplaza
/// la rejilla ~0.2 s al final de una canción, por eso el periodo se reajusta.
(double, double) _estimateGrid(
    Float64List env, Float64List low, Float64List harm, double hopSec, double bpm0, MixTick? tick) {
  var best = (bpm0, 0.0);
  var bestScore = -1.0;
  var step = 0;
  for (var rel = -0.006; rel <= 0.006; rel += 0.0002) {
    final bpm = bpm0 * (1 + rel);
    final beat = 60 / bpm / hopSec;
    for (var off = 0.0; off < 4 * beat; off += 0.25) {
      var s = 0.0;
      for (var k = 0;; k++) {
        final i = (off + k * beat).round();
        if (i >= env.length) break;
        final w = (k % 4 == 0) ? 2.0 : (k % 2 == 0 ? 1.0 : 0.5);
        s += w * (env[i] + low[i]) + (k % 4 == 0 ? 4 * harm[i] : 0);
      }
      if (s > bestScore) {
        bestScore = s;
        best = (bpm, off * hopSec);
      }
    }
    if (tick != null) tick(++step / 61);
  }
  return best;
}

/// Cambio armónico por trama: 1 - coseno entre el croma medio de las 8 tramas
/// siguientes y el de las 8 anteriores.
Float64List _harmonicChange(_Frames f) {
  final nf = f.mags.length;
  final ch = List.generate(nf, (_) => Float64List(12));
  for (var t = 0; t < nf; t++) {
    final m = f.mags[t];
    for (var k = 1; k < m.length; k++) {
      final hz = k * f.sr / f.fftSize;
      if (hz < 55 || hz > 2000) continue;
      final midi = 69 + 12 * math.log(hz / 440) / math.ln2;
      ch[t][((midi.round() % 12) + 12) % 12] += m[k];
    }
  }
  final h = Float64List(nf);
  for (var t = 8; t < nf - 8; t++) {
    final a = Float64List(12), b = Float64List(12);
    for (var j = 0; j < 8; j++) {
      for (var p = 0; p < 12; p++) {
        a[p] += ch[t - 8 + j][p];
        b[p] += ch[t + j][p];
      }
    }
    var ab = 0.0, aa = 0.0, bb = 0.0;
    for (var p = 0; p < 12; p++) {
      ab += a[p] * b[p];
      aa += a[p] * a[p];
      bb += b[p] * b[p];
    }
    h[t] = 1 - ab / (math.sqrt(aa * bb) + 1e-12);
  }
  final mx = h.reduce(math.max) + 1e-12;
  for (var t = 0; t < nf; t++) {
    h[t] /= mx;
  }
  return h;
}

(int, bool, double) _estimateKey(_Frames f) {
  final chroma = Float64List(12);
  for (final m in f.mags) {
    for (var k = 1; k < m.length; k++) {
      final hz = k * f.sr / f.fftSize;
      if (hz < 55 || hz > 2000) continue;
      final midi = 69 + 12 * math.log(hz / 440) / math.ln2;
      final pc = ((midi.round() % 12) + 12) % 12;
      chroma[pc] += math.log(1 + 10 * m[k]);
    }
  }
  double corr(List<double> p, int shift) {
    final mx = chroma.reduce((a, b) => a + b) / 12;
    final mp = p.reduce((a, b) => a + b) / 12;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var i = 0; i < 12; i++) {
      final x = chroma[(i + shift) % 12] - mx, y = p[i] - mp;
      sxy += x * y;
      sxx += x * x;
      syy += y * y;
    }
    return sxy / math.sqrt(sxx * syy);
  }

  var best = (0, false, -2.0);
  for (var r = 0; r < 12; r++) {
    final a = corr(_ksMajor, r), b = corr(_ksMinor, r);
    if (a > best.$3) best = (r, false, a);
    if (b > best.$3) best = (r, true, b);
  }
  return best;
}

/// Rasgos por compás: croma (12) + energía en 8 bandas log, normalizados.
List<Float64List> _barFeatures(_Frames f, double downbeat, double barSec, int bars) {
  final feats = <Float64List>[];
  final hopSec = f.hop / f.sr;
  final edges = [30, 120, 250, 500, 1000, 2000, 4000, 8000, 11000];
  for (var b = 0; b < bars; b++) {
    final v = Float64List(20);
    final t0 = math.max(0, ((downbeat + b * barSec) / hopSec).floor());
    final t1 = math.min(((downbeat + (b + 1) * barSec) / hopSec).floor(), f.mags.length);
    for (var t = t0; t < t1; t++) {
      final m = f.mags[t];
      for (var k = 1; k < m.length; k++) {
        final hz = k * f.sr / f.fftSize;
        final e = m[k] * m[k];
        if (hz >= 55 && hz <= 2000) {
          final midi = 69 + 12 * math.log(hz / 440) / math.ln2;
          v[((midi.round() % 12) + 12) % 12] += e;
        }
        for (var j = 0; j < 8; j++) {
          if (hz >= edges[j] && hz < edges[j + 1]) v[12 + j] += e;
        }
      }
    }
    for (var i = 0; i < 20; i++) {
      v[i] = math.log(1 + v[i]);
    }
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n) + 1e-9;
    for (var i = 0; i < 20; i++) {
      v[i] /= n;
    }
    feats.add(v);
  }
  return feats;
}

/// Novedad de Foote sobre la matriz de autosimilitud (coseno) por compás;
/// picos en múltiplos de 4 compases.
List<int> segmentBars(List<Float64List> feats, {int half = 4}) {
  final n = feats.length;
  if (n < 2 * half + 1) return [0];
  double sim(int i, int j) {
    var s = 0.0;
    for (var k = 0; k < feats[i].length; k++) {
      s += feats[i][k] * feats[j][k];
    }
    return s;
  }

  final nov = Float64List(n);
  for (var c = half; c <= n - half; c++) {
    var s = 0.0;
    for (var i = -half; i < half; i++) {
      for (var j = -half; j < half; j++) {
        final sign = ((i < 0) == (j < 0)) ? 1.0 : -1.0;
        s += sign * sim(c + i, c + j);
      }
    }
    nov[c] = math.max(0, s);
  }
  final sorted = [...nov]..sort();
  final thr = sorted[(n * 0.6).floor()];
  final out = <int>[0];
  for (var c = 4; c < n - 2; c += 4) {
    // Toma el máximo local en ±1 compás alrededor de cada múltiplo de 4.
    final v = math.max(nov[c], math.max(nov[c - 1], nov[c + 1]));
    var isPeak = true;
    for (var d = -4; d <= 4; d++) {
      if (c + d >= 0 && c + d < n && nov[c + d] > v) isPeak = false;
    }
    if (isPeak && v >= thr && v > 1e-6) out.add(c);
  }
  return out;
}

/// Analiza la mezcla mono [mono44k] (y, si hay, el stem de voces mono).
SongAnalysis analyzeSong(Float32List mono44k, int sr, {Float32List? vocals, MixTick? tick}) {
  void t(double a, double b, double f) => tick?.call(a + (b - a) * f.clamp(0.0, 1.0));
  final x = _decimate2(mono44k);
  final sr2 = sr ~/ 2;
  final f = _stft(x, sr2, 4096, 512, (p) => t(0, 0.35, p));
  final (bpm, env, hopSec) = _estimateTempo(f);
  t(0, 1, 0.45);
  final low = Float64List(f.mags.length);
  for (var i = 1; i < f.mags.length; i++) {
    var s = 0.0;
    for (var k = 1; k * sr2 / 4096 < 150; k++) {
      final d = f.mags[i][k] - f.mags[i - 1][k];
      if (d > 0) s += d;
    }
    low[i] = s;
  }
  final lmax = low.reduce(math.max) + 1e-9, emax = env.reduce(math.max) + 1e-9;
  for (var i = 0; i < low.length; i++) {
    low[i] = low[i] / lmax;
    env[i] = env[i] / emax;
  }
  final harm = _harmonicChange(f);
  t(0, 1, 0.5);
  final (bpmFit, phase) = _estimateGrid(env, low, harm, hopSec, bpm, (p) => t(0.5, 0.9, p));
  // El flujo de la trama t compara ventanas que empiezan en t·hop; un onset
  // pesa más cuando cae en el centro de la ventana de 4096 (≈93 ms después).
  final barFit = 240 / bpmFit;
  var downbeat = (phase + 4096 / 2 / sr2) % barFit;
  if (downbeat > barFit * 0.75) downbeat -= barFit;
  final key = _estimateKey(f);
  final barSec = barFit;
  final bars = ((mono44k.length / sr - downbeat) / barSec).floor();
  final energy = <double>[];
  final vocal = <double>[];
  for (var b = 0; b < bars; b++) {
    final s0 = math.max(0, ((downbeat + b * barSec) * sr).round());
    final s1 = math.min(((downbeat + (b + 1) * barSec) * sr).round(), mono44k.length);
    var e = 0.0, v = 0.0;
    for (var i = s0; i < s1; i++) {
      e += mono44k[i] * mono44k[i];
      if (vocals != null) v += vocals[i] * vocals[i];
    }
    energy.add(math.sqrt(e / (s1 - s0)));
    vocal.add(vocals == null ? 0 : math.sqrt(v / (s1 - s0)) / (math.sqrt(e / (s1 - s0)) + 1e-9));
  }
  final feats = _barFeatures(f, downbeat, barSec, bars);
  final boundaries = segmentBars(feats);
  t(0, 1, 1);
  return SongAnalysis(
    bpm: bpmFit,
    downbeatSec: downbeat,
    keyRoot: key.$1,
    keyMinor: key.$2,
    keyScore: key.$3,
    barEnergy: energy,
    boundaries: boundaries,
    barVocal: vocal,
  );
}

/// Estabilidad de rejilla: mediana de la distancia (ms) de los picos de onset
/// fuertes al pulso más cercano de una rejilla fija a [pulsesPerBar] pulsos por
/// compás, tras quitar la fase media. Menos es más estable.
double gridResidualMs(Float32List mono44k, int sr, double bpm, double downbeat, {int pulsesPerBar = 8}) {
  final x = _decimate2(mono44k);
  final sr2 = sr ~/ 2;
  final f = _stft(x, sr2, 2048, 256);
  final nf = f.mags.length;
  final env = Float64List(nf);
  for (var t = 1; t < nf; t++) {
    var s = 0.0;
    for (var k = 1; k < f.mags[t].length; k++) {
      final d = math.log(1 + 100 * f.mags[t][k]) - math.log(1 + 100 * f.mags[t - 1][k]);
      if (d > 0) s += d;
    }
    env[t] = s;
  }
  final mean = env.reduce((a, b) => a + b) / nf;
  var v = 0.0;
  for (final e in env) {
    v += (e - mean) * (e - mean);
  }
  final thr = mean + 1.5 * math.sqrt(v / nf);
  final hop = 256 / sr2, lag = 1024 / sr2; // centro de la ventana
  final pulse = 240 / bpm / pulsesPerBar;
  final ph = <double>[];
  for (var t = 2; t < nf - 2; t++) {
    if (env[t] > thr && env[t] >= env[t - 1] && env[t] >= env[t + 1] && env[t] >= env[t - 2] && env[t] >= env[t + 2]) {
      final time = t * hop + lag - downbeat;
      ph.add(time / pulse - (time / pulse).floorToDouble());
    }
  }
  var cs = 0.0, sn = 0.0;
  for (final p in ph) {
    cs += math.cos(2 * math.pi * p);
    sn += math.sin(2 * math.pi * p);
  }
  final mu = math.atan2(sn, cs) / (2 * math.pi);
  final d = <double>[];
  for (final p in ph) {
    var r = p - mu;
    r -= r.roundToDouble();
    d.add((r * pulse * 1000).abs());
  }
  if (d.isEmpty) return double.infinity;
  d.sort();
  return d[d.length ~/ 2];
}
