// Ondas del editor del Mix DJ, dibujadas a mano con CustomPainter a partir de
// las envolventes por compás (sin dependencias de ondas). La correspondencia
// entre compás y píxel es pura y está probada aparte de los widgets.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/mix/mix_edit_plan.dart';
import '../services/mix/mix_envelope.dart' show kEnvelopePointsPerBar;
import '../services/mix/mix_types.dart';

const kMixSongAColor = Color(0xFF4DD0E1);
const kMixSongBColor = Color(0xFFFF8A65);

Color mixSongColor(String song) => song == 'a' ? kMixSongAColor : kMixSongBColor;

/// Posición horizontal del compás [bar] (admite fracciones) en un carril de [width] píxeles.
double barToX(double bar, int totalBars, double width) {
  if (totalBars <= 0 || width <= 0) return 0;
  return (bar / totalBars).clamp(0.0, 1.0) * width;
}

/// Compás (entero, 0..totalBars-1) que hay en la posición [x]. Sin compases devuelve 0.
int xToBar(double x, int totalBars, double width) {
  if (totalBars <= 0 || width <= 0 || !x.isFinite) return 0;
  final bar = (x / width * totalBars).floor();
  return bar < 0 ? 0 : (bar > totalBars - 1 ? totalBars - 1 : bar);
}

/// Línea de compás (0..totalBars) más cercana a [x]: la rejilla a la que se pega un arrastre.
int xToSnappedBar(double x, int totalBars, double width) {
  if (totalBars <= 0 || width <= 0 || !x.isFinite) return 0;
  final bar = (x / width * totalBars).round();
  return bar < 0 ? 0 : (bar > totalBars ? totalBars : bar);
}

/// Compás de salida al que va un bloque que empezaba en [startOutBar] cuando el
/// dedo, que lo agarró en [grabX], está en [x]. Sin acotar: lo acota la operación.
int dragTargetBar({
  required int startOutBar,
  required double grabX,
  required double x,
  required int totalBars,
  required double width,
}) {
  if (totalBars <= 0 || width <= 0 || !x.isFinite || !grabX.isFinite) return startOutBar;
  return startOutBar + ((x - grabX) / width * totalBars).round();
}

/// Parte de un bloque que se tocó: el cuerpo (mover) o un borde (acortar o alargar).
enum MixBlockPart { body, start, end }

/// Ancho en píxeles de la zona de cada borde de un bloque.
const kMixBlockEdgePx = 12.0;

/// Bloque (el último dibujado gana) y parte que hay bajo [pos] en un carril de
/// [size]; índice -1 si no hay ninguno. Un bloque demasiado estrecho para tener
/// dos bordes y cuerpo es todo cuerpo.
({int index, MixBlockPart part}) hitTestBlock(List<MixEditSegment> segments, int totalBars, Size size, Offset pos) {
  for (var i = segments.length - 1; i >= 0; i--) {
    final s = segments[i];
    if (s.bars <= 0) continue;
    final r = MixResultLanePainter.segmentRect(s, totalBars, size).inflate(0.5);
    if (!r.contains(pos)) continue;
    if (r.width < kMixBlockEdgePx * 3) return (index: i, part: MixBlockPart.body);
    if (pos.dx < r.left + kMixBlockEdgePx) return (index: i, part: MixBlockPart.start);
    if (pos.dx > r.right - kMixBlockEdgePx) return (index: i, part: MixBlockPart.end);
    return (index: i, part: MixBlockPart.body);
  }
  return (index: -1, part: MixBlockPart.body);
}

/// Rango de compases `[start, end)` que cubren dos compases tocados, en cualquier orden.
({int start, int end}) barRangeBetween(int a, int b, int totalBars) {
  final hi = math.max(0, totalBars - 1);
  final lo = math.min(math.max(math.min(a, b), 0), hi), up = math.min(math.max(math.max(a, b), 0), hi);
  return (start: lo, end: up + 1);
}

