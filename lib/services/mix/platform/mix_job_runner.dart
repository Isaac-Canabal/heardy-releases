// Un trabajo de Mix DJ de principio a fin: decodificar las dos canciones,
// separarlas (con caché por canción y modelo), analizar y renderizar con el
// motor, codificar a AAC/M4A 192k y comprobar el true peak del archivo ya
// codificado. Todo en almacenamiento privado de la app y en el dispositivo;
// nada se sube. Sin UI: la pantalla (T16) solo escucha [MixJob.progress].
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../mix_analysis.dart';
import '../mix_edit_plan.dart';
import '../mix_engine.dart';
import '../mix_envelope.dart';
import '../mix_mastering.dart';
import '../mix_types.dart';
import 'mix_codec.dart';
import 'mix_models.dart';
import 'pcm_convert.dart';
import 'sherpa_separation.dart';
import 'stem_cache.dart';

class MixSongSource {
  const MixSongSource({required this.songId, required this.name, required this.playablePath});

  /// `Song.id` (= hash del audio): clave de la caché de stems.
  final String songId;
  final String name;

  /// `Song.playablePath`: `content://` en Android, ruta en Windows.
  final String playablePath;
}

class MixJobRequest {
  const MixJobRequest({
    required this.a,
    required this.b,
    required this.mode,
    required this.quality,
    required this.outputPath,
    this.options = const MixOptions(),
  });
  final MixSongSource a, b;
  final MixMode mode;
  final MixQualityMode quality;

  /// Destino del .m4a, en almacenamiento privado de la app.
  final String outputPath;
  final MixOptions options;
}

enum MixJobStage { decoding, separating, analyzing, rendering, encoding, checkingPeak, done }

class MixJobProgress {
  const MixJobProgress(this.stage, this.fraction);
  final MixJobStage stage;

  /// Avance total, 0..1, no decreciente.
  final double fraction;
}

class MixJobResult {
  const MixJobResult({
    required this.outputPath,
    required this.report,
    required this.encodedTruePeakDb,
    required this.trimDb,
    required this.encodes,
    required this.peakWithinCeiling,
    this.outputEnvelope = const [],
  });
  final String outputPath;
  final MixReport report;

  /// True peak medido sobre el último archivo codificado.
  final double encodedTruePeakDb;

  /// Ganancia aplicada al codificar (0 o el recorte del segundo intento).
  final double trimDb;
  final int encodes;

  /// `false` si tras la única recodificación sigue por encima del techo.
  final bool peakWithinCeiling;

  /// Envolvente del resultado (pico 0..1 por 1/8 de compás del plan, desde el
  /// compás 0); vacía en el mix de una pasada, que no la calcula.
  final List<double> outputEnvelope;
}

class MixRenderInput {
  const MixRenderInput({
    required this.name,
    required this.mixPath,
    required this.vocalsPath,
    required this.instrumentalPath,
    this.analysis,
  });
  final String name, mixPath, vocalsPath, instrumentalPath;
  final SongAnalysis? analysis;
}

class MixRenderRequest {
  const MixRenderRequest({
    required this.a,
    required this.b,
    required this.mode,
    required this.options,
    required this.outputPcmPath,
  });
  final MixRenderInput a, b;
  final MixMode mode;
  final MixOptions options;
  final String outputPcmPath;
}

class MixRenderOutcome {
  const MixRenderOutcome(this.report, this.analysisA, this.analysisB);
  final MixReport report;
  final SongAnalysis analysisA, analysisB;
}

/// Análisis + render + master. La implementación real corre en un isolate que
/// lee los stems de disco, para no copiar ~0.5 GB de PCM entre isolates.
abstract class MixRenderBackend {
  Future<MixRenderOutcome> render(MixRenderRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel});
}

/// Fase 1 del editor: analizar el par y armar el plan automático.
class MixAnalyzeRequest {
  const MixAnalyzeRequest({required this.a, required this.b, required this.mode, required this.options});
  final MixRenderInput a, b;
  final MixMode mode;
  final MixOptions options;
}

