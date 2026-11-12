import 'dart:async';

import 'transition_preview_player.dart';

/// Decide cuándo y cómo se repite la escucha de una transición.
///
/// La repetición real la hace el reproductor ([TransitionPreviewPlayer.setLoop]);
/// el reproductor de la app, al llegar al final sin repetición, se detiene y
/// reinicia su posición, así que mirar la posición después no sirve. Este
/// controlador sólo añade una red de seguridad: si el reproductor igual se
/// detuvo al final, vuelve a lanzar el clip una única vez.
class TransitionPreviewLoop {
  TransitionPreviewLoop({
    required this.player,
    required this.replay,
    this.endMargin = const Duration(milliseconds: 80),
    this.nearEndWindow = const Duration(milliseconds: 800),
  });

  final TransitionPreviewPlayer player;

  /// Vuelve a cargar y reproducir el clip desde el principio.
  final Future<void> Function() replay;
  final Duration endMargin;
  final Duration nearEndWindow;

  bool _enabled = true;
  bool _replaying = false;
  bool _nearEnd = false;
  String? _id;
  Duration _length = Duration.zero;

  bool get enabled => _enabled;
  bool get active => _id != null;

  /// El clip [id] de duración [length] acaba de empezar a sonar.
  Future<void> begin(String id, Duration length) async {
    _id = id;
    _length = length;
    _nearEnd = false;
    await _apply(_enabled);
  }

  /// Activa o desactiva la repetición; con el clip sonando surte efecto ya.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (active) await _apply(value);
  }

  /// La escucha terminó (pausa del editor, otro clip o cierre de la pantalla):
  /// deja el reproductor sin repetición propia.
  Future<void> end() async {
    if (!active) return;
    _id = null;
    _nearEnd = false;
    await _apply(false);
  }

  Future<void> _apply(bool on) async {
    try {
      await player.setLoop(on);
    } catch (_) {}
  }

  /// Red de seguridad por si el reproductor se detuvo al final igualmente.
  Future<void> onTick(TransitionPreviewTick t) async {
    final id = _id;
    if (id == null || !_enabled || _replaying || t.mediaId != id || _length <= Duration.zero) return;
    final end = _length - endMargin;
    if (t.playing) {
      _nearEnd = t.position >= _length - nearEndWindow;
      return;
    }
    final stoppedAtEnd = t.position >= end || (t.position == Duration.zero && _nearEnd);
    if (!stoppedAtEnd) return;
    _replaying = true;
    _nearEnd = false;
    try {
      await replay();
    } finally {
      _replaying = false;
    }
  }
}