/// Reduce [points] a [columns] columnas tomando el máximo de cada grupo (una
/// onda más ancha que sus puntos se repite, una más estrecha pierde detalle sin perder picos).
List<double> downsampleEnvelope(List<double> points, int columns) {
  if (columns <= 0 || points.isEmpty) return const [];
  return [
    for (var c = 0; c < columns; c++)
      () {
        final a = (c * points.length / columns).floor();
        final b = math.max(a + 1, ((c + 1) * points.length / columns).ceil());
        var peak = 0.0;
        for (var i = a; i < math.min(b, points.length); i++) {
          peak = math.max(peak, points[i]);
        }
        return peak;
      }(),
  ];
}

void _paintRuler(Canvas canvas, Size size, int totalBars, Paint paint) {
  for (var bar = 0; bar <= totalBars; bar += 4) {
    final x = barToX(bar.toDouble(), totalBars, size.width);
    final major = bar % 16 == 0;
    canvas.drawLine(Offset(x, size.height), Offset(x, size.height - (major ? 10 : 5)), paint);
  }
}

void _paintWave(Canvas canvas, Size size, List<double> points, Paint paint, {double top = 0, double? height}) {
  final h = height ?? size.height;
  final cols = size.width.floor();
  final env = downsampleEnvelope(points, cols);
  final mid = top + h / 2;
  for (var c = 0; c < env.length; c++) {
    final half = math.max(0.5, env[c] * h / 2);
    canvas.drawLine(Offset(c + 0.5, mid - half), Offset(c + 0.5, mid + half), paint);
  }
}

/// Onda de una capa de una canción con la regla de compases y, si hay, el rango elegido.
class MixLanePainter extends CustomPainter {
  MixLanePainter({
    required this.points,
    required this.totalBars,
    required this.color,
    this.selection,
    this.rulerColor = Colors.white30,
  });

  final List<double> points;
  final int totalBars;
  final Color color;
  final ({int start, int end})? selection;
  final Color rulerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    if (sel != null) {
      final x0 = barToX(sel.start.toDouble(), totalBars, size.width), x1 = barToX(sel.end.toDouble(), totalBars, size.width);
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, size.height), Paint()..color = color.withValues(alpha: 0.28));
    }
    _paintWave(canvas, size, points, Paint()
      ..color = color
      ..strokeWidth = 1);
    _paintRuler(canvas, size, totalBars, Paint()
      ..color = rulerColor
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(MixLanePainter old) =>
      old.points != points || old.totalBars != totalBars || old.color != color || old.selection != selection;
}

/// Carril del resultado: los tramos del plan sobre la línea de tiempo (la
/// música arriba y la voz debajo) y, tras un render, la onda real encima.
class MixResultLanePainter extends CustomPainter {
  MixResultLanePainter({
    required this.segments,
    required this.totalBars,
    this.selectedIndex = -1,
    this.cursorBar,
    this.envelope = const [],
    this.rulerColor = Colors.white30,
    this.labels = const [],
    this.playheadBar,
  });

  final List<MixEditSegment> segments;
  final int totalBars;
  final int selectedIndex;
  final int? cursorBar;
  final List<double> envelope;
  final Color rulerColor;

  /// Texto de cada tramo (mismo orden que [segments]); se dibuja si cabe.
  final List<String> labels;

  /// Por dónde va la escucha, en compases (con fracción), o `null`.
  final double? playheadBar;