/// Fase 2 del editor: renderizar el plan (editado) con las mismas canciones.
class MixEditRenderRequest {
  const MixEditRenderRequest({
    required this.a,
    required this.b,
    required this.plan,
    required this.options,
    required this.outputPcmPath,
  });
  final MixRenderInput a, b;
  final MixEditPlan plan;
  final MixOptions options;
  final String outputPcmPath;
}

class MixEditRenderOutcome {
  const MixEditRenderOutcome(this.report, this.envelope, this.analysisA, this.analysisB);
  final MixReport report;

  /// [outputEnvelope] del resultado ya masterizado.
  final List<double> envelope;
  final SongAnalysis analysisA, analysisB;
}

/// Las dos fases del editor. La implementación real corre cada una en un
/// isolate que lee los stems de disco, igual que [MixRenderBackend].
abstract class MixEditBackend {
  Future<MixEditAnalysis> analyze(MixAnalyzeRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel});
  Future<MixEditRenderOutcome> render(MixEditRenderRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel});
}

typedef MixModelResolver = Future<SeparationModelFiles> Function(MixQualityMode mode);

class MixJob {
  MixJob._(this._cancel, this._progress, this.result);

  /// Un trabajo hecho fuera de [MixJobRunner] (dobles de prueba de la UI).
  MixJob.external({
    required MixCancelToken cancel,
    required StreamController<MixJobProgress> progress,
    required this.result,
  })  : _cancel = cancel,
        _progress = progress;
  final MixCancelToken _cancel;
  final StreamController<MixJobProgress> _progress;
  final Future<MixJobResult> result;

  Stream<MixJobProgress> get progress => _progress.stream;
  void cancel() => _cancel.cancel();
}

/// Petición de la fase de análisis del editor (separa si hace falta, analiza y
/// arma el plan automático; no renderiza ni escribe ningún .m4a).
class MixAnalyzeJobRequest {
  const MixAnalyzeJobRequest({
    required this.a,
    required this.b,
    required this.mode,
    required this.quality,
    this.options = const MixOptions(targetDurationSec: null),
  });
  final MixSongSource a, b;
  final MixMode mode;
  final MixQualityMode quality;

  /// Para el editor, `targetDurationSec: null`: los compases de origen son los originales.
  final MixOptions options;
}

/// Petición de la fase de render del editor: reutiliza los stems y el análisis
/// que dejó la fase de análisis en la caché (no vuelve a separar mientras sigan).
class MixEditRenderJobRequest {
  const MixEditRenderJobRequest({
    required this.a,
    required this.b,
    required this.quality,
    required this.plan,
    required this.outputPath,
    this.options = const MixOptions(targetDurationSec: null),
  });
  final MixSongSource a, b;
  final MixQualityMode quality;
  final MixEditPlan plan;
  final String outputPath;
  final MixOptions options;
}

typedef MixAnalyzeStarter = MixAnalyzeJob Function(MixAnalyzeJobRequest request);
typedef MixEditRenderStarter = MixJob Function(MixEditRenderJobRequest request);

class MixAnalyzeJob {
  MixAnalyzeJob._(this._cancel, this._progress, this.result);

  /// Un trabajo hecho fuera de [MixJobRunner] (dobles de prueba de la UI).
  MixAnalyzeJob.external({
    required MixCancelToken cancel,
    required StreamController<MixJobProgress> progress,
    required this.result,
  })  : _cancel = cancel,
        _progress = progress;
  final MixCancelToken _cancel;
  final StreamController<MixJobProgress> _progress;
  final Future<MixEditAnalysis> result;

  Stream<MixJobProgress> get progress => _progress.stream;
  void cancel() => _cancel.cancel();
}

