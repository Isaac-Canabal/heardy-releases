const Duration trackFadeDuration = Duration(seconds: 3);

/// Ganancia (0..1) por posición: sube desde 0 al inicio de la pista y baja a 0
/// al final. Depende sólo de la posición, así un salto o una pausa nunca deja
/// el volumen a medias. Sin duración conocida, sin fundido, o en pistas
/// demasiado cortas (< 3 fundidos) devuelve 1.0.
double trackFadeGain(Duration position, Duration duration, Duration fade) {
  if (fade <= Duration.zero || duration <= fade * 3) return 1.0;
  final fadeUs = fade.inMicroseconds;
  final intoTrack = position.inMicroseconds / fadeUs;
  final untilEnd = (duration - position).inMicroseconds / fadeUs;
  final g = intoTrack < untilEnd ? intoTrack : untilEnd;
  return g.clamp(0.0, 1.0);
}

/// Evita llamar al motor de audio por cambios imperceptibles; los extremos
/// siempre se aplican para no dejar 0.99 / 0.01 fijos.
bool shouldApplyGain(double previous, double next) {
  if (next == previous) return false;
  if (next == 1.0 || next == 0.0) return true;
  return (next - previous).abs() >= 0.02;
}
