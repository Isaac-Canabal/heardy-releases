// Modelos de separación del Mix DJ: catálogo fijado por SHA-256, modos de
// calidad según la memoria del dispositivo y descarga bajo petición explícita
// del usuario a almacenamiento privado de la app. El checksum.txt del release
// oficial está desactualizado (los .tar.bz2 se resubieron después), así que
// los hashes son los medidos sobre los archivos descargados en el spike T13.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../device_range_downloader.dart' show parseContentRange;
import '../mix_types.dart';
import 'bzip2_tar.dart';

/// Rápido = Spleeter fp16, Alta calidad = UVR MDX 9482, Máxima = UVR MDX Voc_FT.
enum MixQualityMode { fast, high, max }

enum MixPlatform { android, windows }

class MixModelFile {
  const MixModelFile(this.name, this.sha256, this.bytes);
  final String name, sha256;
  final int bytes;
}

class MixModelSpec {
  const MixModelSpec({
    required this.mode,
    required this.id,
    required this.url,
    required this.sha256,
    required this.downloadBytes,
    required this.archive,
    required this.files,
  });
  final MixQualityMode mode;
  final String id;
  final Uri url;

  /// SHA-256 de lo que se descarga (el .tar.bz2 o el .onnx).
  final String sha256;
  final int downloadBytes;

  /// `true`: .tar.bz2 del que solo se extraen [files]; `false`: un .onnx suelto.
  final bool archive;
  final List<MixModelFile> files;

  int get installedBytes => files.fold(0, (n, f) => n + f.bytes);

  /// UVR (MDX-Net) usa un solo modelo; Spleeter, uno de voz y otro de acompañamiento.
  bool get isUvr => !archive;
}

const _release = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models';

final Map<MixQualityMode, MixModelSpec> kMixModelSpecs = {
  MixQualityMode.fast: MixModelSpec(
    mode: MixQualityMode.fast,
    id: 'spleeter-2stems-fp16',
    url: Uri.parse('$_release/sherpa-onnx-spleeter-2stems-fp16.tar.bz2'),
    sha256: 'd54561979bd2e08a51e7dbd99ac36bb47564e089eefd403636dbca93e811bba2',
    downloadBytes: 35271738,
    archive: true,
    files: const [
      MixModelFile('vocals.fp16.onnx', '24cef84aedcd1fe87c0b743ef3370ad34dc1fabf6c9014d6128a75a538c7b668', 19681017),
      MixModelFile(
          'accompaniment.fp16.onnx', 'd14cea55793cc531a5875f5f4da08207d1c5ab9292e8e0099a104eecb014fcc0', 19681024),
    ],
  ),
  MixQualityMode.high: MixModelSpec(
    mode: MixQualityMode.high,
    id: 'uvr-mdx-9482',
    url: Uri.parse('$_release/UVR_MDXNET_9482.onnx'),
    sha256: '9d78f8566fa8198065214ab628be1de966a500c57786695aa4b13e2b27a7727d',
    downloadBytes: 29704738,
    archive: false,
    files: const [
      MixModelFile('UVR_MDXNET_9482.onnx', '9d78f8566fa8198065214ab628be1de966a500c57786695aa4b13e2b27a7727d', 29704738),
    ],
  ),
  MixQualityMode.max: MixModelSpec(
    mode: MixQualityMode.max,
    id: 'uvr-mdx-voc-ft',
    url: Uri.parse('$_release/UVR-MDX-NET-Voc_FT.onnx'),
    sha256: 'e411182ce2c53541fefdcc99a8f46f2fe03978eb22038b9497c1d9d95a00fad4',
    downloadBytes: 66762795,
    archive: false,
    files: const [
      MixModelFile('UVR-MDX-NET-Voc_FT.onnx', 'e411182ce2c53541fefdcc99a8f46f2fe03978eb22038b9497c1d9d95a00fad4', 66762795),
    ],
  ),
};