class MixJobRunner {
  MixJobRunner({
    required this.codec,
    required this.separator,
    required this.models,
    required this.cache,
    required this.workRoot,
    MixRenderBackend? renderer,
    MixEditBackend? editor,
    this.peakCeilingDbtp = -1.5,
  })  : renderer = renderer ?? IsolateMixRenderBackend(),
        editor = editor ?? IsolateMixEditBackend();

  final MixAudioCodec codec;
  final StemSeparator separator;
  final MixModelResolver models;
  final StemCache cache;

  /// Directorio privado para los temporales de cada trabajo.
  final String workRoot;
  final MixRenderBackend renderer;
  final MixEditBackend editor;
  final double peakCeilingDbtp;
  int _seq = 0;

  MixJob start(MixJobRequest request) {
    final cancel = MixCancelToken();
    final ctrl = StreamController<MixJobProgress>.broadcast();
    final result = _run(request, cancel, ctrl);
    // Sin oyente no debe quedar un error sin manejar.
    result.ignore();
    return MixJob._(cancel, ctrl, result);
  }

  /// Fase 1 del editor: decodifica, separa (con caché), analiza y arma el plan
  /// automático con las envolventes. No renderiza.
  MixAnalyzeJob startAnalyze(MixAnalyzeJobRequest request) {
    final cancel = MixCancelToken();
    final ctrl = StreamController<MixJobProgress>.broadcast();
    final result = _runAnalyze(request, cancel, ctrl);
    result.ignore();
    return MixAnalyzeJob._(cancel, ctrl, result);
  }

  /// Fase 2 del editor: renderiza el plan, sin volver a separar si los stems
  /// siguen en la caché, y deja el .m4a como el mix de una pasada.
  MixJob startEditRender(MixEditRenderJobRequest request) {
    final cancel = MixCancelToken();
    final ctrl = StreamController<MixJobProgress>.broadcast();
    final result = _runEditRender(request, cancel, ctrl);
    result.ignore();
    return MixJob._(cancel, ctrl, result);
  }

  /// Ejecuta [body] y limpia siempre: stems a medias, directorio de trabajo,
  /// caché acotada a [keys] y el flujo de avance.
  Future<T> _guarded<T>(
    StreamController<MixJobProgress> ctrl,
    Set<String> keys,
    List<CachedStems> pending,
    Directory work,
    Future<T> Function() body,
  ) async {
    try {
      return await body();
    } finally {
      for (final e in pending) {
        try {
          await cache.abort(e);
        } catch (_) {}
      }
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (err) {
        print('Mix: no se pudo borrar el directorio de trabajo ($err)');
      }
      try {
        await cache.evict(keepKeys: keys);
      } catch (err) {
        print('Mix: no se pudo acotar la caché de stems ($err)');
      }
      await ctrl.close();
    }
  }

  Directory _newWork() =>
      Directory('$workRoot${Platform.pathSeparator}job-${DateTime.now().microsecondsSinceEpoch}-${++_seq}');

