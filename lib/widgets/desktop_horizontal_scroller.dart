import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/desktop_layout.dart';

/// Cuánto hay que añadir al alto de una fila horizontal en escritorio para
/// que la barra de desplazamiento no tape el pie de las tarjetas.
const double kDesktopScrollbarGap = 14;

/// Posición del scroll a la que saltan las flechas ‹ ›: casi una pantalla
/// ([fraction] del viewport), acotada al rango válido. Pura para poder
/// probarla sin pintar nada.
double desktopScrollTarget({
  required double offset,
  required double viewport,
  required double maxExtent,
  required bool forward,
  double fraction = 0.8,
}) {
  final step = viewport * fraction;
  return (forward ? offset + step : offset - step).clamp(0.0, maxExtent < 0 ? 0.0 : maxExtent);
}

/// Fila que se desplaza en horizontal. En escritorio añade arrastre con el
/// ratón, una barra visible y flechas ‹ › cuando hay desbordamiento; en
/// teléfono (ancho < [desktopBreakpoint]) sólo entrega el [builder] tal cual.
class DesktopHorizontalScroller extends StatefulWidget {
  final double height;
  final Widget Function(BuildContext context, ScrollController controller, EdgeInsets extraPadding) builder;

  const DesktopHorizontalScroller({super.key, required this.height, required this.builder});

  @override
  State<DesktopHorizontalScroller> createState() => _DesktopHorizontalScrollerState();
}

class _DesktopHorizontalScrollerState extends State<DesktopHorizontalScroller> {
  final ScrollController _controller = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    _controller.removeListener(_updateArrows);
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final back = pos.pixels > 1;
    final forward = pos.pixels < pos.maxScrollExtent - 1;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  void _scrollBy({required bool forward}) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    _controller.animateTo(
      desktopScrollTarget(
        offset: pos.pixels,
        viewport: pos.viewportDimension,
        maxExtent: pos.maxScrollExtent,
        forward: forward,
      ),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopLayout(MediaQuery.sizeOf(context).width);
    if (!desktop) {
      return SizedBox(height: widget.height, child: widget.builder(context, _controller, EdgeInsets.zero));
    }
    // Las flechas se reevalúan tras cada layout: la lista puede cambiar de
    // tamaño (datos que llegan, ventana redimensionada) sin mover el scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
    return SizedBox(
      height: widget.height + kDesktopScrollbarGap,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {...PointerDeviceKind.values}..remove(PointerDeviceKind.unknown),
          scrollbars: false,
        ),
        child: Stack(
          children: [
            Scrollbar(
              controller: _controller,
              thumbVisibility: true,
              child: widget.builder(
                context,
                _controller,
                const EdgeInsets.only(bottom: kDesktopScrollbarGap),
              ),
            ),
            if (_canBack) _arrow(Alignment.centerLeft, Icons.chevron_left_rounded, false),
            if (_canForward) _arrow(Alignment.centerRight, Icons.chevron_right_rounded, true),
          ],
        ),
      ),
    );
  }

  Widget _arrow(Alignment alignment, IconData icon, bool forward) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.only(bottom: kDesktopScrollbarGap, left: 4, right: 4),
        child: Material(
          color: Colors.black.withValues(alpha: 0.65),
          shape: const CircleBorder(),
          child: IconButton(
            key: Key(forward ? 'desktop_scroll_forward' : 'desktop_scroll_back'),
            icon: Icon(icon, color: Colors.white),
            onPressed: () => _scrollBy(forward: forward),
          ),
        ),
      ),
    );
  }
}
