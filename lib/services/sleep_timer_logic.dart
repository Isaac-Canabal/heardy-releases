const int maxSleepTracks = 50;

int clampSleepTracks(int value) => value.clamp(1, maxSleepTracks);

/// Cuenta de pistas para el temporizador de sueño: la pista en curso cuenta
/// como la primera, así que con N = 1 se detiene al terminar la actual.
class TrackSleepCounter {
  int? _remaining;

  int? get remaining => _remaining;
  bool get isActive => _remaining != null;

  void start(int tracks) => _remaining = clampSleepTracks(tracks);

  void cancel() => _remaining = null;

  /// Una pista terminó. Devuelve true cuando hay que detener la reproducción.
  bool onTrackEnded() {
    final left = _remaining;
    if (left == null) return false;
    if (left <= 1) {
      _remaining = null;
      return true;
    }
    _remaining = left - 1;
    return false;
  }
}
