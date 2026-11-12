// Motor del Mix DJ: análisis → base → plan → render → master, sobre PCM ya
// decodificado y separado. Puro Dart y sin estado global, para correr en otro
// isolate ([MixIsolateJob]); se cancela con [MixCancelToken] y avisa del avance.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_analysis.dart';
import 'mix_dsp.dart';
import 'mix_edit_plan.dart';
import 'mix_envelope.dart';
import 'mix_mastering.dart';
import 'mix_planner.dart';
import 'mix_renderer.dart';
import 'mix_song.dart';
import 'mix_template_selector.dart';
import 'mix_types.dart';

class _Progress {
  _Progress(this.cb, this.cancel);
  final MixProgressCallback? cb;
  final MixCancelToken? cancel;
  double _last = 0;

  void check() {
    if (cancel?.isCancelled ?? false) throw const MixCancelled();
  }

  void report(MixStage stage, double fraction) {
    _last = math.max(_last, fraction.clamp(0.0, 1.0));
    cb?.call(MixProgress(stage, _last));
    check();
  }

  /// Tick de una etapa que ocupa [a, b) del avance total.
  MixTick span(MixStage stage, double a, double b) => (f) => report(stage, a + (b - a) * f.clamp(0.0, 1.0));

  Future<void> yieldNow() async {
    await Future<void>.delayed(Duration.zero);
    check();
  }
}

Float32List _mono(Float32List l, Float32List r) {
  final m = Float32List(l.length);
  for (var i = 0; i < l.length; i++) {
    m[i] = 0.5 * (l[i] + r[i]);
  }
  return m;
}

Clip _clip(StereoPcm p) {
  final (l, r) = p.planar();
  return Clip(l, r);
}

