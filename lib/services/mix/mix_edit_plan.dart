// Plan editable del Mix DJ: los mismos tramos que produce el planificador, pero
// como datos planos, inmutables y serializables, más el tono por canción. El
// editor avanzado los modifica y el motor los renderiza (renderEditPlan). El
// editor es permisivo: el validador solo informa, y la conversión a tramos del
// render descarta lo que no se puede tocar sin leer fuera de rango.
import 'dart:math' as math;

import 'mix_analysis.dart' show SongAnalysis;
import 'mix_envelope.dart';
import 'mix_planner.dart';
import 'mix_song.dart';
import 'mix_types.dart';

/// Rango de transposición por canción que acepta el render (±12 semitonos).
const kMixMaxSemitones = 12;

const _kMaxGainDb = 24.0, _kMinGainDb = -60.0, _kMaxLeadInBars = 8.0;

/// Un tramo del plan, ya colocado en la salida. Mismo significado que
/// [MixSeg] y [MixSection], sin referencia a la canción.
class MixEditSegment {
  const MixEditSegment({
    required this.song,
    required this.layer,
    required this.sourceBar,
    required this.outBar,
    required this.bars,
    this.gainDb = 0,
    this.leadInBars = 0,
    this.toEnd = false,
  });

  factory MixEditSegment.fromSeg(MixSeg s) => MixEditSegment(
        song: s.song.id,
        layer: s.kind,
        sourceBar: s.src,
        outBar: s.out,
        bars: s.bars,
        gainDb: s.db,
        leadInBars: s.leadIn,
        toEnd: s.toEnd,
      );

  factory MixEditSegment.fromJson(Map<String, dynamic> j) {
    final song = _str(j, 'song');
    if (song != 'a' && song != 'b') throw FormatException('segmento: "song" debe ser "a" o "b", no "$song"');
    final layerName = _str(j, 'layer');
    final layer = MixLayer.values.where((l) => l.name == layerName).firstOrNull;
    if (layer == null) throw FormatException('segmento: capa desconocida "$layerName"');
    return MixEditSegment(
      song: song,
      layer: layer,
      sourceBar: _int(j, 'sourceBar'),
      outBar: _int(j, 'outBar'),
      bars: _int(j, 'bars'),
      gainDb: _num(j, 'gainDb'),
      leadInBars: _num(j, 'leadInBars'),
      toEnd: _bool(j, 'toEnd'),
    );
  }

  /// 'a' o 'b'.
  final String song;
  final MixLayer layer;
  final int sourceBar;
  final int outBar;
  final int bars;
  final double gainDb;
  final double leadInBars;
  final bool toEnd;

  int get endBar => outBar + bars;

  MixEditSegment copyWith({
    String? song,
    MixLayer? layer,
    int? sourceBar,
    int? outBar,
    int? bars,
    double? gainDb,
    double? leadInBars,
    bool? toEnd,
  }) =>
      MixEditSegment(
        song: song ?? this.song,
        layer: layer ?? this.layer,
        sourceBar: sourceBar ?? this.sourceBar,
        outBar: outBar ?? this.outBar,
        bars: bars ?? this.bars,
        gainDb: gainDb ?? this.gainDb,
        leadInBars: leadInBars ?? this.leadInBars,
        toEnd: toEnd ?? this.toEnd,
      );

  Map<String, dynamic> toJson() => {
        'song': song,
        'layer': layer.name,
        'sourceBar': sourceBar,
        'outBar': outBar,
        'bars': bars,
        'gainDb': gainDb,
        'leadInBars': leadInBars,
        'toEnd': toEnd,
      };

  @override
  String toString() => 'MixEditSegment($song.${layer.name}[$sourceBar+$bars]@$outBar'
      '${gainDb != 0 ? ' ${gainDb.toStringAsFixed(1)}dB' : ''}${toEnd ? ' toEnd' : ''})';
}