const _gib = 1024 * 1024 * 1024;

/// Pico de RAM previsto por modo (spike T13, 4 hilos, trozos de 15 s): la
/// separación (Spleeter 0.9 GB, 9482 3.6 GB, Voc_FT 6.9-7.0 GB; UVR no baja al
/// trocear) y el render, que va después y llega a ~1.3 GB. Cuenta el mayor.
const Map<MixQualityMode, double> kMixPeakMemoryGib = {
  MixQualityMode.fast: 1.3,
  MixQualityMode.high: 3.6,
  MixQualityMode.max: 7.0,
};

/// Parte de la RAM total que el Mix puede ocupar sin que el sistema mate la
/// app: Android reserva mucho para el sistema y el low-memory killer actúa
/// antes de agotar la memoria; en escritorio hay archivo de paginación pero
/// también otras aplicaciones abiertas.
const Map<MixPlatform, double> kMixMemoryFraction = {
  MixPlatform.android: 0.4,
  MixPlatform.windows: 0.6,
};

/// Qué tan bien le sienta un modo a la memoria del dispositivo. Un modo
/// arriesgado se puede elegir (con aviso), pero nunca es el de por defecto.
enum MixQualityFit { recommended, risky }

/// Si [mode] cabe en el presupuesto de memoria de [totalMemoryBytes]. Sin el
/// dato (no se pudo leer) solo Rápido es recomendado.
MixQualityFit qualityFit(MixQualityMode mode, int? totalMemoryBytes, MixPlatform platform) {
  if (totalMemoryBytes == null || totalMemoryBytes <= 0) {
    return mode == MixQualityMode.fast ? MixQualityFit.recommended : MixQualityFit.risky;
  }
  final budget = totalMemoryBytes * kMixMemoryFraction[platform]!;
  return kMixPeakMemoryGib[mode]! * _gib <= budget ? MixQualityFit.recommended : MixQualityFit.risky;
}

/// Modos recomendados para [totalMemoryBytes] (RAM total del dispositivo); los
/// demás se siguen ofreciendo como arriesgados (ver [qualityFit]). Sin el dato
/// solo se recomienda Rápido, el de menos memoria.
List<MixQualityMode> availableQualityModes(int? totalMemoryBytes, MixPlatform platform) => [
      for (final m in MixQualityMode.values)
        if (qualityFit(m, totalMemoryBytes, platform) == MixQualityFit.recommended) m,
    ];

/// Estimación (no medida en el dispositivo del usuario) del tiempo de
/// separación por minuto de audio.
class MixTimeEstimate {
  const MixTimeEstimate(this.perMinute, {required this.measuredOnPlatform});
  final Duration perMinute;

  /// Si el factor de tiempo real se midió en esta plataforma (Windows, en el
  /// portátil del spike) o es una extrapolación (Android).
  final bool measuredOnPlatform;

  /// Siempre es una estimación: depende del procesador y de la temperatura.
  bool get isEstimate => true;
}

/// RTF (segundos de proceso por segundo de audio) del spike en un i5-13420H,
/// 4 hilos, trozos de 15 s: Spleeter 0.12, 9482 0.77 (solo; 1.26 con otras
/// tareas), Voc_FT 2.24-2.77. Se toma el valor más lento medido sin carga.
const Map<MixQualityMode, double> kMixSpikeRtf = {
  MixQualityMode.fast: 0.12,
  MixQualityMode.high: 0.77,
  MixQualityMode.max: 2.6,
};

/// Factor supuesto para un teléfono de gama media frente a ese portátil. Sin
/// medir: el procedimiento de Android del spike no se corrió en un teléfono.
const kMixAndroidSlowdown = 3.0;

MixTimeEstimate estimatedTimePerAudioMinute(MixQualityMode mode, MixPlatform platform) {
  final rtf = kMixSpikeRtf[mode]! * (platform == MixPlatform.android ? kMixAndroidSlowdown : 1);
  return MixTimeEstimate(Duration(milliseconds: (rtf * 60000).round()),
      measuredOnPlatform: platform == MixPlatform.windows);
}

