// Trabajos de transición. Lo pesado (analizar una canción, renderizar un clip)
// corre en un isolate que lee los PCM de disco; al isolate principal sólo
// vuelven el perfil o los tiempos del clip. [TransitionEngine] coordina:
// decodificar con la costura inyectada, caché de perfiles y de clips.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../mix/mix_analysis.dart' show SongAnalysis, analyzeSong;
import '../../mix/mix_dsp.dart' show slice;
import '../../mix/mix_types.dart' show MixCancelToken, MixCancelled, kMixSampleRate;
import '../transition_analysis.dart';
import '../transition_model.dart';
import '../transition_render.dart';
import '../transition_suggest.dart';
import 'transition_clip_cache.dart';
import 'transition_profile.dart';
import 'transition_windows.dart';

enum TransitionErrorKind { missingFile, decoderFailed, analysisFailed, renderFailed, cancelled }

class TransitionException implements Exception {
  const TransitionException(this.kind, [this.detail = '']);
  final TransitionErrorKind kind;
  final String detail;
  @override
  String toString() => 'TransitionException: ${kind.name}${detail.isEmpty ? '' : ' ($detail)'}';
}

/// Dónde suena en el clip y en cada canción lo que el reproductor necesita para el relevo.
class TransitionClipInfo {
  const TransitionClipInfo({
    required this.sampleRate,
    required this.clipSec,
    required this.clipStartInOutgoingSec,
    required this.overlapStartInClipSec,
    required this.overlapSec,
    required this.handoverInClipSec,
    required this.handoverInIncomingSec,
    required this.resumeInIncomingSec,
    required this.tempoRatio,
    required this.tempoMatchApplied,
    required this.peakDb,
    required this.notes,
  });

  factory TransitionClipInfo.fromResult(TransitionRenderResult r) => TransitionClipInfo(
        sampleRate: r.sampleRate,
        clipSec: r.clipSec,
        clipStartInOutgoingSec: r.clipStartInOutgoingSec,
        overlapStartInClipSec: r.overlapStartInClipSec,
        overlapSec: r.overlapSec,
        handoverInClipSec: r.handoverInClipSec,
        handoverInIncomingSec: r.handoverInIncomingSec,
        resumeInIncomingSec: r.resumeInIncomingSec,
        tempoRatio: r.tempoRatio,
        tempoMatchApplied: r.tempoMatchApplied,
        peakDb: r.peakDb,
        notes: [for (final n in r.notes) n.name],
      );

  final int sampleRate;
  final double clipSec;
  final double clipStartInOutgoingSec;
  final double overlapStartInClipSec;
  final double overlapSec;
  final double handoverInClipSec;
  final double handoverInIncomingSec;
  final double resumeInIncomingSec;
  final double tempoRatio;
  final bool tempoMatchApplied;
  final double peakDb;
  final List<String> notes;

  Map<String, dynamic> toJson() => {
        'sampleRate': sampleRate,
        'clipSec': clipSec,
        'clipStartInOutgoingSec': clipStartInOutgoingSec,
        'overlapStartInClipSec': overlapStartInClipSec,
        'overlapSec': overlapSec,
        'handoverInClipSec': handoverInClipSec,
        'handoverInIncomingSec': handoverInIncomingSec,
        'resumeInIncomingSec': resumeInIncomingSec,
        'tempoRatio': tempoRatio,
        'tempoMatchApplied': tempoMatchApplied,
        'peakDb': peakDb,
        'notes': notes,
      };

  static TransitionClipInfo fromJson(Map<String, dynamic> j) {
    double d(String k) => (j[k] as num).toDouble();
    return TransitionClipInfo(
      sampleRate: j['sampleRate'] as int,
      clipSec: d('clipSec'),
      clipStartInOutgoingSec: d('clipStartInOutgoingSec'),
      overlapStartInClipSec: d('overlapStartInClipSec'),
      overlapSec: d('overlapSec'),
      handoverInClipSec: d('handoverInClipSec'),
      handoverInIncomingSec: d('handoverInIncomingSec'),
      resumeInIncomingSec: d('resumeInIncomingSec'),
      tempoRatio: d('tempoRatio'),
      tempoMatchApplied: j['tempoMatchApplied'] == true,
      peakDb: d('peakDb'),
      notes: [for (final n in (j['notes'] as List)) n as String],
    );
  }
}

