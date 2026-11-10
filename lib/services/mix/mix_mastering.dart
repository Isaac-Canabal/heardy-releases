// Masterización del Mix DJ, portada del spike (tool/mix_spike/lib/mastering.dart
// y el final de bin/render3.dart): sonoridad aproximada a BS.1770 (ponderación
// K + gating), limitador con lookahead, true peak aproximado y el ajuste de
// ganancia tras un codificador externo.
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_dsp.dart';

/// Potencia ponderada K por muestra (suma de canales) como prefijo acumulado,
/// para sacar la potencia media de cualquier tramo en O(1).
class KPower {
  KPower(Float32List l, Float32List r, this.sr) {
    final s = Biquad.kShelf(sr), h = Biquad.kHighpass(sr);
    final kl = h.apply(s.apply(l)), kr = h.apply(s.apply(r));
    prefix = Float64List(l.length + 1);
    for (var i = 0; i < l.length; i++) {
      prefix[i + 1] = prefix[i] + kl[i] * kl[i] + kr[i] * kr[i];
    }
  }
  final int sr;
  late final Float64List prefix;
  int get length => prefix.length - 1;

  double power(int a, int b) {
    a = a.clamp(0, length);
    b = b.clamp(0, length);
    return b > a ? (prefix[b] - prefix[a]) / (b - a) : 0;
  }

  static double lufs(double p) => -0.691 + 10 * math.log(math.max(p, 1e-20)) / math.ln10;

  /// Sonoridad integrada: bloques de 400 ms con 75 % de solape, gate absoluto
  /// -70 LUFS y relativo -10 LU.
  double integrated([int a = 0, int? b]) {
    b ??= length;
    final blk = (0.4 * sr).round(), hop = (0.1 * sr).round();
    final ps = <double>[];
    for (var s = a; s + blk <= b; s += hop) {
      final p = power(s, s + blk);
      if (lufs(p) > -70) ps.add(p);
    }
    if (ps.isEmpty) return -70;
    final rel = lufs(ps.reduce((x, y) => x + y) / ps.length) - 10;
    final g = ps.where((p) => lufs(p) > rel).toList();
    return lufs(g.reduce((x, y) => x + y) / g.length);
  }
}

/// Sonoridad integrada de un estéreo completo.
double integratedLufs(Float32List l, Float32List r, int sr) => KPower(l, r, sr).integrated();

/// Pico verdadero aproximado (sobremuestreo ×4 con sinc), solo cerca de picos.
double truePeak(Float32List l, Float32List r) {
  var sp = 0.0;
  for (var i = 0; i < l.length; i++) {
    sp = math.max(sp, math.max(l[i].abs(), r[i].abs()));
  }
  final tab = SincTable();
  var tp = sp;
  for (final ch in [l, r]) {
    for (var i = 0; i + 1 < ch.length; i++) {
      if (math.max(ch[i].abs(), ch[i + 1].abs()) < 0.6 * sp) continue;
      for (final f in const [0.25, 0.5, 0.75]) {
        tp = math.max(tp, tab.at(ch, i + f).abs());
      }
    }
  }
  return tp;
}

/// Estadísticas del limitador: reducción máxima (dB), media sobre las muestras
/// con más de 0.1 dB, y % de muestras con más de 0.1 dB.
class LimiterStats {
  const LimiterStats(this.maxReductionDb, this.meanReductionDb, this.percentActive);
  final double maxReductionDb, meanReductionDb, percentActive;
}

/// Limitador con lookahead (no causal, offline), en sitio: ganancia requerida →
/// mínimo deslizante ±look → media móvil de look (ataque) → release exponencial.
LimiterStats limit(Float32List l, Float32List r, int sr,
    {double ceilingDb = -1.5, double lookMs = 5, double releaseMs = 150}) {
  final n = l.length, ceil = fromDb(ceilingDb), look = (lookMs / 1000 * sr).round();
  if (n == 0) return const LimiterStats(0, 0, 0);
  final req = Float64List(n);
  for (var i = 0; i < n; i++) {
    final p = math.max(l[i].abs(), r[i].abs());
    req[i] = p > ceil ? ceil / p : 1.0;
  }
  // Mínimo deslizante centrado con deque monótono.
  final mn = Float64List(n);
  final dq = Int32List(n + 2 * look + 2);
  var h = 0, t = 0;
  for (var i = 0; i < n + look; i++) {
    if (i < n) {
      while (t > h && req[dq[t - 1]] >= req[i]) {
        t--;
      }
      dq[t++] = i;
    }
    final c = i - look;
    if (c >= 0) {
      while (dq[h] < c - look) {
        h++;
      }
      mn[c] = req[dq[h]];
    }
  }
  final pre = Float64List(n + 1);
  for (var i = 0; i < n; i++) {
    pre[i + 1] = pre[i] + mn[i];
  }
  final rel = math.exp(-1 / (releaseMs / 1000 * sr));
  var g = 1.0, maxRed = 0.0, sumRed = 0.0, cnt = 0;
  final half = look ~/ 2;
  for (var i = 0; i < n; i++) {
    final a = math.max(0, i - half), b = math.min(n, i + half + 1);
    final tgt = (pre[b] - pre[a]) / (b - a);
    g = tgt < g ? tgt : tgt - (tgt - g) * rel;
    if (g > req[i]) g = req[i];
    l[i] *= g;
    r[i] *= g;
    final red = -dbOf(g);
    if (red > maxRed) maxRed = red;
    if (red > 0.1) {
      sumRed += red;
      cnt++;
    }
  }
  return LimiterStats(maxRed, cnt == 0 ? 0.0 : sumRed / cnt, 100 * cnt / n);
}

