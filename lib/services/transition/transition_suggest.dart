import 'dart:math' as math;

import '../mix/mix_analysis.dart' show SongAnalysis;
import 'transition_analysis.dart';
import 'transition_model.dart';
import 'transition_presets.dart';
import 'transition_render.dart' show kTransitionTempoGlideFraction, transitionTempoRatio;

const kTransitionBarChoices = [2, 4, 8, 16];
const kTransitionSecondChoices = [2.0, 4.0, 6.0, 8.0, 12.0];

/// Why lengths in bars are not offered for a pair.
enum TransitionGridIssue { none, outgoingGridUnknown, incomingGridUnknown, tempoTooFar }

/// One entry of the length menu: whole bars of the outgoing song, or plain seconds when [bars] is null.
class TransitionLengthOption {
  const TransitionLengthOption({required this.seconds, this.bars});
  final int? bars;
  final double seconds;
}

double transitionLengthForBars(num bars, double outBpm) => bars * 240 / outBpm;

/// Lengths to offer: 2, 4, 8 and 16 bars at the outgoing tempo when the beat grid is trusted (those that fit
/// the allowed range), plain seconds otherwise.
List<TransitionLengthOption> transitionLengthOptions({
  required double outBpm,
  required bool beatGridTrusted,
  double maxSec = kTransitionMaxLengthSec,
}) {
  if (beatGridTrusted && outBpm.isFinite && outBpm > 0) {
    final bars = [
      for (final b in kTransitionBarChoices)
        if (transitionLengthForBars(b, outBpm) >= kTransitionMinLengthSec && transitionLengthForBars(b, outBpm) <= maxSec)
          TransitionLengthOption(bars: b, seconds: transitionLengthForBars(b, outBpm)),
    ];
    if (bars.isNotEmpty) return bars;
  }
  return [
    for (final s in kTransitionSecondChoices)
      if (s <= maxSec) TransitionLengthOption(seconds: s),
  ];
}

class TransitionSuggestion {
  const TransitionSuggestion({
    required this.transition,
    required this.beatGridTrusted,
    required this.gridIssue,
    required this.lengthBars,
    required this.tempoRatio,
    required this.keysCompatible,
  });
  final SongTransition transition;

  /// True when both grids are usable and the tempos are close enough to beat-match: lengths go in bars.
  final bool beatGridTrusted;
  final TransitionGridIssue gridIssue;

  /// Overlap in bars of the outgoing song; null when the length is in seconds.
  final int? lengthBars;

  /// Outgoing over incoming tempo (octave-folded), null when unknown.
  final double? tempoRatio;

  /// Null when a key is not trusted.
  final bool? keysCompatible;
}

bool _camelotCompatible(SongAnalysis a, SongAnalysis b) {
  int number(SongAnalysis s) => int.tryParse(s.camelot.substring(0, s.camelot.length - 1)) ?? 0;
  final na = number(a), nb = number(b);
  if (a.keyMinor != b.keyMinor) return na == nb;
  final d = (na - nb).abs() % 12;
  return d == 0 || d == 1 || d == 11;
}

/// Seconds where the audible part of the song starts and ends, from the per-bar energy (bars under a tenth of
/// the median count as silence).
(double, double) _audibleRange(SongAnalysis a, double durationSec) {
  if (!hasUsableTempo(a) || a.barEnergy.isEmpty) return (0, durationSec);
  final sorted = [...a.barEnergy]..sort();
  final floor = 0.1 * sorted[sorted.length ~/ 2];
  final first = a.barEnergy.indexWhere((e) => e > floor);
  final last = a.barEnergy.lastIndexWhere((e) => e > floor);
  if (first < 0) return (0, durationSec);
  final start = (a.downbeatSec + first * a.barSec).clamp(0.0, durationSec).toDouble();
  final end = (a.downbeatSec + (last + 1) * a.barSec).clamp(0.0, durationSec).toDouble();
  return end > start ? (start, end) : (0, durationSec);
}

