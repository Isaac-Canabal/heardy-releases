import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';

/// Where the audible hand-over between two songs is, as far as the UI cares.
///
/// - [pre]: a transition clip is playing but both songs are not heard yet; the
///   UI keeps showing the outgoing song even if the player already advanced.
/// - [enter]: the overlap just began; the incoming cover arrives.
/// - [both]: both songs are heard.
/// - [leave]: the overlap is over; the outgoing cover leaves.
enum OverlapPhase { pre, enter, both, leave }

/// Longest part of the overlap that counts as [OverlapPhase.enter].
const double overlapEnterMaxSec = 0.4;

/// Immutable view-state of an overlap. Pure data: it never touches playback.
class OverlapView {
  const OverlapView({
    required this.outgoing,
    required this.incoming,
    required this.progress,
    required this.phase,
  });

  final MediaItem outgoing;
  final MediaItem incoming;

  /// 0..1 across the audible overlap.
  final double progress;
  final OverlapPhase phase;

  @override
  bool operator ==(Object other) =>
      other is OverlapView &&
      other.outgoing.id == outgoing.id &&
      other.incoming.id == incoming.id &&
      other.progress == progress &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(outgoing.id, incoming.id, progress, phase);
}

/// Phase and progress at [positionSec] of an overlap that starts at
/// [overlapStartSec] and lasts [overlapSec]. Null for anything that is not a
/// usable number; never throws.
({OverlapPhase phase, double progress})? overlapPhaseAt({
  required double positionSec,
  required double overlapStartSec,
  required double overlapSec,
}) {
  if (!positionSec.isFinite || !overlapStartSec.isFinite || !overlapSec.isFinite) return null;
  if (overlapSec <= 0) return null;
  final into = positionSec - overlapStartSec;
  if (into < 0) return (phase: OverlapPhase.pre, progress: 0.0);
  final progress = math.min(1.0, into / overlapSec);
  if (into >= overlapSec) return (phase: OverlapPhase.leave, progress: 1.0);
  final enterSec = math.min(overlapEnterMaxSec, overlapSec * 0.2);
  return (phase: into < enterSec ? OverlapPhase.enter : OverlapPhase.both, progress: progress);
}

/// [OverlapView] for [positionSec] of an overlap, or null when the numbers are unusable.
OverlapView? overlapViewAt({
  required MediaItem outgoing,
  required MediaItem incoming,
  required double positionSec,
  required double overlapStartSec,
  required double overlapSec,
}) {
  final at = overlapPhaseAt(
    positionSec: positionSec,
    overlapStartSec: overlapStartSec,
    overlapSec: overlapSec,
  );
  if (at == null) return null;
  return OverlapView(outgoing: outgoing, incoming: incoming, progress: at.progress, phase: at.phase);
}

/// Song whose title and artist the UI shows: what is heard, not what the
/// player has already advanced to. During an overlap the text follows the
/// louder song.
MediaItem displayedMediaItem(MediaItem real, OverlapView? view) {
  if (view == null) return real;
  switch (view.phase) {
    case OverlapPhase.pre:
      return view.outgoing;
    case OverlapPhase.enter:
    case OverlapPhase.both:
      return view.progress >= 0.5 ? view.incoming : view.outgoing;
    case OverlapPhase.leave:
      return view.incoming;
  }
}
