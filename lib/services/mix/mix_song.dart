// Una canción preparada para el planificador del Mix DJ, portada de las clases
// Song y Stem de tool/mix_spike/bin/render3.dart: rejilla en "compases dobles"
// (8 pulsos reales, como el DnB a medio tiempo), ganancia por canción, umbral
// de voz, intro/outro y medidas por compás de cada stem.
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_analysis.dart';
import 'mix_dsp.dart';
import 'mix_mastering.dart';
import 'mix_types.dart';

/// Ganancia por canción: su mezcla a -19 LUFS.
const kSongMixLufs = -19.0;

class MixStem {
  MixStem(this.l, this.r) : kp = KPower(l, r, kMixSampleRate);

  final Float32List l, r;
  final KPower kp;
  late final List<double> barLufs;
  late final double median;
  late final List<bool> gappy;
  late final MixSong _song;

  int get length => l.length;

  void _measure(MixSong song) {
    _song = song;
    const sr = kMixSampleRate;
    // Un compás tiene hueco si alguna ventana de 50 ms queda 20 dB por debajo
    // de la mediana de los compases (tras ganancia y master rondaría -40 dBFS).
    final m = Float32List(length);
    for (var i = 0; i < length; i++) {
      m[i] = 0.5 * (l[i] + r[i]);
    }
    final w = (0.05 * sr).round();
    double rmsDb(int a, int b) {
      var e = 0.0;
      for (var i = a; i < b; i++) {
        e += m[i] * m[i];
      }
      return dbOf(math.sqrt(e / math.max(1, b - a)));
    }

    final barDb = <double>[], minDb = <double>[];
    for (var b = 0; b < song.bars; b++) {
      final a0 = song.barSample(b).clamp(0, m.length), a1 = song.barSample(b + 1).clamp(0, m.length);
      barDb.add(rmsDb(a0, a1));
      var mn = 0.0;
      for (var s0 = a0; s0 + w <= a1; s0 += w ~/ 2) {
        mn = math.min(mn, rmsDb(s0, s0 + w));
      }
      minDb.add(mn);
    }
    final sb = [...barDb]..sort();
    final med = sb.isEmpty ? -120.0 : sb[sb.length ~/ 2];
    gappy = [for (final x in minDb) x < med - 20];
    barLufs = [
      for (var b = 0; b < song.bars; b++) KPower.lufs(kp.power(song.barSample(b), song.barSample(b + 1)))
    ];
    final s = barLufs.where((x) => x > -70).toList()..sort();
    median = s.isEmpty ? -70 : s[s.length ~/ 2];
  }

  bool dead(int b) => b < 0 || b >= _song.bars || barLufs[b] < median - 12;
  bool usable(int b) => !dead(b) && !gappy[b];
  double lufs(int b0, int b1) => kp.integrated(_song.barSample(b0), _song.barSample(b1));
}

