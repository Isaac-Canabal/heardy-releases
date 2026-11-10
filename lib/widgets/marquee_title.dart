import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

const double kMarqueePixelsPerSecond = 40;

/// La ruta de Now Playing tarda unos 300 ms en deslizarse y la paleta espera
/// 320 ms: arrancar antes movería el título mientras la pantalla aún entra.
const Duration kMarqueeStartDelay = Duration(milliseconds: 600);
const Duration kMarqueeEndHold = Duration(seconds: 1);
const Duration kMarqueeStartHold = Duration(milliseconds: 500);
const int kMarqueePasses = 2;

/// Tiempo de un recorrido de [distance] px a velocidad fija, para que títulos
/// largos y cortos se sientan iguales.
Duration marqueeSlideDuration(double distance) {
  if (distance <= 0) return Duration.zero;
  final seconds = distance / kMarqueePixelsPerSecond;
  return Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );
}

Duration _marqueePassDuration(double distance) {
  final slide = marqueeSlideDuration(distance);
  return slide + kMarqueeEndHold + slide + kMarqueeStartHold;
}

/// Duración total: el retardo más todas las pasadas. Cero si no hay desborde.
Duration marqueeSequenceDuration(
  double distance, {
  Duration startDelay = kMarqueeStartDelay,
}) {
  if (distance <= 0) return Duration.zero;
  return startDelay + _marqueePassDuration(distance) * kMarqueePasses;
}

/// Desplazamiento en px, de 0 a [distance], a los [elapsed] de iniciada la
/// secuencia. Lineal: es movimiento constante, no una entrada ni una salida.
double marqueeOffsetAt(
  Duration elapsed,
  double distance, {
  Duration startDelay = kMarqueeStartDelay,
}) {
  final slide = marqueeSlideDuration(distance);
  if (slide == Duration.zero) return 0;
  final running = elapsed - startDelay;
  final pass = _marqueePassDuration(distance);
  if (running <= Duration.zero || running >= pass * kMarqueePasses) return 0;

  var inPass = running.inMicroseconds % pass.inMicroseconds;
  if (inPass < slide.inMicroseconds) {
    return distance * inPass / slide.inMicroseconds;
  }
  inPass -= slide.inMicroseconds;
  if (inPass < kMarqueeEndHold.inMicroseconds) return distance;
  inPass -= kMarqueeEndHold.inMicroseconds;
  if (inPass < slide.inMicroseconds) {
    return distance * (1 - inPass / slide.inMicroseconds);
  }
  return 0;
}

/// Título de una línea que, si no cabe, se desliza para mostrarse completo:
/// dos pasadas al aparecer, al cambiar de título y al tocarlo. En reposo se ve
/// truncado con puntos suspensivos.
class MarqueeTitle extends StatefulWidget {
  final String title;
  final TextStyle? style;
  final TextAlign textAlign;
  final Duration startDelay;

  const MarqueeTitle(
    this.title, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.startDelay = kMarqueeStartDelay,
  });

  @override
  State<MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<MarqueeTitle>
    with SingleTickerProviderStateMixin {
  // Toda la secuencia, retardo y pausas incluidos, es un único controlador:
  // reiniciar nunca apila temporizadores y dispose no deja nada pendiente.
  late final AnimationController _controller;

  // Sigue en true hasta que este título haga sus pasadas, aunque hoy quepa:
  // si una rotación lo hace desbordar después, aún no se ha mostrado completo.
  bool _runPending = true;
  bool _syncScheduled = false;

  double _measuredDistance = 0;
  bool _animationsDisabled = false;

  double _runDistance = 0;
  Duration _runDelay = Duration.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(MarqueeTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // mediaItem.add emite desde muchos sitios: sólo cuenta el texto.
    if (oldWidget.title != widget.title) {
      _runPending = true;
      if (_controller.isAnimating) _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measureOverflow({
    required double availableWidth,
    required TextStyle style,
    required TextDirection direction,
    required TextScaler textScaler,
    required Locale? locale,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: widget.title, style: style),
      textDirection: direction,
      textScaler: textScaler,
      locale: locale,
      maxLines: 1,
    )..layout();
    final overflow = painter.width - availableWidth;
    painter.dispose();
    return overflow > 0 ? overflow : 0;
  }

  // La medida sale de LayoutBuilder, en plena fase de layout, donde no se puede
  // tocar el controlador: sus oyentes marcarían widgets para reconstruir.
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _sync();
    });
  }

  void _sync() {
    if (_measuredDistance <= 0 || _animationsDisabled) {
      if (_controller.isAnimating) _controller.reset();
    } else if (_runPending) {
      _play(widget.startDelay);
    } else if (_controller.isAnimating && _measuredDistance != _runDistance) {
      // Redimensionar conserva el progreso proporcional en vez de reiniciar.
      _runDistance = _measuredDistance;
      _controller.duration = marqueeSequenceDuration(
        _runDistance,
        startDelay: _runDelay,
      );
      _controller.forward();
    }
  }

  void _play(Duration delay) {
    _runPending = false;
    _runDelay = delay;
    _runDistance = _measuredDistance;
    _controller.duration = marqueeSequenceDuration(
      _runDistance,
      startDelay: delay,
    );
    _controller.forward(from: 0);
  }

  Widget _staticText() {
    return Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.textAlign,
      style: widget.style,
    );
  }

  Widget _slidingText(TextDirection direction) {
    return AnimatedBuilder(
      animation: _controller,
      child: Text(
        widget.title,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: widget.style,
      ),
      builder: (context, child) {
        if (!_controller.isAnimating) return _staticText();
        final elapsed = _controller.duration! * _controller.value;
        if (elapsed < _runDelay) return _staticText();
        final offset = marqueeOffsetAt(
          elapsed,
          _runDistance,
          startDelay: _runDelay,
        );
        return RepaintBoundary(
          child: ClipRect(
            child: OverflowBox(
              fit: OverflowBoxFit.deferToChild,
              minWidth: 0,
              maxWidth: double.infinity,
              alignment: AlignmentDirectional.centerStart,
              child: Transform.translate(
                offset: Offset(
                  direction == TextDirection.rtl ? offset : -offset,
                  0,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    final direction = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    // Igual que Text, para medir exactamente lo que se va a pintar.
    var style = DefaultTextStyle.of(context).style.merge(widget.style);
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final distance = _measureOverflow(
          availableWidth: constraints.maxWidth,
          style: style,
          direction: direction,
          textScaler: textScaler,
          locale: locale,
        );
        _measuredDistance = distance;
        _animationsDisabled = animationsDisabled;
        _scheduleSync();

        if (distance <= 0 || animationsDisabled) return _staticText();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // El toque sólo repite un efecto visual: no es una acción para el
          // lector de pantalla, que ya recibe el título completo.
          excludeFromSemantics: true,
          // El retardo es para la entrada de la ruta; aquí el usuario espera
          // respuesta inmediata.
          onTap: () => _play(Duration.zero),
          child: _slidingText(direction),
        );
      },
    );
  }
}
