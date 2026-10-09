import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../services/desktop_title_bar.dart';
import '../theme/app_theme.dart';

/// Barra de título propia para escritorio: la ventana se abre con
/// `TitleBarStyle.hidden` (main.dart) y esta barra sustituye a la nativa a
/// todo el ancho, por encima de las tres columnas del shell y de cualquier
/// pantalla que se abra a pantalla completa (se monta desde el `builder` de
/// `MaterialApp`, no en cada pantalla). Izquierda: icono y nombre; centro:
/// arrastre (doble clic = maximizar/restaurar); derecha: los tres botones al
/// estilo de Windows. El marco nativo sigue ahí (redimensionar desde los
/// bordes, ajustar a los lados), sólo desaparece la franja de arriba.
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted && value != _maximized) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  void _run(WindowCaptionAction action) {
    switch (action) {
      case WindowCaptionAction.minimize:
        windowManager.minimize();
      case WindowCaptionAction.maximize:
        windowManager.maximize();
      case WindowCaptionAction.restore:
        windowManager.unmaximize();
      case WindowCaptionAction.close:
        windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = desktopTitleBarFor(maximized: _maximized);
    final bar = Material(
      color: AppTheme.backgroundTop,
      child: SizedBox(
        height: spec.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: () =>
                    _run(titleBarDoubleClickAction(maximized: _maximized)),
                child: const _TitleBarBrand(),
              ),
            ),
            for (final action in spec.buttons)
              _CaptionButton(action: action, onPressed: () => _run(action)),
          ],
        ),
      ),
    );
    if (spec.resizeEdge == 0) return bar;
    // Altura acotada obligatoria: `DragToResizeArea` monta por dentro una
    // `Column` con `Expanded`, que bajo la altura libre de la `Column`
    // exterior falla en el layout y deja toda la app sin pintar.
    return SizedBox(
      height: spec.height,
      child: DragToResizeArea(
        resizeEdgeSize: spec.resizeEdge,
        enableResizeEdges: const [
          ResizeEdge.topLeft,
          ResizeEdge.top,
          ResizeEdge.topRight,
        ],
        child: bar,
      ),
    );
  }
}

class _TitleBarBrand extends StatelessWidget {
  const _TitleBarBrand();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.asset(
              'assets/icon/app_icon.png',
              width: 18,
              height: 18,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final WindowCaptionAction action;
  final VoidCallback onPressed;

  const _CaptionButton({required this.action, required this.onPressed});

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  bool get _isClose => widget.action == WindowCaptionAction.close;

  Color get _background {
    if (!_hovered && !_pressed) return Colors.transparent;
    if (_isClose) {
      return _pressed ? const Color(0xFFF1707A) : const Color(0xFFC42B1C);
    }
    return Colors.white.withValues(alpha: _pressed ? 0.06 : 0.1);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: windowCaptionButtonWidth,
          color: _background,
          alignment: Alignment.center,
          child: CustomPaint(
            size: const Size(10, 10),
            painter: _CaptionGlyphPainter(
              action: widget.action,
              color: Colors.white.withValues(alpha: _hovered ? 1 : 0.85),
            ),
          ),
        ),
      ),
    );
  }
}

/// Los glifos de Windows 11 dibujados a mano (10 px, trazo de 1 px): una
/// raya, un cuadrado, dos cuadrados solapados y una cruz. Los `Icons.*` de
/// Material quedan demasiado gruesos a este tamaño.
class _CaptionGlyphPainter extends CustomPainter {
  final WindowCaptionAction action;
  final Color color;

  const _CaptionGlyphPainter({required this.action, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;
    switch (action) {
      case WindowCaptionAction.minimize:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), paint);
      case WindowCaptionAction.maximize:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0.5, 0.5, w - 1, h - 1),
            const Radius.circular(1.5),
          ),
          paint,
        );
      case WindowCaptionAction.restore:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0.5, 2.5, w - 3, h - 3),
            const Radius.circular(1.5),
          ),
          paint,
        );
        final back = Path()
          ..moveTo(2.5, 2.5)
          ..lineTo(2.5, 1.5)
          ..quadraticBezierTo(2.5, 0.5, 3.5, 0.5)
          ..lineTo(w - 1.5, 0.5)
          ..quadraticBezierTo(w - 0.5, 0.5, w - 0.5, 1.5)
          ..lineTo(w - 0.5, h - 3.5)
          ..quadraticBezierTo(w - 0.5, h - 2.5, w - 1.5, h - 2.5)
          ..lineTo(w - 2.5, h - 2.5);
        canvas.drawPath(back, paint);
      case WindowCaptionAction.close:
        canvas.drawLine(Offset.zero, Offset(w, h), paint);
        canvas.drawLine(Offset(w, 0), Offset(0, h), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter old) =>
      old.action != action || old.color != color;
}
