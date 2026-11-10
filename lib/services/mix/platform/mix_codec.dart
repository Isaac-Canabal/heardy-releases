// Decodificar a PCM y codificar a AAC/M4A para el Mix DJ. Todo lo que se
// escribe va a almacenamiento privado de la app; la entrada es un
// `Song.playablePath` (`content://` en Android, que solo abre el código nativo
// con MediaExtractor, nunca `dart:io`; ruta de archivo en Windows).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../windows_waveform_source.dart' show locateBundledFfmpeg;
import '../mix_types.dart';
import 'pcm_convert.dart';

/// True peak del resumen de `ebur128=peak=true` de ffmpeg (no el de las líneas
/// de avance). `-inf` para silencio.
double parseEbur128TruePeakDb(String log) {
  final i = log.lastIndexOf('True peak:');
  if (i < 0) throw const FormatException('ebur128 sin resumen de true peak');
  final m = RegExp(r'Peak:\s+(-?inf|[-+]?\d+(?:\.\d+)?)\s+dBFS').firstMatch(log.substring(i));
  if (m == null) throw const FormatException('ebur128 sin valor de true peak');
  final v = m.group(1)!;
  return v.endsWith('inf') ? double.negativeInfinity : double.parse(v);
}

class MixProcessOutcome {
  const MixProcessOutcome(this.exitCode, this.stderr);
  final int exitCode;
  final String stderr;
}

typedef MixProcessRunner = Future<MixProcessOutcome> Function(String exe, List<String> args, MixCancelToken? cancel);

class MixCodecException implements Exception {
  const MixCodecException(this.message);
  final String message;
  @override
  String toString() => 'MixCodecException: $message';
}

abstract class MixAudioCodec {
  /// Decodifica [playablePath] a f32le estéreo 44.1 kHz intercalado en
  /// [outPath]. Devuelve los frames escritos.
  Future<int> decodeToMixPcm(String playablePath, String outPath, {MixCancelToken? cancel});

  /// Codifica [pcmPath] (f32le estéreo 44.1 kHz) a AAC-LC en M4A, con [gainDb].
  Future<void> encodeAac(String pcmPath, String outPath, {double gainDb = 0, int bitrate = 192000, MixCancelToken? cancel});

  /// True peak (dBTP) del archivo ya codificado.
  Future<double> measureTruePeakDb(String encodedPath, {MixCancelToken? cancel});
}

/// Proceso con stderr acotado (los últimos 64 KB, de donde sale el resumen de
/// ebur128) y muerte al cancelar.
Future<MixProcessOutcome> runMixProcess(String exe, List<String> args, MixCancelToken? cancel) async {
  final p = await Process.start(exe, args);
  final err = StringBuffer();
  final errDone = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach((s) {
    err.write(s);
    if (err.length > 1 << 17) {
      final keep = err.toString().substring(err.length - (1 << 16));
      err
        ..clear()
        ..write(keep);
    }
  });
  unawaited(p.stdout.drain<void>());
  Timer? poll;
  if (cancel != null) {
    poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (cancel.isCancelled) p.kill();
    });
  }
  try {
    final code = await p.exitCode;
    await errDone;
    return MixProcessOutcome(code, err.toString());
  } finally {
    poll?.cancel();
  }
}

String _fmtDb(double db) {
  final s = db.toStringAsFixed(2);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
}

/// Windows: el ffmpeg LGPL empaquetado (`<exe>/ffmpeg/ffmpeg.exe`).
class WindowsFfmpegMixCodec implements MixAudioCodec {
  WindowsFfmpegMixCodec({String? Function()? locator, MixProcessRunner? runner})
      : _locator = locator ?? locateBundledFfmpeg,
        _runner = runner ?? runMixProcess;

  final String? Function() _locator;
  final MixProcessRunner _runner;

  Future<MixProcessOutcome> _run(List<String> args, MixCancelToken? cancel, {String? output}) async {
    final exe = _locator();
    if (exe == null) throw const MixCodecException('falta ffmpeg empaquetado');
    final r = await _runner(exe, args, cancel);
    if (cancel?.isCancelled ?? false) {
      if (output != null) _deleteQuietly(output);
      throw const MixCancelled();
    }
    if (r.exitCode != 0) {
      if (output != null) _deleteQuietly(output);
      // Solo el código: el texto de ffmpeg puede llevar rutas.
      throw MixCodecException('ffmpeg terminó con ${r.exitCode}');
    }
    return r;
  }