  /// Decodifica las dos canciones y deja sus stems (de la caché o recién
  /// separados) y su análisis, como entradas del render, más el id del modelo.
  /// Ocupa 0..0.6 del avance.
  Future<(List<MixRenderInput>, String)> _prepareInputs({
    required List<MixSongSource> songs,
    required MixQualityMode quality,
    required Directory work,
    required MixCancelToken cancel,
    required void Function(MixJobStage, double) report,
    required Set<String> keys,
    required List<CachedStems> pending,
  }) async {
    void check() {
      if (cancel.isCancelled) throw const MixCancelled();
    }

    final sep = Platform.pathSeparator;
    check();
    await work.create(recursive: true);
    final model = await models(quality);
    final modelId = model.spec.id;
    final inputs = <MixRenderInput>[];

    for (var k = 0; k < 2; k++) {
      final s = songs[k];
      keys.add(StemCache.keyFor(s.songId, modelId));
      report(MixJobStage.decoding, 0.3 * k);
      final mixPath = '${work.path}${sep}mix_$k.f32';
      await codec.decodeToMixPcm(s.playablePath, mixPath, cancel: cancel);
      check();
      report(MixJobStage.separating, 0.3 * k + 0.05);
      var hit = await cache.lookup(s.songId, modelId);
      if (hit == null) {
        final entry = await cache.begin(s.songId, modelId);
        pending.add(entry);
        await separator.separate(
          inputPcmPath: mixPath,
          vocalsPath: entry.vocalsPath,
          instrumentalPath: entry.instrumentalPath,
          model: model,
          cancel: cancel,
          onProgress: (f) => report(MixJobStage.separating, 0.3 * k + 0.05 + 0.25 * f.clamp(0.0, 1.0)),
        );
        check();
        await cache.commit(entry);
        pending.remove(entry);
        hit = entry;
      }
      report(MixJobStage.separating, 0.3 * (k + 1));
      inputs.add(MixRenderInput(
        name: s.name,
        mixPath: mixPath,
        vocalsPath: hit.vocalsPath,
        instrumentalPath: hit.instrumentalPath,
        analysis: hit.analysis,
      ));
    }
    return (inputs, modelId);
  }

  /// AAC sube el true peak: se mide el archivo codificado y, si pasa del
  /// techo, se recodifica una vez con el recorte que propone el motor. Deja el
  /// resultado en [outputPath].
  Future<({double tp, double trim, int encodes, bool within, String path})> _encodeAndSave({
    required String outPcm,
    required Directory work,
    required String outputPath,
    required MixCancelToken cancel,
    required void Function(MixJobStage, double) report,
  }) async {
    void check() {
      if (cancel.isCancelled) throw const MixCancelled();
    }

    final sep = Platform.pathSeparator;
    final encoded = '${work.path}${sep}out.m4a';
    report(MixJobStage.encoding, 0.9);
    await codec.encodeAac(outPcm, encoded, cancel: cancel);
    check();
    report(MixJobStage.checkingPeak, 0.95);
    var tp = await codec.measureTruePeakDb(encoded, cancel: cancel);
    var trim = 0.0, encodes = 1;
    var within = true;
    final decision = checkEncodedTruePeak(measuredTruePeakDb: tp, ceilingDbtp: peakCeilingDbtp);
    if (!decision.withinCeiling) {
      check();
      trim = decision.trimDb;
      report(MixJobStage.encoding, 0.96);
      await codec.encodeAac(outPcm, encoded, gainDb: trim, cancel: cancel);
      encodes = 2;
      check();
      report(MixJobStage.checkingPeak, 0.98);
      tp = await codec.measureTruePeakDb(encoded, cancel: cancel);
      within = tp <= peakCeilingDbtp;
    }
    check();
    final out = File(outputPath);
    await out.parent.create(recursive: true);
    if (await out.exists()) await out.delete();
    try {
      await File(encoded).rename(out.path);
    } on FileSystemException {
      await File(encoded).copy(out.path);
    }
    report(MixJobStage.done, 1);
    return (tp: tp, trim: trim, encodes: encodes, within: within, path: out.path);
  }

