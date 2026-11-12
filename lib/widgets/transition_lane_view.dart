// Una canción ampliada sobre la zona de la mezcla: su onda con escala en dB,
// la rejilla de ritmo si es fiable, la mezcla resaltada y las curvas de la
// transición encima. Arrastrar la onda mueve qué parte de la canción cae en la
// mezcla; con una línea elegida, arrastrar sus puntos la edita. La geometría es
// pura y vive en `transition_editor_logic.dart`.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/transition/platform/transition_profile.dart';
import '../services/transition/transition_analysis.dart';
import '../services/transition/transition_model.dart';
import 'mix_waveform_painter.dart' show kMixSongAColor, kMixSongBColor;
import 'transition_editor_logic.dart';

const kTransitionVolumeColor = Color(0xFF4A90FF);
const kTransitionEqColor = Color(0xFFFFD54F);
const kTransitionEffectColor = Color(0xFFB388FF);
const kTransitionLaneHeight = 132.0;

Color transitionCurveColor(TransitionCurveKind k) => switch (k) {
      TransitionCurveKind.volume => kTransitionVolumeColor,
      TransitionCurveKind.low || TransitionCurveKind.mid || TransitionCurveKind.high => kTransitionEqColor,
      TransitionCurveKind.filter || TransitionCurveKind.echo => kTransitionEffectColor,
    };

class TransitionLane extends StatefulWidget {
  const TransitionLane({
    super.key,
    required this.profile,
    required this.outgoing,
    required this.transition,
    required this.title,
    required this.onStartChanged,
    required this.onCurveChanged,
    this.showGrid = false,
    this.showBands = false,
    this.editKind,
    this.snap = TransitionSnap.free,
    this.playheadFraction,
    this.onGestureBegin,
    this.onLimit,
  });

  final TransitionSongProfile profile;
  final bool outgoing;
  final SongTransition transition;
  final String title;
  final bool showGrid, showBands;
  final TransitionCurveKind? editKind;
  final TransitionSnap snap;

  /// 0 al empezar la mezcla y 1 al acabar; `null` si no suena la escucha.
  final double? playheadFraction;

  /// Nuevo inicio (segundos de la canción) mientras se arrastra la onda.
  final ValueChanged<double> onStartChanged;
  final void Function(TransitionCurveKind kind, TransitionCurve curve) onCurveChanged;

  /// Al empezar cualquier gesto que cambie el borrador (para guardar un paso de deshacer).
  final VoidCallback? onGestureBegin;
  final ValueChanged<LaneLimit>? onLimit;

  @override
  State<TransitionLane> createState() => _TransitionLaneState();
}

enum _Grab { none, wave, point }

/// Agarra el toque al instante cuando cae sobre un punto de la línea elegida,
/// para que arrastrarlo (también hacia arriba o abajo) no desplace la pantalla.
/// Si el toque no cae en un punto, no participa.
class _PointGrabRecognizer extends PanGestureRecognizer {
  bool Function(Offset local) canGrab = (_) => false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!canGrab(event.localPosition)) return;
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}


class _TransitionLaneState extends State<TransitionLane> {
  _Grab _grab = _Grab.none;
  Offset _downAt = Offset.zero;
  double _startAtGrab = 0;
  int _pointIndex = -1;
  int _candidate = -1;
  Offset _pointOffset = Offset.zero;
  TransitionCurve? _working;
  bool _moved = false;
  int _lastTapPoint = -1;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  double get _start => widget.outgoing ? widget.transition.outStartSec : widget.transition.inStartSec;
  TransitionLanes get _lanes => widget.outgoing ? widget.transition.outLanes : widget.transition.inLanes;

  ({double min, double max}) get _range => widget.outgoing
      ? outgoingStartRange(outDurationSec: widget.profile.durationSec, lengthSec: widget.transition.clampedLengthSec)
      : incomingStartRange(
          inDurationSec: widget.profile.durationSec,
          lengthSec: widget.transition.clampedLengthSec,
          tempoMatch: widget.transition.tempoMatch);

  CurveFrame _frame(double width, double height) {
    final r = overlapPixelRange(lengthSec: widget.transition.clampedLengthSec, widthPx: width);
    return CurveFrame(left: r.left, width: r.width, height: height);
  }

  /// Al tocar la onda se decide qué se agarra, con el punto exacto del dedo: el
  /// arrastre sólo se reconoce unos píxeles más allá y por entonces el punto ya
  /// podría haber quedado fuera del radio.
  void _pressed(Offset pos, Size size) {
    _candidate = -1;
    final kind = widget.editKind;
    if (kind == null) return;
    final curve = curveOfKind(_lanes, kind), f = _frame(size.width, size.height);
    _candidate = hitTestCurvePoint(curve, kind, f, pos.dx, pos.dy);
    if (_candidate >= 0) {
      final p = curve.points[_candidate];
      _pointOffset = Offset(f.xOf(p.x) - pos.dx, f.yOf(kind, p.value) - pos.dy);
    }
  }

