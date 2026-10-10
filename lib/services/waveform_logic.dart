import 'dart:typed_data';

/// Barras que se dibujan por canción (y bytes que se guardan en caché).
const int kWaveformBars = 200;

/// Reduce [samples] (amplitudes >= 0) a [bars] valores tomando el pico de
/// cada tramo; si hay menos muestras que barras, se repiten por posición.
List<double> downsampleAmplitudes(List<double> samples, int bars) {
  if (bars <= 0) return const [];
  if (samples.isEmpty) return List<double>.filled(bars, 0);
  final out = List<double>.filled(bars, 0);
  final n = samples.length;
  for (var i = 0; i < bars; i++) {
    final start = (i * n) ~/ bars;
    var end = ((i + 1) * n) ~/ bars;
    if (end <= start) end = start + 1;
    var peak = 0.0;
    for (var j = start; j < end && j < n; j++) {
      final v = samples[j].isFinite ? samples[j].abs() : 0.0;
      if (v > peak) peak = v;
    }
    out[i] = peak;
  }
  return out;
}

/// Escala al rango 0..255 con el máximo en 255. Silencio total queda en 0.
Uint8List normalizeToBytes(List<double> amplitudes) {
  var maxValue = 0.0;
  for (final v in amplitudes) {
    if (v.isFinite && v > maxValue) maxValue = v;
  }
  final out = Uint8List(amplitudes.length);
  if (maxValue <= 0) return out;
  for (var i = 0; i < amplitudes.length; i++) {
    final v = amplitudes[i];
    out[i] = v.isFinite && v > 0 ? (v / maxValue * 255).round().clamp(0, 255) : 0;
  }
  return out;
}

const int _waveformVersion = 1;
const List<int> _waveformMagic = [0x48, 0x57, 0x56]; // "HWV"
const int _waveformHeaderLength = 6;

/// Cabecera: magia "HWV" + versión (1 byte) + cantidad de barras (uint16 LE).
Uint8List encodeWaveform(Uint8List peaks) {
  final out = Uint8List(_waveformHeaderLength + peaks.length);
  out.setRange(0, 3, _waveformMagic);
  out[3] = _waveformVersion;
  out[4] = peaks.length & 0xFF;
  out[5] = (peaks.length >> 8) & 0xFF;
  out.setRange(_waveformHeaderLength, out.length, peaks);
  return out;
}

/// `null` si los bytes no son un archivo válido de esta versión: el
/// llamador lo trata como "no hay caché" y vuelve a extraer.
Uint8List? decodeWaveform(Uint8List bytes) {
  if (bytes.length < _waveformHeaderLength) return null;
  for (var i = 0; i < 3; i++) {
    if (bytes[i] != _waveformMagic[i]) return null;
  }
  if (bytes[3] != _waveformVersion) return null;
  final count = bytes[4] | (bytes[5] << 8);
  if (count == 0 || bytes.length != _waveformHeaderLength + count) return null;
  return Uint8List.fromList(bytes.sublist(_waveformHeaderLength));
}

/// Posición horizontal -> fracción 0..1 del ancho.
double positionToFraction(double dx, double width) {
  if (width <= 0 || dx.isNaN) return 0;
  return (dx / width).clamp(0.0, 1.0);
}

/// Fracción 0..1 -> posición dentro de [duration].
Duration fractionToDuration(double fraction, Duration duration) {
  final f = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
  return Duration(milliseconds: (duration.inMilliseconds * f).round());
}

/// Posición -> fracción 0..1 (0 si no hay duración).
double durationToFraction(Duration position, Duration duration) {
  if (duration.inMilliseconds <= 0) return 0;
  return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}