/// Mezcla [a] y [b] según [mode]. Lanza [MixCancelled] si se cancela. Es
/// [buildAutoEditPlan] seguido de [renderEditPlan], sin repetir el análisis.
Future<MixResult> renderMix({
  required MixSongInput a,
  required MixSongInput b,
  required MixMode mode,
  MixOptions options = const MixOptions(),
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  final p = _Progress(onProgress, cancel);
  final (auto, songs) = await _buildAuto(a, b, mode, options, p);
  return _renderPlanned(a, b, auto.plan, songs, options, p,
      warnings: auto.warnings, selection: auto.selection);
}

/// Fase de análisis y planificación: todo lo que hace [renderMix] hasta el
/// plan inclusive (base, tempo, tono, frases quitadas, plantilla), sin render.
/// El [MixAutoPlan] lleva el plan editable y lo que la interfaz muestra antes
/// de editar. Pasar `analysisA`/`analysisB` en `MixSongInput.analysis` evita
/// repetir el análisis en [renderEditPlan].
Future<MixAutoPlan> buildAutoEditPlan({
  required MixSongInput a,
  required MixSongInput b,
  required MixMode mode,
  MixOptions options = const MixOptions(),
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  final p = _Progress(onProgress, cancel);
  final (auto, _) = await _buildAuto(a, b, mode, options, p);
  return auto;
}

/// [buildAutoEditPlan] más las envolventes por compás de las dos canciones, que
/// salen de las mismas canciones ya medidas (sin repetir el trabajo). Para el
/// editor se llama con `MixOptions(targetDurationSec: null)`: sin compases
/// quitados, los compases de origen son los de la canción original.
Future<MixEditAnalysis> analyzeForEdit({
  required MixSongInput a,
  required MixSongInput b,
  required MixMode mode,
  MixOptions options = const MixOptions(),
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  final p = _Progress(onProgress, cancel);
  final (auto, songs) = await _buildAuto(a, b, mode, options, p);
  final envelopes = MixEnvelopes.fromSongs(songs);
  p.report(MixStage.done, 1);
  return MixEditAnalysis(auto: auto, envelopes: envelopes);
}

/// Renderiza y masteriza desde [plan] con las dos canciones. Tolera cualquier
/// plan (descarta o acota lo que no se puede renderizar; ver
/// [editSegmentsToSegs]); [validateEditPlan] dice qué no cuadra. El informe sale
/// del plan tal como está, con los avisos recalculados con su tono y tempo.
Future<MixResult> renderEditPlan({
  required MixSongInput a,
  required MixSongInput b,
  required MixEditPlan plan,
  MixOptions options = const MixOptions(),
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  final p = _Progress(onProgress, cancel);
  p.report(MixStage.analysis, 0);
  final inputs = {'a': a, 'b': b};
  final (clips, analyses) = await _analyze(inputs, p);
  final songs = await _measure(inputs, clips, analyses, {'a': plan.foldA, 'b': plan.foldB}, p);
  final dropped = {for (final x in plan.droppedBars) x};
  final target = songs[plan.droppedSong];
  // Si quitar esos compases dejara la canción sin cuerpo, se ignora.
  if (target != null && dropped.where((x) => x >= 0 && x < target.bars).length + 8 <= target.bars) {
    songs[plan.droppedSong] = target.withoutBars(dropped);
  }
  p.report(MixStage.planning, 0.55);
  return _renderPlanned(a, b, plan, songs, options, p);
}

Future<(Map<String, (Clip, Clip, Clip)>, Map<String, SongAnalysis>)> _analyze(
    Map<String, MixSongInput> inputs, _Progress p) async {
  const sr = kMixSampleRate;
  final clips = <String, (Clip, Clip, Clip)>{};
  final analyses = <String, SongAnalysis>{};
  var k = 0;
  for (final e in inputs.entries) {
    final mix = _clip(e.value.mix), voc = _clip(e.value.vocals), inst = _clip(e.value.instrumental);
    clips[e.key] = (mix, voc, inst);
    analyses[e.key] = e.value.analysis ??
        analyzeSong(_mono(mix.l, mix.r), sr,
            vocals: _mono(voc.l, voc.r), tick: p.span(MixStage.analysis, 0.2 * k, 0.2 * (k + 1)));
    k++;
    await p.yieldNow();
  }
  return (clips, analyses);
}

Future<Map<String, MixSong>> _measure(
  Map<String, MixSongInput> inputs,
  Map<String, (Clip, Clip, Clip)> clips,
  Map<String, SongAnalysis> analyses,
  Map<String, bool> folds,
  _Progress p,
) async {
  final songs = <String, MixSong>{};
  var k = 0;
  for (final e in inputs.entries) {
    final (mix, voc, inst) = clips[e.key]!;
    songs[e.key] = MixSong.fromAnalysis(
        id: e.key,
        name: e.value.name,
        mix: mix,
        vocals: voc,
        instrumental: inst,
        analysis: analyses[e.key]!,
        halfTime: folds[e.key]);
    p.report(MixStage.measure, 0.4 + 0.075 * ++k);
    await p.yieldNow();
  }
  return songs;
}

/// Análisis, base, tempo, tono, frases quitadas y plantilla. Devuelve además las
/// canciones ya medidas (la base recortada) para renderizar sin repetir trabajo.
Future<(MixAutoPlan, Map<String, MixSong>)> _buildAuto(
    MixSongInput a, MixSongInput b, MixMode mode, MixOptions options, _Progress p) async {
  p.report(MixStage.analysis, 0);
  final inputs = {'a': a, 'b': b};
  final (clips, analyses) = await _analyze(inputs, p);
  p.report(MixStage.measure, 0.4);
  // Plegado a medio tiempo mirando el par entero, no cada canción por separado.
  final (foldA, foldB) = chooseTempoFold(analyses['a']!.bpm, analyses['b']!.bpm,
      maxStretch: options.maxStretch, maxShared: options.maxSharedStretch);
  final songs = await _measure(inputs, clips, analyses, {'a': foldA, 'b': foldB}, p);
  final sa = songs['a']!, sb = songs['b']!;

  p.report(MixStage.planning, 0.55);
  final choice = chooseBase(sa, sb, mode);
  var base = choice.base;
  final o = choice.other;
  final tempo = planTempoForced(base.bpm, o.bpm,
      maxStretch: options.maxStretch, maxShared: options.maxSharedStretch, maxForced: options.maxForcedStretch);
  // Cuánto se alarga la base en la salida (1 si suena a su tempo nativo).
  final baseScale = base.bpm / tempo.commonBpm;
  final keysTrusted = sa.keyScore >= options.minKeyScore && sb.keyScore >= options.minKeyScore;
  final semitones = chooseSemitones(
    baseRoot: base.keyRoot,
    baseMinor: base.minor,
    baseScore: base.keyScore,
    otherRoot: o.keyRoot,
    otherMinor: o.minor,
    otherScore: o.keyScore,
    minKeyScore: options.minKeyScore,
  );

  final warnings = mixWarnings(
    bpmA: sa.bpm,
    bpmB: sb.bpm,
    secondsA: a.mix.seconds,
    secondsB: b.mix.seconds,
    rootA: sa.keyRoot,
    minorA: sa.minor,
    scoreA: sa.keyScore,
    rootB: sb.keyRoot,
    minorB: sb.minor,
    scoreB: sb.keyScore,
    baseIsA: base.id == 'a',
    semitonesOther: semitones,
    tempo: tempo,
    maxShared: options.maxSharedStretch,
    minKeyScore: options.minKeyScore,
  );

  final dropped = <int>[];
  final target = options.targetDurationSec;
  if (target != null) {
    final starts = phrasesToDrop(
      bars: base.bars,
      barSec: 240 / tempo.commonBpm,
      extraSec: (base.seconds - base.bars * base.barSec()) * baseScale,
      targetSec: target,
      lufs: (b0, b1) => base.stem(MixLayer.mix).lufs(b0, b1),
    );
    for (final s in starts) {
      dropped.addAll([for (var i = s; i < s + 8; i++) i]);
    }
  }
  final originalBars = base.bars;
  if (dropped.isNotEmpty) base = base.withoutBars(dropped.toSet());
  // La selección va sobre la base ya recortada: es la que se planifica de verdad.
  final TemplateChoice? auto = options.template == null
      ? selectTemplate(base: base, o: o, mode: mode, warnings: warnings)
      : null;
  final requested = options.template ?? auto!.template;
  final (usedTemplate, planned) = planMixResolved(requested, base, o, mode);
  final segs = planned..sort((x, y) => x.out.compareTo(y.out));
  await p.yieldNow();

  final baseIsA = choice.base.id == 'a';
  final plan = MixEditPlan.fromSegs(
    segs,
    baseSong: base.id,
    tempoBpm: tempo.commonBpm,
    semitonesA: baseIsA ? 0 : semitones,
    semitonesB: baseIsA ? semitones : 0,
    stretchA: baseIsA ? tempo.stretchBase : tempo.stretchOther,
    stretchB: baseIsA ? tempo.stretchOther : tempo.stretchBase,
    foldA: foldA,
    foldB: foldB,
    droppedSong: dropped.isEmpty ? '' : base.id,
    droppedBars: dropped,
    template: usedTemplate,
    baseReason: choice.reason,
    mode: mode,
  );
  final selection = auto?.selection ?? MixTemplateSelection(requested: requested, automatic: false);
  MixSongSummary summary(MixSongInput i, MixSong s, SongAnalysis an, bool fold) => MixSongSummary.of(s,
      name: i.name, nativeBpm: an.bpm, halfTime: fold, planBars: s.id == base.id ? originalBars - dropped.length : null);
  return (
    MixAutoPlan(
      plan: plan,
      warnings: warnings,
      selection: selection,
      keysTrusted: keysTrusted,
      summaryA: summary(a, sa, analyses['a']!, foldA),
      summaryB: summary(b, sb, analyses['b']!, foldB),
      analysisA: analyses['a']!,
      analysisB: analyses['b']!,
    ),
    {'a': baseIsA ? base : sa, 'b': baseIsA ? sb : base},
  );
}

/// Render y master de [plan] sobre canciones ya medidas ([songs]: la recortada
/// ya recortada). Sin [warnings] se calculan con el tono y tempo del plan.
Future<MixResult> _renderPlanned(
  MixSongInput a,
  MixSongInput b,
  MixEditPlan plan,
  Map<String, MixSong> songs,
  MixOptions options,
  _Progress p, {
  List<MixWarning>? warnings,
  MixTemplateSelection? selection,
}) async {
  const sr = kMixSampleRate;
  final sa = songs['a']!, sb = songs['b']!;
  final base = plan.baseSong == 'b' ? sb : sa;
  final o = identical(base, sa) ? sb : sa;
  final tempoBpm = plan.tempoBpm.isFinite && plan.tempoBpm > 0
      ? plan.tempoBpm.clamp(base.bpm / 4, base.bpm * 4).toDouble()
      : base.bpm;
  int clampSemis(int s) => s.clamp(-kMixMaxSemitones, kMixMaxSemitones).toInt();
  final semisA = clampSemis(plan.semitonesA), semisB = clampSemis(plan.semitonesB);
  final semisBase = base.id == 'a' ? semisA : semisB, semisOther = base.id == 'a' ? semisB : semisA;
  final stretchOther = tempoBpm / o.bpm - 1, stretchBase = tempoBpm / base.bpm - 1;
  final segs = editSegmentsToSegs(plan.segments, a: sa, b: sb, timelineBars: base.bars);

  final warn = warnings ??
      mixWarnings(
        bpmA: sa.bpm,
        bpmB: sb.bpm,
        secondsA: a.mix.seconds,
        secondsB: b.mix.seconds,
        rootA: sa.keyRoot,
        minorA: sa.minor,
        scoreA: sa.keyScore,
        rootB: sb.keyRoot,
        minorB: sb.minor,
        scoreB: sb.keyScore,
        baseIsA: base.id == 'a',
        semitonesOther: semisOther,
        semitonesA: semisA,
        semitonesB: semisB,
        tempo: TempoPlan(tempoBpm, stretchBase, stretchOther),
        maxShared: options.maxSharedStretch,
        minKeyScore: options.minKeyScore,
      );

  p.report(MixStage.rendering, 0.6);
  final bus = renderPlan(segs, base,
      tempoBpm: tempoBpm,
      semitones: semisOther.toDouble(),
      semitonesBase: semisBase.toDouble(),
      bandSplit: options.bandSplit,
      tick: p.span(MixStage.rendering, 0.6, 0.9));
  await p.yieldNow();

  p.report(MixStage.mastering, 0.9);
  final m = master(bus.l, bus.r, sr, options.master);
  p.report(MixStage.mastering, 0.97);
  final gaps = findGaps(bus.l, bus.r);
  final cuts = <int>{
    for (final s in segs)
      if (s.out > 0 && s.kind != MixLayer.vocals) bus.sampleOfBar(s.out)
  }.toList()
    ..sort();
  final report = MixReport(
    mode: plan.mode,
    baseSong: base.id,
    baseReason: plan.baseReason.isEmpty ? 'plan editado' : plan.baseReason,
    tempoBpm: tempoBpm,
    stretchPercent: stretchOther * 100,
    stretchPercentBase: stretchBase * 100,
    semitones: semisOther,
    keysTrusted: sa.keyScore >= options.minKeyScore && sb.keyScore >= options.minKeyScore,
    camelotA: sa.camelot,
    camelotB: sb.camelot,
    residualMsA: sa.residualMs,
    residualMsB: sb.residualMs,
    sections: [
      for (final s in segs)
        MixSection(
          song: s.song.id,
          layer: s.kind,
          sourceBar: s.src,
          outBar: s.out,
          bars: s.bars,
          gainDb: s.db,
          leadInBars: s.leadIn,
          toEnd: s.toEnd,
          startSec: bus.sampleOfBar(s.out) / sr,
        )
    ],
    cutsSec: [for (final c in cuts) c / sr],
    droppedBaseBars: plan.droppedBars,
    makeupDb: m.makeupDb,
    limiterMaxDb: m.limiter.maxReductionDb,
    limiterMeanDb: m.limiter.meanReductionDb,
    limiterPercent: m.limiter.percentActive,
    lufs: m.lufs,
    truePeakDb: m.truePeakDb,
    durationSec: bus.l.length / sr,
    gapsSec: gaps,
    warnings: warn,
    template: plan.template ?? MixTemplate.classic,
    selection: selection ?? MixTemplateSelection(requested: plan.template ?? MixTemplate.classic, automatic: false),
    outputBarZeroSec: bus.sampleOfBar(0) / sr,
  );
  p.report(MixStage.done, 1);
  return MixResult(StereoPcm.fromPlanar(bus.l, bus.r), report);
}

/// Un mix en un isolate aparte. [cancel] mata el isolate (el motor no guarda
/// nada fuera de él) y completa [result] con [MixCancelled].
class MixIsolateJob {
  MixIsolateJob._(this._isolate, this._events, this.result);

  final Isolate _isolate;
  final ReceivePort _events;
  final Future<MixResult> result;
  bool _finished = false;

  static Future<MixIsolateJob> start({
    required MixSongInput a,
    required MixSongInput b,
    required MixMode mode,
    MixOptions options = const MixOptions(),
    MixProgressCallback? onProgress,
  }) async {
    final events = ReceivePort();
    final done = Completer<MixResult>();
    late MixIsolateJob job;
    events.listen((m) {
      if (m is MixProgress) {
        onProgress?.call(m);
        return;
      }
      if (done.isCompleted) return;
      if (m is MixResult) {
        done.complete(m);
      } else if (m is MixRejected) {
        done.completeError(m);
      } else {
        done.completeError(StateError('fallo en el isolate del mix: $m'));
      }
      job._finish();
    });
    final iso = await Isolate.spawn(_mixIsolateMain, (events.sendPort, a, b, mode, options),
        errorsAreFatal: true, debugName: 'mix');
    job = MixIsolateJob._(iso, events, done.future);
    job._cancelDone = done;
    return job;
  }

  late final Completer<MixResult> _cancelDone;

  void cancel() {
    if (_finished) return;
    _isolate.kill(priority: Isolate.immediate);
    if (!_cancelDone.isCompleted) _cancelDone.completeError(const MixCancelled());
    _finish();
  }

  void _finish() {
    _finished = true;
    _events.close();
  }
}

Future<void> _mixIsolateMain((SendPort, MixSongInput, MixSongInput, MixMode, MixOptions) msg) async {
  final (port, a, b, mode, options) = msg;
  try {
    final r = await renderMix(a: a, b: b, mode: mode, options: options, onProgress: port.send);
    port.send(r);
  } on MixRejected catch (e) {
    port.send(e);
  } catch (e) {
    port.send('$e');
  }
}