  void _down(DragStartDetails d, Size size) {
    final kind = widget.editKind;
    _downAt = d.localPosition;
    _moved = false;
    widget.onLimit?.call(LaneLimit.none);
    if (kind != null && _candidate >= 0) {
      final curve = curveOfKind(_lanes, kind);
      widget.onGestureBegin?.call();
      final baked = bakeCurve(curve, kind);
      // Al hornear una forma con nombre cambian los puntos: el agarrado es el más cercano de la nueva línea.
      final f = _frame(size.width, size.height);
      final p = curve.points[_candidate];
      _pointIndex = identical(baked, curve)
          ? _candidate
          : hitTestCurvePoint(baked, kind, f, f.xOf(p.x), f.yOf(kind, p.value));
      if (_pointIndex >= 0) {
        _working = baked;
        _grab = _Grab.point;
        return;
      }
    }
    widget.onGestureBegin?.call();
    _startAtGrab = _start;
    _grab = _Grab.wave;
  }

  void _update(DragUpdateDetails d, Size size) {
    if ((d.localPosition - _downAt).distance > 1) _moved = true;
    if (_grab == _Grab.wave) {
      final view = transitionLaneView(
          overlapStartSec: _startAtGrab, lengthSec: widget.transition.clampedLengthSec, widthPx: size.width);
      final r = _range;
      final res = dragLaneStart(
        startAtGrab: _startAtGrab,
        dxPx: d.localPosition.dx - _downAt.dx,
        viewSec: view.viewSec,
        widthPx: size.width,
        minSec: r.min,
        maxSec: r.max,
        analysis: widget.profile.analysis,
        snap: widget.snap,
      );
      widget.onLimit?.call(res.limit);
      if ((res.sec - _start).abs() > 1e-9) widget.onStartChanged(res.sec);
    } else if (_grab == _Grab.point) {
      final kind = widget.editKind!;
      final next = dragCurvePoint(_working!, _pointIndex, kind, _frame(size.width, size.height),
          d.localPosition.dx + _pointOffset.dx, d.localPosition.dy + _pointOffset.dy);
      _working = next;
      widget.onCurveChanged(kind, next);
    }
  }

  void _end(Size size) {
    // Tocar un punto dos veces seguidas lo quita (no hay otro modo de hacerlo: el punto agarra el toque al instante).
    if (_grab == _Grab.point && !_moved) {
      final now = DateTime.now();
      final kind = widget.editKind;
      if (kind != null && _pointIndex == _lastTapPoint && now.difference(_lastTapAt).inMilliseconds < 450) {
        final curve = curveOfKind(_lanes, kind);
        final next = removeCurvePoint(_working ?? curve, _pointIndex);
        if (!identical(next, curve) && next.points.length != curve.points.length) {
          widget.onCurveChanged(kind, next);
        }
        _lastTapPoint = -1;
      } else {
        _lastTapPoint = _pointIndex;
        _lastTapAt = now;
      }
    }
    _grab = _Grab.none;
    _working = null;
    _pointIndex = -1;
  }