  /// Rectángulo (en píxeles) de un tramo dentro de un carril de [size].
  static Rect segmentRect(MixEditSegment s, int totalBars, Size size) {
    final x0 = barToX(s.outBar.toDouble(), totalBars, size.width), x1 = barToX(s.endBar.toDouble(), totalBars, size.width);
    final vocal = s.layer == MixLayer.vocals;
    final half = size.height / 2;
    return Rect.fromLTRB(x0, vocal ? half : 0, math.max(x1, x0 + 1), vocal ? size.height : half).deflate(0.5);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.bars <= 0) continue;
      final r = segmentRect(s, totalBars, size);
      final c = mixSongColor(s.song);
      canvas.drawRect(r, Paint()..color = c.withValues(alpha: i == selectedIndex ? 0.7 : 0.35));
      if (i < labels.length && r.width > 34) {
        final tp = TextPainter(
          text: TextSpan(
              text: labels[i], style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          maxLines: 1,
          ellipsis: '\u2026',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: r.width - 10);
        tp.paint(canvas, Offset(r.left + 5, r.top + (r.height - tp.height) / 2));
      }
      if (i == selectedIndex) {
        canvas.drawRect(r, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
        // Asas de los bordes: por ahí se acorta o alarga el bloque.
        if (r.width >= kMixBlockEdgePx * 3) {
          final grip = Paint()..color = Colors.white;
          for (final x in [r.left + 2, r.right - 5]) {
            canvas.drawRRect(
                RRect.fromRectAndRadius(Rect.fromLTWH(x, r.top + r.height * 0.25, 3, r.height * 0.5), const Radius.circular(2)),
                grip);
          }
        }
      }
    }
    if (envelope.isNotEmpty) {
      final width = barToX(math.min(envelope.length / kEnvelopePointsPerBar, totalBars.toDouble()), totalBars, size.width);
      _paintWave(canvas, Size(width, size.height), envelope, Paint()
        ..color = Colors.white
        ..strokeWidth = 1);
    }
    _paintRuler(canvas, size, totalBars, Paint()
      ..color = rulerColor
      ..strokeWidth = 1);
    final cur = cursorBar;
    if (cur != null) {
      final x = barToX(cur.toDouble(), totalBars, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = Colors.amberAccent
        ..strokeWidth = 2);
    }
    final head = playheadBar;
    if (head != null) {
      final x = barToX(head, totalBars, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = Colors.white
        ..strokeWidth = 2);
      canvas.drawCircle(Offset(x, 4), 4, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(MixResultLanePainter old) =>
      old.segments != segments ||
      old.totalBars != totalBars ||
      old.selectedIndex != selectedIndex ||
      old.cursorBar != cursorBar ||
      old.envelope != envelope ||
      old.labels != labels ||
      old.playheadBar != playheadBar;
}

/// Carril de una canción: toca o arrastra para elegir un rango de compases.
class MixWaveformLane extends StatefulWidget {
  const MixWaveformLane({
    super.key,
    required this.points,
    required this.totalBars,
    required this.color,
    required this.onSelect,
    this.selection,
    this.height = 64,
  });

  final List<double> points;
  final int totalBars;
  final Color color;
  final ({int start, int end})? selection;
  final double height;
  final void Function(int start, int end) onSelect;

  @override
  State<MixWaveformLane> createState() => _MixWaveformLaneState();
}

class _MixWaveformLaneState extends State<MixWaveformLane> {
  int? _anchor;

  void _pick(double x, double width) {
    final bar = xToBar(x, widget.totalBars, width);
    final a = _anchor ?? (_anchor = bar);
    final r = barRangeBetween(a, bar, widget.totalBars);
    widget.onSelect(r.start, r.end);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragDown: (d) {
          _anchor = null;
          _pick(d.localPosition.dx, width);
        },
        onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx, width),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0x22FFFFFF)),
            child: CustomPaint(
              size: Size(width, widget.height),
              painter: MixLanePainter(
                  points: widget.points, totalBars: widget.totalBars, color: widget.color, selection: widget.selection),
            ),
          ),
        ),
      );
    });
  }
}

/// Carril del resultado: tocar un compás coloca el cursor y elige el tramo que lo cubre.
class MixResultLane extends StatelessWidget {
  const MixResultLane({
    super.key,
    required this.segments,
    required this.totalBars,
    required this.onTapBar,
    this.selectedIndex = -1,
    this.cursorBar,
    this.envelope = const [],
    this.height = 72,
    this.labels = const [],
  });

  final List<String> labels;

  final List<MixEditSegment> segments;
  final int totalBars;
  final int selectedIndex;
  final int? cursorBar;
  final List<double> envelope;
  final double height;
  final void Function(int bar) onTapBar;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onTapBar(xToBar(d.localPosition.dx, totalBars, width)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0x22FFFFFF)),
            child: CustomPaint(
              size: Size(width, height),
              painter: MixResultLanePainter(
                segments: segments,
                totalBars: totalBars,
                selectedIndex: selectedIndex,
                cursorBar: cursorBar,
                envelope: envelope,
                labels: labels,
              ),
            ),
          ),
        ),
      );
    });
  }
}
