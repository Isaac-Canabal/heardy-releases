// Cubre `desktopShortcutFor`, la única parte de los atajos de teclado de
// escritorio (W3 del plan de escritorio) que es una función pura — el
// cableado real (Focus, EditableText, AudioPlayerHandler) vive en main.dart
// y no tiene doble de test en este codebase.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/desktop_shortcuts.dart';

void main() {
  group('desktopShortcutFor', () {
    test('espacio es play/pause', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.space),
        DesktopPlaybackShortcut.playPause,
      );
    });

    test('flecha izquierda retrocede', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.arrowLeft),
        DesktopPlaybackShortcut.seekBack,
      );
    });

    test('flecha derecha adelanta', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.arrowRight),
        DesktopPlaybackShortcut.seekForward,
      );
    });

    test('flechas arriba/abajo son volumen', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.arrowUp),
        DesktopPlaybackShortcut.volumeUp,
      );
      expect(
        desktopShortcutFor(LogicalKeyboardKey.arrowDown),
        DesktopPlaybackShortcut.volumeDown,
      );
    });

    test('teclas multimedia', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.mediaPlayPause),
        DesktopPlaybackShortcut.mediaPlayPause,
      );
      expect(
        desktopShortcutFor(LogicalKeyboardKey.mediaTrackNext),
        DesktopPlaybackShortcut.next,
      );
      expect(
        desktopShortcutFor(LogicalKeyboardKey.mediaTrackPrevious),
        DesktopPlaybackShortcut.previous,
      );
    });

    test('cualquier otra tecla no hace nada', () {
      expect(
        desktopShortcutFor(LogicalKeyboardKey.keyA),
        DesktopPlaybackShortcut.none,
      );
      expect(
        desktopShortcutFor(LogicalKeyboardKey.enter),
        DesktopPlaybackShortcut.none,
      );
    });
  });
}