/// Plan completo y autosuficiente: con las dos canciones basta para reproducir
/// el render. Los compases de origen de la canción recortada ([droppedSong])
/// cuentan sobre la canción ya recortada; [originalBarOf] los devuelve a los
/// de la canción original.
class MixEditPlan {
  MixEditPlan({
    required this.baseSong,
    required this.tempoBpm,
    required List<MixEditSegment> segments,
    this.semitonesA = 0,
    this.semitonesB = 0,
    this.stretchA = 0,
    this.stretchB = 0,
    this.foldA = false,
    this.foldB = false,
    this.droppedSong = '',
    List<int> droppedBars = const [],
    this.template,
    this.baseReason = '',
    this.mode = MixMode.automatic,
  })  : segments = List.unmodifiable(segments),
        droppedBars = List.unmodifiable(droppedBars);

  factory MixEditPlan.fromJson(Map<String, dynamic> j) {
    final base = _str(j, 'baseSong');
    if (base != 'a' && base != 'b') throw FormatException('plan: "baseSong" debe ser "a" o "b", no "$base"');
    final segs = j['segments'];
    if (segs is! List) throw const FormatException('plan: falta la lista "segments"');
    final dropped = j['droppedBars'];
    if (dropped is! List || dropped.any((x) => x is! int)) {
      throw const FormatException('plan: "droppedBars" debe ser una lista de enteros');
    }
    final tName = j['template'];
    MixTemplate? template;
    if (tName != null) {
      template = MixTemplate.values.where((t) => t.name == tName).firstOrNull;
      if (template == null) throw FormatException('plan: plantilla desconocida "$tName"');
    }
    final modeName = _str(j, 'mode');
    final mode = MixMode.values.where((m) => m.name == modeName).firstOrNull;
    if (mode == null) throw FormatException('plan: modo desconocido "$modeName"');
    final ds = _str(j, 'droppedSong');
    if (ds != '' && ds != 'a' && ds != 'b') throw FormatException('plan: "droppedSong" inválido "$ds"');
    return MixEditPlan(
      baseSong: base,
      tempoBpm: _num(j, 'tempoBpm'),
      semitonesA: _int(j, 'semitonesA'),
      semitonesB: _int(j, 'semitonesB'),
      stretchA: _num(j, 'stretchA'),
      stretchB: _num(j, 'stretchB'),
      foldA: _bool(j, 'foldA'),
      foldB: _bool(j, 'foldB'),
      droppedSong: ds,
      droppedBars: [for (final x in dropped) x as int],
      template: template,
      baseReason: _str(j, 'baseReason'),
      mode: mode,
      segments: [
        for (final s in segs)
          if (s is Map<String, dynamic>) MixEditSegment.fromJson(s) else throw const FormatException('plan: segmento inválido')
      ],
    );
  }

  /// Plan a partir de los tramos del planificador. Conserva su orden.
  factory MixEditPlan.fromSegs(
    List<MixSeg> segs, {
    required String baseSong,
    required double tempoBpm,
    int semitonesA = 0,
    int semitonesB = 0,
    double stretchA = 0,
    double stretchB = 0,
    bool foldA = false,
    bool foldB = false,
    String droppedSong = '',
    List<int> droppedBars = const [],
    MixTemplate? template,
    String baseReason = '',
    MixMode mode = MixMode.automatic,
  }) =>
      MixEditPlan(
        baseSong: baseSong,
        tempoBpm: tempoBpm,
        segments: [for (final s in segs) MixEditSegment.fromSeg(s)],
        semitonesA: semitonesA,
        semitonesB: semitonesB,
        stretchA: stretchA,
        stretchB: stretchB,
        foldA: foldA,
        foldB: foldB,
        droppedSong: droppedSong,
        droppedBars: droppedBars,
        template: template,
        baseReason: baseReason,
        mode: mode,
      );

  /// Canción cuya rejilla, tempo y duración definen la línea de tiempo ('a' o 'b').
  final String baseSong;

  /// Tempo común del plan, en BPM del plan (compás doble a medio tiempo). El
  /// render estira cada canción hasta él.
  final double tempoBpm;

  /// Transposición de cada canción entera (semitonos); el render la acota a ±[kMixMaxSemitones].
  final int semitonesA, semitonesB;

