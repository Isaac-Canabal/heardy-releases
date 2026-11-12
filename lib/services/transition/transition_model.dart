import 'dart:math' as math;

const kTransitionVersion = 1;
const kTransitionMinLengthSec = 0.5;
const kTransitionMaxLengthSec = 40.0;
const kTransitionDefaultLengthSec = 8.0;
const kTransitionMinDb = -60.0;
const kTransitionMaxDb = 6.0;

/// Largest tempo change the incoming song accepts to match the outgoing one.
const kTransitionMaxTempoShift = 0.08;

double _num(Object? v, double fallback) => v is num && v.isFinite ? v.toDouble() : fallback;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

T _enumOf<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// How a curve moves between two consecutive points.
enum TransitionCurveShape {
  linear,
  easeIn,
  easeOut,
  sCurve,

  /// On dB lanes the gain follows a sine/cosine law, so two opposite fades keep the summed power constant.
  equalPower,

  /// On dB lanes the gain (not the dB value) moves in a straight line.
  linearGain,
}

class TransitionPoint {
  const TransitionPoint(this.x, this.value);

  /// Position across the overlap, 0..1.
  final double x;
  final double value;
}

/// Automation line across the overlap. Points are sanitized on construction: points with a non-finite x or value are dropped,
/// x is clamped to 0..1 and the order is by x (stable, so a repeated x is a step).
class TransitionCurve {
  TransitionCurve(Iterable<TransitionPoint> points, {this.shape = TransitionCurveShape.linear})
      : points = _sanitize(points);

  factory TransitionCurve.constant(double value) => TransitionCurve([TransitionPoint(0, value)]);

  factory TransitionCurve.ramp(double from, double to, {TransitionCurveShape shape = TransitionCurveShape.linear}) =>
      TransitionCurve([TransitionPoint(0, from), TransitionPoint(1, to)], shape: shape);

  final List<TransitionPoint> points;
  final TransitionCurveShape shape;

  static List<TransitionPoint> _sanitize(Iterable<TransitionPoint> raw) {
    final indexed = <(int, TransitionPoint)>[];
    var i = 0;
    for (final p in raw) {
      if (!p.value.isFinite || !p.x.isFinite) continue;
      indexed.add((i++, TransitionPoint(p.x.clamp(0.0, 1.0).toDouble(), p.value)));
    }
    indexed.sort((a, b) {
      final c = a.$2.x.compareTo(b.$2.x);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return List.unmodifiable([for (final e in indexed) e.$2]);
  }

  bool isConstant(double value) => points.every((p) => p.value == value);

  double get minValue => points.isEmpty ? 0 : points.map((p) => p.value).reduce(math.min);
  double get maxValue => points.isEmpty ? 0 : points.map((p) => p.value).reduce(math.max);

  /// Index of the last point at or before [x], or -1 when [x] is before the first one.
  int _segment(double x) {
    var i = -1;
    for (var k = 0; k < points.length && points[k].x <= x; k++) {
      i = k;
    }
    return i;
  }

  double _shaped(double t) {
    switch (shape) {
      case TransitionCurveShape.linear:
      case TransitionCurveShape.linearGain:
        return t;
      case TransitionCurveShape.easeIn:
        return t * t;
      case TransitionCurveShape.easeOut:
        return 1 - (1 - t) * (1 - t);
      case TransitionCurveShape.sCurve:
        return t * t * (3 - 2 * t);
      case TransitionCurveShape.equalPower:
        return math.sin(math.pi / 2 * t);
    }
  }

  /// Value at [x] in the lane's own unit. An empty curve reads 0.
  double valueAt(double x) {
    if (points.isEmpty) return 0;
    final q = x.isNaN ? 0.0 : x.clamp(0.0, 1.0).toDouble();
    final i = _segment(q);
    if (i < 0) return points.first.value;
    if (i == points.length - 1) return points[i].value;
    final a = points[i], b = points[i + 1];
    return a.value + (b.value - a.value) * _shaped((q - a.x) / (b.x - a.x));
  }

  static double _gainOfDb(double db) =>
      db <= kTransitionMinDb ? 0 : math.pow(10, math.min(db, kTransitionMaxDb) / 20).toDouble();

  /// Linear gain at [x] reading the values as dB: -60 dB or less is silence and +6 dB is the cap.
  double gainAt(double x) {
    if (shape != TransitionCurveShape.equalPower && shape != TransitionCurveShape.linearGain) {
      return _gainOfDb(valueAt(x));
    }
    if (points.isEmpty) return 1;
    final q = x.isNaN ? 0.0 : x.clamp(0.0, 1.0).toDouble();
    final i = _segment(q);
    if (i < 0) return _gainOfDb(points.first.value);
    if (i == points.length - 1) return _gainOfDb(points[i].value);
    final a = _gainOfDb(points[i].value), b = _gainOfDb(points[i + 1].value);
    final t = (q - points[i].x) / (points[i + 1].x - points[i].x);
    if (shape == TransitionCurveShape.linearGain) return a + (b - a) * t;
    final c = math.cos(math.pi / 2 * t), s = math.sin(math.pi / 2 * t);
    return math.sqrt(a * a * c * c + b * b * s * s);
  }

  /// [gainAt] back in dB, floored at -60: what a dB lane should draw.
  double dbAt(double x) {
    final g = gainAt(x);
    return g <= 0 ? kTransitionMinDb : math.max(kTransitionMinDb, 20 * math.log(g) / math.ln10);
  }

  Map<String, dynamic> toJson() => {
        'points': [
          for (final p in points) [p.x, p.value],
        ],
        'shape': shape.name,
      };

  static TransitionCurve fromJson(Object? json, {double fallback = 0}) {
    if (json is! Map) return TransitionCurve.constant(fallback);
    final raw = json['points'];
    final pts = <TransitionPoint>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
          pts.add(TransitionPoint((e[0] as num).toDouble(), (e[1] as num).toDouble()));
        } else if (e is Map && e['x'] is num && e['value'] is num) {
          pts.add(TransitionPoint((e['x'] as num).toDouble(), (e['value'] as num).toDouble()));
        }
      }
    }
    return TransitionCurve(pts, shape: _enumOf(TransitionCurveShape.values, json['shape'], TransitionCurveShape.linear));
  }
}

