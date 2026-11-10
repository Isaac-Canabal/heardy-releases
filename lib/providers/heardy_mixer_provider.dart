import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/mix_record.dart';
import '../models/song.dart';
import '../services/cover_art.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/mix/mix_cover.dart';
import '../services/mix/mix_naming.dart';
import '../services/mix/mix_types.dart';
import '../services/mix/mixer_logic.dart';
import '../services/mix/platform/mix_job_runner.dart';
import '../services/mix/platform/mix_models.dart';
import '../services/mix/platform/mixer_environment.dart';
import '../theme/app_theme.dart';

export '../services/mix/platform/mixer_environment.dart' show HeardyMixerServices, MixJobStarter;

enum MixerSlotId { a, b }

/// Una de las dos canciones: de la biblioteca o de una búsqueda ya resuelta.
class MixerSlot {
  const MixerSlot.library(Song this.song) : track = null;
  const MixerSlot.remote(RemoteTrack this.track) : song = null;
  final Song? song;
  final RemoteTrack? track;

  bool get isRemote => track != null;
  String get title => song?.title ?? track!.title;
  String get artist => song?.artist ?? track!.artist;
  int get durationSeconds => song?.duration ?? track!.durationSeconds;

  /// Carátula local de la biblioteca ('' si no hay o es remota).
  String get artPath => song?.artPath ?? '';
  String get thumbnailUrl => track?.thumbnailUrl ?? '';

  /// Clave de la caché de stems: el hash del audio, o el id de vídeo.
  String get stemKey => song?.id ?? 'yt:${track!.id}';
}

abstract class MixRecordStore {
  Future<void> insert(MixRecord record);
  Future<void> rename(String id, String name);
}

class DatabaseMixRecordStore implements MixRecordStore {
  DatabaseMixRecordStore([DatabaseHelper? db]) : _db = db ?? DatabaseHelper.instance;
  final DatabaseHelper _db;
  @override
  Future<void> insert(MixRecord record) => _db.insertMix(record);
  @override
  Future<void> rename(String id, String name) => _db.renameMix(id, name);
}

/// Hace la carátula del mix y devuelve su ruta ('' = degradado del tema).
typedef MixCoverMaker = Future<String> Function(MixRecord record, MixerSlot a, MixerSlot b);

/// Las dos carátulas fundidas en diagonal ([renderMixCoverFile]). Una canción
/// de la biblioteca usa su carátula local; una buscada, su miniatura, que se
/// baja como ya hace una descarga normal ([fetchCoverArt]). Sin carátula, el
/// degradado del tema de esa mitad.
MixCoverMaker fusedMixCoverMaker({
  http.Client Function()? clientFactory,
  Future<String> Function(String id, Uint8List bytes) save = saveCoverArt,
}) {
  final newClient = clientFactory ?? (() => http.Client());
  Future<Uint8List?> coverOf(MixerSlot slot) async {
    try {
      if (!slot.isRemote) {
        final art = slot.artPath;
        if (art.isEmpty) return null;
        final file = File(art);
        return await file.exists() ? await file.readAsBytes() : null;
      }
      final client = newClient();
      try {
        return await fetchCoverArt(client, slot.thumbnailUrl, slot.track!.id);
      } finally {
        client.close();
      }
    } catch (e) {
      print('Mix: no se pudo leer una carátula (${e.runtimeType})');
      return null;
    }
  }

  return (record, a, b) async => renderMixCoverFile(
        id: record.id,
        coverA: await coverOf(a),
        coverB: await coverOf(b),
        fallbackA: AppTheme.gradientForTitle(a.title),
        fallbackB: AppTheme.gradientForTitle(b.title),
        save: save,
      );
}

Future<String> _noCover(MixRecord record, MixerSlot a, MixerSlot b) async => '';

enum MixerPhase { idle, running, succeeded, failed }

enum MixerModelDownloadState { idle, downloading, failed, cancelled }

