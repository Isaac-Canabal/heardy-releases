import 'package:flutter/widgets.dart';

/// Lo que el shell de escritorio expone a las pantallas que viven dentro de
/// su columna de contenido: si el panel de "reproduciendo ahora" está
/// abierto y cómo abrirlo. Ausente en el diseño de teléfono (y por tanto
/// siempre en Android), así que `maybeOf` devolviendo `null` es la señal de
/// "comportate como siempre" — es lo que hace que `MiniPlayer` siga
/// existiendo tal cual en el teléfono y desaparezca en el escritorio, donde
/// la barra inferior del shell ya cumple su papel.
class DesktopShellScope extends InheritedWidget {
  final bool panelOpen;
  final VoidCallback openNowPlaying;
  final VoidCallback toggleNowPlaying;
  final ValueChanged<String> openPlaylist;

  const DesktopShellScope({
    super.key,
    required this.panelOpen,
    required this.openNowPlaying,
    required this.toggleNowPlaying,
    required this.openPlaylist,
    required super.child,
  });

  static DesktopShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopShellScope>();

  @override
  bool updateShouldNotify(DesktopShellScope oldWidget) =>
      panelOpen != oldWidget.panelOpen;
}