  Future<MixJobResult> _run(MixJobRequest req, MixCancelToken cancel, StreamController<MixJobProgress> ctrl) async {
    await Future<void>.delayed(Duration.zero); // deja suscribirse a progress
    var last = 0.0;
    void report(MixJobStage stage, double f) {
      last = f > last ? f : last;
      if (!ctrl.isClosed) ctrl.add(MixJobProgress(stage, last));
    }

    void check() {
      if (cancel.isCancelled) throw const MixCancelled();
    }

    final work = _newWork();
    final sep = Platform.pathSeparator;
    final keys = <String>{};
    final pending = <CachedStems>[];
    return _guarded(ctrl, keys, pending, work, () async {
      final (inputs, modelId) = await _prepareInputs(
        songs: [req.a, req.b],
        quality: req.quality,
        work: work,
        cancel: cancel,
        report: report,
        keys: keys,
        pending: pending,
      );

      final outPcm = '${work.path}${sep}out.f32';
      report(MixJobStage.analyzing, 0.6);
      final outcome = await renderer.render(
        MixRenderRequest(a: inputs[0], b: inputs[1], mode: req.mode, options: req.options, outputPcmPath: outPcm),
        cancel: cancel,
        onProgress: (p) {
          final stage = p.stage == MixStage.analysis ? MixJobStage.analyzing : MixJobStage.rendering;
          report(stage, 0.6 + 0.3 * p.fraction);
        },
      );
      check();
      await cache.saveAnalysis(req.a.songId, modelId, outcome.analysisA);
      await cache.saveAnalysis(req.b.songId, modelId, outcome.analysisB);

      final saved =
          await _encodeAndSave(outPcm: outPcm, work: work, outputPath: req.outputPath, cancel: cancel, report: report);
      return MixJobResult(
        outputPath: saved.path,
        report: outcome.report,
        encodedTruePeakDb: saved.tp,
        trimDb: saved.trim,
        encodes: saved.encodes,
        peakWithinCeiling: saved.within,
      );
    });
  }

  Future<MixEditAnalysis> _runAnalyze(
      MixAnalyzeJobRequest req, MixCancelToken cancel, StreamController<MixJobProgress> ctrl) async {
    await Future<void>.delayed(Duration.zero);
    var last = 0.0;
    void report(MixJobStage stage, double f) {
      last = f > last ? f : last;
      if (!ctrl.isClosed) ctrl.add(MixJobProgress(stage, last));
    }

    void check() {
      if (cancel.isCancelled) throw const MixCancelled();
    }

    final work = _newWork();
    final keys = <String>{};
    final pending = <CachedStems>[];
    return _guarded(ctrl, keys, pending, work, () async {
      final (inputs, modelId) = await _prepareInputs(
        songs: [req.a, req.b],
        quality: req.quality,
        work: work,
        cancel: cancel,
        report: report,
        keys: keys,
        pending: pending,
      );
      report(MixJobStage.analyzing, 0.6);
      final analysis = await editor.analyze(
        MixAnalyzeRequest(a: inputs[0], b: inputs[1], mode: req.mode, options: req.options),
        cancel: cancel,
        onProgress: (p) => report(MixJobStage.analyzing, 0.6 + 0.39 * p.fraction),
      );
      check();
      await cache.saveAnalysis(req.a.songId, modelId, analysis.auto.analysisA);
      await cache.saveAnalysis(req.b.songId, modelId, analysis.auto.analysisB);
      report(MixJobStage.done, 1);
      return analysis;
    });
  }

  Future<MixJobResult> _runEditRender(
      MixEditRenderJobRequest req, MixCancelToken cancel, StreamController<MixJobProgress> ctrl) async {
    await Future<void>.delayed(Duration.zero);
    var last = 0.0;
    void report(MixJobStage stage, double f) {
      last = f > last ? f : last;
      if (!ctrl.isClosed) ctrl.add(MixJobProgress(stage, last));
    }

    void check() {
      if (cancel.isCancelled) throw const MixCancelled();
    }

    final work = _newWork();
    final sep = Platform.pathSeparator;
    final keys = <String>{};
    final pending = <CachedStems>[];
    return _guarded(ctrl, keys, pending, work, () async {
      final (inputs, modelId) = await _prepareInputs(
        songs: [req.a, req.b],
        quality: req.quality,
        work: work,
        cancel: cancel,
        report: report,
        keys: keys,
        pending: pending,
      );
      final outPcm = '${work.path}${sep}out.f32';
      report(MixJobStage.analyzing, 0.6);
      final outcome = await editor.render(
        MixEditRenderRequest(a: inputs[0], b: inputs[1], plan: req.plan, options: req.options, outputPcmPath: outPcm),
        cancel: cancel,
        onProgress: (p) {
          final stage = p.stage == MixStage.analysis ? MixJobStage.analyzing : MixJobStage.rendering;
          report(stage, 0.6 + 0.3 * p.fraction);
        },
      );
      check();
      await cache.saveAnalysis(req.a.songId, modelId, outcome.analysisA);
      await cache.saveAnalysis(req.b.songId, modelId, outcome.analysisB);
      final saved =
          await _encodeAndSave(outPcm: outPcm, work: work, outputPath: req.outputPath, cancel: cancel, report: report);
      return MixJobResult(
        outputPath: saved.path,
        report: outcome.report,
        encodedTruePeakDb: saved.tp,
        trimDb: saved.trim,
        encodes: saved.encodes,
        peakWithinCeiling: saved.within,
        outputEnvelope: outcome.envelope,
      );
    });
  }
}

