/// Decisiones puras de la barra de título propia de escritorio (la ventana
/// se abre con `TitleBarStyle.hidden` y la app dibuja la suya): cuánto
/// mide, qué hace el botón del medio y cuánto borde superior reservar para
/// redimensionar. Extraídas para probarlas sin `window_manager`, que no
/// tiene doble de test.
enum WindowCaptionAction { minimize, maximize, restore, close }

const double desktopTitleBarHeight = 40;
const double windowCaptionButtonWidth = 46;

/// Franja superior de la barra que actúa como asa de redimensionado: con la
/// barra nativa oculta, el marco de arriba desaparece y sin esto no habría
/// forma de estirar la ventana desde ese borde.
const double windowTopResizeEdge = 4;

class DesktopTitleBarSpec {
  final double height;

  /// 0 si la ventana está maximizada: ahí no hay nada que redimensionar y
  /// la franja sólo robaría clics al arrastre y a los botones.
  final double resizeEdge;

  /// Lo que hace el botón del medio: maximizar si la ventana está
  /// restaurada, restaurar si ya está maximizada.
  final WindowCaptionAction middleAction;

  const DesktopTitleBarSpec({
    required this.height,
    required this.resizeEdge,
    required this.middleAction,
  });

  List<WindowCaptionAction> get buttons => [
        WindowCaptionAction.minimize,
        middleAction,
        WindowCaptionAction.close,
      ];
}

DesktopTitleBarSpec desktopTitleBarFor({required bool maximized}) {
  return DesktopTitleBarSpec(
    height: desktopTitleBarHeight,
    resizeEdge: maximized ? 0 : windowTopResizeEdge,
    middleAction: maximized
        ? WindowCaptionAction.restore
        : WindowCaptionAction.maximize,
  );
}

/// Doble clic en la zona de arrastre: alterna maximizar/restaurar, igual que
/// la barra nativa de Windows.
WindowCaptionAction titleBarDoubleClickAction({required bool maximized}) =>
    maximized ? WindowCaptionAction.restore : WindowCaptionAction.maximize;
