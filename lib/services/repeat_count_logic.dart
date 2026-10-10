const int maxRepeatCount = 20;

int clampRepeatCount(int value) => value.clamp(1, maxRepeatCount);

/// Repeticiones extra de la canción actual antes de seguir con la cola.
class RepeatCounter {
  int _remaining = 0;

  int get remaining => _remaining;
  bool get isActive => _remaining > 0;

  void start(int extraPlays) => _remaining = clampRepeatCount(extraPlays);

  void cancel() => _remaining = 0;

  /// La canción volvió a empezar por el bucle. Devuelve true mientras el
  /// bucle deba seguir; false cuando esa vuelta era la última repetición.
  bool onWrap() {
    if (_remaining <= 0) return false;
    _remaining--;
    return _remaining > 0;
  }
}
