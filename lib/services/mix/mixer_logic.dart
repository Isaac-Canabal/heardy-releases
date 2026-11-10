// Lógica pura de la pantalla de Heardy Mixer: qué calidades se ofrecen en este
// dispositivo y cuánto tardarían, cómo se agrupan las etapas del trabajo y qué
// tipo de fallo ve el usuario (nunca el texto de la excepción).
import 'package:audio_service/audio_service.dart';

import '../../models/mix_record.dart';
import '../download_source.dart';
import 'mix_naming.dart';
import 'mix_types.dart';
import 'platform/mix_codec.dart';
import 'platform/mix_job_runner.dart';
import 'platform/mix_models.dart';
import 'platform/sherpa_separation.dart';

enum MixerUiStage { preparing, separating, analyzing, mixing, encoding }

enum MixerErrorKind {
  modelMissing,
  notEnoughMemory,
  decodeFailed,
  encodeFailed,
  separationFailed,
  incompatible,
  tempoTooFar,
  sourceUnavailable,
  cancelled,
  unknown,
}

class MixerQualityOption {
  const MixerQualityOption(this.mode, {required this.fit, required this.estimate});
  final MixQualityMode mode;

  /// Recomendado o arriesgado para la memoria de este dispositivo. Un modo
  /// arriesgado se puede elegir, pero tras un aviso.
  final MixQualityFit fit;

  bool get recommended => fit == MixQualityFit.recommended;
  bool get risky => fit == MixQualityFit.risky;

  /// Siempre una estimación (ver [estimatedTimePerAudioMinute]).
  final Duration estimate;
}

/// Análisis, render y codificación, aparte de la separación (spike T13: unos
/// 3 s por canción de análisis y 3 s de render en el portátil).
const _fixedWork = Duration(seconds: 10);

/// Las tres calidades, en orden, marcando las arriesgadas para esta memoria. [audioSeconds] es
/// la duración sumada de las dos canciones (las dos se separan).
List<MixerQualityOption> mixerQualityOptions({
  required int? totalMemoryBytes,
  required MixPlatform platform,
  required int audioSeconds,
}) {
  final seconds = audioSeconds > 0 ? audioSeconds : 480;
  final slowdown = platform == MixPlatform.android ? kMixAndroidSlowdown : 1.0;
  return [
    for (final m in MixQualityMode.values)
      MixerQualityOption(
        m,
        fit: qualityFit(m, totalMemoryBytes, platform),
        estimate: Duration(
          milliseconds: (estimatedTimePerAudioMinute(m, platform).perMinute.inMilliseconds * seconds / 60 +
                  _fixedWork.inMilliseconds * slowdown)
              .round(),
        ),
      ),
  ];
}

/// Alta calidad si es recomendada (Máxima tarda varias veces más), si no
/// Rápido. Nunca devuelve Alta ni Máxima si son arriesgadas.
MixQualityMode bestDefaultQuality(List<MixerQualityOption> options) {
  final ok = {for (final o in options) if (o.recommended) o.mode};
  return ok.contains(MixQualityMode.high) ? MixQualityMode.high : MixQualityMode.fast;
}

MixerUiStage mixerUiStage(MixJobStage stage) => switch (stage) {
      MixJobStage.decoding => MixerUiStage.preparing,
      MixJobStage.separating => MixerUiStage.separating,
      MixJobStage.analyzing => MixerUiStage.analyzing,
      MixJobStage.rendering => MixerUiStage.mixing,
      MixJobStage.encoding || MixJobStage.checkingPeak || MixJobStage.done => MixerUiStage.encoding,
    };

/// [stage] es la última etapa vista: un fallo del códec antes de codificar es
/// de lectura de la canción, después es de escritura del mix.
MixerErrorKind classifyMixError(Object error, {MixerUiStage? stage}) => switch (error) {
      MixCancelled() => MixerErrorKind.cancelled,
      MixModelNotInstalled() => MixerErrorKind.modelMissing,
      OutOfMemoryError() => MixerErrorKind.notEnoughMemory,
      MixSeparationFailed() => MixerErrorKind.separationFailed,
      MixRejected(tempo: true) => MixerErrorKind.tempoTooFar,
      MixRejected() => MixerErrorKind.incompatible,
      MixCodecException() =>
        stage == MixerUiStage.encoding ? MixerErrorKind.encodeFailed : MixerErrorKind.decodeFailed,
      DownloadSourceException() => MixerErrorKind.sourceUnavailable,
      _ => MixerErrorKind.unknown,
    };

/// Entrada de cola para escuchar un mix sin guardarlo: `isStream` lo deja
/// fuera de `play_history`, de la restauración y del ecualizador por ruta, y
/// sin `videoId` Reproduciendo no ofrece descargarlo.
MediaItem mixMediaItem(MixRecord r) => MediaItem(
      id: 'mix:${r.id}',
      title: r.name,
      artist: combinedMixArtist(r.artistA, r.artistB),
      album: 'Heardy Mixer',
      duration: r.durationMs > 0 ? Duration(milliseconds: r.durationMs) : null,
      artUri: r.artPath.isNotEmpty ? Uri.file(r.artPath) : null,
      extras: {
        'isStream': true,
        'isMix': true,
        'mixId': r.id,
        'filePath': '',
        'artPath': r.artPath,
      },
    );
