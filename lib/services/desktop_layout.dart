import 'dart:ui';

/// Decisiones puras del diseño de escritorio (W3 del plan de escritorio):
/// a partir de qué ancho se usa, y cuánto mide cada columna. Extraídas para
/// probarlas sin levantar el shell (que lee el `AudioPlayerHandler` real y
/// no se puede testear con widgets en este codebase).
class DesktopLayoutSpec {
  final double sidebarWidth;

  /// 0 cuando el panel de "reproduciendo ahora" está cerrado.
  final double panelWidth;
  final double contentWidth;

  const DesktopLayoutSpec({
    required this.sidebarWidth,
    required this.panelWidth,
    required this.contentWidth,
  });
}

/// A partir de acá la ventana da para el diseño de tres columnas (barra
/// lateral + contenido + panel). Por debajo se usa el diseño de teléfono tal
/// cual, que es también lo que ve Android siempre.
const double desktopBreakpoint = 900;

const double desktopSidebarWidth = 240;

/// El panel derecho ocupa un tercio de la ventana, acotado para que una
/// ventana enorme no lo convierta en una carátula gigante ni una ventana al
/// límite lo deje demasiado angosto para la letra.
const double minPanelWidth = 300;
const double maxPanelWidth = 460;

bool isDesktopLayout(double width) => width >= desktopBreakpoint;

/// Tamaño mínimo real de la ventana (`WindowOptions.minimumSize` en
/// main.dart). El modo mini (`DesktopMiniModeService`) lo relaja
/// temporalmente para poder encoger por debajo de esto, y lo restaura al
/// salir — compartido acá en vez de duplicado en los dos sitios, porque un
/// valor desincronizado deja el modo mini incapaz de volver al tamaño
/// mínimo real.
const Size desktopMinimumWindowSize = Size(1040, 640);

DesktopLayoutSpec desktopLayoutFor({
  required double width,
  required bool panelOpen,
}) {
  final panel = panelOpen
      ? (width / 3).clamp(minPanelWidth, maxPanelWidth).toDouble()
      : 0.0;
  return DesktopLayoutSpec(
    sidebarWidth: desktopSidebarWidth,
    panelWidth: panel,
    contentWidth: width - desktopSidebarWidth - panel,
  );
}

/// Un paso del volumen desde el teclado (flechas arriba/abajo).
const double volumeStep = 0.05;

double steppedVolume(double current, {required bool up}) {
  final next = current + (up ? volumeStep : -volumeStep);
  // Redondeo a dos decimales: sumar 0.05 en coma flotante acumula basura
  // (0.15000000000000002) que después se ve en el porcentaje del tooltip.
  return ((next * 100).round() / 100).clamp(0.0, 1.0).toDouble();
}
