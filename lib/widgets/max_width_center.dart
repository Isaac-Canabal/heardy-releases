import 'package:flutter/material.dart';

/// Centra [child] con un ancho máximo, sin aflojar la altura — el problema
/// real de `Center(child: ConstrainedBox(maxWidth: ...))`: `Center` afloja
/// las restricciones en LOS DOS ejes, no sólo el ancho, así que cualquier
/// hijo que dependa de una altura real (un `Scaffold`, una `Column` con
/// `spaceEvenly`) colapsa a casi nada. Bug real, encontrado con el `.exe`
/// instalado de verdad (W3 del plan de escritorio): sólo se veía el menú
/// inferior, con su propia altura fija; el resto de la pantalla, en blanco.
///
/// En un teléfono real, [maxWidth] nunca es el límite (el ancho disponible
/// ya es menor), así que esto es un no-op ahí — sin necesidad de ninguna
/// guarda de plataforma.
class MaxWidthCenter extends StatelessWidget {
  final double maxWidth;

  /// `false` para un hijo que ya sabe su propia altura (p. ej. la barra de
  /// navegación inferior, cuya altura la fija `NavigationBar.height`) — ahí
  /// forzar la altura completa de la ventana lo estiraría de más.
  final bool stretchHeight;

  final Widget child;

  const MaxWidthCenter({
    super.key,
    this.maxWidth = 480,
    this.stretchHeight = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < maxWidth
            ? constraints.maxWidth
            : maxWidth;
        return Align(
          // El segundo bug real, encontrado con el mismo `.exe`: `Align`
          // sin `heightFactor` se expande a TODA la altura disponible —
          // aunque su hijo (acá, la barra de navegación) tenga una altura
          // fija propia — en vez de encogerse a la altura real del hijo.
          // Con `stretchHeight: false` eso hacía que `Align` reportara
          // ~682px de alto a `Scaffold` (toda la ventana) en vez de los
          // 68px reales de `NavigationBar`, así que `Scaffold` le daba a
          // el `body` una altura de exactamente 0 — el bug original
          // reportado ("sólo se ve el menú inferior") no era sólo la
          // ausencia de altura explícita; era este `Align` estirándose de
          // más. `heightFactor: 1` fuerza a `Align` a medir exactamente lo
          // que el hijo necesita, nunca más.
          heightFactor: stretchHeight ? null : 1.0,
          child: SizedBox(
            width: width,
            height: stretchHeight ? constraints.maxHeight : null,
            child: child,
          ),
        );
      },
    );
  }
}