class TransitionProfileRequest {
  const TransitionProfileRequest({required this.songId, required this.stamp, required this.pcmPath, this.existingAnalysis});
  final String songId, stamp, pcmPath;
  final SongAnalysis? existingAnalysis;
}

class TransitionRenderRequest {
  const TransitionRenderRequest({
    required this.outgoingPcmPath,
    required this.incomingPcmPath,
    required this.transition,
    required this.wavPath,
    this.outBpm,
    this.inBpm,
  });
  final String outgoingPcmPath, incomingPcmPath, wavPath;
  final SongTransition transition;
  final double? outBpm, inBpm;
}

Future<int> _frames(String path) async => (await File(path).length()) ~/ 8;

/// Perfil de una canción ya decodificada: análisis (el existente si lo hay) y resúmenes de nivel.
Future<TransitionSongProfile> profileSongFile(TransitionProfileRequest r) async {
  final frames = await _frames(r.pcmPath);
  if (frames <= 0) throw StateError('audio vacío');
  final whole = (await readPcmWindow(r.pcmPath, 0, frames / kMixSampleRate)).pcm;
  final n = whole.length;
  final analysis = r.existingAnalysis ??
      analyzeSong(() {
        final m = Float32List(n);
        for (var i = 0; i < n; i++) {
          m[i] = 0.5 * (whole.l[i] + whole.r[i]);
        }
        return m;
      }(), kMixSampleRate);
  final dur = n / kMixSampleRate;
  final win = (kTransitionDetailWindowSec * kMixSampleRate).round();
  final outroStart = math.max(0, n - win);
  final outro = slice(whole.l, whole.r, outroStart, n);
  final intro = slice(whole.l, whole.r, 0, math.min(n, win));
  return TransitionSongProfile(
    songId: r.songId,
    stamp: r.stamp,
    durationSec: dur,
    analysis: analysis,
    overview: analyzeForTransition(whole, kMixSampleRate, pointsPerSecond: kTransitionOverviewPointsPerSecond),
    outro: analyzeForTransition(outro, kMixSampleRate, pointsPerSecond: kTransitionDetailPointsPerSecond),
    outroOffsetSec: outroStart / kMixSampleRate,
    intro: analyzeForTransition(intro, kMixSampleRate, pointsPerSecond: kTransitionDetailPointsPerSecond),
  );
}

/// Renderiza el clip leyendo sólo las ventanas necesarias y lo escribe como WAV de 16 bits.
Future<TransitionClipInfo> renderClipFile(TransitionRenderRequest r) async {
  final outDur = await _frames(r.outgoingPcmPath) / kMixSampleRate;
  final inDur = await _frames(r.incomingPcmPath) / kMixSampleRate;
  final (oa, ob) = transitionWindowFor(r.transition, durationSec: outDur, outgoing: true);
  final (ia, ib) = transitionWindowFor(r.transition, durationSec: inDur, outgoing: false);
  final o = await readPcmWindow(r.outgoingPcmPath, oa, ob);
  final i = await readPcmWindow(r.incomingPcmPath, ia, ib);
  final result = renderTransition(
    outgoing: o.pcm,
    outgoingOffsetSec: o.offsetSec,
    incoming: i.pcm,
    incomingOffsetSec: i.offsetSec,
    sampleRate: kMixSampleRate,
    transition: r.transition,
    outBpm: r.outBpm,
    inBpm: r.inBpm,
  );
  if (result.pcm.length == 0) throw StateError('clip vacío');
  await writeWav16(r.wavPath, result.pcm, result.sampleRate);
  return TransitionClipInfo.fromResult(result);
}

abstract class TransitionBackend {
  Future<TransitionSongProfile> profile(TransitionProfileRequest r, {MixCancelToken? cancel});
  Future<TransitionClipInfo> render(TransitionRenderRequest r, {MixCancelToken? cancel});
}

/// Sin isolate: para pruebas y para quien ya esté en uno.
class DirectTransitionBackend implements TransitionBackend {
  @override
  Future<TransitionSongProfile> profile(TransitionProfileRequest r, {MixCancelToken? cancel}) => profileSongFile(r);

