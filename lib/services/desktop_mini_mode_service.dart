import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_layout.dart';

/// "Minimizar y superponer" (sólo Windows): encoge la ventana actual a un
/// rectángulo chico, siempre encima de las demás ventanas, en vez de abrir
/// una ventana de sistema operativo aparte — evita depender de soporte
/// multi-ventana (que Flutter desktop no tiene de fábrica) y de sincronizar
/// estado de reproducción entre dos ventanas separadas.
class DesktopMiniModeService {
  DesktopMiniModeService._();
  static final DesktopMiniModeService instance = DesktopMiniModeService._();

  final ValueNotifier<bool> isMini = ValueNotifier<bool>(false);

  static const _miniSize = Size(320, 180);
  static const _screenMargin = 16.0;

  Size? _restoreSize;
  Offset? _restorePosition;

  Future<void> enter() async {
    if (isMini.value) return;
    _restoreSize = await windowManager.getSize();
    _restorePosition = await windowManager.getPosition();

    // `WindowOptions.minimumSize` (main.dart) fija un mínimo real a nivel de
    // SO — sin relajarlo acá, Windows rechaza en silencio cualquier
    // `setSize` por debajo de él, y sólo `setAlwaysOnTop` llega a surtir
    // efecto (reproducido en vivo: "superponer" funcionaba, "minimizar" no).
    await windowManager.setMinimumSize(_miniSize);
    await windowManager.setResizable(false);
    await windowManager.setSize(_miniSize);
    await windowManager.setPosition(await _bottomRightTarget());
    await windowManager.setAlwaysOnTop(true);
    isMini.value = true;
  }

  Future<void> exit() async {
    if (!isMini.value) return;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    final size = _restoreSize;
    final position = _restorePosition;
    if (size != null) await windowManager.setSize(size);
    if (position != null) await windowManager.setPosition(position);
    await windowManager.setMinimumSize(desktopMinimumWindowSize);
    isMini.value = false;
  }

  Future<void> toggle() => isMini.value ? exit() : enter();

  /// Esquina inferior derecha del área útil de la pantalla principal (sin
  /// tapar la barra de tareas). Si `screen_retriever` no puede resolverlo
  /// (falla de plataforma, monitor desconectado), se cae a la posición
  /// actual de la ventana — nunca deja el toggle a medias.
  Future<Offset> _bottomRightTarget() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final workPosition = display.visiblePosition ?? Offset.zero;
      final workSize = display.visibleSize ?? display.size;
      return Offset(
        workPosition.dx + workSize.width - _miniSize.width - _screenMargin,
        workPosition.dy + workSize.height - _miniSize.height - _screenMargin,
      );
    } catch (_) {
      return _restorePosition ?? Offset.zero;
    }
  }
}