Future<StereoPcm> _readPcm(String path) async {
  final bytes = await File(path).readAsBytes();
  final x = F32leChunker().add(bytes);
  return StereoPcm(x.length.isOdd ? Float32List.sublistView(x, 0, x.length - 1) : x);
}

Float32List _mono(StereoPcm p) {
  final x = p.interleaved;
  final m = Float32List(p.frames);
  for (var i = 0; i < m.length; i++) {
    m[i] = 0.5 * (x[2 * i] + x[2 * i + 1]);
  }
  return m;
}

/// Lanza [entry] en un isolate y espera un [T]. Los [MixProgress] van a
/// [onProgress]; un [MixRejected] o cualquier otro mensaje cuenta como fallo.
/// Cancelar mata el isolate; si muere solo sin responder, falla en vez de
/// quedarse esperando.
Future<T> _runInIsolate<T, M>(
  void Function((SendPort, M)) entry,
  M message, {
  required String debugName,
  MixProgressCallback? onProgress,
  MixCancelToken? cancel,
}) async {
  final events = ReceivePort();
  final done = Completer<T>();
  events.listen((m) {
    if (m is MixProgress) {
      onProgress?.call(m);
    } else if (m is T) {
      if (!done.isCompleted) done.complete(m);
    } else if (m is MixRejected) {
      if (!done.isCompleted) done.completeError(m);
    } else if (!done.isCompleted) {
      done.completeError(StateError('fallo en el isolate del mix: $m'));
    }
  });
  // Si el sistema o la memoria matan el isolate sin que llegue un resultado,
  // el aviso de salida evita que el trabajo se quede "en marcha" para siempre.
  final exitPort = ReceivePort();
  exitPort.listen((_) {
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!done.isCompleted) done.completeError(StateError('el isolate del mix terminó sin respuesta'));
    });
  });
  final iso = await Isolate.spawn<(SendPort, M)>(entry, (events.sendPort, message),
      onExit: exitPort.sendPort, debugName: debugName);
  Timer? poll;
  if (cancel != null) {
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (cancel.isCancelled && !done.isCompleted) {
        iso.kill(priority: Isolate.immediate);
        done.completeError(const MixCancelled());
      }
    });
  }
  try {
    return await done.future;
  } finally {
    poll?.cancel();
    events.close();
    exitPort.close();
  }
}

/// [MixRenderBackend] real: lee los PCM dentro de un isolate, analiza lo que
/// no venga de la caché, renderiza y escribe el resultado; al main isolate
/// solo vuelven el informe y los análisis. Cancelar mata el isolate.
class IsolateMixRenderBackend implements MixRenderBackend {
  @override
  Future<MixRenderOutcome> render(MixRenderRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel}) =>
      _runInIsolate<MixRenderOutcome, MixRenderRequest>(_renderMain, r,
          debugName: 'mix-render', onProgress: onProgress, cancel: cancel);
}

