// Conversión de PCM para el Mix DJ, pura y por trozos: bytes f32le, mapeo a
// estéreo, remuestreo a 44.1 kHz y true peak de un archivo ya codificado.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../mix_dsp.dart';

/// Recompone float32 little-endian de trozos partidos en cualquier byte.
class F32leChunker {
  final _pending = Uint8List(4);
  int _pendingLen = 0;

  int get pendingBytes => _pendingLen;

  Float32List add(List<int> bytes) {
    final total = _pendingLen + bytes.length;
    final out = Float32List(total ~/ 4);
    final bd = ByteData(4);
    var o = 0, i = 0;
    while (_pendingLen > 0 && _pendingLen < 4 && i < bytes.length) {
      _pending[_pendingLen++] = bytes[i++];
    }
    if (_pendingLen == 4) {
      for (var k = 0; k < 4; k++) {
        bd.setUint8(k, _pending[k]);
      }
      out[o++] = bd.getFloat32(0, Endian.little);
      _pendingLen = 0;
    } else if (_pendingLen > 0) {
      return out;
    }
    final whole = (bytes.length - i) ~/ 4;
    if (whole > 0) {
      final src = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      final view = ByteData.sublistView(src, i, i + 4 * whole);
      for (var k = 0; k < whole; k++) {
        out[o++] = view.getFloat32(4 * k, Endian.little);
      }
      i += 4 * whole;
    }
    while (i < bytes.length) {
      _pending[_pendingLen++] = bytes[i++];
    }
    return o == out.length ? out : Float32List.sublistView(out, 0, o);
  }
}

