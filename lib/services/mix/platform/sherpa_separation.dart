// Separación voz / instrumental con la API C de sherpa-onnx (v2.0.1) por
// `dart:ffi`, como el puente del spike (tool/mix_spike/bin/separate.dart). El
// paquete sherpa_onnx de pub no expone la separación y arrastra los cuatro ABI
// de Android, así que se enlaza directamente con las bibliotecas que bajan el
// build de Gradle (arm64-v8a) y el de CMake (Windows x64).
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../mix_types.dart';
import 'mix_models.dart';
import 'pcm_convert.dart';
import 'separation_chunks.dart';

abstract class StemSeparator {
  /// Separa [inputPcmPath] (f32le estéreo 44.1 kHz) en voz e instrumental,
  /// escritos como el mismo formato a medida que salen los trozos.
  Future<void> separate({
    required String inputPcmPath,
    required String vocalsPath,
    required String instrumentalPath,
    required SeparationModelFiles model,
    void Function(double fraction)? onProgress,
    MixCancelToken? cancel,
  });
}

class MixSeparationFailed implements Exception {
  const MixSeparationFailed(this.message);
  final String message;
  @override
  String toString() => 'MixSeparationFailed: $message';
}

/// Rutas de las bibliotecas nativas. En Windows se abre primero nuestro
/// `onnxruntime.dll` por ruta completa: Windows 11 trae uno 1.17.1 en System32
/// que, si gana, hace fallar la API C ("API version [28] is not available").
class SherpaLibraries {
  const SherpaLibraries({this.onnxRuntime, required this.sherpa});
  final String? onnxRuntime;
  final String sherpa;

  static SherpaLibraries? forCurrentPlatform() {
    if (Platform.isWindows && Abi.current() == Abi.windowsX64) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      return SherpaLibraries(onnxRuntime: '$dir\\onnxruntime.dll', sherpa: '$dir\\sherpa-onnx-c-api.dll');
    }
    if (Platform.isAndroid && Abi.current() == Abi.androidArm64) {
      return const SherpaLibraries(onnxRuntime: 'libonnxruntime.so', sherpa: 'libsherpa-onnx-c-api.so');
    }
    return null;
  }

  /// Las bibliotecas existen (Windows) o se pueden cargar (Android).
  bool isAvailable() {
    try {
      if (Platform.isWindows) {
        return File(onnxRuntime!).existsSync() && File(sherpa).existsSync();
      }
      _open();
      return true;
    } catch (_) {
      return false;
    }
  }

  DynamicLibrary _open() {
    if (onnxRuntime != null) DynamicLibrary.open(onnxRuntime!);
    return DynamicLibrary.open(sherpa);
  }
}

final class _SpleeterCfg extends Struct {
  external Pointer<Utf8> vocals;
  external Pointer<Utf8> accompaniment;
}

final class _UvrCfg extends Struct {
  external Pointer<Utf8> model;
}

final class _ModelCfg extends Struct {
  external _SpleeterCfg spleeter;
  external _UvrCfg uvr;
  @Int32()
  external int numThreads;
  @Int32()
  external int debug;
  external Pointer<Utf8> provider;
}

final class _SepCfg extends Struct {
  external _ModelCfg model;
}

final class _Stem extends Struct {
  external Pointer<Pointer<Float>> samples;
  @Int32()
  external int numChannels;
  @Int32()
  external int n;
}

final class _SepOutput extends Struct {
  external Pointer<_Stem> stems;
  @Int32()
  external int numStems;
  @Int32()
  external int sampleRate;
}

