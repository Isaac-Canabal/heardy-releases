import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/waveform_logic.dart';

/// Barra de progreso con forma de onda real. El seek se emite al soltar
/// (tap o fin del arrastre), nunca en cada movimiento; [onScrub] avisa de la
/// posición tentativa mientras se arrastra (null al terminar).
class WaveformSeekBar extends StatefulWidget {
  final Uint8List peaks;
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration?>? onScrub;
  final Color activeColor;
  final Color inactiveColor;
  final double height;

  /// Margen lateral: las barras y el área táctil se limitan al ancho interior,
  /// así que tocar en el borde interior izquierdo es 0 y en el derecho el total.
  final double horizontalInset;

  /// Ancho mínimo por barra; si hay más picos que barras caben, se agrupan.
  final double minBarSlot;
  final String semanticsLabel;
  final String semanticsValue;

  const WaveformSeekBar({
    super.key,
    required this.peaks,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.activeColor,
    required this.inactiveColor,
    required this.semanticsLabel,
    required this.semanticsValue,
    this.onScrub,
    this.height = 48,
    this.horizontalInset = 0,
    this.minBarSlot = 0,
  });

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  double? _dragFraction;
  static const Duration _step = Duration(seconds: 5);

  bool get _enabled => widget.duration.inMilliseconds > 0;

  void _scrub(double dx, double width) {
    final f = positionToFraction(dx, width);
    setState(() => _dragFraction = f);
    widget.onScrub?.call(fractionToDuration(f, widget.duration));
  }

  void _commit(double dx, double width) {
    final f = positionToFraction(dx, width);
    setState(() => _dragFraction = null);
    widget.onScrub?.call(null);
    widget.onSeek(fractionToDuration(f, widget.duration));
  }

  void _cancel() {
    if (_dragFraction == null) return;
    setState(() => _dragFraction = null);
    widget.onScrub?.call(null);
  }

  void _seekBy(Duration delta) {
    final target = widget.position + delta;
    final ms = target.inMilliseconds.clamp(0, widget.duration.inMilliseconds);
    widget.onSeek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final fraction =
        _dragFraction ?? durationToFraction(widget.position, widget.duration);
    return Semantics(
      container: true,
      slider: true,
      label: widget.semanticsLabel,
      value: widget.semanticsValue,
      increasedValue: widget.semanticsValue,
      decreasedValue: widget.semanticsValue,
      onIncrease: _enabled ? () => _seekBy(_step) : null,
      onDecrease: _enabled ? () => _seekBy(-_step) : null,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = widget.horizontalInset;
            final width = math.max(constraints.maxWidth - 2 * inset, 1.0);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _enabled
                  ? (d) => _commit(d.localPosition.dx - inset, width)
                  : null,
              onHorizontalDragStart: _enabled
                  ? (d) => _scrub(d.localPosition.dx - inset, width)
                  : null,
              onHorizontalDragUpdate: _enabled
                  ? (d) => _scrub(d.localPosition.dx - inset, width)
                  : null,
              onHorizontalDragEnd: _enabled
                  ? (_) {
                      final f = _dragFraction;
                      if (f != null) _commit(f * width, width);
                    }
                  : null,
              onHorizontalDragCancel: _cancel,
              child: SizedBox(
                height: widget.height,
                width: double.infinity,
                child: CustomPaint(
                  painter: WaveformPainter(
                    peaks: widget.peaks,
                    inset: inset,
                    minBarSlot: widget.minBarSlot,
                    fraction: fraction,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final Uint8List peaks;
  final double fraction;
  final Color activeColor;
  final Color inactiveColor;
  final double inset;
  final double minBarSlot;

  WaveformPainter({
    this.inset = 0,
    this.minBarSlot = 0,
    required this.peaks,
    required this.fraction,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final inner = size.width - 2 * inset;
    if (peaks.isEmpty || inner <= 0) return;
    final n = minBarSlot > 0
        ? math.max(1, math.min(peaks.length, (inner / minBarSlot).floor()))
        : peaks.length;
    final bars = n == peaks.length ? peaks : _group(peaks, n);
    final slot = inner / n;
    final barWidth = (slot * 0.6).clamp(1.0, 6.0);
    final minHeight = 3.0;
    final centerY = size.height / 2;

    void drawBars(Color color) {
      final paint = Paint()..color = color;
      for (var i = 0; i < n; i++) {
        final h = minHeight + (size.height - minHeight) * (bars[i] / 255.0);
        final cx = inset + slot * i + slot / 2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, centerY),
              width: barWidth,
              height: h,
            ),
            Radius.circular(barWidth / 2),
          ),
          paint,
        );
      }
    }

    drawBars(inactiveColor);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, 0, inset + inner * fraction, size.height),
    );
    drawBars(activeColor);
    canvas.restore();
  }

  static Uint8List _group(Uint8List peaks, int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final from = (i * peaks.length / n).floor();
      final to = math.max(from + 1, ((i + 1) * peaks.length / n).floor());
      var m = 0;
      for (var j = from; j < to && j < peaks.length; j++) {
        if (peaks[j] > m) m = peaks[j];
      }
      out[i] = m;
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.inset != inset ||
      old.minBarSlot != minBarSlot ||
      old.fraction != fraction ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      !identical(old.peaks, peaks);
}
