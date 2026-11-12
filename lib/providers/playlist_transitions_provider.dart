import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/mix/mix_analysis.dart' show SongAnalysis;
import '../services/mix/mix_types.dart' show MixCancelToken;
import '../services/transition/platform/transition_job_runner.dart';
import '../services/transition/transition_model.dart';

/// Un par ordenado de canciones consecutivas de una playlist. Sólo tiene
/// transición posible si las dos son canciones de la biblioteca con archivo local.
class TransitionPair {
  const TransitionPair(this.from, this.to);
  final Song from, to;

  String get key => '${from.id}>${to.id}';

  bool get eligible =>
      from.id != to.id && !from.missing && !to.missing && from.playablePath.isNotEmpty && to.playablePath.isNotEmpty;
}

List<TransitionPair> pairsOfPlaylist(List<Song> songs) =>
    [for (var i = 0; i + 1 < songs.length; i++) TransitionPair(songs[i], songs[i + 1])];

TransitionSongRef transitionRefOf(Song s) => TransitionSongRef(
      id: s.id,
      playablePath: s.playablePath,
      stamp: s.fileHash ?? (s.fileSize == null ? '' : '${s.fileSize}'),
    );

class PairTransitionView {
  const PairTransitionView({required this.pair, this.transition, this.isAuto = false, this.disabled = false});
  final TransitionPair pair;

  /// El usuario la apagó: el par suena normal, pero la transición sigue guardada.
  final bool disabled;

  /// Guardada (a mano o automática) o, si no hay, la última sugerida en esta sesión.
  final SongTransition? transition;
  final bool isAuto;
  bool get isCustom => transition != null && !isAuto;
}

class TransitionPreview {
  const TransitionPreview.ok(this.clip, this.transition) : error = null;
  const TransitionPreview.failed(this.error, this.transition) : clip = null;
  final TransitionClip? clip;
  final TransitionErrorKind? error;
  final SongTransition transition;
  bool get ok => clip != null;
}

class AutoFillReport {
  const AutoFillReport({
    this.filled = 0,
    this.skippedCustom = 0,
    this.skippedDisabled = 0,
    this.skippedIneligible = 0,
    this.failed = 0,
    this.cancelled = false,
  });
  final int filled, skippedCustom, skippedDisabled, skippedIneligible, failed;
  final bool cancelled;
}

abstract class PlaylistTransitionStore {
  Future<Map<String, String>> list(String playlistId);
  Future<void> set(String playlistId, String fromSongId, String toSongId, String json);
  Future<void> delete(String playlistId, String fromSongId, String toSongId);
}

class DatabaseTransitionStore implements PlaylistTransitionStore {
  DatabaseTransitionStore([DatabaseHelper? db]) : _db = db ?? DatabaseHelper.instance;
  final DatabaseHelper _db;

  @override
  Future<Map<String, String>> list(String playlistId) => _db.listPlaylistTransitions(playlistId);

  @override
  Future<void> set(String playlistId, String fromSongId, String toSongId, String json) =>
      _db.setPlaylistTransition(playlistId, fromSongId, toSongId, json);

  @override
  Future<void> delete(String playlistId, String fromSongId, String toSongId) =>
      _db.deletePlaylistTransition(playlistId, fromSongId, toSongId);
}

abstract class TransitionEnabledStore {
  Future<bool> isEnabled(String playlistId);
  Future<void> setEnabled(String playlistId, bool enabled);
}

class PrefsTransitionEnabledStore implements TransitionEnabledStore {
  String _key(String id) => 'transitions_enabled_$id';

  @override
  Future<bool> isEnabled(String playlistId) async => (await SharedPreferences.getInstance()).getBool(_key(playlistId)) ?? false;

  @override
  Future<void> setEnabled(String playlistId, bool enabled) async =>
      (await SharedPreferences.getInstance()).setBool(_key(playlistId), enabled);
}

const _autoFlag = 'auto';
const _disabledFlag = 'disabled';

class _Saved {
  const _Saved(this.transition, {required this.auto, this.disabled = false});
  final SongTransition transition;
  final bool auto, disabled;

