import 'package:flutter/services.dart';

/// Qué hacer con una tecla física del teclado de escritorio, si algo — ver
/// W3 del plan de escritorio (`heardy-escritorio-windows.md`). Extraída pura
/// para poder probarla sin levantar un árbol de widgets.
enum DesktopPlaybackShortcut {
  playPause,
  seekBack,
  seekForward,
  volumeUp,
  volumeDown,
  // Teclas multimedia: distintas de `playPause` (espacio) porque, con las
  // teclas globales nativas activas, la app debe ignorarlas para no duplicar.
  mediaPlayPause,
  next,
  previous,
  none,
}

DesktopPlaybackShortcut desktopShortcutFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.mediaPlayPause) return DesktopPlaybackShortcut.mediaPlayPause;
  if (key == LogicalKeyboardKey.mediaTrackNext) return DesktopPlaybackShortcut.next;
  if (key == LogicalKeyboardKey.mediaTrackPrevious) return DesktopPlaybackShortcut.previous;
  if (key == LogicalKeyboardKey.space) return DesktopPlaybackShortcut.playPause;
  if (key == LogicalKeyboardKey.arrowLeft) return DesktopPlaybackShortcut.seekBack;
  if (key == LogicalKeyboardKey.arrowRight) return DesktopPlaybackShortcut.seekForward;
  if (key == LogicalKeyboardKey.arrowUp) return DesktopPlaybackShortcut.volumeUp;
  if (key == LogicalKeyboardKey.arrowDown) return DesktopPlaybackShortcut.volumeDown;
  return DesktopPlaybackShortcut.none;
}
