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
import '../services/mix/mix_edit_plan.dart';
import '../services/mix/mix_envelope.dart';
import '../services/mix/mix_naming.dart';
import '../services/mix/mix_planner.dart' show durationWarning;
import '../services/mix/mix_templates.dart' show templateSupportsMode;
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

/// Borra el audio temporal de una escucha; un fallo solo se registra.
Future<void> deletePreviewFile(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (e) {
    print('Mix: no se pudo borrar el audio de la escucha (${e.runtimeType})');
  }
}

Future<String> _noCover(MixRecord record, MixerSlot a, MixerSlot b) async => '';

enum MixerPhase { idle, running, succeeded, failed }

enum MixerModelDownloadState { idle, downloading, failed, cancelled }

/// "Escuchar" en el editor: nada oído aún, preparándose, al día con lo que se
/// ve, o desactualizado porque el plan cambió después.
enum MixPreviewStatus { none, preparing, fresh, stale }

MixPreviewStatus previewStatusOf({required bool preparing, required bool hasPreview, required bool planMatches}) {
  if (preparing) return MixPreviewStatus.preparing;
  if (!hasPreview) return MixPreviewStatus.none;
  return planMatches ? MixPreviewStatus.fresh : MixPreviewStatus.stale;
}

/// Estado de Heardy Mixer. Vive en el `MultiProvider` de main.dart para que el
/// trabajo siga y su avance se vea al salir y volver a la pantalla.
class HeardyMixerProvider extends ChangeNotifier {
  HeardyMixerProvider({
    required Future<HeardyMixerServices?> Function() services,
    required DownloadSource source,
    MixRecordStore? store,
    MixCoverMaker? coverMaker,
    Future<void> Function(String path)? deleteFile,
    DateTime Function()? clock,
    String Function()? newId,
    MixAnalyzeStarter? analyzeStarter,
    MixEditRenderStarter? editRenderStarter,
  })  : _servicesLoader = services,
        _source = source,
        _store = store ?? DatabaseMixRecordStore(),
        _coverMaker = coverMaker ?? _noCover,
        _deleteFile = deleteFile ?? deletePreviewFile,
        _clock = clock ?? DateTime.now,
        _newId = newId ?? (() => const Uuid().v4()),
        _analyzeStarter = analyzeStarter,
        _editRenderStarter = editRenderStarter;

  final Future<HeardyMixerServices?> Function() _servicesLoader;
  final DownloadSource _source;
  final MixRecordStore _store;
  final MixCoverMaker _coverMaker;
  final Future<void> Function(String path) _deleteFile;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// Las dos fases del editor avanzado, si se inyectan aquí; si no, se usan las
  /// de [HeardyMixerServices]. Sin ninguna el editor no está disponible (el mix
  /// de una pasada, [start], no las necesita).
  final MixAnalyzeStarter? _analyzeStarter;
  final MixEditRenderStarter? _editRenderStarter;

  HeardyMixerServices? _services;
  Future<void>? _loading;
  bool _ready = false;
  bool _disposed = false;

  final Map<MixerSlotId, MixerSlot> _slots = {};
  final Set<MixerSlotId> _resolving = {};
  final Map<MixerSlotId, int> _slotGen = {MixerSlotId.a: 0, MixerSlotId.b: 0};
  MixMode _mode = MixMode.automatic;
  MixQualityMode _quality = MixQualityMode.fast;
  MixTemplate? _template;
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
  MixAnalyzeJob? _analyzeJob;
  bool _cancelRequested = false;

