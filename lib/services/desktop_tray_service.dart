import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import 'desktop_mini_mode_service.dart';

/// Clave de navegador raíz, para poder mostrar el diálogo de "¿minimizar o
/// cerrar?" desde acá (un servicio plano, sin `BuildContext` propio) — se
/// engancha en el `MaterialApp` de `main.dart`.
final GlobalKey<NavigatorState> desktopRootNavigatorKey = GlobalKey<NavigatorState>();

/// Bandeja del sistema + estado de visibilidad de la ventana, sólo para
/// escritorio. Cerrar la ventana pregunta si minimizar a la bandeja (la
/// reproducción sigue sonando) o cerrar Heardy del todo — antes se ocultaba
/// directo a la bandeja sin preguntar, lo que dejaba sin ninguna forma
/// evidente de cerrar de verdad si además el clic derecho del ícono no
/// abría el menú (ver `onTrayIconRightMouseDown`, bug real reportado en vivo:
/// `trayManager.setContextMenu` por sí solo no engancha el clic derecho).
///
/// [isVisible] es además la única fuente de verdad de "¿la ventana se ve
/// ahora mismo?": queda en `false` mientras está minimizada u oculta en la
/// bandeja, para que animaciones caras (el disco girando del modo cine, ver
/// `now_playing_screen.dart`) se pausen solas sin que cada una tenga que
/// escuchar eventos de ventana por su cuenta.
class DesktopTrayService with TrayListener, WindowListener {
  DesktopTrayService._();
  static final DesktopTrayService instance = DesktopTrayService._();

  final ValueNotifier<bool> isVisible = ValueNotifier<bool>(true);

  Future<void> init({
    required String showLabel,
    required String quitLabel,
  }) async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    await trayManager.setIcon('assets/icon/tray_icon.ico');
    await trayManager.setToolTip('Heardy');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: showLabel, onClick: (_) => _show()),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: quitLabel, onClick: (_) => _quit()),
        ],
      ),
    );
  }

  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    isVisible.dispose();
  }

  @override
  void onWindowClose() async {
    // `windowManager.close()` (el botón de cerrar de la barra de título
    // propia, Alt+F4, "Cerrar" del menú de la barra de tareas) dispara este
    // evento igual estando `preventClose` activo — se intercepta acá en vez
    // de tocar el botón de la barra de título, para cubrir todos los
    // caminos de cierre de una sola vez.
    if (!await windowManager.isPreventClose()) return;

    final context = desktopRootNavigatorKey.currentContext;
    if (context == null) {
      // Sin árbol de widgets todavía (cierre disparado antes del primer
      // frame): no hay dónde mostrar el diálogo, así que se cae al
      // comportamiento anterior en vez de bloquear el cierre.
      await windowManager.hide();
      isVisible.value = false;
      return;
    }

    // En modo mini la ventana mide 320x180: el diálogo no cabe y el botón de
    // "Cerrar Heardy" queda fuera de alcance, así que se restaura primero.
    await DesktopMiniModeService.instance.exit();
    await windowManager.show();
    final l10n = AppLocalizations.of(context)!;
    final quit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.desktopCloseDialogTitle),
        content: Text(l10n.desktopCloseDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.desktopCloseDialogMinimize),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.desktopCloseDialogQuit),
          ),
        ],
      ),
    );

    if (quit == true) {
      await _quit();
    } else if (quit == false) {
      await windowManager.hide();
      isVisible.value = false;
    }
    // `quit == null` (Escape, tocar fuera del diálogo): se cancela el
    // cierre y la ventana se queda tal cual, visible — ya se mostró arriba.
  }

  @override
  void onWindowMinimize() => isVisible.value = false;

  @override
  void onWindowRestore() => isVisible.value = true;

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
    isVisible.value = true;
  }

  Future<void> _quit() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