  void _longPress(Offset pos, Size size) {
    final kind = widget.editKind;
    if (kind == null) return;
    final f = _frame(size.width, size.height);
    if (pos.dx < f.left || pos.dx > f.left + f.width) return;
    widget.onGestureBegin?.call();
    widget.onCurveChanged(kind, addCurvePoint(curveOfKind(_lanes, kind), kind, f.x01Of(pos.dx)));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, kTransitionLaneHeight);
      return Semantics(
        label: widget.title,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _PointGrabRecognizer: GestureRecognizerFactoryWithHandlers<_PointGrabRecognizer>(
              () => _PointGrabRecognizer(),
              (r) => r
                ..canGrab = ((pos) {
                  _pressed(pos, size);
                  return _candidate >= 0;
                })
                ..onStart = ((d) => _down(d, size))
                ..onUpdate = ((d) => _update(d, size))
                ..onEnd = ((_) => _end(size))
                ..onCancel = (() => _end(size)),
            ),
            HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
              () => HorizontalDragGestureRecognizer(),
              (r) => r
                ..onStart = ((d) => _down(d, size))
                ..onUpdate = ((d) => _update(d, size))
                ..onEnd = ((_) => _end(size))
                ..onCancel = (() => _end(size)),
            ),
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(),
              (r) => r.onLongPressStart = ((d) => _longPress(d.localPosition, size)),
            ),
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CustomPaint(
              size: size,
              painter: TransitionLanePainter(
                profile: widget.profile,
                outgoing: widget.outgoing,
                transition: widget.transition,
                showGrid: widget.showGrid,
                showBands: widget.showBands,
                editKind: widget.editKind,
                playheadFraction: widget.playheadFraction,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class TransitionLanePainter extends CustomPainter {
  TransitionLanePainter({
    required this.profile,
    required this.outgoing,
    required this.transition,
    required this.showGrid,
    required this.showBands,
    required this.editKind,
    required this.playheadFraction,
  });

  final TransitionSongProfile profile;
  final bool outgoing, showGrid, showBands;
  final SongTransition transition;
  final TransitionCurveKind? editKind;
  final double? playheadFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final len = transition.clampedLengthSec;
    final start = outgoing ? transition.outStartSec : transition.inStartSec;
    final view = transitionLaneView(overlapStartSec: start, lengthSec: len, widthPx: size.width);
    final overlap = overlapPixelRange(lengthSec: len, widthPx: size.width);
    final centerY = size.height / 2;
    final halfH = size.height / 2 - 6;
    final color = outgoing ? kMixSongAColor : kMixSongBColor;

    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF12161C));

    _gridlines(canvas, size, centerY, halfH);
    _wave(canvas, size, view, overlap, centerY, halfH, color);
    if (showGrid) _beats(canvas, size, view);

    // La mezcla, resaltada.
    final ov = Rect.fromLTWH(overlap.left, 0, overlap.width, size.height);
    canvas.drawRect(ov, Paint()..color = Colors.white.withValues(alpha: 0.07));
    final edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(ov.left, 0), Offset(ov.left, size.height), edge);
    canvas.drawLine(Offset(ov.right, 0), Offset(ov.right, size.height), edge);

    _curves(canvas, size, overlap);

    final f = playheadFraction;
    if (f != null) {
      final x = playheadX(f, lengthSec: len, laneWidthPx: size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = Colors.white
        ..strokeWidth = 2);
    }
  }

  void _label(Canvas canvas, String text, Offset at, {Color color = const Color(0x99FFFFFF)}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _gridlines(Canvas canvas, Size size, double centerY, double halfH) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.09)
      ..strokeWidth = 1;
    for (final db in kTransitionDbGridlines) {
      final up = dbToY(db, centerY: centerY, halfH: halfH);
      final down = 2 * centerY - up;
      canvas.drawLine(Offset(0, up), Offset(size.width, up), line);
      canvas.drawLine(Offset(0, down), Offset(size.width, down), line);
      _label(canvas, db == 0 ? '0 dB' : '${db.toInt()}', Offset(3, up + 1));
    }
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), line..color = Colors.white.withValues(alpha: 0.16));
  }

  void _wave(Canvas canvas, Size size, TransitionLaneView view, ({double left, double width}) overlap, double centerY,
      double halfH, Color color) {
    const step = 2.0;
    final outside = Paint()..color = Colors.black.withValues(alpha: 0.55);
    for (var x = 0.0; x < size.width; x += step) {
      if (view.xToTime(x + step) < 0 || view.xToTime(x) > profile.durationSec) {
        canvas.drawRect(Rect.fromLTWH(x, 0, step, size.height), outside);
      }
    }
    void bars(TransitionLevelKind kind, Color c, {double alpha = 1}) {
      final inside = Paint()..color = c.withValues(alpha: alpha);
      final dim = Paint()..color = c.withValues(alpha: alpha * 0.45);
      for (var x = 0.0; x < size.width; x += step) {
        final t0 = view.xToTime(x), t1 = view.xToTime(x + step);
        final db = waveformColumnDb(profile, outgoing: outgoing, t0: t0, t1: t1, kind: kind);
        if (db == null) continue;
        final h = dbToFraction(db) * halfH;
        if (h < 0.5) continue;
        final within = x + step > overlap.left && x < overlap.left + overlap.width;
        canvas.drawRect(Rect.fromLTRB(x, centerY - h, x + step - 0.5, centerY + h), within ? inside : dim);
      }
    }

    if (showBands) {
      bars(TransitionLevelKind.low, const Color(0xFFEF5350), alpha: 0.75);
      bars(TransitionLevelKind.mid, const Color(0xFF66BB6A), alpha: 0.6);
      bars(TransitionLevelKind.high, const Color(0xFF42A5F5), alpha: 0.6);
    } else {
      bars(TransitionLevelKind.peak, color, alpha: 0.28);
      bars(TransitionLevelKind.rms, color);
    }
  }

  void _beats(Canvas canvas, Size size, TransitionLaneView view) {
    final grid = beatGridInWindow(profile.analysis, view.startSec, view.endSec);
    if (grid.beats.isEmpty) return;
    final beat = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    final bar = Paint()
      ..color = const Color(0xFF69F0AE).withValues(alpha: 0.85)
      ..strokeWidth = 1.6;
    final downs = grid.downbeats.toSet();
    for (final t in grid.beats) {
      final x = view.timeToX(t);
      if (downs.contains(t)) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), bar);
      } else {
        canvas.drawLine(Offset(x, size.height * 0.62), Offset(x, size.height), beat);
      }
    }
  }

  void _curves(Canvas canvas, Size size, ({double left, double width}) overlap) {
    final lanes = outgoing ? transition.outLanes : transition.inLanes;
    final frame = CurveFrame(left: overlap.left, width: overlap.width, height: size.height);

    void line(TransitionCurveKind k, {double alpha = 0.85}) {
      final curve = curveOfKind(lanes, k);
      final selected = editKind == k;
      final color = transitionCurveColor(k);
      final unchanged = curve.isConstant(0) && k != TransitionCurveKind.volume;
      if (unchanged && !selected) return;
      final paint = Paint()
        ..color = color.withValues(alpha: selected ? 1 : alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : (k == TransitionCurveKind.volume ? 2.4 : 1.2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      const n = 64;
      for (var i = 0; i <= n; i++) {
        final x01 = i / n;
        final p = Offset(frame.xOf(x01), frame.yOf(k, curveDrawValue(curve, k, x01)));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
      if (selected) {
        final fill = Paint()..color = color;
        final ring = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        for (final p in curve.points) {
          final c = Offset(frame.xOf(p.x), frame.yOf(k, p.value));
          canvas.drawCircle(c, 7, fill);
          canvas.drawCircle(c, 7, ring);
        }
      }
    }

    const order = [
      TransitionCurveKind.echo,
      TransitionCurveKind.filter,
      TransitionCurveKind.high,
      TransitionCurveKind.mid,
      TransitionCurveKind.low,
      TransitionCurveKind.volume,
    ];
    for (final k in order) {
      if (k != editKind) line(k, alpha: k == TransitionCurveKind.volume ? 0.95 : 0.8);
    }
    if (editKind != null) line(editKind!);
  }

  @override
  bool shouldRepaint(TransitionLanePainter old) =>
      old.profile != profile ||
      old.outgoing != outgoing ||
      old.showGrid != showGrid ||
      old.showBands != showBands ||
      old.editKind != editKind ||
      old.playheadFraction != playheadFraction ||
      !sameTransition(old.transition, transition);
}

/// La canción entera pequeña, con un marcador donde cae la mezcla.
class TransitionOverviewStrip extends StatelessWidget {
  const TransitionOverviewStrip({
    super.key,
    required this.profile,
    required this.startSec,
    required this.lengthSec,
    required this.outgoing,
  });

  final TransitionSongProfile profile;
  final double startSec, lengthSec;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CustomPaint(
        size: const Size(double.infinity, 26),
        painter: _OverviewPainter(profile, startSec, lengthSec, outgoing ? kMixSongAColor : kMixSongBColor),
      ),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.profile, this.startSec, this.lengthSec, this.color);
  final TransitionSongProfile profile;
  final double startSec, lengthSec;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF12161C));
    final dur = profile.durationSec;
    if (dur <= 0 || size.width <= 0) return;
    final w = profile.overview;
    final cy = size.height / 2;
    final paint = Paint()..color = color.withValues(alpha: 0.7);
    final cols = math.max(1, size.width ~/ 2);
    for (var i = 0; i < cols; i++) {
      final t0 = i / cols * dur, t1 = (i + 1) / cols * dur;
      final a = (t0 * w.pointsPerSecond).floor().clamp(0, math.max(0, w.length - 1)).toInt();
      final b = (t1 * w.pointsPerSecond).floor().clamp(a, math.max(0, w.length - 1)).toInt();
      if (w.length == 0) break;
      var best = w.rmsDb[a];
      for (var k = a + 1; k <= b; k++) {
        best = math.max(best, w.rmsDb[k]);
      }
      final h = dbToFraction(best) * (cy - 1);
      canvas.drawRect(Rect.fromLTRB(i * 2.0, cy - h, i * 2.0 + 1.4, cy + h), paint);
    }
    final x0 = (startSec / dur).clamp(0.0, 1.0) * size.width;
    final x1 = ((startSec + lengthSec) / dur).clamp(0.0, 1.0) * size.width;
    final box = Rect.fromLTRB(x0, 0, math.max(x1, x0 + 3), size.height);
    canvas.drawRect(box, Paint()..color = Colors.white.withValues(alpha: 0.22));
    canvas.drawRect(
        box,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_OverviewPainter old) =>
      old.profile != profile || old.startSec != startSec || old.lengthSec != lengthSec || old.color != color;
}
