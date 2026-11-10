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
import '../mix_engine.dart';
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

class MixJobRunner {
  MixJobRunner({
    required this.codec,
    required this.separator,
    required this.models,
    required this.cache,
    required this.workRoot,
    MixRenderBackend? renderer,
    this.peakCeilingDbtp = -1.5,
  }) : renderer = renderer ?? IsolateMixRenderBackend();

  final MixAudioCodec codec;
  final StemSeparator separator;
  final MixModelResolver models;
  final StemCache cache;

  /// Directorio privado para los temporales de cada trabajo.
  final String workRoot;
  final MixRenderBackend renderer;
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

    final work = Directory('$workRoot${Platform.pathSeparator}job-${DateTime.now().microsecondsSinceEpoch}-${++_seq}');
    final sep = Platform.pathSeparator;
    final keys = <String>{};
    final pending = <CachedStems>[];
    try {
      check();
      await work.create(recursive: true);
      final model = await models(req.quality);
      final modelId = model.spec.id;
      final songs = [req.a, req.b];
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

      // AAC sube el true peak: se mide el archivo codificado y, si pasa del
      // techo, se recodifica una vez con el recorte que propone el motor.
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
      final out = File(req.outputPath);
      await out.parent.create(recursive: true);
      if (await out.exists()) await out.delete();
      try {
        await File(encoded).rename(out.path);
      } on FileSystemException {
        await File(encoded).copy(out.path);
      }
      report(MixJobStage.done, 1);
      return MixJobResult(
        outputPath: out.path,
        report: outcome.report,
        encodedTruePeakDb: tp,
        trimDb: trim,
        encodes: encodes,
        peakWithinCeiling: within,
      );
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

/// [MixRenderBackend] real: lee los PCM dentro de un isolate, analiza lo que
/// no venga de la caché, renderiza y escribe el resultado; al main isolate
/// solo vuelven el informe y los análisis. Cancelar mata el isolate.
class IsolateMixRenderBackend implements MixRenderBackend {
  @override
  Future<MixRenderOutcome> render(MixRenderRequest r, {MixProgressCallback? onProgress, MixCancelToken? cancel}) async {
    final events = ReceivePort();
    final done = Completer<MixRenderOutcome>();
    events.listen((m) {
      if (m is MixProgress) {
        onProgress?.call(m);
      } else if (m is MixRenderOutcome) {
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
    final iso = await Isolate.spawn(_renderMain, (events.sendPort, r), onExit: exitPort.sendPort, debugName: 'mix-render');
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
}

Future<void> _renderMain((SendPort, MixRenderRequest) msg) async {
  final (port, r) = msg;
  try {
    Future<MixSongInput> load(MixRenderInput s, double from) async {
      final mix = await _readPcm(s.mixPath);
      final voc = await _readPcm(s.vocalsPath);
      final inst = await _readPcm(s.instrumentalPath);
      final analysis = s.analysis ??
          analyzeSong(_mono(mix), kMixSampleRate,
              vocals: _mono(voc), tick: (f) => port.send(MixProgress(MixStage.analysis, from + 0.15 * f)));
      return MixSongInput(name: s.name, mix: mix, vocals: voc, instrumental: inst, analysis: analysis);
    }

    final a = await load(r.a, 0);
    final b = await load(r.b, 0.15);
    final res = await renderMix(
      a: a,
      b: b,
      mode: r.mode,
      options: r.options,
      onProgress: (p) => port.send(MixProgress(p.stage, 0.3 + 0.7 * p.fraction)),
    );
    final sink = File(r.outputPcmPath).openWrite();
    const step = 1 << 18;
    final x = res.pcm.interleaved;
    for (var i = 0; i < x.length; i += step) {
      sink.add(float32ToLeBytes(Float32List.sublistView(x, i, i + step < x.length ? i + step : x.length)));
    }
    await sink.close();
    port.send(MixRenderOutcome(res.report, a.analysis!, b.analysis!));
  } on MixRejected catch (e) {
    port.send(e);
  } catch (e) {
    port.send('$e');
  }
}