/// Parámetros del master (los de render3 por defecto).
class MasterSettings {
  const MasterSettings({
    this.targetLufs = -12.0,
    this.ceilingDb = -2.0,
    this.maxLimiterDb = 4.0,
    this.busPeakDb = -6.0,
  });

  final double targetLufs;

  /// Techo de muestra; deja margen para que el true peak quede ≤ -1.5 dBTP
  /// tras codificar a AAC.
  final double ceilingDb;

  /// Reducción máxima prevista en el limitador: tope de la ganancia de entrada.
  final double maxLimiterDb;

  /// Pico al que se lleva el bus antes de la ganancia de entrada.
  final double busPeakDb;
}

/// Resultado del master.
class MasterReport {
  const MasterReport({
    required this.makeupDb,
    required this.limiter,
    required this.truePeakDb,
    required this.lufs,
  });
  final double makeupDb;
  final LimiterStats limiter;
  final double truePeakDb;
  final double lufs;
}

void _gain(Float32List l, Float32List r, double g) {
  for (var i = 0; i < l.length; i++) {
    l[i] *= g;
    r[i] *= g;
  }
}

/// Master en sitio: bus a [MasterSettings.busPeakDb] de pico, ganancia de
/// entrada hacia el objetivo con tope, limitador y, si el true peak supera el
/// techo, una bajada de ganancia final.
MasterReport master(Float32List l, Float32List r, int sr, [MasterSettings s = const MasterSettings()]) {
  var peak = 1e-9;
  for (var i = 0; i < l.length; i++) {
    peak = math.max(peak, math.max(l[i].abs(), r[i].abs()));
  }
  _gain(l, r, fromDb(s.busPeakDb) / peak);
  final preLufs = KPower(l, r, sr).integrated();
  final makeup = math.min(s.targetLufs - preLufs, s.ceilingDb + s.maxLimiterDb - s.busPeakDb);
  _gain(l, r, fromDb(makeup));
  final stats = limit(l, r, sr, ceilingDb: s.ceilingDb);
  var tp = truePeak(l, r);
  if (tp > fromDb(s.ceilingDb)) {
    _gain(l, r, fromDb(s.ceilingDb) / tp);
    tp = fromDb(s.ceilingDb);
  }
  return MasterReport(makeupDb: makeup, limiter: stats, truePeakDb: dbOf(tp), lufs: KPower(l, r, sr).integrated());
}

/// Decisión tras medir el true peak del archivo ya codificado.
class EncodedPeakCheck {
  const EncodedPeakCheck({required this.withinCeiling, required this.trimDb, required this.exhausted});

  /// El archivo medido ya cumple el techo: no hay que volver a codificar.
  final bool withinCeiling;

  /// Ganancia total (≤ 0 dB) a aplicar al PCM masterizado antes de codificar.
  final double trimDb;

  /// Se llegó al tope de recorte sin cumplir: el llamador decide (p. ej. avisar).
  final bool exhausted;
}

/// Gancho para después de un codificador externo (AAC sube el true peak, y no
/// de forma lineal: en la Ronda 4 un -0.5 dB dio más pico que 0 dB). Recibe el
/// true peak medido con [appliedTrimDb] ya aplicado y devuelve el recorte
/// total para el siguiente intento: baja al menos [stepDb] y al menos el exceso
/// medido, sin pasar de [maxTrimDb].
EncodedPeakCheck checkEncodedTruePeak({
  required double measuredTruePeakDb,
  double appliedTrimDb = 0,
  double ceilingDbtp = -1.5,
  double stepDb = 0.5,
  double maxTrimDb = 6,
}) {
  if (measuredTruePeakDb <= ceilingDbtp) {
    return EncodedPeakCheck(withinCeiling: true, trimDb: appliedTrimDb, exhausted: false);
  }
  final next = appliedTrimDb - math.max(stepDb, measuredTruePeakDb - ceilingDbtp);
  if (next < -maxTrimDb) {
    return EncodedPeakCheck(withinCeiling: false, trimDb: -maxTrimDb, exhausted: appliedTrimDb <= -maxTrimDb);
  }
  return EncodedPeakCheck(withinCeiling: false, trimDb: next, exhausted: false);
}

/// Aplica [db] de ganancia a un PCM estéreo intercalado y devuelve una copia.
Float32List applyGainDb(Float32List interleaved, double db) {
  final g = fromDb(db);
  final out = Float32List(interleaved.length);
  for (var i = 0; i < interleaved.length; i++) {
    out[i] = interleaved[i] * g;
  }
  return out;
}