  _Saved withDisabled(bool v) => _Saved(transition, auto: auto, disabled: v);
}

/// Transiciones por playlist, locales a este dispositivo (nunca se sincronizan).
/// Apagar las transiciones de una playlist no borra las guardadas.
class PlaylistTransitionsProvider extends ChangeNotifier {
  PlaylistTransitionsProvider({
    required Future<TransitionService?> Function() service,
    PlaylistTransitionStore? store,
    TransitionEnabledStore? enabledStore,
  })  : _serviceFactory = service,
        _store = store ?? DatabaseTransitionStore(),
        _enabledStore = enabledStore ?? PrefsTransitionEnabledStore();

  final Future<TransitionService?> Function() _serviceFactory;
  final PlaylistTransitionStore _store;
  final TransitionEnabledStore _enabledStore;

  TransitionService? _service;
  final _songs = <String, List<Song>>{};
  final _saved = <String, Map<String, _Saved>>{};
  final _suggested = <String, SongTransition>{};
  final _enabled = <String, bool>{};
  final _analyses = <String, SongAnalysis>{};

  bool _autoRunning = false;
  int _autoDone = 0, _autoTotal = 0;
  MixCancelToken? _autoCancel;

  bool get autoFillRunning => _autoRunning;
  int get autoFillDone => _autoDone;
  int get autoFillTotal => _autoTotal;

  Future<TransitionService?> _svc() async => _service ??= await _serviceFactory();

  /// Disponible en este dispositivo (decodificador presente).
  Future<bool> get available async => await _svc() != null;

  bool isEnabled(String playlistId) => _enabled[playlistId] ?? false;

  /// Tempo, rejilla y tonalidad de la canción si ya se analizó en esta sesión (para mostrarlos en la lista).
  SongAnalysis? analysisOf(String songId) => _analyses[songId];

  void _remember(TransitionPairAnalysis a, TransitionPair pair) {
    _analyses[pair.from.id] = a.outgoing.analysis;
    _analyses[pair.to.id] = a.incoming.analysis;
  }

  /// Carga las transiciones guardadas y el estado de [songs], las canciones actuales de la playlist en orden.
  Future<void> load(String playlistId, List<Song> songs) async {
    _songs[playlistId] = List.unmodifiable(songs);
    _enabled[playlistId] = await _enabledStore.isEnabled(playlistId);
    final rows = await _store.list(playlistId);
    final map = <String, _Saved>{};
    rows.forEach((key, json) {
      try {
        final m = jsonDecode(json);
        if (m is Map<String, dynamic>) {
          map[key] = _Saved(SongTransition.fromJson(m), auto: m[_autoFlag] == true, disabled: m[_disabledFlag] == true);
        }
      } catch (e) {
        print('Transición: fila guardada ilegible, se ignora (${e.runtimeType})');
      }
    });
    _saved[playlistId] = map;
    notifyListeners();
  }

  Future<void> setEnabled(String playlistId, bool enabled) async {
    _enabled[playlistId] = enabled;
    notifyListeners();
    await _enabledStore.setEnabled(playlistId, enabled);
  }

  List<PairTransitionView> pairs(String playlistId) {
    final saved = _saved[playlistId] ?? const {};
    return [
      for (final p in pairsOfPlaylist(_songs[playlistId] ?? const []))
        if (saved[p.key] != null)
          PairTransitionView(
              pair: p, transition: saved[p.key]!.transition, isAuto: saved[p.key]!.auto, disabled: saved[p.key]!.disabled)
        else
          PairTransitionView(pair: p, transition: _suggested['$playlistId/${p.key}'], isAuto: true),
    ];
  }

  /// La transición guardada del par, o `null` si no hay (las sugerencias sin guardar no cuentan).
  SongTransition? savedTransition(String playlistId, String fromId, String toId) =>
      _saved[playlistId]?['$fromId>$toId']?.transition;

  String _toJson(SongTransition t, bool auto, bool disabled) =>
      jsonEncode({...t.toJson(), _autoFlag: auto, if (disabled) _disabledFlag: true});

