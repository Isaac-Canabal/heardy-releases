import 'transition_model.dart';

enum TransitionLaneGroup { volume, eq, effect }

typedef _LanePair = (TransitionLanes, TransitionLanes);

/// A named shape for one lane group. Applying it rewrites only that group's curves on both songs.
class TransitionLaneShape {
  const TransitionLaneShape._(this.id, this.group, this.name, this.description, this._build);
  final String id;
  final TransitionLaneGroup group;
  final String name;
  final String description;
  final _LanePair Function(TransitionLanes out, TransitionLanes inn) _build;
}

/// A whole-transition preset: one shape per lane group.
class TransitionPreset {
  const TransitionPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.volumeShapeId,
    required this.eqShapeId,
    required this.effectShapeId,
    this.preferredBars = 8,
  });
  final String id;
  final String name;
  final String description;
  final String volumeShapeId, eqShapeId, effectShapeId;

  /// Overlap length this preset is designed for, in bars of the outgoing song.
  final int preferredBars;
}

const _ep = TransitionCurveShape.equalPower;
const _lg = TransitionCurveShape.linearGain;
const _off = kTransitionMinDb;

TransitionCurve _c(List<(double, double)> pts, [TransitionCurveShape shape = TransitionCurveShape.linear]) =>
    TransitionCurve([for (final p in pts) TransitionPoint(p.$1, p.$2)], shape: shape);

TransitionCurve get _flat => TransitionCurve.constant(0);

_LanePair Function(TransitionLanes, TransitionLanes) _volume(TransitionCurve out, TransitionCurve inn) =>
    (o, i) => (o.copyWith(volumeDb: out), i.copyWith(volumeDb: inn));

/// Per song: (low, mid, high).
_LanePair Function(TransitionLanes, TransitionLanes) _eq(
  (TransitionCurve, TransitionCurve, TransitionCurve) out,
  (TransitionCurve, TransitionCurve, TransitionCurve) inn,
) =>
    (o, i) => (
          o.copyWith(lowDb: out.$1, midDb: out.$2, highDb: out.$3),
          i.copyWith(lowDb: inn.$1, midDb: inn.$2, highDb: inn.$3),
        );

_LanePair Function(TransitionLanes, TransitionLanes) _effect({
  TransitionCurve? outFilter,
  TransitionCurve? inFilter,
  TransitionCurve? outEcho,
}) =>
    (o, i) => (
          o.copyWith(filter: outFilter ?? _flat, echo: outEcho ?? _flat),
          i.copyWith(filter: inFilter ?? _flat, echo: _flat),
        );

_LanePair Function(TransitionLanes, TransitionLanes) _bassSwap(double outCut, double inEnter) => _eq(
      (_c([(outCut - 0.03, 0), (outCut, _off)], _lg), _flat, _flat),
      (_c([(inEnter, _off), (inEnter + 0.03, 0)], _lg), _flat, _flat),
    );

final List<TransitionLaneShape> kTransitionVolumeShapes = List.unmodifiable([
  TransitionLaneShape._('smooth', TransitionLaneGroup.volume, 'Smooth crossfade',
      'Equal-loudness crossfade: the level stays steady from start to end.',
      _volume(TransitionCurve.ramp(0, _off, shape: _ep), TransitionCurve.ramp(_off, 0, shape: _ep))),
  TransitionLaneShape._('linear', TransitionLaneGroup.volume, 'Linear crossfade',
      'Straight crossfade with a slight dip in the middle.',
      _volume(TransitionCurve.ramp(0, _off, shape: _lg), TransitionCurve.ramp(_off, 0, shape: _lg))),
  TransitionLaneShape._('overlap', TransitionLaneGroup.volume, 'Overlap',
      'Both songs at full level; the outgoing one drops at the end.',
      _volume(_c([(0, 0), (0.85, 0), (1, _off)], _ep), _c([(0, _off), (0.15, 0)], _ep))),
  TransitionLaneShape._('fadeInFadeOut', TransitionLaneGroup.volume, 'Fade in, then fade out',
      'The incoming song fades in during the first half, the outgoing one fades out during the second.',
      _volume(_c([(0.5, 0), (1, _off)], _ep), _c([(0, _off), (0.5, 0)], _ep))),
  TransitionLaneShape._('cutInFadeOut', TransitionLaneGroup.volume, 'Cut in, fade out',
      'The incoming song starts at full level while the outgoing one fades out.',
      _volume(TransitionCurve.ramp(0, _off, shape: _ep), _flat)),
  TransitionLaneShape._('fadeInCutOut', TransitionLaneGroup.volume, 'Fade in, cut out',
      'The incoming song fades in and the outgoing one stops at the end.',
      _volume(_flat, TransitionCurve.ramp(_off, 0, shape: _ep))),
  TransitionLaneShape._('centerCut', TransitionLaneGroup.volume, 'Center cut',
      'Instant switch from one song to the other at the midpoint.',
      _volume(_c([(0.5, 0), (0.5, _off)]), _c([(0.5, _off), (0.5, 0)]))),
  TransitionLaneShape._('dropIn', TransitionLaneGroup.volume, 'Fade out, drop in',
      'The outgoing song fades away, a short gap follows and the incoming one enters at full level.',
      _volume(_c([(0, 0), (0.8, _off)], _ep), _c([(0.97, _off), (1, 0)], _ep))),
  TransitionLaneShape._('none', TransitionLaneGroup.volume, 'No volume change',
      'Both songs keep their level; the other lanes do the work.', _volume(_flat, _flat)),
]);

