// Pure helpers for the plain-language Mixer screens: song titles, times and the
// mapping from plan segments to the colored blocks the editor draws. No widgets
// and no l10n here, so everything is testable without rendering.
import 'dart:math' as math;

import '../../models/mix_record.dart';
import 'mix_edit_plan.dart';
import 'mix_types.dart';
import 'platform/mix_models.dart';

/// A title short enough for a button or chip; [fallback] when it is blank.
String shortSongTitle(String title, {int max = 26, String fallback = ''}) {
  final t = title.trim();
  if (t.isEmpty) return fallback;
  if (t.length <= max) return t;
  return '${t.substring(0, math.max(1, max - 1)).trimRight()}…';
}

/// Seconds that one bar lasts at [tempoBpm] (4 beats per bar); 0 for an invalid tempo.
double barSeconds(double tempoBpm) => tempoBpm.isFinite && tempoBpm > 0 ? 240 / tempoBpm : 0;

/// `m:ss`.
String clockText(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The time at which output bar [bar] starts.
String barTime(int bar, double tempoBpm) => clockText(bar * barSeconds(tempoBpm));

/// How many seconds a move of [bars] bars shifts a block.
double moveStepSeconds(int bars, double tempoBpm) => bars * barSeconds(tempoBpm);

/// Where the playhead is, in (fractional) output bars, for a position in the rendered file.
double playheadBar(int positionMs, double tempoBpm) {
  final bs = barSeconds(tempoBpm);
  return bs <= 0 || positionMs < 0 ? 0 : positionMs / 1000 / bs;
}

/// Position in the rendered file where output bar [bar] starts.
Duration positionForBar(num bar, double tempoBpm) =>
    Duration(milliseconds: (math.max(0, bar) * barSeconds(tempoBpm) * 1000).round());

enum MixBlockKind { music, voice, both }

/// A segment of the plan as a block on the result lane: [start]/[end] are 0..1
/// fractions of the timeline.
class MixBlock {
  const MixBlock({
    required this.index,
    required this.song,
    required this.kind,
    required this.start,
    required this.end,
    required this.selected,
  });
  final int index;
  final String song;
  final MixBlockKind kind;
  final double start, end;
  final bool selected;
}

MixBlockKind mixBlockKind(MixLayer layer) => switch (layer) {
      MixLayer.vocals => MixBlockKind.voice,
      MixLayer.instrumental => MixBlockKind.music,
      MixLayer.mix => MixBlockKind.both,
    };

/// One block per segment that lasts something, in plan order.
List<MixBlock> mixBlocks(List<MixEditSegment> segments, int totalBars, {int selectedIndex = -1}) {
  if (totalBars <= 0) return const [];
  return [
    for (var i = 0; i < segments.length; i++)
      if (segments[i].bars > 0)
        MixBlock(
          index: i,
          song: segments[i].song,
          kind: mixBlockKind(segments[i].layer),
          start: (segments[i].outBar / totalBars).clamp(0.0, 1.0),
          end: (segments[i].endBar / totalBars).clamp(0.0, 1.0),
          selected: i == selectedIndex,
        ),
  ];
}

/// The block the user touched: the last one covering [bar] on the touched row
/// (music on top, voice below; a block with both answers in either row), or
/// else the last one covering the bar at all, or -1.
int blockIndexAt(List<MixEditSegment> segments, {required int bar, required bool voiceRow}) {
  var any = -1;
  for (var i = segments.length - 1; i >= 0; i--) {
    final s = segments[i];
    if (s.bars <= 0 || bar < s.outBar || bar >= s.endBar) continue;
    any = any < 0 ? i : any;
    final onRow = s.layer == MixLayer.mix || (s.layer == MixLayer.vocals) == voiceRow;
    if (onRow) return i;
  }
  return any;
}

/// How a saved mix got its style, as the details dialog tells it.
enum MixStyleKind {
  /// The app picked the style ([MixDetails.template] says which).
  automatic,

  /// The user picked the style.
  chosen,

  /// Edited by hand in the editor ([MixDetails.template] is where it started, if known).
  edited,

  /// The mix predates the record of its style.
  unknown,
}

/// What the "Detalles" dialog shows about a [MixRecord], free of l10n so it is
/// testable without rendering.
class MixDetails {
  const MixDetails({
    required this.style,
    required this.template,
    required this.quality,
    required this.createdAt,
    required this.titleA,
    required this.titleB,
  });

  final MixStyleKind style;
  final MixTemplate? template;
  final MixQualityMode? quality;
  final DateTime createdAt;
  final String titleA, titleB;
}

MixDetails mixDetailsOf(MixRecord r) {
  final template = MixTemplate.values.where((t) => t.name == r.styleId).firstOrNull;
  final quality = MixQualityMode.values.where((q) => q.name == r.quality).firstOrNull;
  final style = switch (r.styleOrigin) {
    MixRecord.kStyleAutomatic => template == null ? MixStyleKind.unknown : MixStyleKind.automatic,
    MixRecord.kStyleChosen => template == null ? MixStyleKind.unknown : MixStyleKind.chosen,
    MixRecord.kStyleEdited => MixStyleKind.edited,
    _ => MixStyleKind.unknown,
  };
  return MixDetails(
    style: style,
    template: style == MixStyleKind.unknown ? null : template,
    quality: quality,
    createdAt: r.createdAt.toLocal(),
    titleA: r.titleA.trim(),
    titleB: r.titleB.trim(),
  );
}
