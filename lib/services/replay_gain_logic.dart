import 'dart:math' as math;

/// Piso del factor: una ganancia absurda (-60 dB) no debe dejar la pista casi
/// muda.
const double minReplayGainFactor = 0.1;

final _gainNumber = RegExp(r'^[+-]?\d+(?:[.,]\d+)?');

/// "-6.54 dB" -> -6.54. null si no es un número finito.
double? parseReplayGainDb(String? raw) {
  if (raw == null) return null;
  final m = _gainNumber.firstMatch(raw.trim());
  if (m == null) return null;
  final value = double.tryParse(m.group(0)!.replaceAll(',', '.'));
  if (value == null || !value.isFinite) return null;
  return value;
}

/// dB -> factor lineal de volumen, acotado a [minReplayGainFactor, 1.0]. Nunca
/// sube por encima de 1.0 (el reproductor no tiene margen sobre el volumen
/// máximo y amplificar saturaría): las pistas más bajas quedan como están y
/// las más fuertes se atenúan.
double replayGainFactor(double gainDb) {
  final linear = math.pow(10, gainDb / 20).toDouble();
  return linear.clamp(minReplayGainFactor, 1.0);
}

/// Ganancia de pista (o de álbum si falta) de un mapa de etiquetas, sin
/// distinguir mayúsculas en las claves.
double? pickTrackGainDb(Map<String, String> tags) {
  final upper = {for (final e in tags.entries) e.key.toUpperCase(): e.value};
  return parseReplayGainDb(upper['REPLAYGAIN_TRACK_GAIN']) ??
      parseReplayGainDb(upper['REPLAYGAIN_ALBUM_GAIN']);
}
