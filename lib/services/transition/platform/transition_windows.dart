// Lectura de ventanas de PCM para las transiciones. El códec decodifica la
// canción completa a un archivo f32le estéreo 44.1 kHz; aquí sólo se leen del
// archivo los rangos que el renderizador necesita.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../mix/mix_dsp.dart' show Clip;
import '../../mix/mix_types.dart' show MixCancelToken, kMixSampleRate;
import '../../mix/platform/mix_codec.dart';
import '../transition_model.dart';

/// Margen extra de la canción entrante por el estiramiento de tempo.
const kTransitionWindowMargin = 0.08;

class TransitionDecodeException implements Exception {
  const TransitionDecodeException(this.message);
  final String message;
  @override
  String toString() => 'TransitionDecodeException: $message';
}

/// Canción ya decodificada a un archivo temporal f32le estéreo 44.1 kHz.
class TransitionDecodedSong {
  const TransitionDecodedSong(this.path, this.frames);
  final String path;
  final int frames;
  double get durationSec => frames / kMixSampleRate;

  void dispose() {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// Costura inyectable: en pruebas se sustituye por un falso.
abstract class TransitionSongDecoder {
  Future<TransitionDecodedSong> decode(String songId, String playablePath, {MixCancelToken? cancel});
}

class CodecTransitionSongDecoder implements TransitionSongDecoder {
  CodecTransitionSongDecoder(this.codec, this.workDir);
  final MixAudioCodec codec;
  final String workDir;
  int _n = 0;

  @override
  Future<TransitionDecodedSong> decode(String songId, String playablePath, {MixCancelToken? cancel}) async {
    await Directory(workDir).create(recursive: true);
    final out = '$workDir${Platform.pathSeparator}tr-${DateTime.now().microsecondsSinceEpoch}-${_n++}.f32';
    try {
      final frames = await codec.decodeToMixPcm(playablePath, out, cancel: cancel);
      if (frames <= 0) throw const TransitionDecodeException('audio vacío');
      return TransitionDecodedSong(out, frames);
    } on MixCodecException catch (e) {
      TransitionDecodedSong(out, 0).dispose();
      throw TransitionDecodeException(e.message);
    } catch (_) {
      TransitionDecodedSong(out, 0).dispose();
      rethrow;
    }
  }
}

/// Segundos de cada canción que hacen falta para renderizar [t]: la saliente
/// desde el pre-roll hasta el final del solape; la entrante desde su punto de
/// entrada hasta el solape más el margen de estiramiento y el post-roll.
(double, double) transitionWindowFor(
  SongTransition t, {
  required double durationSec,
  required bool outgoing,
  double preRollSec = 2,
  double postRollSec = 2,
}) {
  final len = t.clampedLengthSec;
  final dur = math.max(0.0, durationSec);
  if (outgoing) {
    final start = math.max(0.0, t.outStartSec - preRollSec);
    return (math.min(start, dur), math.min(dur, t.outStartSec + len + 0.25));
  }
  final start = math.min(math.max(0.0, t.inStartSec), dur);
  return (start, math.min(dur, t.inStartSec + len * (1 + kTransitionWindowMargin) + postRollSec + 0.25));
}

class TransitionPcmWindow {
  const TransitionPcmWindow(this.pcm, this.offsetSec);
  final Clip pcm;

  /// Posición en la canción del primer frame.
  final double offsetSec;
}

/// Lee [startSec]..[endSec] del archivo f32le estéreo; el rango se recorta a lo que hay.
Future<TransitionPcmWindow> readPcmWindow(String f32Path, double startSec, double endSec) async {
  final raf = await File(f32Path).open();
  try {
    final total = await raf.length() ~/ 8;
    final a = (startSec * kMixSampleRate).round().clamp(0, total).toInt();
    final b = (endSec * kMixSampleRate).round().clamp(a, total).toInt();
    await raf.setPosition(a * 8);
    final bytes = await raf.read((b - a) * 8);
    final frames = bytes.length ~/ 8;
    final data = ByteData.sublistView(bytes);
    final l = Float32List(frames), r = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      l[i] = data.getFloat32(8 * i, Endian.little);
      r[i] = data.getFloat32(8 * i + 4, Endian.little);
    }
    return TransitionPcmWindow(Clip(l, r), a / kMixSampleRate);
  } finally {
    await raf.close();
  }
}

/// Escribe [pcm] como WAV PCM de 16 bits estéreo (recorta a ±1).
Future<void> writeWav16(String path, Clip pcm, int sampleRate) async {
  final n = math.min(pcm.l.length, pcm.r.length);
  final dataBytes = n * 4;
  final header = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 4, Endian.little);
  header.setUint16(32, 4, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, dataBytes, Endian.little);
  final sink = File(path).openWrite();
  try {
    sink.add(header.buffer.asUint8List());
    const step = 1 << 16;
    int q(double v) => v.isFinite ? (v.clamp(-1.0, 1.0) * 32767).round() : 0;
    for (var i = 0; i < n; i += step) {
      final m = math.min(step, n - i);
      final chunk = ByteData(m * 4);
      for (var k = 0; k < m; k++) {
        chunk.setInt16(4 * k, q(pcm.l[i + k]), Endian.little);
        chunk.setInt16(4 * k + 2, q(pcm.r[i + k]), Endian.little);
      }
      sink.add(chunk.buffer.asUint8List());
    }
  } finally {
    await sink.close();
  }
}