/// Estado de Heardy Mixer. Vive en el `MultiProvider` de main.dart para que el
/// trabajo siga y su avance se vea al salir y volver a la pantalla.
class HeardyMixerProvider extends ChangeNotifier {
  HeardyMixerProvider({
    required Future<HeardyMixerServices?> Function() services,
    required DownloadSource source,
    MixRecordStore? store,
    MixCoverMaker? coverMaker,
    DateTime Function()? clock,
    String Function()? newId,
  })  : _servicesLoader = services,
        _source = source,
        _store = store ?? DatabaseMixRecordStore(),
        _coverMaker = coverMaker ?? _noCover,
        _clock = clock ?? DateTime.now,
        _newId = newId ?? (() => const Uuid().v4());

  final Future<HeardyMixerServices?> Function() _servicesLoader;
  final DownloadSource _source;
  final MixRecordStore _store;
  final MixCoverMaker _coverMaker;
  final DateTime Function() _clock;
  final String Function() _newId;

  HeardyMixerServices? _services;
  Future<void>? _loading;
  bool _ready = false;
  bool _disposed = false;

  final Map<MixerSlotId, MixerSlot> _slots = {};
  final Set<MixerSlotId> _resolving = {};
  final Map<MixerSlotId, int> _slotGen = {MixerSlotId.a: 0, MixerSlotId.b: 0};
  MixMode _mode = MixMode.automatic;
  MixQualityMode _quality = MixQualityMode.fast;
  final Set<MixQualityMode> _installed = {};

  MixerModelDownloadState _modelState = MixerModelDownloadState.idle;
  MixModelProgress? _modelProgress;
  MixCancelToken? _modelCancel;
  bool _modelChecksumFailed = false;

  MixerPhase _phase = MixerPhase.idle;
  MixerUiStage? _stage;
  double? _fraction;
  MixerErrorKind? _error;
  MixRecord? _lastRecord;
  MixJob? _job;
  bool _cancelRequested = false;

  bool get ready => _ready;
  bool get supported => _services?.platform != null;

