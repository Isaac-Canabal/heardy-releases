import 'dart:math';

import '../models/remote_track_record.dart';
import 'audio_player_handler.dart' show shouldRecordPlay;
import 'download_source.dart';

/// Lógica pura de las playlists online, aparte del handler (`just_audio` no
/// tiene doble de test).

enum OnlinePlayResult { started, empty, streamingUnsupported }

class OnlinePlaybackPlan {
  final OnlinePlayResult result;
  final List<RemoteTrack> tracks;
  final String startId;

  /// Ids guardados de la cola: sólo sus escuchas cuentan en estadísticas.
  final Set<String> savedIds;

  const OnlinePlaybackPlan._(this.result, this.tracks, this.startId, this.savedIds);

  const OnlinePlaybackPlan.failure(OnlinePlayResult result) : this._(result, const [], '', const {});
}

/// Mezcla [tracks] sin mutarla; con [startVideoId] presente, esa pista abre la
/// cola y el resto va barajado.
List<RemoteTrackRecord> shuffleFromStart(
  List<RemoteTrackRecord> tracks, {
  String? startVideoId,
  Random? random,
}) {
  final rest = List<RemoteTrackRecord>.of(tracks)..shuffle(random ?? Random());
  final startAt = startVideoId == null ? -1 : rest.indexWhere((t) => t.videoId == startVideoId);
  if (startAt > 0) rest.insert(0, rest.removeAt(startAt));
  return rest;
}

OnlinePlaybackPlan planOnlinePlayback(
  List<RemoteTrackRecord> records, {
  required bool streamingSupported,
  String? startVideoId,
  bool shuffle = false,
  Random? random,
}) {
  if (!streamingSupported) return const OnlinePlaybackPlan.failure(OnlinePlayResult.streamingUnsupported);
  if (records.isEmpty) return const OnlinePlaybackPlan.failure(OnlinePlayResult.empty);

  final ordered = shuffle ? shuffleFromStart(records, startVideoId: startVideoId, random: random) : records;
  final tracks = [for (final r in ordered) r.toRemoteTrack()];
  final startId = tracks.any((t) => t.id == startVideoId) ? startVideoId! : tracks.first.id;
  return OnlinePlaybackPlan._(
    OnlinePlayResult.started,
    tracks,
    startId,
    {for (final r in records) r.videoId},
  );
}

/// Una escucha por streaming cuenta para las estadísticas sólo si la pista es
/// una referencia guardada y se alcanzó el mismo umbral que en las locales.
bool shouldRecordRemotePlay({
  required String videoId,
  required Set<String> savedIds,
  required Duration listened,
  required Duration duration,
}) =>
    savedIds.contains(videoId) && shouldRecordPlay(listened: listened, duration: duration);

/// Nuevo orden de [ids] tras arrastrar con `ReorderableListView` (su
/// [newIndex] cuenta con el elemento aún en su sitio). No muta [ids].
List<String> reorderedIds(List<String> ids, int oldIndex, int newIndex) {
  final result = List<String>.of(ids);
  final target = oldIndex < newIndex ? newIndex - 1 : newIndex;
  result.insert(target, result.removeAt(oldIndex));
  return result;
}
