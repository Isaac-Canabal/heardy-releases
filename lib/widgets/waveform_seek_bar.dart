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
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _enabled
                  ? (d) => _commit(d.localPosition.dx, width)
                  : null,
              onHorizontalDragStart: _enabled
                  ? (d) => _scrub(d.localPosition.dx, width)
                  : null,
              onHorizontalDragUpdate: _enabled
                  ? (d) => _scrub(d.localPosition.dx, width)
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

  WaveformPainter({
    required this.peaks,
    required this.fraction,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = peaks.length;
    if (n == 0 || size.width <= 0) return;
    final slot = size.width / n;
    final barWidth = (slot * 0.6).clamp(1.0, 6.0);
    final minHeight = 3.0;
    final centerY = size.height / 2;

    void drawBars(Color color) {
      final paint = Paint()..color = color;
      for (var i = 0; i < n; i++) {
        final h = minHeight + (size.height - minHeight) * (peaks[i] / 255.0);
        final cx = slot * i + slot / 2;
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
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * fraction, size.height));
    drawBars(activeColor);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.fraction != fraction ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      !identical(old.peaks, peaks);
}