  @override
  Future<TransitionClipInfo> render(TransitionRenderRequest r, {MixCancelToken? cancel}) => renderClipFile(r);
}

class _JobFailure {
  const _JobFailure(this.type);
  final String type;
}

Future<void> _profileMain((SendPort, TransitionProfileRequest) a) async {
  try {
    a.$1.send(await profileSongFile(a.$2));
  } catch (e) {
    a.$1.send(_JobFailure(e.runtimeType.toString()));
  }
}

Future<void> _renderMain((SendPort, TransitionRenderRequest) a) async {
  try {
    a.$1.send(await renderClipFile(a.$2));
  } catch (e) {
    a.$1.send(_JobFailure(e.runtimeType.toString()));
  }
}

Future<T> _runInIsolate<T, M>(
  Future<void> Function((SendPort, M)) entry,
  M message, {
  required String debugName,
  MixCancelToken? cancel,
}) async {
  final events = ReceivePort();
  final done = Completer<T>();
  events.listen((m) {
    if (done.isCompleted) return;
    if (m is T) {
      done.complete(m);
    } else if (m is _JobFailure) {
      done.completeError(StateError('falló el trabajo (${m.type})'));
    } else {
      done.completeError(StateError('respuesta inesperada del isolate'));
    }
  });
  final exitPort = ReceivePort();
  exitPort.listen((_) {
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!done.isCompleted) done.completeError(StateError('el isolate terminó sin respuesta'));
    });
  });
  final iso = await Isolate.spawn<(SendPort, M)>(entry, (events.sendPort, message),
      onExit: exitPort.sendPort, debugName: debugName);
  Timer? poll;
  if (cancel != null) {
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (cancel.isCancelled && !done.isCompleted) {
        iso.kill(priority: Isolate.immediate);
        done.completeError(const MixCancelled());
      }
    });
  }
  try {
    return await done.future;
  } finally {
    poll?.cancel();
    events.close();
    exitPort.close();
  }
}

class IsolateTransitionBackend implements TransitionBackend {
  @override
  Future<TransitionSongProfile> profile(TransitionProfileRequest r, {MixCancelToken? cancel}) =>
      _runInIsolate<TransitionSongProfile, TransitionProfileRequest>(_profileMain, r,
          debugName: 'transition-profile', cancel: cancel);

  @override
  Future<TransitionClipInfo> render(TransitionRenderRequest r, {MixCancelToken? cancel}) =>
      _runInIsolate<TransitionClipInfo, TransitionRenderRequest>(_renderMain, r,
          debugName: 'transition-render', cancel: cancel);
}

/// Canción que el motor puede decodificar: [stamp] cambia cuando cambia el archivo.
class TransitionSongRef {
  const TransitionSongRef({required this.id, required this.playablePath, this.stamp = ''});
  final String id, playablePath, stamp;
}

class TransitionPairAnalysis {
  const TransitionPairAnalysis({required this.outgoing, required this.incoming, required this.suggestion});
  final TransitionSongProfile outgoing, incoming;
  final TransitionSuggestion suggestion;
}

class TransitionClip {
  const TransitionClip({required this.key, required this.wavPath, required this.info});
  final String key, wavPath;
  final TransitionClipInfo info;
}

/// Lo que consume el proveedor; en pruebas se sustituye por un falso.
abstract class TransitionService {
  Future<TransitionPairAnalysis> analyzePair(TransitionSongRef from, TransitionSongRef to, {MixCancelToken? cancel});
  Future<TransitionClip> renderClip(TransitionSongRef from, TransitionSongRef to, SongTransition transition,
      {MixCancelToken? cancel});
  Future<void> invalidateClip(TransitionSongRef from, TransitionSongRef to, SongTransition transition);
}

class TransitionEngine implements TransitionService {
  TransitionEngine({
    required this.decoder,
    required this.backend,
    required this.clipCache,
    required this.profileCache,
    this.existingAnalysis,
  });

  final TransitionSongDecoder decoder;
  final TransitionBackend backend;
  final TransitionClipCache clipCache;
  final TransitionProfileCache profileCache;