final List<TransitionLaneShape> kTransitionEqShapes = List.unmodifiable([
  TransitionLaneShape._('centerBassSwap', TransitionLaneGroup.eq, 'Bass swap at the middle',
      'The outgoing bass leaves and the incoming bass enters at the midpoint.', _bassSwap(0.5, 0.5)),
  TransitionLaneShape._('endBassSwap', TransitionLaneGroup.eq, 'Bass swap at the end',
      'The outgoing bass stays almost to the end, then the incoming bass takes over.', _bassSwap(0.88, 0.88)),
  TransitionLaneShape._(
      'threeBandFade',
      TransitionLaneGroup.eq,
      'Three-band fade',
      'Highs, mids and lows change hands one after the other.',
      _eq(
        (_c([(0.6, 0), (1, _off)], _ep), _c([(0.3, 0), (0.7, _off)], _ep), _c([(0, 0), (0.4, _off)], _ep)),
        (_c([(0.6, _off), (1, 0)], _ep), _c([(0.3, _off), (0.7, 0)], _ep), _c([(0, _off), (0.4, 0)], _ep)),
      )),
  TransitionLaneShape._('quickBassCut', TransitionLaneGroup.eq, 'Quick bass cut',
      'The outgoing bass is cut early, leaving a short gap before the incoming bass enters.', _bassSwap(0.4, 0.5)),
  TransitionLaneShape._('none', TransitionLaneGroup.eq, 'No EQ', 'Lows, mids and highs are left untouched.',
      _eq((_flat, _flat, _flat), (_flat, _flat, _flat))),
]);

final List<TransitionLaneShape> kTransitionEffectShapes = List.unmodifiable([
  TransitionLaneShape._('lowPassOut', TransitionLaneGroup.effect, 'Low-pass out',
      'A low-pass filter closes on the outgoing song until only its bass is left.',
      _effect(outFilter: TransitionCurve.ramp(0, -1))),
  TransitionLaneShape._('highPassIn', TransitionLaneGroup.effect, 'High-pass in',
      'The incoming song starts thin and its body opens up.', _effect(inFilter: _c([(0, 0.8), (0.8, 0)]))),
  TransitionLaneShape._('lowPassIn', TransitionLaneGroup.effect, 'Low-pass in',
      'The incoming song starts muffled and its highs open up.', _effect(inFilter: _c([(0, -0.8), (0.8, 0)]))),
  TransitionLaneShape._('highPassOut', TransitionLaneGroup.effect, 'High-pass out',
      'A high-pass filter thins the outgoing song until only its highs are left.',
      _effect(outFilter: TransitionCurve.ramp(0, 0.9))),
  TransitionLaneShape._('echoOut', TransitionLaneGroup.effect, 'Echo out',
      'The outgoing song feeds a beat-synced echo whose tail rings over the incoming one.',
      _effect(outEcho: _c([(0, 0), (0.3, 1)]))),
  TransitionLaneShape._('none', TransitionLaneGroup.effect, 'No effect', 'No filter and no echo.', _effect()),
]);

