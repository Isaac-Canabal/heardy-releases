// DSP del Mix DJ, portado del spike (tool/mix_spike/lib/dsp.dart y parte de
// mastering.dart): WSOLA para el tempo, remuestreo sinc para el tono, biquads
// e interpolación sinc con ventana.
import 'dart:math' as math;
import 'dart:typed_data';

double dbOf(double x) => 20 * math.log(math.max(x, 1e-12)) / math.ln10;
double fromDb(double d) => math.pow(10, d / 20).toDouble();

/// Audio estéreo en float, canales separados.
class Clip {
  Clip(this.l, this.r);
  final Float32List l;
  final Float32List r;
  int get length => l.length;
}

/// Copia [start, end) de los canales; fuera de rango rellena con ceros.
Clip slice(Float32List l, Float32List r, int start, int end) {
  final n = end - start;
  final ol = Float32List(n), or = Float32List(n);
  for (var i = 0; i < n; i++) {
    final j = start + i;
    if (j >= 0 && j < l.length) {
      ol[i] = l[j];
      or[i] = r[j];
    }
  }
  return Clip(ol, or);
}

/// WSOLA estéreo: estira [x] a [outLen] muestras sin cambiar el tono. La
/// alineación se calcula sobre la suma mono y se aplica a ambos canales.
Clip wsola(Clip x, int outLen) {
  const n = 2048, ho = n ~/ 2, search = 384;
  final alpha = outLen / x.length;
  final hi = ho / alpha;
  final win = Float32List(n);
  for (var i = 0; i < n; i++) {
    win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  final mono = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    mono[i] = x.l[i] + x.r[i];
  }
  double at(int i) => (i >= 0 && i < mono.length) ? mono[i] : 0.0;
  // Correlación normalizada por la energía del candidato: sin esto WSOLA
  // prefiere los tramos más fuertes (golpes de bombo) y duplica transitorios.
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
    final nominal = (m * hi).round();
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

/// Cambia tempo y tono a la vez: WSOLA a outLen·p y luego remuestreo sinc
/// con paso p (p = 2^(semitonos/12)).
Clip stretchPitch(Clip x, int outLen, double semitones) {
  if (semitones == 0) return wsola(x, outLen);
  final p = math.pow(2, semitones / 12).toDouble();
  final mid = wsola(x, (outLen * p).round());
  return resampleSinc(mid, p, outLen);
}

class Biquad {
  Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;

  factory Biquad.highpass(double fc, int sr, [double q = 0.7071]) {
    final w = 2 * math.pi * fc / sr, al = math.sin(w) / (2 * q), c = math.cos(w), a0 = 1 + al;
    return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  factory Biquad.lowpass(double fc, int sr, [double q = 0.7071]) {
    final w = 2 * math.pi * fc / sr, al = math.sin(w) / (2 * q), c = math.cos(w), a0 = 1 + al;
    return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  /// Etapa 1 de la ponderación K (estante alto), coeficientes para cualquier fs.
  factory Biquad.kShelf(int sr) {
    const g = 3.99984385397, q = 0.7071752369554193, fc = 1681.9744509555319;
    final a = math.pow(10, g / 40).toDouble();
    final w = 2 * math.pi * fc / sr, al = math.sin(w) / (2 * q), c = math.cos(w), sa = math.sqrt(a);
    final a0 = (a + 1) - (a - 1) * c + 2 * sa * al;
    return Biquad(
      a * ((a + 1) + (a - 1) * c + 2 * sa * al) / a0,
      -2 * a * ((a - 1) + (a + 1) * c) / a0,
      a * ((a + 1) + (a - 1) * c - 2 * sa * al) / a0,
      2 * ((a - 1) - (a + 1) * c) / a0,
      ((a + 1) - (a - 1) * c - 2 * sa * al) / a0,
    );
  }

  /// Etapa 2 de la ponderación K (paso alto RLB).
  factory Biquad.kHighpass(int sr) => Biquad.highpass(38.13547087613982, sr, 0.5003270373253953);

  Float32List apply(Float32List x) {
    final y = Float32List(x.length);
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < x.length; i++) {
      final x0 = x[i];
      final y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x0;
      y2 = y1;
      y1 = y0;
      y[i] = y0;
    }
    return y;
  }
}

/// Núcleo sinc con ventana de Blackman, tabulado: 16 lóbulos por lado y 512
/// fases por muestra.
class SincTable {
  SincTable({this.half = 16, this.phases = 512, double cutoff = 0.95}) {
    table = Float64List((2 * half) * phases + 1);
    for (var i = 0; i < table.length; i++) {
      final t = i / phases - half;
      final x = math.pi * t * cutoff;
      final sinc = t == 0 ? 1.0 : math.sin(x) / x;
      final u = (t + half) / (2 * half);
      final win = 0.42 - 0.5 * math.cos(2 * math.pi * u) + 0.08 * math.cos(4 * math.pi * u);
      table[i] = cutoff * sinc * win;
    }
  }
  final int half, phases;
  late final Float64List table;

  double at(Float32List x, double pos) {
    final k = pos.floor();
    final frac = pos - k;
    var s = 0.0;
    for (var j = -half + 1; j <= half; j++) {
      final i = k + j;
      if (i < 0 || i >= x.length) continue;
      final t = (frac - j + half) * phases;
      final ti = t.floor();
      final f = t - ti;
      if (ti < 0 || ti + 1 >= table.length) continue;
      s += x[i] * (table[ti] * (1 - f) + table[ti + 1] * f);
    }
    return s;
  }
}

/// Remuestreo de calidad: lee [x] con paso [step] (> 1 sube el tono). El corte
/// baja a 1/step cuando se submuestrea, para no plegar agudos.
Clip resampleSinc(Clip x, double step, int outLen) {
  final tab = SincTable(cutoff: 0.95 * math.min(1.0, 1 / step));
  final ol = Float32List(outLen), or = Float32List(outLen);
  for (var i = 0; i < outLen; i++) {
    final p = i * step;
    if (p >= x.length) break;
    ol[i] = tab.at(x.l, p);
    or[i] = tab.at(x.r, p);
  }
  return Clip(ol, or);
}

/// Cómo se parte cada stem en grave y agudo para que los graves cambien en el
/// downbeat sin solaparse.
enum MixBandSplit {
  /// Cruce Linkwitz-Riley de 4.º orden: dos Butterworth de 2.º orden en
  /// cascada por banda. Graves y agudos quedan en fase y suman plano (un
  /// pasa-todo), y el agudo atenúa el grave de verdad (-46 dB a 40 Hz).
  linkwitzRiley4,

  /// El del spike (render3): agudo = x − LP4(x). Por el desfase del LP4 el
  /// "agudo" conserva casi todo el grave (≈ +1 dB a 65 Hz). Solo para el
  /// test golden contra render3.
  legacy,
}

/// Parte [x] en (grave, agudo) a [fc].
(Clip, Clip) splitBands(Clip x, int sr, {double fc = 150, MixBandSplit mode = MixBandSplit.linkwitzRiley4}) {
  Float32List lp(Float32List v) => Biquad.lowpass(fc, sr).apply(Biquad.lowpass(fc, sr).apply(v));
  final low = Clip(lp(x.l), lp(x.r));
  if (mode == MixBandSplit.legacy) {
    Float32List sub(Float32List a, Float32List b) {
      final y = Float32List(a.length);
      for (var i = 0; i < a.length; i++) {
        y[i] = a[i] - b[i];
      }
      return y;
    }

    return (low, Clip(sub(x.l, low.l), sub(x.r, low.r)));
  }
  Float32List hp(Float32List v) => Biquad.highpass(fc, sr).apply(Biquad.highpass(fc, sr).apply(v));
  return (low, Clip(hp(x.l), hp(x.r)));
}
