// Cubre la lógica pura de la barra de título propia de escritorio: qué botón
// va en el medio según el estado de la ventana, cuánto borde de redimensionado
// reserva y qué hace el doble clic. El widget en sí habla con
// `window_manager`, que no tiene doble de test.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/desktop_title_bar.dart';

void main() {
  group('desktopTitleBarFor', () {
    test('restaurada: botón de maximizar y franja para redimensionar arriba',
        () {
      final spec = desktopTitleBarFor(maximized: false);
      expect(spec.height, desktopTitleBarHeight);
      expect(spec.resizeEdge, windowTopResizeEdge);
      expect(spec.middleAction, WindowCaptionAction.maximize);
    });

    test('maximizada: botón de restaurar y sin franja de redimensionado', () {
      final spec = desktopTitleBarFor(maximized: true);
      expect(spec.height, desktopTitleBarHeight);
      expect(spec.resizeEdge, 0);
      expect(spec.middleAction, WindowCaptionAction.restore);
    });

    test('la altura no cambia con el estado: nada debajo se mueve', () {
      expect(
        desktopTitleBarFor(maximized: true).height,
        desktopTitleBarFor(maximized: false).height,
      );
    });

    test('siempre tres botones, en el orden de Windows', () {
      expect(desktopTitleBarFor(maximized: false).buttons, [
        WindowCaptionAction.minimize,
        WindowCaptionAction.maximize,
        WindowCaptionAction.close,
      ]);
      expect(desktopTitleBarFor(maximized: true).buttons, [
        WindowCaptionAction.minimize,
        WindowCaptionAction.restore,
        WindowCaptionAction.close,
      ]);
    });
  });

  group('titleBarDoubleClickAction', () {
    test('alterna maximizar/restaurar como la barra nativa', () {
      expect(
        titleBarDoubleClickAction(maximized: false),
        WindowCaptionAction.maximize,
      );
      expect(
        titleBarDoubleClickAction(maximized: true),
        WindowCaptionAction.restore,
      );
    });
  });
}