  /// Crea los servicios y lee qué modelos hay. Idempotente.
  Future<void> ensureReady() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _services = await _servicesLoader();
      final s = _services;
      if (s != null && s.platform != null) {
        _quality = bestDefaultQuality(qualityOptions);
        await _refreshInstalled();
      }
    } catch (e) {
      print('Mix: no se pudo preparar Heardy Mixer (${e.runtimeType})');
      _services = null;
    } finally {
      _ready = true;
      _notify();
    }
  }

  Future<void> _refreshInstalled() async {
    final s = _services;
    if (s == null) return;
    for (final m in MixQualityMode.values) {
      if (await s.models.isInstalled(m)) {
        _installed.add(m);
      } else {
        _installed.remove(m);
      }
    }
  }

  bool get _busy => _phase == MixerPhase.running;

  MixerSlot? slot(MixerSlotId id) => _slots[id];
  bool isResolving(MixerSlotId id) => _resolving.contains(id);

  void setLibrarySong(MixerSlotId id, Song song) {
    if (_busy) return;
    _slotGen[id] = _slotGen[id]! + 1;
    _resolving.remove(id);
    _slots[id] = MixerSlot.library(song);
    _clearOutcome();
    _notify();
  }

  /// Un resultado de búsqueda trae el canal como artista y metadata plana:
  /// se vuelve a resolver entero antes de usarlo (CLAUDE.md, Descargas).
  Future<bool> setSearchResult(MixerSlotId id, RemoteTrack listed) async {
    if (_busy) return false;
    final gen = _slotGen[id] = _slotGen[id]! + 1;
    _resolving.add(id);
    _notify();
    try {
      final url = listed.sourceUrl.isNotEmpty ? listed.sourceUrl : 'https://www.youtube.com/watch?v=${listed.id}';
      final resolved = await _source.resolve(url);
      if (_slotGen[id] != gen || _busy) return false;
      _slots[id] = MixerSlot.remote(resolved);
      _clearOutcome();
      return true;
    } catch (e) {
      print('Mix: no se pudo resolver la canción buscada (${e.runtimeType})');
      return false;
    } finally {
      if (_slotGen[id] == gen) _resolving.remove(id);
      _notify();
    }
  }

  final Set<String> _queuedForLibrary = {};

  /// "Descargar también a mi biblioteca" ya encoló este vídeo en la cola normal.
  bool isQueuedForLibrary(String videoId) => _queuedForLibrary.contains(videoId);

  void markQueuedForLibrary(String videoId) {
    if (_queuedForLibrary.add(videoId)) _notify();
  }

  void clearSlot(MixerSlotId id) {
    if (_busy) return;
    _slotGen[id] = _slotGen[id]! + 1;
    _resolving.remove(id);
    _slots.remove(id);
    _notify();
  }

  MixMode get mode => _mode;
  set mode(MixMode m) {
    if (_busy || m == _mode) return;
    _mode = m;
    _notify();
  }

  MixQualityMode get quality => _quality;
  set quality(MixQualityMode q) {
    if (_busy || q == _quality) return;
    if (!qualityOptions.any((o) => o.mode == q)) return;
    _quality = q;
    _modelChecksumFailed = false;
    if (_modelState != MixerModelDownloadState.downloading) _modelState = MixerModelDownloadState.idle;
    _notify();
  }

  /// El modo que el dispositivo aguanta sin riesgo (el de por defecto).
  MixQualityMode get recommendedQuality => bestDefaultQuality(qualityOptions);

  bool isRisky(MixQualityMode q) => qualityOptions.any((o) => o.mode == q && o.risky);

  bool _riskAcknowledged = false;

  /// El usuario ya aceptó el aviso de modo arriesgado en esta sesión.
  bool get riskAcknowledged => _riskAcknowledged;
  void acknowledgeRisk() => _riskAcknowledged = true;

  int get _audioSeconds => _slots.values.fold(0, (n, s) => n + s.durationSeconds);

  List<MixerQualityOption> get qualityOptions {
    final s = _services;
    if (s == null || s.platform == null) return const [];
    return mixerQualityOptions(
      totalMemoryBytes: s.totalMemoryBytes,
      platform: s.platform!,
      audioSeconds: _audioSeconds,
    );
  }

  bool isModelInstalled(MixQualityMode q) => _installed.contains(q);
  int modelDownloadBytes(MixQualityMode q) => kMixModelSpecs[q]!.downloadBytes;

  MixerModelDownloadState get modelDownloadState => _modelState;
  MixModelProgress? get modelProgress => _modelProgress;
  bool get modelChecksumFailed => _modelChecksumFailed;

  /// Baja el modelo de la calidad elegida. Solo se llama tras la confirmación
  /// explícita del usuario; un corte o una cancelación conservan el parcial y
  /// volver a llamar lo reanuda.
  Future<bool> downloadModel() async {
    final s = _services;
    if (s == null || _modelState == MixerModelDownloadState.downloading) return false;
    final mode = _quality;
    final cancel = _modelCancel = MixCancelToken();
    _modelState = MixerModelDownloadState.downloading;
    _modelChecksumFailed = false;
    _modelProgress = null;
    _notify();
    try {
      await s.models.install(mode, cancel: cancel, onProgress: (p) {
        _modelProgress = p;
        _notify();
      });
      _installed.add(mode);
      _modelState = MixerModelDownloadState.idle;
      if (_error == MixerErrorKind.modelMissing) _clearOutcome();
      return true;
    } on MixCancelled {
      _modelState = MixerModelDownloadState.cancelled;
      return false;
    } catch (e) {
      print('Mix: falló la descarga del modelo (${e.runtimeType})');
      _modelChecksumFailed = e is MixModelChecksumMismatch;
      _modelState = cancel.isCancelled ? MixerModelDownloadState.cancelled : MixerModelDownloadState.failed;
      return false;
    } finally {
      _modelCancel = null;
      _notify();
    }
  }

  void cancelModelDownload() => _modelCancel?.cancel();

  MixerPhase get phase => _phase;
  MixerUiStage? get stage => _stage;

  /// 0..1, o `null` mientras no hay avance medible (bajando una canción).
  double? get fraction => _fraction;
  MixerErrorKind? get error => _error;
  MixRecord? get lastRecord => _lastRecord;

  bool get canStart =>
      supported &&
      !_busy &&
      _slots.length == 2 &&
      _resolving.isEmpty &&
      _modelState != MixerModelDownloadState.downloading;

  Future<void> start() async {
    final s = _services;
    if (!canStart || s == null) return;
    final a = _slots[MixerSlotId.a]!, b = _slots[MixerSlotId.b]!;
    final mode = _mode, quality = _quality;
    _cancelRequested = false;
    _lastRecord = null;
    _error = null;
    _phase = MixerPhase.running;
    _stage = MixerUiStage.preparing;
    _fraction = null;
    _notify();

    try {
      if (!await s.models.isInstalled(quality)) {
        _installed.remove(quality);
        throw MixModelNotInstalled(quality);
      }
      final sources = <MixSongSource>[];
      for (final slot in [a, b]) {
        if (_cancelRequested) throw const MixCancelled();
        final path = slot.isRemote
            ? await s.sourceCache.fetch(slot.track!, _source, isCancelled: () => _cancelRequested)
            : slot.song!.playablePath;
        sources.add(MixSongSource(songId: slot.stemKey, name: slot.title, playablePath: path));
      }
      if (_cancelRequested) throw const MixCancelled();

      final id = _newId();
      final output = '${s.mixesDirectory}${Platform.pathSeparator}$id.m4a';
      final job = _job = s.startJob(MixJobRequest(
        a: sources[0],
        b: sources[1],
        mode: mode,
        quality: quality,
        outputPath: output,
      ));
      final sub = job.progress.listen((p) {
        _stage = mixerUiStage(p.stage);
        _fraction = p.fraction;
        _notify();
      });
      final MixJobResult result;
      try {
        result = await job.result;
      } finally {
        unawaited(sub.cancel());
        _job = null;
      }

      var record = MixRecord(
        id: id,
        name: combinedMixName(a.title, b.title),
        songAId: a.song?.id,
        songBId: b.song?.id,
        remoteAId: a.track?.id,
        remoteBId: b.track?.id,
        titleA: a.title,
        artistA: a.artist,
        titleB: b.title,
        artistB: b.artist,
        mode: mode.name,
        quality: quality.name,
        durationMs: (result.report.durationSec * 1000).round(),
        filePath: result.outputPath,
        artPath: '',
        createdAt: _clock(),
      );
      try {
        final art = await _coverMaker(record, a, b);
        if (art.isNotEmpty) record = record.copyWith(artPath: art);
      } catch (e) {
        print('Mix: sin carátula (${e.runtimeType})');
      }
      await _store.insert(record);
      _lastRecord = record;
      _phase = MixerPhase.succeeded;
      _fraction = 1;
    } catch (e) {
      final kind = _cancelRequested ? MixerErrorKind.cancelled : classifyMixError(e, stage: _stage);
      if (kind == MixerErrorKind.unknown) print('Mix: el mix falló (${e.runtimeType})');
      _error = kind;
      _phase = MixerPhase.failed;
    } finally {
      _notify();
      try {
        await s.sourceCache.evict(keepVideoIds: {for (final x in [a, b]) if (x.isRemote) x.track!.id});
      } catch (e) {
        print('Mix: no se pudo acotar la caché de canciones (${e.runtimeType})');
      }
    }
  }

  void cancel() {
    if (!_busy) return;
    _cancelRequested = true;
    _job?.cancel();
  }

  Future<void> rename(String name) async {
    final r = _lastRecord;
    final bounded = normalizeMixName(name);
    if (r == null || bounded == null || bounded == r.name) return;
    await _store.rename(r.id, bounded);
    _lastRecord = r.copyWith(name: bounded);
    _notify();
  }

  /// Vuelve a la elección (conserva las dos canciones) y vacía la caché
  /// temporal de canciones buscadas.
  Future<void> reset() async {
    if (_busy) return;
    _clearOutcome();
    try {
      await _services?.sourceCache.clear();
    } catch (e) {
      print('Mix: no se pudo vaciar la caché de canciones (${e.runtimeType})');
    }
    _notify();
  }

  void _clearOutcome() {
    if (_busy) return;
    _phase = MixerPhase.idle;
    _stage = null;
    _fraction = null;
    _error = null;
    _lastRecord = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _job?.cancel();
    _modelCancel?.cancel();
    super.dispose();
  }
}