const List<TransitionPreset> kTransitionPresets = [
  TransitionPreset(
    id: 'classic',
    name: 'Classic fade',
    description: 'Plain equal-loudness crossfade.',
    volumeShapeId: 'smooth',
    eqShapeId: 'none',
    effectShapeId: 'none',
  ),
  TransitionPreset(
    id: 'bassSwap',
    name: 'Bass swap',
    description: 'Crossfade where the two basses never play together: they swap at the midpoint.',
    volumeShapeId: 'smooth',
    eqShapeId: 'centerBassSwap',
    effectShapeId: 'none',
  ),
  TransitionPreset(
    id: 'longBlend',
    name: 'Long blend',
    description: 'Both songs play together for a long time while highs, mids and lows change hands in turn.',
    volumeShapeId: 'overlap',
    eqShapeId: 'threeBandFade',
    effectShapeId: 'none',
    preferredBars: 16,
  ),
  TransitionPreset(
    id: 'lift',
    name: 'Lift',
    description: 'The incoming song builds up from its highs and takes the bass at the end.',
    volumeShapeId: 'overlap',
    eqShapeId: 'endBassSwap',
    effectShapeId: 'highPassIn',
  ),
  TransitionPreset(
    id: 'washOut',
    name: 'Wash out',
    description: 'A low-pass filter closes on the outgoing song while the incoming one takes over.',
    volumeShapeId: 'fadeInFadeOut',
    eqShapeId: 'centerBassSwap',
    effectShapeId: 'lowPassOut',
  ),
  TransitionPreset(
    id: 'echoOut',
    name: 'Echo out',
    description: 'The outgoing song stops and leaves an echo tail; the incoming one enters clean.',
    volumeShapeId: 'centerCut',
    eqShapeId: 'none',
    effectShapeId: 'echoOut',
    preferredBars: 4,
  ),
  TransitionPreset(
    id: 'hardCut',
    name: 'Cut',
    description: 'Instant switch on the beat, with no blend.',
    volumeShapeId: 'centerCut',
    eqShapeId: 'none',
    effectShapeId: 'none',
    preferredBars: 2,
  ),
  TransitionPreset(
    id: 'drop',
    name: 'Drop',
    description: 'The outgoing song thins out and fades, a short gap, then the incoming one hits at full level.',
    volumeShapeId: 'dropIn',
    eqShapeId: 'quickBassCut',
    effectShapeId: 'highPassOut',
    preferredBars: 4,
  ),
  TransitionPreset(
    id: 'sweep',
    name: 'Sweep',
    description: 'The incoming song opens up from a muffled start under the outgoing one; basses swap midway.',
    volumeShapeId: 'overlap',
    eqShapeId: 'centerBassSwap',
    effectShapeId: 'lowPassIn',
  ),
];

List<TransitionLaneShape> transitionLaneShapes(TransitionLaneGroup group) {
  switch (group) {
    case TransitionLaneGroup.volume:
      return kTransitionVolumeShapes;
    case TransitionLaneGroup.eq:
      return kTransitionEqShapes;
    case TransitionLaneGroup.effect:
      return kTransitionEffectShapes;
  }
}

TransitionLaneShape? transitionLaneShapeById(TransitionLaneGroup group, String? id) {
  for (final s in transitionLaneShapes(group)) {
    if (s.id == id) return s;
  }
  return null;
}

TransitionPreset? transitionPresetById(String? id) {
  for (final p in kTransitionPresets) {
    if (p.id == id) return p;
  }
  return null;
}

/// The preset made of exactly these three shapes, if any.
String? matchingPresetId(String? volumeShapeId, String? eqShapeId, String? effectShapeId) {
  for (final p in kTransitionPresets) {
    if (p.volumeShapeId == volumeShapeId && p.eqShapeId == eqShapeId && p.effectShapeId == effectShapeId) {
      return p.id;
    }
  }
  return null;
}

SongTransition _withShape(SongTransition t, TransitionLaneShape s) {
  final (o, i) = s._build(t.outLanes, t.inLanes);
  final next = t.copyWith(outLanes: o, inLanes: i);
  switch (s.group) {
    case TransitionLaneGroup.volume:
      return next.copyWith(volumeShapeId: s.id);
    case TransitionLaneGroup.eq:
      return next.copyWith(eqShapeId: s.id);
    case TransitionLaneGroup.effect:
      return next.copyWith(effectShapeId: s.id);
  }
}

/// Sets one lane group to a named shape, keeping position, length and the other lanes. The preset id follows
/// the resulting triple. An unknown id returns [t] unchanged.
SongTransition applyLaneShape(TransitionLaneGroup group, String id, SongTransition t) {
  final shape = transitionLaneShapeById(group, id);
  if (shape == null) return t;
  final next = _withShape(t, shape);
  final preset = matchingPresetId(next.volumeShapeId, next.eqShapeId, next.effectShapeId);
  return preset == null ? next.copyWith(clearPreset: true) : next.copyWith(presetId: preset);
}

/// Replaces the lanes with the preset's three shapes, keeping position, length, tempo and alignment. An
/// unknown id returns [base] unchanged.
SongTransition applyPreset(String id, SongTransition base) {
  final preset = transitionPresetById(id);
  if (preset == null) return base;
  var t = base;
  final picks = {
    TransitionLaneGroup.volume: preset.volumeShapeId,
    TransitionLaneGroup.eq: preset.eqShapeId,
    TransitionLaneGroup.effect: preset.effectShapeId,
  };
  for (final e in picks.entries) {
    final shape = transitionLaneShapeById(e.key, e.value);
    if (shape != null) t = _withShape(t, shape);
  }
  return t.copyWith(presetId: preset.id);
}

/// Marks one lane group as hand-edited after its curves were changed directly.
SongTransition markLaneEdited(TransitionLaneGroup group, SongTransition t) => t.copyWith(
      clearPreset: true,
      clearVolumeShape: group == TransitionLaneGroup.volume,
      clearEqShape: group == TransitionLaneGroup.eq,
      clearEffectShape: group == TransitionLaneGroup.effect,
    );