  /// Guarda [t]; el apagado del par (si lo hay) se conserva.
  Future<void> _save(String playlistId, TransitionPair pair, SongTransition t, {required bool auto}) async {
    final disabled = _saved[playlistId]?[pair.key]?.disabled ?? false;
    await _store.set(playlistId, pair.from.id, pair.to.id, _toJson(t, auto, disabled));
    (_saved[playlistId] ??= {})[pair.key] = _Saved(t, auto: auto, disabled: disabled);
    _suggested.remove('$playlistId/${pair.key}');
  }

  Future<void> _invalidate(String playlistId, TransitionPair pair) async {
    final old = savedTransition(playlistId, pair.from.id, pair.to.id);
    if (old == null) return;
    await (await _svc())?.invalidateClip(transitionRefOf(pair.from), transitionRefOf(pair.to), old);
  }

  /// Análisis y sugerencia del par para el editor (no guarda nada).
  Future<TransitionPairAnalysis> analyzePair(TransitionPair pair, {MixCancelToken? cancel}) async {
    final svc = await _svc();
    if (svc == null || !pair.eligible) throw const TransitionException(TransitionErrorKind.missingFile);
    final a = await svc.analyzePair(transitionRefOf(pair.from), transitionRefOf(pair.to), cancel: cancel);
    _remember(a, pair);
    return a;
  }

  /// `false` sólo si el par tiene una transición guardada que el usuario apagó.
  bool isPairEnabled(String playlistId, TransitionPair pair) => !(_saved[playlistId]?[pair.key]?.disabled ?? false);

  /// Apaga o enciende la transición de un par sin borrar nada: la guardada se
  /// conserva y al encenderla vuelve tal cual. Si el par no tiene transición
  /// guardada, apagarlo guarda [fallback] (la sugerida que muestra el editor) ya
  /// apagada; sin [fallback] no hay nada que apagar.
  Future<void> setPairEnabled(String playlistId, TransitionPair pair, bool enabled, {SongTransition? fallback}) async {
    final cur = _saved[playlistId]?[pair.key];
    if (cur == null) {
      if (enabled || fallback == null) return;
      await _store.set(playlistId, pair.from.id, pair.to.id, _toJson(fallback, true, true));
      (_saved[playlistId] ??= {})[pair.key] = _Saved(fallback, auto: true, disabled: true);
      _suggested.remove('$playlistId/${pair.key}');
    } else {
      if (cur.disabled == !enabled) return;
      await _store.set(playlistId, pair.from.id, pair.to.id, _toJson(cur.transition, cur.auto, !enabled));
      _saved[playlistId]![pair.key] = cur.withDisabled(!enabled);
    }
    notifyListeners();
  }

  /// Guarda [t] como personalizada y descarta el clip de la anterior.
  Future<void> setTransition(String playlistId, TransitionPair pair, SongTransition t) async {
    await _invalidate(playlistId, pair);
    await _save(playlistId, pair, t, auto: false);
    notifyListeners();
  }

  /// Quita la personalización: vuelve a sugerir y guarda como automática. Si no se puede
  /// analizar, el par queda sin transición guardada y se propaga el error.
  Future<SongTransition> resetToAuto(String playlistId, TransitionPair pair, {MixCancelToken? cancel}) async {
    await _invalidate(playlistId, pair);
    try {
      final a = await analyzePair(pair, cancel: cancel);
      await _save(playlistId, pair, a.suggestion.transition, auto: true);
      notifyListeners();
      return a.suggestion.transition;
    } catch (_) {
      await _store.delete(playlistId, pair.from.id, pair.to.id);
      _saved[playlistId]?.remove(pair.key);
      notifyListeners();
      rethrow;
    }
  }