  /// Estiramiento de cada canción hacia [tempoBpm] (0.05 = 5 % más rápida). Informativo:
  /// el render lo deduce de [tempoBpm] y del tempo de cada canción.
  final double stretchA, stretchB;

  /// Plegado a medio tiempo de cada canción (lo decide el motor mirando el par).
  final bool foldA, foldB;

  /// Canción a la que se le quitaron compases ('a', 'b' o '' si ninguna) y cuáles
  /// (índices de la canción original). Los tramos cuentan sobre la canción recortada.
  final String droppedSong;
  final List<int> droppedBars;

  final List<MixEditSegment> segments;

  /// Plantilla con la que se generó (informativo; `null` si se armó a mano).
  final MixTemplate? template;

  /// Motivo de la elección de base (informativo).
  final String baseReason;

  /// Modo con el que se generó (informativo: el informe lo repite).
  final MixMode mode;

  String get otherSong => baseSong == 'a' ? 'b' : 'a';

  int semitonesOf(String song) => song == 'a' ? semitonesA : semitonesB;

  /// Compás de la canción original que corresponde al compás [trimmedBar] de la
  /// canción recortada (sin cambio si [song] no es la recortada).
  int originalBarOf(String song, int trimmedBar) =>
      song == droppedSong ? originalBarAfterDrop(trimmedBar, droppedBars) : trimmedBar;

  MixEditPlan copyWith({
    String? baseSong,
    double? tempoBpm,
    List<MixEditSegment>? segments,
    int? semitonesA,
    int? semitonesB,
    double? stretchA,
    double? stretchB,
    bool? foldA,
    bool? foldB,
    String? droppedSong,
    List<int>? droppedBars,
    MixTemplate? template,
    bool clearTemplate = false,
    String? baseReason,
    MixMode? mode,
  }) =>
      MixEditPlan(
        baseSong: baseSong ?? this.baseSong,
        tempoBpm: tempoBpm ?? this.tempoBpm,
        segments: segments ?? this.segments,
        semitonesA: semitonesA ?? this.semitonesA,
        semitonesB: semitonesB ?? this.semitonesB,
        stretchA: stretchA ?? this.stretchA,
        stretchB: stretchB ?? this.stretchB,
        foldA: foldA ?? this.foldA,
        foldB: foldB ?? this.foldB,
        droppedSong: droppedSong ?? this.droppedSong,
        droppedBars: droppedBars ?? this.droppedBars,
        template: clearTemplate ? null : (template ?? this.template),
        baseReason: baseReason ?? this.baseReason,
        mode: mode ?? this.mode,
      );

  Map<String, dynamic> toJson() => {
        'baseSong': baseSong,
        'tempoBpm': tempoBpm,
        'semitonesA': semitonesA,
        'semitonesB': semitonesB,
        'stretchA': stretchA,
        'stretchB': stretchB,
        'foldA': foldA,
        'foldB': foldB,
        'droppedSong': droppedSong,
        'droppedBars': droppedBars,
        'template': template?.name,
        'baseReason': baseReason,
        'mode': mode.name,
        'segments': [for (final s in segments) s.toJson()],
      };
}

/// Compás de la canción original que ocupa el compás [trimmedBar] una vez
/// quitados los compases [dropped] (índices de la original).
int originalBarAfterDrop(int trimmedBar, List<int> dropped) {
  final d = dropped.toSet().toList()..sort();
  var bar = trimmedBar;
  for (final x in d) {
    if (x <= bar) bar++;
  }
  return bar;
}

