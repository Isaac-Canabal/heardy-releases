// Tipos de valor del motor del Mix DJ: datos planos de entrada y salida, para
// poder pasarlos a otro isolate. Sin rutas ni código de plataforma.
import 'dart:typed_data';

import 'mix_analysis.dart';
import 'mix_dsp.dart' show MixBandSplit;
import 'mix_mastering.dart';

/// Frecuencia de muestreo que exige el motor (la de los stems de separación).
const kMixSampleRate = 44100;

/// PCM estéreo float32 intercalado (L, R, L, R...).
class StereoPcm {
  StereoPcm(this.interleaved, {this.sampleRate = kMixSampleRate}) {
    if (interleaved.length.isOdd) {
      throw ArgumentError('PCM estéreo intercalado con longitud impar');
    }
  }

  factory StereoPcm.fromPlanar(Float32List l, Float32List r, {int sampleRate = kMixSampleRate}) {
    if (l.length != r.length) throw ArgumentError('canales de distinta longitud');
    final x = Float32List(2 * l.length);
    for (var i = 0; i < l.length; i++) {
      x[2 * i] = l[i];
      x[2 * i + 1] = r[i];
    }
    return StereoPcm(x, sampleRate: sampleRate);
  }

  final Float32List interleaved;
  final int sampleRate;

  int get frames => interleaved.length ~/ 2;
  double get seconds => frames / sampleRate;

  (Float32List, Float32List) planar() {
    final n = frames;
    final l = Float32List(n), r = Float32List(n);
    for (var i = 0; i < n; i++) {
      l[i] = interleaved[2 * i];
      r[i] = interleaved[2 * i + 1];
    }
    return (l, r);
  }
}

/// Una canción ya separada: la mezcla y sus dos stems.
class MixSongInput {
  MixSongInput({
    required this.name,
    required this.mix,
    required this.vocals,
    required this.instrumental,
    this.analysis,
  }) {
    for (final p in [mix, vocals, instrumental]) {
      if (p.sampleRate != kMixSampleRate) {
        throw ArgumentError('el motor del mix espera $kMixSampleRate Hz, no ${p.sampleRate}');
      }
    }
  }

  final String name;
  final StereoPcm mix;
  final StereoPcm vocals;
  final StereoPcm instrumental;

  /// Análisis previo (p. ej. de una caché); si falta, el motor lo calcula.
  final SongAnalysis? analysis;
}

enum MixMode {
  /// La base sale de la regla de rejilla; la otra aporta voces y secciones.
  automatic,

  /// Voces de A sobre la música de B (B es la base).
  vocalsAOverMusicB,

  /// Voces de B sobre la música de A (A es la base).
  vocalsBOverMusicA,
}

/// Capa de una canción que suena en un tramo.
enum MixLayer { mix, vocals, instrumental }

class MixOptions {
  const MixOptions({
    this.targetDurationSec = 225,
    this.maxStretch = 0.08,
    this.maxSharedStretch = 0.16,
    this.minKeyScore = 0.6,
    this.master = const MasterSettings(),
    this.bandSplit = MixBandSplit.linkwitzRiley4,
  });

  /// Opciones que reproducen render3 del spike tal cual (sin recorte).
  static const spikeRender3 = MixOptions(targetDurationSec: null, bandSplit: MixBandSplit.legacy);

  /// Duración buscada: una base más larga pierde frases enteras del cuerpo
  /// hasta acercarse a ella (la referencia dura 3:45). `null` no recorta.
  final double? targetDurationSec;

  /// Estiramiento máximo de la canción que no es base (0.08 = 8 %) para que la
  /// base siga a su tempo nativo, como en la referencia.
  final double maxStretch;

  /// Si la diferencia pasa de [maxStretch], las dos canciones se acercan a un
  /// tempo común (media geométrica) y cada una puede cambiar de velocidad hasta
  /// este tope (0.16 = ±16 %, hasta un 34 % de diferencia entre las dos). La
  /// medida con pulsos sintéticos (mix_stretch_quality_test) no muestra más
  /// error de rejilla ni más transitorios duplicados entre ±6 % y ±25 %; solo
  /// una pérdida suave de nitidez (0.90 a ±25 %), así que el tope es de gusto.
  final double maxSharedStretch;

