import 'package:flutter/material.dart';

Color hsvToColor(double hue, double saturation, double value) {
  return HSVColor.fromAHSV(
    1,
    hue.clamp(0.0, 360.0).toDouble(),
    saturation.clamp(0.0, 1.0).toDouble(),
    value.clamp(0.0, 1.0).toDouble(),
  ).toColor();
}

HSVColor colorToHsv(Color color) => HSVColor.fromColor(color);

/// Selector HSV: cuadrado de saturación/brillo y barra de tono. Mantiene el
/// tono internamente porque un gris no lo conserva al pasar por [Color].
class ColorPickerPanel extends StatefulWidget {
  final Color color;
  final ValueChanged<Color> onChanged;
  final String hueLabel;
  final String saturationValueLabel;
  final bool showRgb;

  const ColorPickerPanel({
    super.key,
    required this.color,
    required this.onChanged,
    required this.hueLabel,
    required this.saturationValueLabel,
    this.showRgb = true,
  });

  @override
  State<ColorPickerPanel> createState() => _ColorPickerPanelState();
}

class _ColorPickerPanelState extends State<ColorPickerPanel> {
  late HSVColor _hsv = colorToHsv(widget.color);

  @override
  void didUpdateWidget(ColorPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      _hsv = colorToHsv(widget.color);
    }
  }

  void _emit(HSVColor next) {
    setState(() => _hsv = next);
    widget.onChanged(next.toColor());
  }

  void _onSv(Offset p, Size size) {
    final s = (p.dx / size.width).clamp(0.0, 1.0).toDouble();
    final v = (1 - p.dy / size.height).clamp(0.0, 1.0).toDouble();
    _emit(_hsv.withSaturation(s).withValue(v));
  }

  void _onHue(Offset p, Size size) {
    final h = (p.dx / size.width * 360).clamp(0.0, 360.0).toDouble();
    _emit(_hsv.withHue(h));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          label: widget.saturationValueLabel,
          child: SizedBox(
            height: 160,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                return GestureDetector(
                  key: const ValueKey('picker-sv'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (d) => _onSv(d.localPosition, size),
                  onPanUpdate: (d) => _onSv(d.localPosition, size),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.white,
                                  hsvToColor(_hsv.hue, 1, 1),
                                ],
                              ),
                            ),
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: _hsv.saturation * size.width - 10,
                        top: (1 - _hsv.value) * size.height - 10,
                        child: _Thumb(color: c),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          container: true,
          label: widget.hueLabel,
          child: SizedBox(
            height: 24,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                return GestureDetector(
                  key: const ValueKey('picker-hue'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (d) => _onHue(d.localPosition, size),
                  onPanUpdate: (d) => _onHue(d.localPosition, size),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              colors: [
                                for (var i = 0; i <= 6; i++)
                                  hsvToColor(i * 60.0, 1, 1),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: _hsv.hue / 360 * size.width - 10,
                        top: 2,
                        child: _Thumb(color: hsvToColor(_hsv.hue, 1, 1)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.showRgb) ...[
          const SizedBox(height: 8),
          Text(
            '${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final Color color;
  const _Thumb({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
      ),
    );
  }
}