  MixEditAnalysis? _analysis;
  MixEditPlan? _editPlan;
  MixQualityMode? _analysisQuality;
  List<double> _outputEnvelope = const [];

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
    _dropAnalysis();
    _notify();
  }

  MixMode get mode => _mode;
  set mode(MixMode m) {
    if (_busy || m == _mode) return;
    _mode = m;
    _dropAnalysis();
    // Un estilo que el nuevo modo no admite vuelve a "Automático".
    if (_template != null && !templateSupportsMode(_template!, m)) _template = null;
    _notify();
  }

  /// Estilo elegido; `null` es "Automático" (lo decide el motor para cada par).
  MixTemplate? get template => _template;
  set template(MixTemplate? t) {
    if (_busy || t == _template) return;
    if (t != null && !templateSupportsMode(t, _mode)) return;
    _template = t;
    _dropAnalysis();
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

  MixReport? _lastReport;

  /// Informe del último mix terminado (estilo usado y por qué), o `null`.
  MixReport? get lastReport => _lastReport;

  List<MixWarning> _lastWarnings = const [];

  /// Avisos del último mix terminado (vacío si no hubo o no hay mix).
  List<MixWarning> get lastWarnings => _lastWarnings;

  /// Lo que ya se sabe antes de empezar: solo las duraciones de la lista; el
  /// tempo y el tono salen del análisis, que ocurre dentro del trabajo.
  List<MixWarning> get preflightWarnings {
    final a = _slots[MixerSlotId.a], b = _slots[MixerSlotId.b];
    if (a == null || b == null) return const [];
    final w = durationWarning(a.durationSeconds.toDouble(), b.durationSeconds.toDouble());
    return w == null ? const [] : [w];
  }

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
    final mode = _mode, quality = _quality, template = _template;
    _cancelRequested = false;
    _lastRecord = null;
    _lastReport = null;
    _lastWarnings = const [];
    _lastFromEditor = false;
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
      final sources = await _sourcesFor(s, a, b);

      final id = _newId();
      final output = '${s.mixesDirectory}${Platform.pathSeparator}$id.m4a';
      final job = _job = s.startJob(MixJobRequest(
        a: sources[0],
        b: sources[1],
        mode: mode,
        quality: quality,
        outputPath: output,
        options: MixOptions(template: template),
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

      final auto = result.report.selection?.automatic ?? template == null;
      await _saveMix(
          id: id,
          a: a,
          b: b,
          mode: mode,
          quality: quality,
          result: result,
          styleOrigin: auto ? MixRecord.kStyleAutomatic : MixRecord.kStyleChosen);
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

  Future<List<MixSongSource>> _sourcesFor(HeardyMixerServices s, MixerSlot a, MixerSlot b) async {
    final sources = <MixSongSource>[];
    for (final slot in [a, b]) {
      if (_cancelRequested) throw const MixCancelled();
      final path = slot.isRemote
          ? await s.sourceCache.fetch(slot.track!, _source, isCancelled: () => _cancelRequested)
          : slot.song!.playablePath;
      sources.add(MixSongSource(songId: slot.stemKey, name: slot.title, playablePath: path));
    }
    if (_cancelRequested) throw const MixCancelled();
    return sources;
  }

  /// Registro, carátula y estado de éxito de un mix terminado (un mix guardado
  /// es una fila normal de `songs` con `isMix`, igual venga de una pasada o del editor).
  MixRecord _recordFor({
    required String id,
    required MixerSlot a,
    required MixerSlot b,
    required MixMode mode,
    required MixQualityMode quality,
    required MixJobResult result,
    required String styleOrigin,
  }) =>
      MixRecord(
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
      styleId: result.report.template.name,
      styleOrigin: styleOrigin,
    );

  Future<MixRecord> _withCover(MixRecord record, MixerSlot a, MixerSlot b) async {
    try {
      final art = await _coverMaker(record, a, b);
      if (art.isNotEmpty) return record.copyWith(artPath: art);
    } catch (e) {
      print('Mix: sin carátula (${e.runtimeType})');
    }
    return record;
  }

  Future<void> _saveMix({
    required String id,
    required MixerSlot a,
    required MixerSlot b,
    required MixMode mode,
    required MixQualityMode quality,
    required MixJobResult result,
    required String styleOrigin,
  }) async {
    final record = await _withCover(
        _recordFor(id: id, a: a, b: b, mode: mode, quality: quality, result: result, styleOrigin: styleOrigin),
        a,
        b);
    await _store.insert(record);
    _lastRecord = record;
    _lastWarnings = result.report.warnings;
    _lastReport = result.report;
    _phase = MixerPhase.succeeded;
    _fraction = 1;
  }

  // ---- Editor avanzado: analizar -> editar el plan -> renderizar ----

  /// El editor está disponible en esta plataforma y las dos fases están conectadas.
  bool get editorAvailable => supported && _analyze != null && _editRender != null;

  MixAnalyzeStarter? get _analyze => _analyzeStarter ?? _services?.startAnalyze;
  MixEditRenderStarter? get _editRender => _editRenderStarter ?? _services?.startEditRender;

  bool get canAnalyze => editorAvailable && canStart;

  /// Ya hay un análisis y un plan que editar (ver [analyze]).
  bool get hasAnalysis => _analysis != null;

  MixEditAnalysis? get editAnalysis => _analysis;

  /// Plan que el usuario edita (empieza siendo el automático); `null` sin análisis.
  MixEditPlan? get editPlan => _editPlan;

  /// Avisos del par calculados en el análisis (tempo, tono, duración).
  List<MixWarning> get editWarnings => _analysis?.auto.warnings ?? const [];

  /// Qué plantilla eligió el análisis y por qué.
  MixTemplateSelection? get editSelection => _analysis?.auto.selection;

  /// Envolventes por compás de las dos canciones, para dibujar sus ondas.
  MixEnvelopes? get editEnvelopes => _analysis?.envelopes;

  /// Envolvente del último render hecho desde el editor (vacía si no hay).
  List<double> get outputEnvelope => _outputEnvelope;

  bool _lastFromEditor = false;

  /// El último mix guardado salió del editor (se puede volver a él con [backToEditing]).
  bool get lastFromEditor => _lastFromEditor && _analysis != null && _lastRecord != null;

  /// Lo que no cuadra en el plan actual (el editor es permisivo: solo informa).
  List<MixPlanProblem> get editProblems {
    final an = _analysis, plan = _editPlan;
    if (an == null || plan == null) return const [];
    return validateEditPlan(plan,
        a: MixEditSongInfo(bars: an.auto.summaryA.planBars), b: MixEditSongInfo(bars: an.auto.summaryB.planBars));
  }

  MixRecord? _previewRecord;
  MixEditPlan? _previewPlan;
  bool _previewing = false;

  /// La escucha ya es un mix guardado (fila insertada): su archivo no se borra.
  bool _previewPersisted = false;
  bool _keeping = false;

  /// El editor se cerró mientras se preparaba una escucha: al terminar se descarta.
  bool _previewAbandoned = false;

  /// Se está preparando la escucha del editor (el editor sigue a la vista).
  bool get previewing => _busy && _previewing;

  /// Audio de la última escucha del editor, o `null`.
  MixRecord? get previewRecord => _previewRecord;

  MixPreviewStatus get previewStatus => previewStatusOf(
      preparing: previewing, hasPreview: _previewRecord != null, planMatches: identical(_previewPlan, _editPlan));

  /// "Escuchar": renderiza el plan actual sin salir del editor. El audio queda
  /// en [previewRecord]; es solo un archivo temporal y no deja ninguna fila en
  /// la biblioteca hasta que [keepPreviewAsMix] lo guarda.
  Future<void> preview() async {
    final plan = _editPlan;
    if (plan == null) return;
    await render(plan, preview: true);
  }

  /// Si lo último que se escuchó es justo el plan actual, lo deja como el mix
  /// terminado (sin renderizar otra vez) y devuelve `true`.
  /// Es aquí donde la escucha pasa a ser un mix guardado.
  Future<bool> keepPreviewAsMix() async {
    final r = _previewRecord;
    final a = _slots[MixerSlotId.a], b = _slots[MixerSlotId.b];
    if (_busy || _keeping || _analysis == null || r == null || a == null || b == null) return false;
    if (previewStatus != MixPreviewStatus.fresh) return false;
    _keeping = true;
    try {
      var record = r;
      if (!_previewPersisted) {
        record = await _withCover(r, a, b);
        if (_disposed || !identical(_previewRecord, r) || previewStatus != MixPreviewStatus.fresh) return false;
        await _store.insert(record);
        _previewRecord = record;
        _previewPersisted = true;
      }
      _lastRecord = record;
      _lastReport = null;
      _lastWarnings = const [];
      _lastFromEditor = true;
      _error = null;
      _phase = MixerPhase.succeeded;
      _fraction = 1;
      _notify();
      return true;
    } catch (e) {
      print('Mix: no se pudo guardar el mix (${e.runtimeType})');
      return false;
    } finally {
      _keeping = false;
    }
  }

  /// Olvida la escucha y borra su archivo si nadie la guardó como mix. Es lo que
  /// hace el editor al cerrarse sin guardar.
  void discardPreview({bool notify = true}) {
    if (_previewing) _previewAbandoned = true;
    final had = _previewRecord != null;
    _forgetPreview();
    if (had && notify) _notify();
  }

  void _forgetPreview() {
    final r = _previewRecord;
    if (r != null && !_previewPersisted) unawaited(_deleteFile(r.filePath));
    _previewRecord = null;
    _previewPlan = null;
    _previewPersisted = false;
  }

  void _dropAnalysis() {
    if (_busy) return;
    _forgetPreview();
    _undo.clear();
    _coalescing = false;
    _analysis = null;
    _editPlan = null;
    _analysisQuality = null;
    _outputEnvelope = const [];
  }

  /// Fase 1: separa y analiza las dos canciones (con caché) y arma el plan
  /// automático sin recortar compases (`targetDurationSec: null`, así los
  /// compases de origen son los de la canción original). Deja el resultado en
  /// [editAnalysis] y [editPlan]; no renderiza ni guarda nada.
  Future<void> analyze() async {
    final s = _services, starter = _analyze;
    if (!canAnalyze || s == null || starter == null) return;
    final a = _slots[MixerSlotId.a]!, b = _slots[MixerSlotId.b]!;
    final mode = _mode, quality = _quality, template = _template;
    _cancelRequested = false;
    _forgetPreview();
    _lastRecord = null;
    _lastReport = null;
    _lastWarnings = const [];
    _error = null;
    _undo.clear();
    _coalescing = false;
    _analysis = null;
    _editPlan = null;
    _analysisQuality = null;
    _outputEnvelope = const [];
    _phase = MixerPhase.running;
    _stage = MixerUiStage.preparing;
    _fraction = null;
    _notify();

    try {
      if (!await s.models.isInstalled(quality)) {
        _installed.remove(quality);
        throw MixModelNotInstalled(quality);
      }
      final sources = await _sourcesFor(s, a, b);
      final job = _analyzeJob = starter(MixAnalyzeJobRequest(
        a: sources[0],
        b: sources[1],
        mode: mode,
        quality: quality,
        options: MixOptions(template: template, targetDurationSec: null),
      ));
      final sub = job.progress.listen((p) {
        _stage = mixerUiStage(p.stage);
        _fraction = p.fraction;
        _notify();
      });
      final MixEditAnalysis analysis;
      try {
        analysis = await job.result;
      } finally {
        unawaited(sub.cancel());
        _analyzeJob = null;
      }
      _analysis = analysis;
      _editPlan = analysis.auto.plan;
      _analysisQuality = quality;
      _phase = MixerPhase.idle;
      _stage = null;
      _fraction = null;
    } catch (e) {
      final kind = _cancelRequested ? MixerErrorKind.cancelled : classifyMixError(e, stage: _stage);
      if (kind == MixerErrorKind.unknown) print('Mix: el análisis falló (${e.runtimeType})');
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

  static const int _maxUndo = 50;
  final List<MixEditPlan> _undo = [];
  bool _coalescing = false;

  /// Hay una edición que [undo] pueda deshacer.
  bool get canUndo => _undo.isNotEmpty;

  void _pushUndo(MixEditPlan previous) {
    _undo.add(previous);
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  /// Sustituye el plan que se edita. No hace nada sin análisis o mientras corre un trabajo.
  /// Con [coalesce] las llamadas seguidas (un arrastre de deslizador) cuentan como un
  /// solo paso de [undo] hasta que se llame a [endCoalescing] o llegue otra edición.
  void updatePlan(MixEditPlan plan, {bool coalesce = false}) {
    final current = _editPlan;
    if (_busy || _analysis == null || current == null) return;
    if (identical(plan, current)) return;
    if (!(coalesce && _coalescing)) _pushUndo(current);
    _coalescing = coalesce;
    _editPlan = plan;
    _notify();
  }

  /// Cierra el paso que agrupaba las llamadas con `coalesce: true`.
  void endCoalescing() => _coalescing = false;

  /// Devuelve el plan que la última edición sustituyó. No hay rehacer.
  void undo() {
    if (_busy || _analysis == null || _undo.isEmpty) return;
    _editPlan = _undo.removeLast();
    _coalescing = false;
    _notify();
  }

  /// Cambia la canción base ('a' o 'b') del plan que se edita y recalcula tempo,
  /// estiramientos y tono de la otra ([changeBaseSong]); los tramos no se tocan.
  void changeBase(String song) {
    final an = _analysis, plan = _editPlan;
    if (_busy || an == null || plan == null) return;
    final next = changeBaseSong(plan, song,
        a: an.auto.summaryA, b: an.auto.summaryB, options: MixOptions(template: _template, targetDurationSec: null));
    if (identical(next, plan)) return;
    _pushUndo(plan);
    _coalescing = false;
    _editPlan = next;
    _notify();
  }

  /// Fase 2: renderiza [plan] con las mismas canciones y el mismo modelo de la
  /// fase 1, sin volver a separar mientras sus stems sigan en la caché. Guarda
  /// el resultado igual que [start]: una fila normal de `songs` con `isMix`.
  Future<void> render(MixEditPlan plan, {bool preview = false}) async {
    final s = _services, starter = _editRender;
    if (!editorAvailable || s == null || starter == null || !hasAnalysis || !canStart) return;
    _previewing = preview;
    if (preview) _previewAbandoned = false;
    _forgetPreview();
    final a = _slots[MixerSlotId.a]!, b = _slots[MixerSlotId.b]!;
    final quality = _analysisQuality ?? _quality;
    _editPlan = plan;
    _cancelRequested = false;
    _lastRecord = null;
    _lastReport = null;
    _lastWarnings = const [];
    _outputEnvelope = const [];
    _lastFromEditor = false;
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
      final sources = await _sourcesFor(s, a, b);
      final id = _newId();
      final output = '${s.mixesDirectory}${Platform.pathSeparator}$id.m4a';
      final job = _job = starter(MixEditRenderJobRequest(
        a: sources[0],
        b: sources[1],
        quality: quality,
        plan: plan,
        outputPath: output,
        options: MixOptions(template: _template, targetDurationSec: null),
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
      _outputEnvelope = result.outputEnvelope;
      if (preview) {
        _previewRecord = _recordFor(
            id: id, a: a, b: b, mode: plan.mode, quality: quality, result: result, styleOrigin: MixRecord.kStyleEdited);
        _previewPlan = plan;
        _previewPersisted = false;
        _outputEnvelope = const [];
        if (_previewAbandoned) _forgetPreview();
        _phase = MixerPhase.idle;
        _stage = null;
        _fraction = null;
      } else {
        await _saveMix(
            id: id,
            a: a,
            b: b,
            mode: plan.mode,
            quality: quality,
            result: result,
            styleOrigin: MixRecord.kStyleEdited);
        _lastFromEditor = true;
      }
    } catch (e) {
      final kind = _cancelRequested ? MixerErrorKind.cancelled : classifyMixError(e, stage: _stage);
      if (kind == MixerErrorKind.unknown) print('Mix: el render del editor falló (${e.runtimeType})');
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

  /// Vuelve del resultado (o de un fallo del render) al editor, conservando
  /// el análisis y el plan para seguir editando.
  void backToEditing() {
    if (_busy || _analysis == null) return;
    _phase = MixerPhase.idle;
    _stage = null;
    _fraction = null;
    _error = null;
    _lastRecord = null;
    _lastReport = null;
    _lastWarnings = const [];
    _outputEnvelope = const [];
    _lastFromEditor = false;
    _notify();
  }

  void cancel() {
    if (!_busy) return;
    _cancelRequested = true;
    _job?.cancel();
    _analyzeJob?.cancel();
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
    _dropAnalysis();
    _phase = MixerPhase.idle;
    _stage = null;
    _fraction = null;
    _error = null;
    _lastRecord = null;
    _lastReport = null;
    _lastWarnings = const [];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _forgetPreview();
    _job?.cancel();
    _analyzeJob?.cancel();
    _modelCancel?.cancel();
    super.dispose();
  }
}
