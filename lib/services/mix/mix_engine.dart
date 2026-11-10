// Motor del Mix DJ: análisis → base → plan → render → master, sobre PCM ya
// decodificado y separado. Puro Dart y sin estado global, para correr en otro
// isolate ([MixIsolateJob]); se cancela con [MixCancelToken] y avisa del avance.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_analysis.dart';
import 'mix_dsp.dart';
import 'mix_mastering.dart';
import 'mix_planner.dart';
import 'mix_renderer.dart';
import 'mix_song.dart';
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

/// Mezcla [a] y [b] según [mode]. Lanza [MixRejected] si el par no se puede
/// mezclar con estas reglas y [MixCancelled] si se cancela.
Future<MixResult> renderMix({
  required MixSongInput a,
  required MixSongInput b,
  required MixMode mode,
  MixOptions options = const MixOptions(),
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  const sr = kMixSampleRate;
  final p = _Progress(onProgress, cancel);
  p.report(MixStage.analysis, 0);

  final clips = <String, (Clip, Clip, Clip)>{};
  final analyses = <String, SongAnalysis>{};
  final inputs = {'a': a, 'b': b};
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
  p.report(MixStage.measure, 0.4);
  final songs = <String, MixSong>{};
  k = 0;
  // Plegado a medio tiempo mirando el par entero, no cada canción por separado.
  final (foldA, foldB) = chooseTempoFold(analyses['a']!.bpm, analyses['b']!.bpm,
      maxStretch: options.maxStretch, maxShared: options.maxSharedStretch);
  final folds = {'a': foldA, 'b': foldB};
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
  final sa = songs['a']!, sb = songs['b']!;

  p.report(MixStage.planning, 0.55);
  final choice = chooseBase(sa, sb, mode);
  var base = choice.base;
  final o = choice.other;
  final tempo = planTempo(base.bpm, o.bpm, maxStretch: options.maxStretch, maxShared: options.maxSharedStretch);
  if (tempo == null) {
    throw MixRejected(
        'tempos demasiado lejos: ${(base.bpm * 2).toStringAsFixed(2)} / ${(o.bpm * 2).toStringAsFixed(2)} BPM '
        '(más de ${(options.maxSharedStretch * 100).round()} % por canción)',
        tempo: true);
  }
  final stretch = tempo.stretchOther;
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
    if (dropped.isNotEmpty) base = base.withoutBars(dropped.toSet());
  }
  final segs = planMix(base, o, mode)..sort((x, y) => x.out.compareTo(y.out));
  await p.yieldNow();

  p.report(MixStage.rendering, 0.6);
  final bus = renderPlan(segs, base,
      tempoBpm: tempo.commonBpm,
      semitones: semitones.toDouble(), bandSplit: options.bandSplit, tick: p.span(MixStage.rendering, 0.6, 0.9));
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
    mode: mode,
    baseSong: base.id,
    baseReason: choice.reason,
    tempoBpm: tempo.commonBpm,
    stretchPercent: stretch * 100,
    stretchPercentBase: tempo.stretchBase * 100,
    semitones: semitones,
    keysTrusted: keysTrusted,
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
    droppedBaseBars: dropped,
    makeupDb: m.makeupDb,
    limiterMaxDb: m.limiter.maxReductionDb,
    limiterMeanDb: m.limiter.meanReductionDb,
    limiterPercent: m.limiter.percentActive,
    lufs: m.lufs,
    truePeakDb: m.truePeakDb,
    durationSec: bus.l.length / sr,
    gapsSec: gaps,
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