/// Automation of one song across the overlap.
class TransitionLanes {
  TransitionLanes({
    TransitionCurve? volumeDb,
    TransitionCurve? lowDb,
    TransitionCurve? midDb,
    TransitionCurve? highDb,
    TransitionCurve? filter,
    TransitionCurve? echo,
  })  : volumeDb = volumeDb ?? TransitionCurve.constant(0),
        lowDb = lowDb ?? TransitionCurve.constant(0),
        midDb = midDb ?? TransitionCurve.constant(0),
        highDb = highDb ?? TransitionCurve.constant(0),
        filter = filter ?? TransitionCurve.constant(0),
        echo = echo ?? TransitionCurve.constant(0);

  final TransitionCurve volumeDb, lowDb, midDb, highDb;

  /// One-knob filter, -1..1: negative closes a low-pass, positive opens a high-pass, 0 is a true bypass.
  final TransitionCurve filter;

  /// Send (0..1) into a tempo-synced feedback delay; 0 is a true bypass.
  final TransitionCurve echo;

  /// Loudest gain any band of this song reaches at [x].
  double audibleGainAt(double x) =>
      volumeDb.gainAt(x) * math.max(lowDb.gainAt(x), math.max(midDb.gainAt(x), highDb.gainAt(x)));

  bool isUntouchedAt(double x) {
    bool unity(TransitionCurve c) => (c.gainAt(x) - 1).abs() < 0.02;
    return unity(volumeDb) && unity(lowDb) && unity(midDb) && unity(highDb) && filter.valueAt(x).abs() < 0.02;
  }

  TransitionLanes copyWith({
    TransitionCurve? volumeDb,
    TransitionCurve? lowDb,
    TransitionCurve? midDb,
    TransitionCurve? highDb,
    TransitionCurve? filter,
    TransitionCurve? echo,
  }) =>
      TransitionLanes(
        volumeDb: volumeDb ?? this.volumeDb,
        lowDb: lowDb ?? this.lowDb,
        midDb: midDb ?? this.midDb,
        highDb: highDb ?? this.highDb,
        filter: filter ?? this.filter,
        echo: echo ?? this.echo,
      );

  Map<String, dynamic> toJson() => {
        'volumeDb': volumeDb.toJson(),
        'lowDb': lowDb.toJson(),
        'midDb': midDb.toJson(),
        'highDb': highDb.toJson(),
        'filter': filter.toJson(),
        'echo': echo.toJson(),
      };

  static TransitionLanes fromJson(Object? json) {
    if (json is! Map) return TransitionLanes();
    return TransitionLanes(
      volumeDb: TransitionCurve.fromJson(json['volumeDb']),
      lowDb: TransitionCurve.fromJson(json['lowDb']),
      midDb: TransitionCurve.fromJson(json['midDb']),
      highDb: TransitionCurve.fromJson(json['highDb']),
      filter: TransitionCurve.fromJson(json['filter']),
      echo: TransitionCurve.fromJson(json['echo']),
    );
  }
}

