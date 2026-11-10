// FFT radix-2 propia para el análisis del Mix DJ. Sustituye a la de `fftea`
// que usaba el spike (sin dependencia nueva): mismas magnitudes sin normalizar
// de los bins 0..n/2 y la misma ventana de Hann simétrica.
import 'dart:math' as math;
import 'dart:typed_data';

/// FFT real de tamaño fijo (potencia de 2) que devuelve magnitudes.
class RealFft {
  RealFft(this.size)
      : assert(size >= 2 && (size & (size - 1)) == 0, 'size debe ser potencia de 2') {
    _cos = Float64List(size ~/ 2);
    _sin = Float64List(size ~/ 2);
    for (var i = 0; i < size ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / size);
      _sin[i] = -math.sin(2 * math.pi * i / size);
    }
    _rev = Int32List(size);
    var bits = 0;
    while ((1 << bits) < size) {
      bits++;
    }
    for (var i = 0; i < size; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
    _re = Float64List(size);
    _im = Float64List(size);
  }

  final int size;
  late final Float64List _cos, _sin, _re, _im;
  late final Int32List _rev;

  /// Magnitudes |X[k]| para k = 0..size/2 de la entrada real [x].
  Float64List magnitudes(Float64List x) {
    final n = size;
    for (var i = 0; i < n; i++) {
      _re[_rev[i]] = x[i];
      _im[_rev[i]] = 0;
    }
    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1, step = n ~/ len;
      for (var s = 0; s < n; s += len) {
        for (var j = 0; j < half; j++) {
          final wr = _cos[j * step], wi = _sin[j * step];
          final a = s + j, b = a + half;
          final tr = _re[b] * wr - _im[b] * wi;
          final ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    final out = Float64List(n ~/ 2 + 1);
    for (var k = 0; k <= n ~/ 2; k++) {
      out[k] = math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
    }
    return out;
  }
}

/// Ventana de Hann simétrica: `0.5 - 0.5·cos(2πi/(n-1))`.
Float64List hannWindow(int n) {
  final w = Float64List(n);
  if (n == 1) {
    w[0] = 1;
    return w;
  }
  final half = n >>> 1;
  for (var i = 0; i <= half; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi / (n - 1) * i);
  }
  for (var i = 0; i < half; i++) {
    w[n - 1 - i] = w[i];
  }
  return w;
}