  @override
  Future<int> decodeToMixPcm(String playablePath, String outPath, {MixCancelToken? cancel}) async {
    await _run([
      '-v', 'error', '-nostdin',
      '-i', playablePath,
      '-vn', '-ac', '2', '-ar', '44100', '-f', 'f32le',
      '-y', outPath,
    ], cancel, output: outPath);
    return File(outPath).lengthSync() ~/ 8;
  }

  @override
  Future<void> encodeAac(String pcmPath, String outPath,
      {double gainDb = 0, int bitrate = 192000, MixCancelToken? cancel}) async {
    await _run([
      '-v', 'error', '-nostdin',
      '-f', 'f32le', '-ar', '44100', '-ac', '2', '-i', pcmPath,
      '-af', 'volume=${_fmtDb(gainDb)}dB',
      '-c:a', 'aac', '-b:a', '${bitrate ~/ 1000}k', '-movflags', '+faststart',
      '-y', outPath,
    ], cancel, output: outPath);
  }

  @override
  Future<double> measureTruePeakDb(String encodedPath, {MixCancelToken? cancel}) async {
    final r = await _run([
      '-hide_banner', '-nostats', '-nostdin',
      '-i', encodedPath,
      '-af', 'ebur128=peak=true', '-f', 'null', '-',
    ], cancel);
    return parseEbur128TruePeakDb(r.stderr);
  }
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// Android: MediaCodec/MediaExtractor/MediaMuxer por el canal `heardy/mix`
/// (MixCodec.kt). El nativo escribe el PCM tal como sale del decodificador
/// (convertido a float según `KEY_PCM_ENCODING`); el mapeo a estéreo y el
/// remuestreo a 44.1 kHz son Dart puro ([convertF32leToMixPcm]).
class AndroidMediaCodecMixCodec implements MixAudioCodec {
  AndroidMediaCodecMixCodec({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('heardy/mix');
  final MethodChannel _channel;
  int _jobs = 0;

  Future<T?> _call<T>(String method, Map<String, Object?> args, MixCancelToken? cancel) async {
    final job = 'mix-${++_jobs}';
    Timer? poll;
    if (cancel != null) {
      poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (cancel.isCancelled) _channel.invokeMethod<void>('cancel', {'job': job});
      });
    }
    try {
      return await _channel.invokeMethod<T>(method, {...args, 'job': job});
    } on PlatformException catch (e) {
      if (e.code == 'cancelled' || (cancel?.isCancelled ?? false)) throw const MixCancelled();
      throw MixCodecException('$method: ${e.code}');
    } finally {
      poll?.cancel();
    }
  }

  @override
  Future<int> decodeToMixPcm(String playablePath, String outPath, {MixCancelToken? cancel}) async {
    final raw = '$outPath.native';
    try {
      final info = await _call<Map<Object?, Object?>>('decode', {'uri': playablePath, 'out': raw}, cancel);
      final rate = info?['sampleRate'] as int?, channels = info?['channels'] as int?;
      if (rate == null || channels == null || rate <= 0 || channels <= 0) {
        throw const MixCodecException('decode: formato desconocido');
      }
      if (cancel?.isCancelled ?? false) throw const MixCancelled();
      return await convertF32leToMixPcm(raw, outPath, srcRate: rate, channels: channels);
    } catch (_) {
      _deleteQuietly(outPath);
      rethrow;
    } finally {
      _deleteQuietly(raw);
    }
  }

  @override
  Future<void> encodeAac(String pcmPath, String outPath,
      {double gainDb = 0, int bitrate = 192000, MixCancelToken? cancel}) async {
    await _call<void>('encodeAac', {'in': pcmPath, 'out': outPath, 'bitrate': bitrate, 'gainDb': gainDb}, cancel);
  }

  /// Decodifica el M4A recién codificado y mide con el true peak del motor.
  @override
  Future<double> measureTruePeakDb(String encodedPath, {MixCancelToken? cancel}) async {
    final pcm = '$encodedPath.peak.f32';
    try {
      await decodeToMixPcm(encodedPath, pcm, cancel: cancel);
      final meter = TruePeakMeter();
      await for (final x in readF32leStereo(pcm)) {
        meter.add(x);
        if (cancel?.isCancelled ?? false) throw const MixCancelled();
      }
      return meter.truePeakDb;
    } finally {
      _deleteQuietly(pcm);
    }
  }
}