/// [MixEditBackend] real: cada fase en su isolate, leyendo los stems de disco.
/// Solo vuelven el plan con las envolventes, o el informe con la envolvente del
/// resultado; el PCM del render se escribe a disco.
class IsolateMixEditBackend implements MixEditBackend {
  @override
  Future<MixEditAnalysis> analyze(MixAnalyzeRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel}) =>
      _runInIsolate<MixEditAnalysis, MixAnalyzeRequest>(_analyzeMain, r,
          debugName: 'mix-analyze', onProgress: onProgress, cancel: cancel);

  @override
  Future<MixEditRenderOutcome> render(MixEditRenderRequest r,
          {MixProgressCallback? onProgress, MixCancelToken? cancel}) =>
      _runInIsolate<MixEditRenderOutcome, MixEditRenderRequest>(_editRenderMain, r,
          debugName: 'mix-edit-render', onProgress: onProgress, cancel: cancel);
}

Future<MixSongInput> _loadInput(SendPort port, MixRenderInput s, double from) async {
  final mix = await _readPcm(s.mixPath);
  final voc = await _readPcm(s.vocalsPath);
  final inst = await _readPcm(s.instrumentalPath);
  final analysis = s.analysis ??
      analyzeSong(_mono(mix), kMixSampleRate,
          vocals: _mono(voc), tick: (f) => port.send(MixProgress(MixStage.analysis, from + 0.15 * f)));
  return MixSongInput(name: s.name, mix: mix, vocals: voc, instrumental: inst, analysis: analysis);
}

Future<void> _writePcmFile(String path, StereoPcm pcm) async {
  final sink = File(path).openWrite();
  const step = 1 << 18;
  final x = pcm.interleaved;
  for (var i = 0; i < x.length; i += step) {
    sink.add(float32ToLeBytes(Float32List.sublistView(x, i, i + step < x.length ? i + step : x.length)));
  }
  await sink.close();
}

Future<void> _renderMain((SendPort, MixRenderRequest) msg) async {
  final (port, r) = msg;
  try {
    final a = await _loadInput(port, r.a, 0);
    final b = await _loadInput(port, r.b, 0.15);
    final res = await renderMix(
      a: a,
      b: b,
      mode: r.mode,
      options: r.options,
      onProgress: (p) => port.send(MixProgress(p.stage, 0.3 + 0.7 * p.fraction)),
    );
    await _writePcmFile(r.outputPcmPath, res.pcm);
    port.send(MixRenderOutcome(res.report, a.analysis!, b.analysis!));
  } on MixRejected catch (e) {
    port.send(e);
  } catch (e) {
    port.send('$e');
  }
}

Future<void> _analyzeMain((SendPort, MixAnalyzeRequest) msg) async {
  final (port, r) = msg;
  try {
    final a = await _loadInput(port, r.a, 0);
    final b = await _loadInput(port, r.b, 0.15);
    final res = await analyzeForEdit(
      a: a,
      b: b,
      mode: r.mode,
      options: r.options,
      onProgress: (p) => port.send(MixProgress(p.stage, 0.3 + 0.7 * p.fraction)),
    );
    port.send(res);
  } on MixRejected catch (e) {
    port.send(e);
  } catch (e) {
    port.send('$e');
  }
}

Future<void> _editRenderMain((SendPort, MixEditRenderRequest) msg) async {
  final (port, r) = msg;
  try {
    final a = await _loadInput(port, r.a, 0);
    final b = await _loadInput(port, r.b, 0.15);
    final res = await renderEditPlan(
      a: a,
      b: b,
      plan: r.plan,
      options: r.options,
      onProgress: (p) => port.send(MixProgress(p.stage, 0.3 + 0.7 * p.fraction)),
    );
    await _writePcmFile(r.outputPcmPath, res.pcm);
    final envelope =
        outputEnvelope(res.pcm, tempoBpm: res.report.tempoBpm, barZeroSec: res.report.outputBarZeroSec);
    port.send(MixEditRenderOutcome(res.report, envelope, a.analysis!, b.analysis!));
  } on MixRejected catch (e) {
    port.send(e);
  } catch (e) {
    port.send('$e');
  }
}
