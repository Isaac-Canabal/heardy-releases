// Servicios reales de Heardy Mixer para este dispositivo. Todo vive en
// almacenamiento privado de la app: modelos y stems en el soporte de la app,
// temporales de trabajo y canciones buscadas en la carpeta temporal.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../windows_waveform_source.dart' show locateBundledFfmpeg;
import '../mix_source_cache.dart';
import 'device_memory.dart';
import 'mix_codec.dart';
import 'mix_job_runner.dart';
import 'mix_models.dart';
import 'sherpa_separation.dart';
import 'stem_cache.dart';

typedef MixJobStarter = MixJob Function(MixJobRequest request);

class HeardyMixerServices {
  HeardyMixerServices({
    required this.models,
    required this.startJob,
    required this.mixesDirectory,
    required this.sourceCache,
    required this.platform,
    required this.totalMemoryBytes,
    this.startAnalyze,
    this.startEditRender,
  });
  final MixModelManager models;
  final MixJobStarter startJob;

  /// Las dos fases del editor avanzado; `null` desactiva el editor.
  final MixAnalyzeStarter? startAnalyze;
  final MixEditRenderStarter? startEditRender;

  /// Almacenamiento privado donde quedan los .m4a de los mixes.
  final String mixesDirectory;
  final MixSourceCache sourceCache;

  /// `null`: el Mixer no está disponible aquí.
  final MixPlatform? platform;
  final int? totalMemoryBytes;
}

/// `null` si esta plataforma o este build no traen lo necesario (bibliotecas
/// de sherpa-onnx, o el ffmpeg empaquetado en Windows).
Future<HeardyMixerServices?> createHeardyMixerServices() async {
  final platform = currentMixPlatform();
  final libs = SherpaLibraries.forCurrentPlatform();
  if (platform == null || libs == null || !libs.isAvailable()) return null;
  if (platform == MixPlatform.windows && locateBundledFfmpeg() == null) return null;

  final support = await getApplicationSupportDirectory();
  final temp = await getTemporaryDirectory();
  final root = p.join(support.path, 'mix');
  final models = MixModelManager(rootPath: root);
  final MixAudioCodec codec = platform == MixPlatform.android ? AndroidMediaCodecMixCodec() : WindowsFfmpegMixCodec();
  final runner = MixJobRunner(
    codec: codec,
    separator: SherpaStemSeparator(libraries: libs),
    models: models.installedFiles,
    cache: StemCache(p.join(root, 'stems')),
    workRoot: p.join(temp.path, 'mix_work'),
  );
  final mixes = Directory(p.join(support.path, 'mixes'));
  await mixes.create(recursive: true);
  return HeardyMixerServices(
    models: models,
    startJob: runner.start,
    startAnalyze: runner.startAnalyze,
    startEditRender: runner.startEditRender,
    mixesDirectory: mixes.path,
    sourceCache: MixSourceCache(p.join(temp.path, 'mix_sources')),
    platform: platform,
    totalMemoryBytes: await totalDeviceMemoryBytes(),
  );
}