/// Un modelo instalado: [directory] contiene los [MixModelSpec.files].
class SeparationModelFiles {
  const SeparationModelFiles(this.spec, this.directory);
  final MixModelSpec spec;
  final String directory;
  String path(String name) => '$directory${Platform.pathSeparator}$name';
}

class ModelDownloadResponse {
  const ModelDownloadResponse({required this.resumed, required this.body});

  /// El servidor respetó el rango: [body] empieza en el offset pedido. Si es
  /// `false`, [body] es el archivo entero.
  final bool resumed;
  final Stream<List<int>> body;
}

abstract class ModelDownloader {
  Future<ModelDownloadResponse> open(Uri url, {int offset = 0});
}

class MixModelDownloadFailed implements Exception {
  const MixModelDownloadFailed(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'MixModelDownloadFailed($statusCode)';
}

/// Descarga HTTP con `Range` para reanudar.
class HttpModelDownloader implements ModelDownloader {
  HttpModelDownloader({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  @override
  Future<ModelDownloadResponse> open(Uri url, {int offset = 0}) async {
    final req = http.Request('GET', url);
    if (offset > 0) req.headers['Range'] = 'bytes=$offset-';
    final res = await _client.send(req);
    if (res.statusCode == 206) {
      final range = parseContentRange(res.headers['content-range']);
      if (range == null || range.start != offset) {
        await res.stream.drain<void>();
        throw const MixModelDownloadFailed(206);
      }
      return ModelDownloadResponse(resumed: true, body: res.stream);
    }
    if (res.statusCode == 200) return ModelDownloadResponse(resumed: false, body: res.stream);
    await res.stream.drain<void>();
    throw MixModelDownloadFailed(res.statusCode);
  }
}

enum MixModelPhase { downloading, verifying, extracting }

class MixModelProgress {
  const MixModelProgress(this.phase, this.receivedBytes, this.totalBytes);
  final MixModelPhase phase;
  final int receivedBytes, totalBytes;
  double get fraction => totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

class MixModelChecksumMismatch implements Exception {
  const MixModelChecksumMismatch(this.what);
  final String what;
  @override
  String toString() => 'MixModelChecksumMismatch($what)';
}

class MixModelNotInstalled implements Exception {
  const MixModelNotInstalled(this.mode);
  final MixQualityMode mode;
  @override
  String toString() => 'MixModelNotInstalled(${mode.name})';
}

Future<String> _sha256OfFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

/// Descarga, verifica, instala y borra los modelos en `<rootPath>/models`.
class MixModelManager {
  MixModelManager({required this.rootPath, ModelDownloader? downloader, Map<MixQualityMode, MixModelSpec>? specs})
      : _downloader = downloader ?? HttpModelDownloader(),
        _specs = specs ?? kMixModelSpecs;

  final String rootPath;
  final ModelDownloader _downloader;
  final Map<MixQualityMode, MixModelSpec> _specs;

  MixModelSpec spec(MixQualityMode mode) => _specs[mode]!;
  String get _dir => '$rootPath${Platform.pathSeparator}models';
  String _modelDir(MixModelSpec s) => '$_dir${Platform.pathSeparator}${s.id}';

  /// Lo que hay que descargar (para avisar antes de empezar).
  int downloadSizeBytes(MixQualityMode mode) => spec(mode).downloadBytes;

  /// Lo que ocupa una vez instalado.
  int installedSizeBytes(MixQualityMode mode) => spec(mode).installedBytes;

  String partialPathFor(MixQualityMode mode) => '$_dir${Platform.pathSeparator}${spec(mode).id}.part';

  Future<bool> isInstalled(MixQualityMode mode) async {
    final s = spec(mode);
    for (final f in s.files) {
      final file = File('${_modelDir(s)}${Platform.pathSeparator}${f.name}');
      if (!await file.exists() || await file.length() != f.bytes) return false;
    }
    return true;
  }

  Future<SeparationModelFiles> installedFiles(MixQualityMode mode) async {
    if (!await isInstalled(mode)) throw MixModelNotInstalled(mode);
    return SeparationModelFiles(spec(mode), _modelDir(spec(mode)));
  }

  /// Descarga (o reanuda) y verifica el modelo. Un corte o una cancelación
  /// conservan el parcial para reanudarlo; un hash distinto lo borra.
  Future<SeparationModelFiles> install(MixQualityMode mode,
      {void Function(MixModelProgress)? onProgress, MixCancelToken? cancel}) async {
    final s = spec(mode);
    if (await isInstalled(mode)) return SeparationModelFiles(s, _modelDir(s));
    await Directory(_dir).create(recursive: true);
    final part = File(partialPathFor(mode));
    var have = await part.exists() ? await part.length() : 0;
    if (have > s.downloadBytes) {
      await part.delete();
      have = 0;
    }
    if (have < s.downloadBytes) await _download(s, part, have, onProgress, cancel);

    onProgress?.call(MixModelProgress(MixModelPhase.verifying, s.downloadBytes, s.downloadBytes));
    if (cancel?.isCancelled ?? false) throw const MixCancelled();
    if (await _sha256OfFile(part.path) != s.sha256) {
      await part.delete();
      throw MixModelChecksumMismatch(s.url.pathSegments.last);
    }

    final staging = Directory('${_modelDir(s)}.staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      if (s.archive) {
        onProgress?.call(MixModelProgress(MixModelPhase.extracting, 0, s.installedBytes));
        final names = {for (final f in s.files) f.name};
        final archivePath = part.path, dest = staging.path;
        await Isolate.run(() => extractTarBz2Allowlist(archivePath, dest, names));
      } else {
        await part.rename('${staging.path}${Platform.pathSeparator}${s.files.single.name}');
      }
      for (final f in s.files) {
        final p = '${staging.path}${Platform.pathSeparator}${f.name}';
        if (await File(p).length() != f.bytes || await _sha256OfFile(p) != f.sha256) {
          throw MixModelChecksumMismatch(f.name);
        }
      }
      final target = Directory(_modelDir(s));
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await part.exists()) await part.delete();
      rethrow;
    }
    if (await part.exists()) await part.delete();
    return SeparationModelFiles(s, _modelDir(s));
  }

  Future<void> _download(MixModelSpec s, File part, int have, void Function(MixModelProgress)? onProgress,
      MixCancelToken? cancel) async {
    final res = await _downloader.open(s.url, offset: have);
    var received = res.resumed ? have : 0;
    final sink = part.openWrite(mode: res.resumed ? FileMode.append : FileMode.write);
    try {
      onProgress?.call(MixModelProgress(MixModelPhase.downloading, received, s.downloadBytes));
      await for (final chunk in res.body) {
        received += chunk.length;
        if (received > s.downloadBytes) throw const MixModelChecksumMismatch('tamaño');
        sink.add(chunk);
        onProgress?.call(MixModelProgress(MixModelPhase.downloading, received, s.downloadBytes));
        if (cancel?.isCancelled ?? false) throw const MixCancelled();
      }
    } on MixModelChecksumMismatch {
      await sink.close();
      await part.delete();
      rethrow;
    } finally {
      await sink.close();
    }
    if (received < s.downloadBytes) throw const SocketException('descarga incompleta');
  }

  /// Borra el modelo instalado y cualquier parcial.
  Future<void> delete(MixQualityMode mode) async {
    final s = spec(mode);
    for (final p in [_modelDir(s), '${_modelDir(s)}.staging']) {
      final d = Directory(p);
      if (await d.exists()) await d.delete(recursive: true);
    }
    final part = File(partialPathFor(mode));
    if (await part.exists()) await part.delete();
  }
}
