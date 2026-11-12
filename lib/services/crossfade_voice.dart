/// Voz fantasma: un segundo reproductor que sólo sostiene la cola de la pista
/// saliente mientras el reproductor principal ya está en la siguiente.
abstract class GhostVoice {
  /// Carga [source] en pausa, posicionada en [position].
  Future<void> load(Object source, Duration position);
  Future<void> seek(Duration position);

  /// Arranca sin esperar a que la pista termine.
  Future<void> play();
  Future<void> stop();
  Future<void> setVolume(double volume);
  Future<void> dispose();
}
