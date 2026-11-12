// Servicio real de transiciones para este dispositivo: todo en almacenamiento
// privado (clips y perfiles en el soporte de la app, decodificaciones en la
// carpeta temporal). `null` si la plataforma no puede decodificar.
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../mix/platform/mix_models.dart' show MixPlatform;
import '../../mix/platform/device_memory.dart';
import '../../mix/platform/mix_codec.dart';
import '../../windows_waveform_source.dart' show locateBundledFfmpeg;
import 'transition_clip_cache.dart';
import 'transition_job_runner.dart';
import 'transition_profile.dart';
import 'transition_windows.dart';

Future<TransitionService?> createTransitionService() async {
  final platform = currentMixPlatform();
  if (platform == null) return null;
  if (platform == MixPlatform.windows && locateBundledFfmpeg() == null) return null;
  final support = await getApplicationSupportDirectory();
  final temp = await getTemporaryDirectory();
  final MixAudioCodec codec = platform == MixPlatform.android ? AndroidMediaCodecMixCodec() : WindowsFfmpegMixCodec();
  return TransitionEngine(
    decoder: CodecTransitionSongDecoder(codec, p.join(temp.path, 'transition_work')),
    backend: IsolateTransitionBackend(),
    clipCache: TransitionClipCache(p.join(support.path, 'transition_clips')),
    profileCache: TransitionProfileCache(p.join(support.path, 'transition_profiles')),
  );
}