/// Tramos del plan para el render. Descarta los que no se pueden renderizar sin
/// leer fuera de rango o reservar memoria sin tope (canción desconocida,
/// `bars` negativo, origen fuera de la canción, salida fuera de la línea de
/// tiempo, números no finitos) y acota ganancia y adelanto de voz. Nunca lanza.
/// Los planes del planificador pasan sin cambios, también un tramo de 0 compases
/// (el planificador puede dejar una voz así; suena solo su entrada y salida).
List<MixSeg> editSegmentsToSegs(List<MixEditSegment> segs, {required MixSong a, required MixSong b, required int timelineBars}) {
  final out = <MixSeg>[];
  for (final s in segs) {
    final MixSong song;
    if (s.song == 'a') {
      song = a;
    } else if (s.song == 'b') {
      song = b;
    } else {
      continue;
    }
    if (s.bars < 0 || s.sourceBar < 0 || s.sourceBar >= song.bars) continue;
    if (s.outBar < 0 || s.outBar >= timelineBars) continue;
    if (!s.gainDb.isFinite || !s.leadInBars.isFinite) continue;
    if (song.barSample(s.sourceBar) >= song.stem(s.layer).length) continue;
    out.add(MixSeg(song, s.layer, s.sourceBar, s.outBar, math.min(s.bars, timelineBars),
        db: s.gainDb.clamp(_kMinGainDb, _kMaxGainDb).toDouble(),
        leadIn: s.leadInBars.clamp(0.0, _kMaxLeadInBars).toDouble(),
        toEnd: s.toEnd));
  }
  return out;
}

/// Ficha de una canción para el validador: compases tal como los ve el plan (ya recortada).
class MixEditSongInfo {
  const MixEditSongInfo({required this.bars});
  final int bars;
}

enum MixPlanProblemKind {
  /// Sin tramos: no hay nada que mezclar.
  emptyPlan,

  /// Transposición fuera de ±[kMixMaxSemitones] (el render la acota).
  pitchOutOfRange,

  /// Canción o base distinta de 'a'/'b'.
  unknownSong,

  /// Tempo no válido (no finito o ≤ 0).
  invalidTempo,

  /// `bars` negativo.
  invalidBars,

  /// `bars` = 0: el tramo no dura nada (el planificador puede dejar alguno; solo suenan su entrada y salida).
  emptySegment,

  /// Ganancia o adelanto no finito, o adelanto negativo.
  invalidValue,

  /// El tramo empieza fuera de la canción o se pasa de su final.
  segmentOutsideSource,

  /// El tramo empieza fuera de la línea de tiempo de la base o se pasa de su final.
  segmentOutsideTimeline,

  /// Dos tramos de voz suenan a la vez.
  overlappingVocals,

  /// Dos tramos de música (mezcla o instrumental) suenan a la vez: dos bajos.
  overlappingBody,

  /// Una voz suena sin un tramo instrumental debajo.
  vocalWithoutInstrumental,
}

class MixPlanProblem {
  const MixPlanProblem(this.kind, {this.segmentIndex = -1, this.song = ''});
  final MixPlanProblemKind kind;

  /// Índice del tramo (en [MixEditPlan.segments]) o -1 si el problema es del plan.
  final int segmentIndex;

  /// Canción afectada, si el problema es de una (p. ej. su tono).
  final String song;

  @override
  String toString() => 'MixPlanProblem(${kind.name}${segmentIndex >= 0 ? ' #$segmentIndex' : ''}'
      '${song.isEmpty ? '' : ' $song'})';
}