Uint8List float32ToLeBytes(Float32List x) {
  final b = ByteData(4 * x.length);
  for (var i = 0; i < x.length; i++) {
    b.setFloat32(4 * i, x[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Intercalado de [channels] canales → estéreo intercalado. Mono se duplica;
/// con más de dos se toman los dos primeros (frente izquierdo y derecho en el
/// orden de canales de Android y de ffmpeg).
Float32List toStereoInterleaved(Float32List x, int channels) {
  if (channels < 1 || x.length % channels != 0) {
    throw ArgumentError('trozo de ${x.length} muestras no es múltiplo de $channels canales');
  }
  if (channels == 2) return x;
  final frames = x.length ~/ channels;
  final y = Float32List(2 * frames);
  for (var f = 0; f < frames; f++) {
    final l = x[f * channels];
    y[2 * f] = l;
    y[2 * f + 1] = channels == 1 ? l : x[f * channels + 1];
  }
  return y;
}

/// Remuestreo estéreo por trozos con el mismo núcleo sinc que el motor
/// ([SincTable], corte bajado al submuestrear). El resultado no depende de cómo
/// se trocee la entrada.
class StereoStreamResampler {
  StereoStreamResampler(this.srcRate, this.dstRate)
      : _step = srcRate / dstRate,
        _tab = SincTable(cutoff: 0.95 * math.min(1.0, dstRate / srcRate));

  final int srcRate, dstRate;
  final double _step;
  final SincTable _tab;
  Float32List _l = Float32List(0), _r = Float32List(0);

  /// Frame absoluto de la fuente en el índice 0 de los buffers.
  int _base = 0;
  int _srcTotal = 0;
  int _k = 0;

  Float32List process(Float32List x) {
    if (srcRate == dstRate) return x;
    final n = x.length ~/ 2;
    final l = Float32List(_l.length + n), r = Float32List(_r.length + n);
    l.setAll(0, _l);
    r.setAll(0, _r);
    for (var i = 0; i < n; i++) {
      l[_l.length + i] = x[2 * i];
      r[_l.length + i] = x[2 * i + 1];
    }
    _l = l;
    _r = r;
    _srcTotal += n;
    return _emit(final_: false);
  }

  Float32List flush() {
    if (srcRate == dstRate) return Float32List(0);
    return _emit(final_: true);
  }

  Float32List _emit({required bool final_}) {
    final h = _tab.half;
    final out = <double>[];
    while (true) {
      final p = _k * _step;
      if (p >= _srcTotal) break;
      if (!final_ && p.floor() + h >= _srcTotal) break;
      final rel = p - _base;
      out
        ..add(_tab.at(_l, rel))
        ..add(_tab.at(_r, rel));
      _k++;
    }
    // Se conserva la historia que aún necesita el núcleo.
    final keepFrom = math.max(0, (_k * _step).floor() - h - _base);
    if (keepFrom > 0) {
      _l = Float32List.fromList(Float32List.sublistView(_l, keepFrom));
      _r = Float32List.fromList(Float32List.sublistView(_r, keepFrom));
      _base += keepFrom;
    }
    return Float32List.fromList(out);
  }
}

/// True peak (×4 sinc, como `truePeak` del motor) de un estéreo intercalado
/// que llega por trozos. Solo interpola cerca de los picos ya vistos, con un
/// umbral que nunca sube por encima del del motor sobre el archivo entero.
class TruePeakMeter {
  final _tab = SincTable();
  Float32List _l = Float32List(0), _r = Float32List(0);
  int _evaluated = 0; // índice del buffer desde el que falta evaluar
  double _sp = 0, _tp = 0;

  void add(Float32List x) {
    final n = x.length ~/ 2;
    final l = Float32List(_l.length + n), r = Float32List(_r.length + n);
    l.setAll(0, _l);
    r.setAll(0, _r);
    for (var i = 0; i < n; i++) {
      final a = x[2 * i], b = x[2 * i + 1];
      l[_l.length + i] = a;
      r[_l.length + i] = b;
      _sp = math.max(_sp, math.max(a.abs(), b.abs()));
    }
    _l = l;
    _r = r;
    _evaluate(_l.length - _tab.half - 1);
    final keepFrom = math.max(0, _evaluated - _tab.half);
    if (keepFrom > 0) {
      _l = Float32List.fromList(Float32List.sublistView(_l, keepFrom));
      _r = Float32List.fromList(Float32List.sublistView(_r, keepFrom));
      _evaluated -= keepFrom;
    }
  }

  void _evaluate(int until) {
    _tp = math.max(_tp, _sp);
    for (var i = _evaluated; i < until && i + 1 < _l.length; i++) {
      for (final ch in [_l, _r]) {
        if (math.max(ch[i].abs(), ch[i + 1].abs()) < 0.6 * _sp) continue;
        for (final f in const [0.25, 0.5, 0.75]) {
          _tp = math.max(_tp, _tab.at(ch, i + f).abs());
        }
      }
    }
    _evaluated = math.max(_evaluated, math.min(until, _l.length - 1));
  }

  double get truePeakDb {
    _evaluate(_l.length - 1);
    return _tp <= 0 ? double.negativeInfinity : dbOf(_tp);
  }
}

/// Lee un archivo f32le estéreo intercalado por trozos.
/// Cada trozo tiene un número par de muestras (frames enteros).
Stream<Float32List> readF32leStereo(String path) async* {
  final chunker = F32leChunker();
  double? odd;
  await for (final b in File(path).openRead()) {
    var x = chunker.add(b);
    if (odd != null) x = Float32List.fromList([odd, ...x]);
    odd = x.length.isOdd ? x.last : null;
    final even = x.length.isOdd ? Float32List.sublistView(x, 0, x.length - 1) : x;
    if (even.isNotEmpty) yield even;
  }
}

/// Copia un archivo f32le de [channels] canales a [srcRate] en estéreo
/// 44.1 kHz, por trozos. Devuelve los frames escritos.
Future<int> convertF32leToMixPcm(String inPath, String outPath, {required int srcRate, required int channels}) async {
  const dst = 44100;
  final rs = StereoStreamResampler(srcRate, dst);
  final sink = File(outPath).openWrite();
  final chunker = F32leChunker();
  var frames = 0;
  var carry = Float32List(0);
  try {
    await for (final b in File(inPath).openRead()) {
      var x = chunker.add(b);
      if (carry.isNotEmpty) {
        x = Float32List.fromList([...carry, ...x]);
      }
      final usable = x.length - x.length % channels;
      carry = Float32List.fromList(Float32List.sublistView(x, usable));
      final y = rs.process(toStereoInterleaved(Float32List.sublistView(x, 0, usable), channels));
      frames += y.length ~/ 2;
      sink.add(float32ToLeBytes(y));
    }
    final y = rs.flush();
    frames += y.length ~/ 2;
    sink.add(float32ToLeBytes(y));
  } finally {
    await sink.close();
  }
  return frames;
}
