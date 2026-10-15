/// Unión aditiva de los archivos de otros dispositivos contra el índice local.
/// Pura: no toca disco ni SQLite. Reutiliza la semántica de la nube
/// (`canonicalizeCloudIndex` + `unionCloudIntoLocalIndex`): empareja por
/// `fileHash`, gana el id local y nada se borra.
library;

import 'folder_sync_format.dart';
import 'library_diff.dart';

class FolderImportPlan {
  /// Playlists que acá no existen (ni por id ni por nombre), con su id remoto.
  final List<Map<String, dynamic>> newPlaylists;

  /// `playlistId` ya es el id local (o el de una playlist nueva); `songId` es
  /// siempre una canción presente acá.
  final List<Map<String, dynamic>> newMemberships;

  /// `songId` local, `playedAtLocal`, `playedAtUtc`, `playSeconds`.
  final List<Map<String, dynamic>> history;

  /// Canciones de otros dispositivos que este equipo no tiene (misma forma que
  /// las filas de la nube, para la pantalla "En tus otros dispositivos").
  final List<Map<String, dynamic>> otherDeviceSongs;

  /// Playlists online por crear o completar (pistas en el orden del archivo,
  /// las propias primero).
  final List<OnlinePlaylistImport> onlinePlaylists;

  /// `videoId`, `playedAtLocal`, `playedAtUtc`, `playSeconds` de pistas que
  /// existirán acá tras materializar; sin repetidos.
  final List<Map<String, dynamic>> remoteHistory;

  const FolderImportPlan({
    required this.newPlaylists,
    required this.newMemberships,
    required this.history,
    required this.otherDeviceSongs,
    this.onlinePlaylists = const [],
    this.remoteHistory = const [],
  });
}

FolderImportPlan planFolderImport({
  required Map<String, List<Map<String, dynamic>>> local,
  required List<FolderSyncSnapshot> snapshots,
  Set<String> localSourceUrls = const {},
}) {
  final remote = canonicalizeCloudIndex(
    [for (final s in snapshots) ...s.songs],
    [for (final s in snapshots) ...s.playlists],
    [for (final s in snapshots) ...s.playlistSongs],
    [for (final s in snapshots) ...s.playlistRemoteTracks],
  );
  final union = unionCloudIntoLocalIndex(
    local: local,
    cloudSongs: remote.songs,
    cloudPlaylists: remote.playlists,
    cloudPlaylistSongs: remote.playlistSongs,
    cloudRemoteTracks: [for (final s in snapshots) ...s.remoteTracks],
    cloudPlaylistRemoteTracks: remote.playlistRemoteTracks,
  );
  final onlinePlaylists = planOnlineMaterialization(local: local, merged: union);

  final localSongs = local['songs'] ?? const [];
  final localSongIds = <String>{};
  final localIdByHash = <String, String>{};
  for (final row in localSongs) {
    final id = row['songId'] as String?;
    if (id == null || id.isEmpty) continue;
    localSongIds.add(id);
    final hash = row['fileHash'] as String?;
    if (hash != null && hash.isNotEmpty) localIdByHash.putIfAbsent(hash, () => id);
  }

  final localPlaylistIds = {
    for (final row in local['playlists'] ?? const [])
      if (row['playlistId'] is String) row['playlistId'] as String,
  };
  final newPlaylists = [
    for (final row in union['playlists']!)
      if (!localPlaylistIds.contains(row['playlistId']) && !isOnlinePlaylistRow(row)) row,
  ];

  final localPairs = {
    for (final row in local['playlistSongs'] ?? const []) '${row['playlistId']} ${row['songId']}',
  };
  final nextOrder = <String, int>{};
  for (final row in local['playlistSongs'] ?? const []) {
    final id = '${row['playlistId']}';
    final order = (row['orderIndex'] as num?)?.toInt() ?? 0;
    final current = nextOrder[id] ?? 0;
    if (order + 1 > current) nextOrder[id] = order + 1;
  }
  final fresh = [
    for (final row in union['playlistSongs']!)
      if (localSongIds.contains(row['songId']) && !localPairs.contains('${row['playlistId']} ${row['songId']}')) row,
  ]..sort((a, b) {
      final byPlaylist = '${a['playlistId']}'.compareTo('${b['playlistId']}');
      if (byPlaylist != 0) return byPlaylist;
      return ((a['orderIndex'] as num?)?.toInt() ?? 0).compareTo((b['orderIndex'] as num?)?.toInt() ?? 0);
    });
  final newMemberships = <Map<String, dynamic>>[];
  for (final row in fresh) {
    final playlistId = row['playlistId'] as String;
    final order = nextOrder[playlistId] ?? 0;
    nextOrder[playlistId] = order + 1;
    newMemberships.add({'playlistId': playlistId, 'songId': row['songId'], 'orderIndex': order});
  }

  final seen = <String>{};
  final history = <Map<String, dynamic>>[];
  for (final snapshot in snapshots) {
    for (final row in snapshot.history) {
      final hash = row['fileHash'] as String?;
      final at = row['playedAtLocal'] as String?;
      if (hash == null || hash.isEmpty || at == null) continue;
      final songId = localIdByHash[hash];
      if (songId == null) continue;
      if (!seen.add('$songId $at')) continue;
      history.add({
        'songId': songId,
        'playedAtLocal': at,
        'playedAtUtc': row['playedAtUtc'],
        'playSeconds': row['playSeconds'] ?? 0,
      });
    }
  }

  final knownVideoIds = {
    for (final row in local['remoteTracks'] ?? const <Map<String, dynamic>>[])
      if (row['videoId'] is String) row['videoId'] as String,
    for (final item in onlinePlaylists)
      for (final track in item.tracks)
        if (track['videoId'] is String) track['videoId'] as String,
  };
  final seenRemote = <String>{};
  final remoteHistory = <Map<String, dynamic>>[];
  for (final snapshot in snapshots) {
    for (final row in snapshot.remoteHistory) {
      final videoId = row['videoId'] as String?;
      final at = row['playedAtLocal'] as String?;
      if (videoId == null || at == null || !knownVideoIds.contains(videoId)) continue;
      if (!seenRemote.add('$videoId $at')) continue;
      remoteHistory.add({
        'videoId': videoId,
        'playedAtLocal': at,
        'playedAtUtc': row['playedAtUtc'],
        'playSeconds': row['playSeconds'] ?? 0,
      });
    }
  }

  final localHashes = localIdByHash.keys.toSet();
  return FolderImportPlan(
    newPlaylists: newPlaylists,
    newMemberships: newMemberships,
    history: history,
    onlinePlaylists: onlinePlaylists,
    remoteHistory: remoteHistory,
    otherDeviceSongs: cloudOnlySongs(
      remote.songs,
      localFileHashes: localHashes,
      localSourceUrls: localSourceUrls,
    ),
  );
}
