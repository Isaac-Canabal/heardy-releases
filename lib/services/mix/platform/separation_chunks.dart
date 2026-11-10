// Troceo de la separación: sherpa-onnx procesa toda la entrada de una vez y la
// RAM crece con la duración (3.3 GB con una canción entera en el spike), así que
// se separa por trozos de 15 s con 1 s de solape y fundido lineal, como en
// tool/mix_spike/bin/separate.dart, y se escribe cada trozo según sale.
import 'dart:typed_data';

const kSeparationChunkFrames = 15 * 44100;
const kSeparationOverlapFrames = 44100;

/// Un trozo a separar: frames [readStart, readEnd) de la entrada. Los primeros
/// [fadeFrames] se funden con la cola del trozo anterior.
class SeparationChunk {
  const SeparationChunk(this.readStart, this.readEnd, this.fadeFrames);
  final int readStart, readEnd, fadeFrames;
  int get frames => readEnd - readStart;
}

List<SeparationChunk> planSeparationChunks(int totalFrames, {required int chunkFrames, required int overlapFrames}) {
  if (overlapFrames < 0 || chunkFrames <= overlapFrames) {
    throw ArgumentError('trozo ($chunkFrames) debe ser mayor que el solape ($overlapFrames)');
  }
  final out = <SeparationChunk>[];
  for (var start = 0; start < totalFrames; start += chunkFrames) {
    final s0 = start == 0 ? 0 : start - overlapFrames;
    final e0 = start + chunkFrames < totalFrames ? start + chunkFrames : totalFrames;
    out.add(SeparationChunk(s0, e0, start == 0 ? 0 : overlapFrames));
  }
  return out;
}

/// Cose la salida estéreo intercalada de cada trozo: guarda la cola (el solape)
/// hasta ver el trozo siguiente y la funde con su comienzo. Devuelve lo que ya
/// se puede escribir; [finish] entrega la última cola.
class ChunkStitcher {
  ChunkStitcher({required this.stems, required this.overlapFrames})
      : _tails = List.generate(stems, (_) => Float32List(0));

  final int stems, overlapFrames;
  final List<Float32List> _tails;

  List<Float32List> add(SeparationChunk chunk, List<Float32List> stemOutputs) {
    if (stemOutputs.length != stems) throw ArgumentError('se esperaban $stems stems');
    final n = chunk.frames;
    final hold = n < overlapFrames ? n : overlapFrames;
    final out = <Float32List>[];
    for (var s = 0; s < stems; s++) {
      // Longitud fija: lo que falte es silencio y lo que sobre se descarta.
      final y = Float32List(2 * n);
      final src = stemOutputs[s];
      y.setRange(0, src.length < y.length ? src.length : y.length, src);
      final tail = _tails[s];
      final fade = chunk.fadeFrames < tail.length ~/ 2 ? chunk.fadeFrames : tail.length ~/ 2;
      for (var i = 0; i < fade; i++) {
        final w = i / chunk.fadeFrames;
        y[2 * i] = tail[2 * i] * (1 - w) + y[2 * i] * w;
        y[2 * i + 1] = tail[2 * i + 1] * (1 - w) + y[2 * i + 1] * w;
      }
      out.add(Float32List.fromList(Float32List.sublistView(y, 0, 2 * (n - hold))));
      _tails[s] = Float32List.fromList(Float32List.sublistView(y, 2 * (n - hold)));
    }
    return out;
  }

  List<Float32List> finish() {
    final out = [for (final t in _tails) t];
    for (var s = 0; s < stems; s++) {
      _tails[s] = Float32List(0);
    }
    return out;
  }
}