enum TransitionTempoMatch {
  none,

  /// Stretch the incoming song to the outgoing tempo during the overlap and glide back before it ends.
  matchIncoming,
}

/// The transition between two consecutive songs. Times are seconds inside each song.
class SongTransition {
  SongTransition({
    required this.outStartSec,
    required this.inStartSec,
    required this.lengthSec,
    TransitionLanes? outLanes,
    TransitionLanes? inLanes,
    this.presetId,
    this.volumeShapeId,
    this.eqShapeId,
    this.effectShapeId,
    this.tempoMatch = TransitionTempoMatch.none,
    this.beatAligned = false,
    this.version = kTransitionVersion,
  })  : outLanes = outLanes ?? TransitionLanes(),
        inLanes = inLanes ?? TransitionLanes();

  /// Position in the outgoing song where the overlap starts.
  final double outStartSec;

  /// Position in the incoming song that sounds at the start of the overlap.
  final double inStartSec;
  final double lengthSec;
  final TransitionLanes outLanes, inLanes;

  /// Null once any lane was changed away from the preset.
  final String? presetId;

  /// Named shape of each lane group; null once that group was edited by hand.
  final String? volumeShapeId, eqShapeId, effectShapeId;
  final TransitionTempoMatch tempoMatch;
  final bool beatAligned;
  final int version;

  double get clampedLengthSec =>
      lengthSec.isFinite ? lengthSec.clamp(kTransitionMinLengthSec, kTransitionMaxLengthSec).toDouble() : kTransitionDefaultLengthSec;

  SongTransition copyWith({
    double? outStartSec,
    double? inStartSec,
    double? lengthSec,
    TransitionLanes? outLanes,
    TransitionLanes? inLanes,
    String? presetId,
    String? volumeShapeId,
    String? eqShapeId,
    String? effectShapeId,
    bool clearPreset = false,
    bool clearVolumeShape = false,
    bool clearEqShape = false,
    bool clearEffectShape = false,
    TransitionTempoMatch? tempoMatch,
    bool? beatAligned,
    int? version,
  }) =>
      SongTransition(
        outStartSec: outStartSec ?? this.outStartSec,
        inStartSec: inStartSec ?? this.inStartSec,
        lengthSec: lengthSec ?? this.lengthSec,
        outLanes: outLanes ?? this.outLanes,
        inLanes: inLanes ?? this.inLanes,
        presetId: clearPreset ? null : presetId ?? this.presetId,
        volumeShapeId: clearVolumeShape ? null : volumeShapeId ?? this.volumeShapeId,
        eqShapeId: clearEqShape ? null : eqShapeId ?? this.eqShapeId,
        effectShapeId: clearEffectShape ? null : effectShapeId ?? this.effectShapeId,
        tempoMatch: tempoMatch ?? this.tempoMatch,
        beatAligned: beatAligned ?? this.beatAligned,
        version: version ?? this.version,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'outStartSec': outStartSec,
        'inStartSec': inStartSec,
        'lengthSec': lengthSec,
        'out': outLanes.toJson(),
        'in': inLanes.toJson(),
        'presetId': presetId,
        'volumeShapeId': volumeShapeId,
        'eqShapeId': eqShapeId,
        'effectShapeId': effectShapeId,
        'tempoMatch': tempoMatch.name,
        'beatAligned': beatAligned,
      };

  /// Permissive on purpose: this is our own stored data, so a damaged field falls back instead of throwing.
  static SongTransition fromJson(Map<String, dynamic> json) => SongTransition(
        outStartSec: _num(json['outStartSec'], 0),
        inStartSec: _num(json['inStartSec'], 0),
        lengthSec: _num(json['lengthSec'], kTransitionDefaultLengthSec),
        outLanes: TransitionLanes.fromJson(json['out']),
        inLanes: TransitionLanes.fromJson(json['in']),
        presetId: _str(json['presetId']),
        volumeShapeId: _str(json['volumeShapeId']),
        eqShapeId: _str(json['eqShapeId']),
        effectShapeId: _str(json['effectShapeId']),
        tempoMatch: _enumOf(TransitionTempoMatch.values, json['tempoMatch'], TransitionTempoMatch.none),
        beatAligned: json['beatAligned'] == true,
        version: json['version'] is int ? json['version'] as int : kTransitionVersion,
      );
}

enum TransitionProblemKind {
  invalidNumber,
  negativeStart,
  lengthOutOfRange,
  overlapBeyondOutgoing,
  overlapBeyondIncoming,
  valueOutOfRange,
  unknownPreset,
  unsupportedVersion,