/// Revisa [plan] y cuenta lo que no cuadra. No lanza ni bloquea: el editor es
/// permisivo y el render tolera cualquier plan.
List<MixPlanProblem> validateEditPlan(MixEditPlan plan, {required MixEditSongInfo a, required MixEditSongInfo b}) {
  final out = <MixPlanProblem>[];
  if (plan.baseSong != 'a' && plan.baseSong != 'b') {
    out.add(const MixPlanProblem(MixPlanProblemKind.unknownSong));
  }
  if (!plan.tempoBpm.isFinite || plan.tempoBpm <= 0) out.add(const MixPlanProblem(MixPlanProblemKind.invalidTempo));
  for (final (song, st) in [('a', plan.semitonesA), ('b', plan.semitonesB)]) {
    if (st.abs() > kMixMaxSemitones) out.add(MixPlanProblem(MixPlanProblemKind.pitchOutOfRange, song: song));
  }
  if (plan.segments.isEmpty) out.add(const MixPlanProblem(MixPlanProblemKind.emptyPlan));
  final timeline = plan.baseSong == 'b' ? b.bars : a.bars;
  final segs = plan.segments;
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    if (s.song != 'a' && s.song != 'b') {
      out.add(MixPlanProblem(MixPlanProblemKind.unknownSong, segmentIndex: i));
      continue;
    }
    final songBars = (s.song == 'a' ? a : b).bars;
    if (s.bars < 0) out.add(MixPlanProblem(MixPlanProblemKind.invalidBars, segmentIndex: i, song: s.song));
    if (s.bars == 0) out.add(MixPlanProblem(MixPlanProblemKind.emptySegment, segmentIndex: i, song: s.song));
    if (!s.gainDb.isFinite || !s.leadInBars.isFinite || s.leadInBars < 0) {
      out.add(MixPlanProblem(MixPlanProblemKind.invalidValue, segmentIndex: i, song: s.song));
    }
    if (s.sourceBar < 0 || s.sourceBar >= songBars || (!s.toEnd && s.sourceBar + s.bars > songBars)) {
      out.add(MixPlanProblem(MixPlanProblemKind.segmentOutsideSource, segmentIndex: i, song: s.song));
    }
    if (s.outBar < 0 || s.outBar >= timeline || s.outBar + s.bars > timeline) {
      out.add(MixPlanProblem(MixPlanProblemKind.segmentOutsideTimeline, segmentIndex: i, song: s.song));
    }
  }
  bool overlap(MixEditSegment x, MixEditSegment y) => x.outBar < y.endBar && y.outBar < x.endBar;
  for (var j = 0; j < segs.length; j++) {
    final y = segs[j];
    if (y.bars <= 0) continue;
    for (var i = 0; i < j; i++) {
      final x = segs[i];
      if (x.bars <= 0 || !overlap(x, y)) continue;
      final xv = x.layer == MixLayer.vocals, yv = y.layer == MixLayer.vocals;
      if (xv && yv) {
        out.add(MixPlanProblem(MixPlanProblemKind.overlappingVocals, segmentIndex: j, song: y.song));
      } else if (!xv && !yv) {
        out.add(MixPlanProblem(MixPlanProblemKind.overlappingBody, segmentIndex: j, song: y.song));
      }
    }
    if (y.layer == MixLayer.vocals) {
      // Cada compás de la voz necesita un instrumental debajo.
      final lo = math.max(0, y.outBar), hi = math.min(y.endBar, math.max(0, timeline));
      var bare = y.endBar > timeline || y.outBar < 0;
      for (var k = lo; k < hi && !bare; k++) {
        bare = !segs.any((x) => x.layer == MixLayer.instrumental && x.bars > 0 && k >= x.outBar && k < x.endBar);
      }
      if (bare) out.add(MixPlanProblem(MixPlanProblemKind.vocalWithoutInstrumental, segmentIndex: j, song: y.song));
    }
  }
  return out;
}

/// Lo que la interfaz necesita saber de una canción tras el análisis.
class MixSongSummary {
  const MixSongSummary({
    required this.id,
    required this.name,
    required this.nativeBpm,
    required this.planBpm,
    required this.halfTime,
    required this.keyRoot,
    required this.minor,
    required this.keyScore,
    required this.camelot,
    required this.bars,
    required this.planBars,
    required this.introBars,
    required this.outroBars,
    required this.downbeatSec,
    required this.barSec,
    required this.seconds,
    required this.residualMs,
  });

  factory MixSongSummary.of(MixSong s,
          {required String name, required double nativeBpm, required bool halfTime, int? planBars}) =>
      MixSongSummary(
        id: s.id,
        name: name,
        nativeBpm: nativeBpm,
        planBpm: s.bpm,
        halfTime: halfTime,
        keyRoot: s.keyRoot,
        minor: s.minor,
        keyScore: s.keyScore,
        camelot: s.camelot,
        bars: s.bars,
        planBars: planBars ?? s.bars,
        introBars: s.introBars,
        outroBars: s.outroBars,
        downbeatSec: s.downbeat,
        barSec: s.barSec(),
        seconds: s.seconds,
        residualMs: s.residualMs,
      );

  final String id, name;