class MixSong {
  MixSong._({
    required this.id,
    required this.name,
    required this.bpm,
    required this.downbeat,
    required this.keyRoot,
    required this.minor,
    required this.keyScore,
    required this.vocal,
    required Map<MixLayer, MixStem> stems,
    double? residualMs,
  }) : _stems = stems {
    bars = vocal.length;
    for (final s in _stems.values) {
      s._measure(this);
    }
    gainDb = kSongMixLufs - stem(MixLayer.mix).kp.integrated();
    final sorted = [...vocal]..sort();
    vocalThr = sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2];
    if (residualMs != null) {
      this.residualMs = residualMs;
    } else {
      final mx = stem(MixLayer.mix);
      final mono = Float32List(mx.length);
      for (var i = 0; i < mono.length; i++) {
        mono[i] = 0.5 * (mx.l[i] + mx.r[i]);
      }
      this.residualMs = gridResidualMs(mono, kMixSampleRate, bpm, downbeat);
    }
    // Intro/outro: compases antes de la primera voz clara (≥ mediana) y
    // después de la última.
    var i = 0;
    while (i < bars && vocal[i] < vocalThr) {
      i++;
    }
    var o = 0;
    while (o < bars && vocal[bars - 1 - o] < vocalThr) {
      o++;
    }
    introBars = i;
    outroBars = o;
  }

  /// Canción a partir de sus stems planares y su análisis. Todo el plan trabaja
  /// en "compases dobles" (8 pulsos reales): una canción analizada a tempo
  /// completo (≥ 100 BPM) pasa a la mitad de BPM y la media de cada par de
  /// compases.
  factory MixSong.fromAnalysis({
    required String id,
    required String name,
    required Clip mix,
    required Clip vocals,
    required Clip instrumental,
    required SongAnalysis analysis,
    bool? halfTime,
  }) {
    var bpm = analysis.bpm;
    final v0 = analysis.barVocal;
    List<double> vocal;
    // [halfTime] fuerza el plegado (el motor lo decide mirando también la otra
    // canción); sin él, 100 BPM o más se cuentan a la mitad.
    if (halfTime ?? bpm >= 100) {
      bpm = bpm / 2;
      vocal = [for (var i = 0; i + 1 < v0.length; i += 2) 0.5 * (v0[i] + v0[i + 1])];
    } else {
      vocal = [...v0];
    }
    return MixSong._(
      id: id,
      name: name,
      bpm: bpm,
      downbeat: analysis.downbeatSec,
      keyRoot: analysis.keyRoot,
      minor: analysis.keyMinor,
      keyScore: analysis.keyScore,
      vocal: vocal,
      stems: {
        MixLayer.mix: MixStem(mix.l, mix.r),
        MixLayer.vocals: MixStem(vocals.l, vocals.r),
        MixLayer.instrumental: MixStem(instrumental.l, instrumental.r),
      },
    );
  }

  final String id, name;
  final double bpm, downbeat, keyScore;
  final int keyRoot;
  final bool minor;
  final List<double> vocal;
  final Map<MixLayer, MixStem> _stems;
  late final int bars, introBars, outroBars;
  late final double gainDb, vocalThr, residualMs;

  MixStem stem(MixLayer k) => _stems[k]!;
  double barSec() => 240 / bpm;
  int barSample(num b) => ((downbeat + b * barSec()) * kMixSampleRate).round();
  String get camelot => camelotOf(keyRoot, minor);

  /// Intro + outro sin voz clara, en compases (desempate de la regla de base).
  int get introOutro => math.min(introBars, 8) + math.min(outroBars, 8);

  /// Duración del audio de la mezcla, en segundos.
  double get seconds => stem(MixLayer.mix).length / kMixSampleRate;

  /// Copia sin los compases de [dropped] (índices de esta canción). Los tramos
  /// que quedan se pegan con un fundido lineal corto en el downbeat; la rejilla
  /// (tempo y downbeat) no cambia porque el principio se conserva.
  MixSong withoutBars(Set<int> dropped) {
    if (dropped.isEmpty) return this;
    final keep = <(int, int)>[]; // tramos [b0, b1) de compases que se quedan
    var b = 0;
    while (b < bars) {
      if (dropped.contains(b)) {
        b++;
        continue;
      }
      final b0 = b;
      while (b < bars && !dropped.contains(b)) {
        b++;
      }
      keep.add((b0, b));
    }
    final ranges = <(int, int)>[
      for (var k = 0; k < keep.length; k++)
        (
          k == 0 && keep[k].$1 == 0 ? 0 : barSample(keep[k].$1),
          k == keep.length - 1 && keep[k].$2 == bars ? stem(MixLayer.mix).length : barSample(keep[k].$2),
        )
    ];
    MixStem cut(MixStem s) {
      final (l, r) = (_splice(s.l, ranges), _splice(s.r, ranges));
      return MixStem(l, r);
    }

    return MixSong._(
      id: id,
      name: name,
      bpm: bpm,
      downbeat: downbeat,
      keyRoot: keyRoot,
      minor: minor,
      keyScore: keyScore,
      vocal: [for (var i = 0; i < bars; i++) if (!dropped.contains(i)) vocal[i]],
      stems: {for (final e in _stems.entries) e.key: cut(e.value)},
      residualMs: residualMs,
    );
  }
}

/// Concatena los tramos [a, b) de [x] con un fundido lineal de 10 ms centrado
/// en cada empalme (lee un poco más allá de cada tramo en el original).
Float32List _splice(Float32List x, List<(int, int)> ranges) {
  final total = ranges.fold<int>(0, (s, r) => s + (r.$2 - r.$1));
  final y = Float32List(total);
  double at(int i) => i >= 0 && i < x.length ? x[i] : 0.0;
  var o = 0;
  for (final (a, b) in ranges) {
    for (var i = a; i < b; i++) {
      y[o + i - a] = x[i];
    }
    o += b - a;
  }
  const h = 220; // 5 ms a cada lado
  o = 0;
  for (var k = 0; k + 1 < ranges.length; k++) {
    o += ranges[k].$2 - ranges[k].$1;
    final endPrev = ranges[k].$2, startNext = ranges[k + 1].$1;
    for (var i = -h; i < h; i++) {
      final j = o + i;
      if (j < 0 || j >= total) continue;
      final t = (i + h) / (2 * h);
      y[j] = (1 - t) * at(endPrev + i) + t * at(startNext + i);
    }
  }
  return y;
}