  /// Edge mismatches: the renderer smooths them, but the lanes do not hand over cleanly by themselves.
  outgoingAlteredAtStart,
  outgoingAudibleAtEnd,
  incomingAudibleAtStart,
  incomingAlteredAtEnd,
}

class TransitionProblem {
  const TransitionProblem(this.kind, this.message, {this.isError = true});
  final TransitionProblemKind kind;
  final String message;

  /// False for the ones the renderer copes with (it clamps, smooths or shortens).
  final bool isError;

  @override
  String toString() => '${kind.name}: $message';
}

/// Structured problems of [t]; never throws. [knownPresetIds] enables the unknown-preset check.
List<TransitionProblem> validateTransition(
  SongTransition t, {
  double? outDurationSec,
  double? inDurationSec,
  Iterable<String>? knownPresetIds,
}) {
  final out = <TransitionProblem>[];
  void add(TransitionProblemKind k, String m, {bool error = true}) => out.add(TransitionProblem(k, m, isError: error));

  final numbers = {'outStartSec': t.outStartSec, 'inStartSec': t.inStartSec, 'lengthSec': t.lengthSec};
  numbers.forEach((name, v) {
    if (!v.isFinite) add(TransitionProblemKind.invalidNumber, '$name is not a finite number');
  });
  if (t.outStartSec < 0) add(TransitionProblemKind.negativeStart, 'outStartSec is negative');
  if (t.inStartSec < 0) add(TransitionProblemKind.negativeStart, 'inStartSec is negative');
  if (t.lengthSec.isFinite && (t.lengthSec < kTransitionMinLengthSec || t.lengthSec > kTransitionMaxLengthSec)) {
    add(TransitionProblemKind.lengthOutOfRange,
        'lengthSec must be within $kTransitionMinLengthSec..$kTransitionMaxLengthSec', error: false);
  }
  final len = t.clampedLengthSec;
  if (outDurationSec != null && t.outStartSec.isFinite && t.outStartSec + len > outDurationSec + 1e-6) {
    add(TransitionProblemKind.overlapBeyondOutgoing, 'the overlap runs past the end of the outgoing song',
        error: false);
  }
  if (inDurationSec != null && t.inStartSec.isFinite && t.inStartSec + len > inDurationSec + 1e-6) {
    add(TransitionProblemKind.overlapBeyondIncoming, 'the overlap runs past the end of the incoming song',
        error: false);
  }
  void lanes(String who, TransitionLanes l) {
    final db = {'volumeDb': l.volumeDb, 'lowDb': l.lowDb, 'midDb': l.midDb, 'highDb': l.highDb};
    db.forEach((name, c) {
      if (c.maxValue > kTransitionMaxDb || c.minValue < kTransitionMinDb) {
        add(TransitionProblemKind.valueOutOfRange, '$who.$name leaves $kTransitionMinDb..$kTransitionMaxDb dB',
            error: false);
      }
    });
    if (l.filter.maxValue > 1 || l.filter.minValue < -1) {
      add(TransitionProblemKind.valueOutOfRange, '$who.filter leaves -1..1', error: false);
    }
    if (l.echo.maxValue > 1 || l.echo.minValue < 0) {
      add(TransitionProblemKind.valueOutOfRange, '$who.echo leaves 0..1', error: false);
    }
  }

  lanes('out', t.outLanes);
  lanes('in', t.inLanes);
  if (t.presetId != null && knownPresetIds != null && !knownPresetIds.contains(t.presetId)) {
    add(TransitionProblemKind.unknownPreset, 'preset ${t.presetId} does not exist', error: false);
  }
  if (t.version > kTransitionVersion || t.version < 1) {
    add(TransitionProblemKind.unsupportedVersion, 'version ${t.version} is not supported');
  }
  if (!t.outLanes.isUntouchedAt(0)) {
    add(TransitionProblemKind.outgoingAlteredAtStart, 'the outgoing song is already altered when the overlap starts',
        error: false);
  }
  if (t.outLanes.audibleGainAt(1) > 0.01) {
    add(TransitionProblemKind.outgoingAudibleAtEnd, 'the outgoing song is still audible when the overlap ends',
        error: false);
  }
  if (t.inLanes.audibleGainAt(0) > 0.01) {
    add(TransitionProblemKind.incomingAudibleAtStart, 'the incoming song is already audible when the overlap starts',
        error: false);
  }
  if (!t.inLanes.isUntouchedAt(1)) {
    add(TransitionProblemKind.incomingAlteredAtEnd, 'the incoming song is still altered when the overlap ends',
        error: false);
  }
  return out;
}