class _Api {
  _Api(DynamicLibrary lib)
      : create = lib.lookupFunction<Pointer<Void> Function(Pointer<_SepCfg>), Pointer<Void> Function(Pointer<_SepCfg>)>(
            'SherpaOnnxCreateOfflineSourceSeparation'),
        destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'SherpaOnnxDestroyOfflineSourceSeparation'),
        process = lib.lookupFunction<
            Pointer<_SepOutput> Function(Pointer<Void>, Pointer<Pointer<Float>>, Int32, Int32, Int32),
            Pointer<_SepOutput> Function(
                Pointer<Void>, Pointer<Pointer<Float>>, int, int, int)>('SherpaOnnxOfflineSourceSeparationProcess'),
        destroyOutput = lib.lookupFunction<Void Function(Pointer<_SepOutput>), void Function(Pointer<_SepOutput>)>(
            'SherpaOnnxDestroySourceSeparationOutput');

  final Pointer<Void> Function(Pointer<_SepCfg>) create;
  final void Function(Pointer<Void>) destroy;
  final Pointer<_SepOutput> Function(Pointer<Void>, Pointer<Pointer<Float>>, int, int, int) process;
  final void Function(Pointer<_SepOutput>) destroyOutput;
}

class _Job {
  const _Job(this.port, this.libs, this.modelPaths, this.uvr, this.threads, this.input, this.vocals, this.inst,
      this.chunkFrames, this.overlapFrames);
  final SendPort port;
  final SherpaLibraries libs;
  final List<String> modelPaths;
  final bool uvr;
  final int threads;
  final String input, vocals, inst;
  final int chunkFrames, overlapFrames;
}

/// [StemSeparator] real: un isolate por canción, trozos de ~15 s, cancelación
/// entre trozos (una llamada nativa en curso no se puede interrumpir).
class SherpaStemSeparator implements StemSeparator {
  SherpaStemSeparator({
    required this.libraries,
    int? threads,
    this.chunkFrames = kSeparationChunkFrames,
    this.overlapFrames = kSeparationOverlapFrames,
  }) : threads = threads ?? (Platform.numberOfProcessors.clamp(1, 4));

  final SherpaLibraries libraries;

  /// Más de 4 hilos empeoró en el CPU híbrido del spike.
  final int threads;
  final int chunkFrames, overlapFrames;

  @override
  Future<void> separate({
    required String inputPcmPath,
    required String vocalsPath,
    required String instrumentalPath,
    required SeparationModelFiles model,
    void Function(double fraction)? onProgress,
    MixCancelToken? cancel,
  }) async {
    final spec = model.spec;
    final paths = [for (final f in spec.files) model.path(f.name)];
    final events = ReceivePort();
    final done = Completer<void>();
    SendPort? control;
    Timer? poll;
    events.listen((m) {
      if (m is SendPort) {
        control = m;
      } else if (m is double) {
        onProgress?.call(m);
      } else if (m == 'done') {
        if (!done.isCompleted) done.complete();
      } else if (m == 'cancelled') {
        if (!done.isCompleted) done.completeError(const MixCancelled());
      } else if (!done.isCompleted) {
        done.completeError(MixSeparationFailed('$m'));
      }
    });
    if (cancel != null) {
      poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (cancel.isCancelled) control?.send('cancel');
      });
    }
    final exitPort = ReceivePort();
    exitPort.listen((_) {
      // El aviso de salida llega por otro puerto y puede adelantarse al "done".
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!done.isCompleted) done.completeError(const MixSeparationFailed('el isolate terminó sin respuesta'));
      });
    });
    try {
      await Isolate.spawn(
          _separateMain,
          _Job(events.sendPort, libraries, paths, spec.isUvr, threads, inputPcmPath, vocalsPath, instrumentalPath,
              chunkFrames, overlapFrames),
          onExit: exitPort.sendPort,
          debugName: 'mix-separation');
      await done.future;
    } catch (_) {
      for (final p in [vocalsPath, instrumentalPath]) {
        try {
          final f = File(p);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      poll?.cancel();
      events.close();
      exitPort.close();
    }
  }
}

