// Envolventes por compás para dibujar las ondas del editor del Mix DJ. Datos
// planos (listas de doubles 0..1), pequeños y enviables fuera del isolate: una
// canción de 5 minutos a 8 puntos por compás son unas pocas centenas de puntos
// por capa. Todo sigue la rejilla del plan (compases dobles, ya recortada si
// hubo compases quitados), no la de la canción original.
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_song.dart';
import 'mix_types.dart';

/// Puntos por compás de las envolventes (resolución de dibujo, no de audio).
const kEnvelopePointsPerBar = 8;

/// Milésimas: sobra para dibujar y mantiene corto el JSON y el mensaje entre isolates.
double _quantize(double v) => (v.clamp(0.0, 1.0) * 1000).round() / 1000;

/// Pico absoluto (0..1+) de la capa [layer] de [song] en toda su rejilla.
double layerPeak(MixSong song, MixLayer layer) {
  final st = song.stem(layer);
  final end = math.min(st.length, song.barSample(song.bars)), start = math.max(0, song.barSample(0));
  var peak = 0.0;
  for (var i = start; i < end; i++) {
    peak = math.max(peak, math.max(st.l[i].abs(), st.r[i].abs()));
  }
  return peak;
}

/// Pico normalizado (0..1) de cada uno de los `song.bars * pointsPerBar` puntos
/// de la capa [layer]: el punto `b * pointsPerBar + p` cubre desde el compás
/// `b + p / pointsPerBar` hasta el siguiente punto. Se divide por [reference]
/// (por defecto el pico de esta misma capa); con una referencia común las
/// capas conservan sus niveles relativos. Un silencio o una canción sin audio
/// dan ceros, nunca NaN.
List<double> barEnvelope(MixSong song, MixLayer layer, {int pointsPerBar = kEnvelopePointsPerBar, double? reference}) {
  final ppb = math.max(1, pointsPerBar);
  final st = song.stem(layer);
  final ref = reference ?? layerPeak(song, layer);
  final scale = ref > 1e-9 ? 1 / ref : 0.0;
  final out = List<double>.filled(song.bars * ppb, 0);
  for (var k = 0; k < out.length; k++) {
    final a = song.barSample(k / ppb).clamp(0, st.length), b = song.barSample((k + 1) / ppb).clamp(0, st.length);
    var peak = 0.0;
    for (var i = a; i < b; i++) {
      peak = math.max(peak, math.max(st.l[i].abs(), st.r[i].abs()));
    }
    out[k] = _quantize(peak * scale);
  }
  return out;
}

/// Las tres capas de una canción, normalizadas con el mismo pico de referencia
/// (el mayor de las tres) para que la voz y el instrumental se vean a su nivel.
class MixSongEnvelope {
  const MixSongEnvelope({
    required this.song,
    required this.bars,
    required this.pointsPerBar,
    required this.mix,
    required this.vocals,
    required this.instrumental,
  });

  factory MixSongEnvelope.fromSong(MixSong s, {int pointsPerBar = kEnvelopePointsPerBar}) {
    final ref = [for (final l in MixLayer.values) layerPeak(s, l)].reduce(math.max);
    List<double> env(MixLayer l) => barEnvelope(s, l, pointsPerBar: pointsPerBar, reference: ref);
    return MixSongEnvelope(
      song: s.id,
      bars: s.bars,
      pointsPerBar: math.max(1, pointsPerBar),
      mix: env(MixLayer.mix),
      vocals: env(MixLayer.vocals),
      instrumental: env(MixLayer.instrumental),
    );
  }

  /// 'a' o 'b'.
  final String song;

  /// Compases de la rejilla del plan (los mismos que `MixSongSummary.planBars`
  /// para la base; para la otra, los de la canción entera).
  final int bars;
  final int pointsPerBar;
  final List<double> mix, vocals, instrumental;

  List<double> layer(MixLayer l) => switch (l) {
        MixLayer.mix => mix,
        MixLayer.vocals => vocals,
        MixLayer.instrumental => instrumental,
      };
}

/// Envolventes de las dos canciones, tal como las ve el plan automático.
class MixEnvelopes {
  const MixEnvelopes({required this.a, required this.b});

  factory MixEnvelopes.fromSongs(Map<String, MixSong> songs, {int pointsPerBar = kEnvelopePointsPerBar}) => MixEnvelopes(
        a: MixSongEnvelope.fromSong(songs['a']!, pointsPerBar: pointsPerBar),
        b: MixSongEnvelope.fromSong(songs['b']!, pointsPerBar: pointsPerBar),
      );

  final MixSongEnvelope a, b;

  MixSongEnvelope forSong(String song) => song == 'a' ? a : b;
}

/// Envolvente del resultado ya masterizado ([pcm] estéreo): un punto cada
/// `1 / pointsPerBar` de compás del plan (a [tempoBpm]), empezando en
/// [barZeroSec], el instante de la salida donde arranca el compás 0 del plan
/// (`MixReport.outputBarZeroSec`). Lo anterior a ese instante no se dibuja.
/// Normalizada por el pico del propio resultado (0..1), de modo que llene la
/// vista. El último punto cubre hasta el final del audio.
List<double> outputEnvelope(StereoPcm pcm, {required double tempoBpm, double barZeroSec = 0, int pointsPerBar = kEnvelopePointsPerBar}) {
  final ppb = math.max(1, pointsPerBar);
  if (!tempoBpm.isFinite || tempoBpm <= 0 || pcm.frames == 0) return const [];
  final x = pcm.interleaved;
  final frames = pcm.frames;
  final pointFrames = 240 / tempoBpm * kMixSampleRate / ppb;
  final start = (barZeroSec.isFinite ? barZeroSec : 0.0) * kMixSampleRate;
  final n = ((frames - start) / pointFrames).ceil();
  if (n <= 0) return const [];
  final out = Float32List(n);
  var global = 0.0;
  for (var k = 0; k < n; k++) {
    final a = (start + k * pointFrames).round().clamp(0, frames), b = (start + (k + 1) * pointFrames).round().clamp(0, frames);
    var peak = 0.0;
    for (var i = a; i < b; i++) {
      peak = math.max(peak, math.max(x[2 * i].abs(), x[2 * i + 1].abs()));
    }
    out[k] = peak;
    global = math.max(global, peak);
  }
  final scale = global > 1e-9 ? 1 / global : 0.0;
  return [for (final v in out) _quantize(v * scale)];
}