  /// Análisis que el Mixer ya guardó para la canción, si lo hay.
  final Future<SongAnalysis?> Function(String songId)? existingAnalysis;

  Future<TransitionDecodedSong> _decode(TransitionSongRef s, MixCancelToken? cancel) async {
    if (s.playablePath.isEmpty) throw const TransitionException(TransitionErrorKind.missingFile);
    try {
      return await decoder.decode(s.id, s.playablePath, cancel: cancel);
    } on MixCancelled {
      throw const TransitionException(TransitionErrorKind.cancelled);
    } on TransitionDecodeException catch (e) {
      throw TransitionException(TransitionErrorKind.decoderFailed, e.message);
    } on FileSystemException {
      throw const TransitionException(TransitionErrorKind.missingFile);
    } catch (e) {
      print('Transición: falló la decodificación (${e.runtimeType})');
      throw const TransitionException(TransitionErrorKind.decoderFailed);
    }
  }

  Future<TransitionSongProfile> profile(TransitionSongRef s, {MixCancelToken? cancel}) async {
    final cached = await profileCache.lookup(s.id, s.stamp);
    if (cached != null) return cached;
    final decoded = await _decode(s, cancel);
    try {
      final p = await backend.profile(
          TransitionProfileRequest(
            songId: s.id,
            stamp: s.stamp,
            pcmPath: decoded.path,
            existingAnalysis: await existingAnalysis?.call(s.id),
          ),
          cancel: cancel);
      await profileCache.save(p);
      return p;
    } on MixCancelled {
      throw const TransitionException(TransitionErrorKind.cancelled);
    } catch (e) {
      print('Transición: falló el análisis (${e.runtimeType})');
      throw const TransitionException(TransitionErrorKind.analysisFailed);
    } finally {
      decoded.dispose();
    }
  }

  @override
  Future<TransitionPairAnalysis> analyzePair(TransitionSongRef from, TransitionSongRef to,
      {MixCancelToken? cancel}) async {
    final out = await profile(from, cancel: cancel);
    final inn = await profile(to, cancel: cancel);
    final suggestion = suggestTransition(
        out: out.analysis, outDurationSec: out.durationSec, inn: inn.analysis, inDurationSec: inn.durationSec);
    return TransitionPairAnalysis(outgoing: out, incoming: inn, suggestion: suggestion);
  }

  @override
  Future<TransitionClip> renderClip(TransitionSongRef from, TransitionSongRef to, SongTransition transition,
      {MixCancelToken? cancel}) async {
    final key = TransitionClipCache.keyFor(transition, from.id, to.id);
    final hit = await clipCache.lookup(key);
    if (hit != null) {
      try {
        return TransitionClip(key: key, wavPath: hit.wavPath, info: TransitionClipInfo.fromJson(hit.meta));
      } catch (_) {
        await clipCache.remove(key);
      }
    }
    final out = await profile(from, cancel: cancel);
    final inn = await profile(to, cancel: cancel);
    final a = await _decode(from, cancel);
    TransitionDecodedSong? b;
    try {
      b = await _decode(to, cancel);
      final tmp = await clipCache.tempWavPath(key);
      final info = await backend.render(
          TransitionRenderRequest(
            outgoingPcmPath: a.path,
            incomingPcmPath: b.path,
            transition: transition,
            wavPath: tmp,
            outBpm: hasUsableTempo(out.analysis) ? out.analysis.bpm : null,
            inBpm: hasUsableTempo(inn.analysis) ? inn.analysis.bpm : null,
          ),
          cancel: cancel);
      final entry = await clipCache.commit(key, info.toJson());
      return TransitionClip(key: key, wavPath: entry.wavPath, info: info);
    } on MixCancelled {
      throw const TransitionException(TransitionErrorKind.cancelled);
    } on TransitionException {
      rethrow;
    } catch (e) {
      print('Transición: falló el renderizado (${e.runtimeType})');
      await clipCache.remove(key);
      throw const TransitionException(TransitionErrorKind.renderFailed);
    } finally {
      a.dispose();
      b?.dispose();
    }
  }

  @override
  Future<void> invalidateClip(TransitionSongRef from, TransitionSongRef to, SongTransition transition) =>
      clipCache.remove(TransitionClipCache.keyFor(transition, from.id, to.id));
}