  /// Sugiere una transición para cada par de la biblioteca salvo los personalizados.
  /// Los pares sin archivo o que fallan se saltan sin detener el resto.
  Future<AutoFillReport> autoFillPlaylist(String playlistId) async {
    if (_autoRunning) return const AutoFillReport();
    final pairs = pairsOfPlaylist(_songs[playlistId] ?? const []);
    final saved = _saved[playlistId] ?? const {};
    var filled = 0, custom = 0, disabled = 0, ineligible = 0, failed = 0;
    final todo = <TransitionPair>[];
    for (final p in pairs) {
      if (!p.eligible) {
        ineligible++;
      } else if (saved[p.key]?.disabled ?? false) {
        disabled++;
      } else if (saved[p.key] != null && !saved[p.key]!.auto) {
        custom++;
      } else {
        todo.add(p);
      }
    }
    _autoRunning = true;
    _autoDone = 0;
    _autoTotal = todo.length;
    final cancel = _autoCancel = MixCancelToken();
    notifyListeners();
    try {
      for (final p in todo) {
        if (cancel.isCancelled) break;
        try {
          final a = await analyzePair(p, cancel: cancel);
          if (cancel.isCancelled) break;
          await _invalidate(playlistId, p);
          await _save(playlistId, p, a.suggestion.transition, auto: true);
          filled++;
        } catch (e) {
          if (e is TransitionException && e.kind == TransitionErrorKind.cancelled) break;
          failed++;
        }
        _autoDone++;
        notifyListeners();
      }
    } finally {
      _autoRunning = false;
      _autoCancel = null;
      notifyListeners();
    }
    return AutoFillReport(
        filled: filled,
        skippedCustom: custom,
        skippedDisabled: disabled,
        skippedIneligible: ineligible,
        failed: failed,
        cancelled: cancel.isCancelled);
  }

  void cancelAutoFill() => _autoCancel?.cancel();

  /// Cuántos pares de [playlistId] tienen una transición guardada (preparada o editada) y encendida.
  int preparedCount(String playlistId) {
    final saved = _saved[playlistId] ?? const {};
    return pairsOfPlaylist(_songs[playlistId] ?? const []).where((p) => saved[p.key] != null && !saved[p.key]!.disabled).length;
  }

  /// Clip para la reproducción: sólo si las transiciones de la playlist están
  /// encendidas y el par tiene una transición GUARDADA (preparada o editada).
  /// Nunca analiza, sugiere ni guarda nada: un par sin preparar suena normal.
  Future<TransitionClip?> playbackClipFor(String playlistId, TransitionPair pair) async {
    try {
      if (!isEnabled(playlistId) || !pair.eligible) return null;
      final saved = _saved[playlistId]?[pair.key];
      if (saved == null || saved.disabled) return null;
      final svc = await _svc();
      if (svc == null) return null;
      return await svc.renderClip(transitionRefOf(pair.from), transitionRefOf(pair.to), saved.transition);
    } catch (e) {
      print('Transición: no se pudo preparar el clip (${e.runtimeType})');
      return null;
    }
  }

  /// Renderiza (o recupera de la caché) el clip del par con su transición guardada o,
  /// si no la hay, con la sugerida. Los errores no se lanzan: vienen en el resultado.
  Future<TransitionPreview> preview(String playlistId, TransitionPair pair, {SongTransition? override, MixCancelToken? cancel}) async {
    final svc = await _svc();
    var t = override ?? savedTransition(playlistId, pair.from.id, pair.to.id);
    try {
      if (svc == null || !pair.eligible) throw const TransitionException(TransitionErrorKind.missingFile);
      if (t == null) {
        final a = await svc.analyzePair(transitionRefOf(pair.from), transitionRefOf(pair.to), cancel: cancel);
        t = a.suggestion.transition;
        _suggested['$playlistId/${pair.key}'] = t;
      }
      final clip = await svc.renderClip(transitionRefOf(pair.from), transitionRefOf(pair.to), t, cancel: cancel);
      return TransitionPreview.ok(clip, t);
    } on TransitionException catch (e) {
      return TransitionPreview.failed(e.kind, t ?? SongTransition(outStartSec: 0, inStartSec: 0, lengthSec: kTransitionDefaultLengthSec));
    } catch (e) {
      print('Transición: falló la vista previa (${e.runtimeType})');
      return TransitionPreview.failed(
          TransitionErrorKind.renderFailed, t ?? SongTransition(outStartSec: 0, inStartSec: 0, lengthSec: kTransitionDefaultLengthSec));
    }
  }
}