/// A starting point for the editor. Deterministic. The overlap begins on a downbeat at the start of the
/// outgoing song's last section (or as late as the length allows), the incoming song enters on its first
/// audible downbeat, the length is whole bars of the outgoing song, and the preset follows tempo and key.
/// When the grids cannot be trusted or the tempos are too far apart it falls back to a plain fade in seconds.
TransitionSuggestion suggestTransition({
  required SongAnalysis out,
  required double outDurationSec,
  required SongAnalysis inn,
  required double inDurationSec,
  String? presetId,
  int? preferredBars,
  bool outGridTrusted = true,
  bool inGridTrusted = true,
  double minSec = 4,
  double maxSec = 20,
  double fallbackSec = 8,
  double minKeyScore = 0.5,
}) {
  final outDur = outDurationSec.isFinite ? math.max(0.0, outDurationSec) : 0.0;
  final inDur = inDurationSec.isFinite ? math.max(0.0, inDurationSec) : 0.0;
  final ratio = hasUsableTempo(out) && hasUsableTempo(inn) ? transitionTempoRatio(out.bpm, inn.bpm) : null;
  final issue = !outGridTrusted || !hasUsableTempo(out)
      ? TransitionGridIssue.outgoingGridUnknown
      : !inGridTrusted || !hasUsableTempo(inn)
          ? TransitionGridIssue.incomingGridUnknown
          : (ratio! - 1).abs() > kTransitionMaxTempoShift
              ? TransitionGridIssue.tempoTooFar
              : TransitionGridIssue.none;
  final trusted = issue == TransitionGridIssue.none;
  final keysTrusted = out.keyScore >= minKeyScore && inn.keyScore >= minKeyScore;
  final keysCompatible = keysTrusted ? _camelotCompatible(out, inn) : null;
  final preset = transitionPresetById(presetId) ??
      transitionPresetById(!trusted ? 'classic' : (keysCompatible == false ? 'washOut' : 'bassSwap'))!;

  final (outAudibleStart, outAudibleEnd) = _audibleRange(out, outDur);
  final (inAudibleStart, _) = _audibleRange(inn, inDur);
  // Neither song gives more than half of itself to the overlap.
  final room = math.min(outAudibleEnd - outAudibleStart, inDur - inAudibleStart) / 2;

  int? bars;
  double length;
  if (trusted) {
    var b = (preferredBars ?? preset.preferredBars).clamp(1, 32).toInt();
    double sec() => transitionLengthForBars(b, out.bpm);
    while (b > 1 && (sec() > maxSec || sec() > room)) {
      b ~/= 2;
    }
    while (b < 32 && sec() < minSec && transitionLengthForBars(b * 2, out.bpm) <= math.min(maxSec, room)) {
      b *= 2;
    }
    bars = b;
    length = sec();
  } else {
    length = math.max(minSec, math.min(maxSec, fallbackSec));
    if (room > 0 && length > room) length = room;
  }
  length = length.clamp(kTransitionMinLengthSec, kTransitionMaxLengthSec).toDouble();

  final latestOut = math.max(0.0, outAudibleEnd - length);
  double outStart;
  if (trusted) {
    final earliest = math.max(outAudibleEnd - math.max(2 * length, 45), outDur / 2);
    double? section;
    for (final bar in out.boundaries) {
      final t = out.downbeatSec + bar * out.barSec;
      if (t >= earliest && t <= latestOut + 1e-6) section = t;
    }
    outStart = section ?? snapToGrid(latestOut - out.barSec / 2, out, downbeat: true, maxSec: latestOut);
  } else {
    outStart = latestOut;
  }

  final meanRatio = trusted ? ratio! + (1 - ratio) * kTransitionTempoGlideFraction / 2 : 1.0;
  final latestIn = math.max(0.0, inDur - length * meanRatio);
  final inStart = trusted
      ? snapToGrid(math.min(inAudibleStart, latestIn), inn, downbeat: true, maxSec: latestIn)
      : math.min(inAudibleStart, latestIn);

  final transition = applyPreset(
    preset.id,
    SongTransition(
      outStartSec: outStart,
      inStartSec: inStart,
      lengthSec: length,
      tempoMatch: trusted && (ratio! - 1).abs() > 0.002 ? TransitionTempoMatch.matchIncoming : TransitionTempoMatch.none,
      beatAligned: trusted,
    ),
  );
  return TransitionSuggestion(
    transition: transition,
    beatGridTrusted: trusted,
    gridIssue: issue,
    lengthBars: bars,
    tempoRatio: ratio,
    keysCompatible: keysCompatible,
  );
}