Future<void> _separateMain(_Job job) async {
  final control = ReceivePort();
  var cancelled = false;
  control.listen((m) {
    if (m == 'cancel') cancelled = true;
  });
  job.port.send(control.sendPort);
  final arena = Arena();
  RandomAccessFile? input;
  IOSink? outV, outI;
  Pointer<Void> ss = nullptr;
  _Api? api;
  try {
    api = _Api(job.libs._open());
    final cfg = arena<_SepCfg>();
    cfg.ref.model.spleeter.vocals = (job.uvr ? '' : job.modelPaths[0]).toNativeUtf8(allocator: arena);
    cfg.ref.model.spleeter.accompaniment = (job.uvr ? '' : job.modelPaths[1]).toNativeUtf8(allocator: arena);
    cfg.ref.model.uvr.model = (job.uvr ? job.modelPaths[0] : '').toNativeUtf8(allocator: arena);
    cfg.ref.model.numThreads = job.threads;
    cfg.ref.model.debug = 0;
    cfg.ref.model.provider = 'cpu'.toNativeUtf8(allocator: arena);
    ss = api.create(cfg);
    if (ss == nullptr) throw const MixSeparationFailed('no se pudo cargar el modelo');

    input = File(job.input).openSync();
    final frames = input.lengthSync() ~/ 8;
    final plan = planSeparationChunks(frames, chunkFrames: job.chunkFrames, overlapFrames: job.overlapFrames);
    final maxLen = plan.fold<int>(0, (m, c) => c.frames > m ? c.frames : m);
    final l = arena<Float>(maxLen), r = arena<Float>(maxLen);
    final chans = arena<Pointer<Float>>(2);
    chans[0] = l;
    chans[1] = r;
    final stitcher = ChunkStitcher(stems: 2, overlapFrames: job.overlapFrames);
    outV = File(job.vocals).openWrite();
    outI = File(job.inst).openWrite();
    final chunker = F32leChunker();
    for (var k = 0; k < plan.length; k++) {
      await Future<void>.delayed(Duration.zero); // deja entrar el "cancel"
      if (cancelled) throw const MixCancelled();
      final c = plan[k];
      input.setPositionSync(8 * c.readStart);
      final x = chunker.add(input.readSync(8 * c.frames));
      final n = x.length ~/ 2;
      final lv = l.asTypedList(n), rv = r.asTypedList(n);
      for (var i = 0; i < n; i++) {
        lv[i] = x[2 * i];
        rv[i] = x[2 * i + 1];
      }
      final out = api.process(ss, chans, 2, n, 44100);
      if (out == nullptr) throw const MixSeparationFailed('falló un trozo');
      try {
        if (out.ref.sampleRate != 44100 || out.ref.numStems < 2) {
          throw MixSeparationFailed('salida inesperada: ${out.ref.numStems} stems a ${out.ref.sampleRate} Hz');
        }
        // Stem 0 = voz, 1 = acompañamiento (con UVR, sherpa-onnx calcula el
        // acompañamiento como mezcla menos voz).
        final stems = <Float32List>[];
        for (var s = 0; s < 2; s++) {
          final st = out.ref.stems[s];
          final m = st.n;
          final y = Float32List(2 * m);
          final cl = st.samples[0].asTypedList(m);
          final cr = st.samples[st.numChannels > 1 ? 1 : 0].asTypedList(m);
          for (var i = 0; i < m; i++) {
            y[2 * i] = cl[i];
            y[2 * i + 1] = cr[i];
          }
          stems.add(y);
        }
        final ready = stitcher.add(c, stems);
        outV.add(float32ToLeBytes(ready[0]));
        outI.add(float32ToLeBytes(ready[1]));
      } finally {
        api.destroyOutput(out);
      }
      job.port.send((k + 1) / plan.length);
    }
    final tail = stitcher.finish();
    outV.add(float32ToLeBytes(tail[0]));
    outI.add(float32ToLeBytes(tail[1]));
    await outV.close();
    await outI.close();
    outV = outI = null;
    job.port.send('done');
  } on MixCancelled {
    job.port.send('cancelled');
  } catch (e) {
    job.port.send('$e');
  } finally {
    try {
      await outV?.close();
      await outI?.close();
    } catch (_) {}
    input?.closeSync();
    if (ss != nullptr) api?.destroy(ss);
    arena.releaseAll();
    control.close();
  }
}