  /// Tempo analizado y tempo en unidades del plan (compás doble: la mitad si se pliega).
  final double nativeBpm, planBpm;
  final bool halfTime;
  final int keyRoot;
  final bool minor;
  final double keyScore;
  final String camelot;

  /// Compases de la canción original y compases tal como los ve el plan (sin los quitados).
  final int bars, planBars;

  /// Compases sin voz clara al principio y al final.
  final int introBars, outroBars;
  final double downbeatSec;

  /// Duración de un compás del plan (nativo) y de toda la canción, en segundos.
  final double barSec, seconds;
  final double residualMs;
}

/// Resultado de la fase de análisis y planificación: el plan automático y lo
/// que la interfaz muestra antes de editar.
class MixAutoPlan {
  const MixAutoPlan({
    required this.plan,
    required this.warnings,
    required this.selection,
    required this.keysTrusted,
    required this.summaryA,
    required this.summaryB,
    required this.analysisA,
    required this.analysisB,
  });

  final MixEditPlan plan;
  final List<MixWarning> warnings;
  final MixTemplateSelection selection;
  final bool keysTrusted;
  final MixSongSummary summaryA, summaryB;

  /// Análisis de cada canción: pasarlos en `MixSongInput.analysis` evita repetirlos al renderizar.
  final SongAnalysis analysisA, analysisB;

  String get baseReason => plan.baseReason;
  MixSongSummary summaryOf(String song) => song == 'a' ? summaryA : summaryB;
}

/// Lo que devuelve la fase de análisis del editor: el plan automático y las
/// envolventes por compás de las dos canciones (en la rejilla del plan) para
/// dibujar sus ondas.
class MixEditAnalysis {
  const MixEditAnalysis({required this.auto, required this.envelopes});
  final MixAutoPlan auto;
  final MixEnvelopes envelopes;
}

/// Cambia la canción base de [plan] a [newBase] ('a' o 'b') y recalcula lo que
/// depende de ella: el tempo común y los estiramientos ([planTempoForced], con
/// los topes de [options]) y la transposición automática de la otra canción
/// ([chooseSemitones]; la base queda en 0). Se descarta el tono y el
/// estiramiento que hubiera puesto el usuario. Los tramos no se tocan: la
/// línea de tiempo pasa a ser la de la nueva base y [validateEditPlan] dirá
/// cuáles quedaron fuera. Si [newBase] ya es la base, devuelve [plan].
MixEditPlan changeBaseSong(
  MixEditPlan plan,
  String newBase, {
  required MixSongSummary a,
  required MixSongSummary b,
  MixOptions options = const MixOptions(),
}) {
  if ((newBase != 'a' && newBase != 'b') || newBase == plan.baseSong) return plan;
  final base = newBase == 'a' ? a : b, other = newBase == 'a' ? b : a;
  final tempo = planTempoForced(base.planBpm, other.planBpm,
      maxStretch: options.maxStretch, maxShared: options.maxSharedStretch, maxForced: options.maxForcedStretch);
  final semis = chooseSemitones(
    baseRoot: base.keyRoot,
    baseMinor: base.minor,
    baseScore: base.keyScore,
    otherRoot: other.keyRoot,
    otherMinor: other.minor,
    otherScore: other.keyScore,
    minKeyScore: options.minKeyScore,
  );
  final baseIsA = newBase == 'a';
  return plan.copyWith(
    baseSong: newBase,
    tempoBpm: tempo.commonBpm,
    semitonesA: baseIsA ? 0 : semis,
    semitonesB: baseIsA ? semis : 0,
    stretchA: baseIsA ? tempo.stretchBase : tempo.stretchOther,
    stretchB: baseIsA ? tempo.stretchOther : tempo.stretchBase,
    baseReason: 'base elegida a mano',
  );
}

String _str(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! String) throw FormatException('falta "$k" o no es texto');
  return v;
}

int _int(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! int) throw FormatException('falta "$k" o no es entero');
  return v;
}

double _num(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! num) throw FormatException('falta "$k" o no es número');
  return v.toDouble();
}

bool _bool(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! bool) throw FormatException('falta "$k" o no es booleano');
  return v;
}