  /// Confianza mínima (r) de ambas tonalidades para plantear transponer.
  final double minKeyScore;
  final MasterSettings master;

  /// Reparto grave/agudo de los cortes; [MixBandSplit.legacy] solo reproduce render3.
  final MixBandSplit bandSplit;
}

/// Un tramo del plan, ya colocado en la salida.
class MixSection {
  const MixSection({
    required this.song,
    required this.layer,
    required this.sourceBar,
    required this.outBar,
    required this.bars,
    required this.gainDb,
    required this.leadInBars,
    required this.toEnd,
    required this.startSec,
  });

  /// 'a' o 'b'.
  final String song;
  final MixLayer layer;
  final int sourceBar;
  final int outBar;
  final int bars;
  final double gainDb;
  final double leadInBars;
  final bool toEnd;
  final double startSec;

  Map<String, dynamic> toJson() => {
        'song': song,
        'layer': layer.name,
        'sourceBar': sourceBar,
        'outBar': outBar,
        'bars': bars,
        'gainDb': gainDb,
        'leadInBars': leadInBars,
        'toEnd': toEnd,
        'startSec': startSec,
      };
}

/// Informe del render.
class MixReport {
  const MixReport({
    required this.mode,
    required this.baseSong,
    required this.baseReason,
    required this.tempoBpm,
    required this.stretchPercent,
    this.stretchPercentBase = 0,
    required this.semitones,
    required this.keysTrusted,
    required this.camelotA,
    required this.camelotB,
    required this.residualMsA,
    required this.residualMsB,
    required this.sections,
    required this.cutsSec,
    required this.droppedBaseBars,
    required this.makeupDb,
    required this.limiterMaxDb,
    required this.limiterMeanDb,
    required this.limiterPercent,
    required this.lufs,
    required this.truePeakDb,
    required this.durationSec,
    required this.gapsSec,
  });

  final MixMode mode;

  /// 'a' o 'b'.
  final String baseSong;
  final String baseReason;

  /// Tempo del plan (el común a las dos canciones) en unidades del plan
  /// (compás doble a medio tiempo). Es el nativo de la base salvo que se haya
  /// repartido el estiramiento ([stretchPercentBase] distinto de 0).
  final double tempoBpm;

  /// Estiramiento aplicado a la otra canción.
  final double stretchPercent;

  /// Estiramiento aplicado a la base (0 si suena a su tempo nativo).
  final double stretchPercentBase;

  /// Transposición de la otra canción (0 salvo tonalidades fiables e incompatibles).
  final int semitones;
  final bool keysTrusted;
  final String camelotA, camelotB;
  final double residualMsA, residualMsB;
  final List<MixSection> sections;

  /// Cortes entre canciones o capas, en segundos de la salida.
  final List<double> cutsSec;

  /// Compases de la base (originales) quitados por la duración objetivo.
  final List<int> droppedBaseBars;
  final double makeupDb, limiterMaxDb, limiterMeanDb, limiterPercent;
  final double lufs, truePeakDb, durationSec;

  /// Huecos (ventanas de 50 ms < -40 dBFS) antes de los últimos 5 s: (inicio, fin).
  final List<(double, double)> gapsSec;
}

class MixResult {
  const MixResult(this.pcm, this.report);
  final StereoPcm pcm;
  final MixReport report;
}

/// El par no se puede mezclar con estas reglas (p. ej. tempos muy lejos).
class MixRejected implements Exception {
  const MixRejected(this.reason, {this.tempo = false});
  final String reason;

  /// El motivo es que los tempos quedan demasiado lejos incluso repartiendo el estiramiento.
  final bool tempo;
  @override
  String toString() => 'MixRejected: $reason';
}

class MixCancelled implements Exception {
  const MixCancelled();
  @override
  String toString() => 'MixCancelled';
}

/// Cancelación cooperativa: el motor la consulta entre etapas y dentro de los
/// bucles largos.
class MixCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

enum MixStage { analysis, measure, planning, rendering, mastering, done }

class MixProgress {
  const MixProgress(this.stage, this.fraction);
  final MixStage stage;

  /// Avance total, 0..1, no decreciente.
  final double fraction;
}

typedef MixProgressCallback = void Function(MixProgress progress);
