import 'dart:math' as math;

/// Ganancias de potencia constante (saliente, entrante) para el progreso
/// [t] en 0..1; un fundido lineal deja un hueco de volumen a mitad.
(double, double) crossfadeGains(double t) {
  final p = t.isNaN ? 0.0 : t.clamp(0.0, 1.0);
  final angle = p * math.pi / 2;
  return (math.cos(angle), math.sin(angle));
}
