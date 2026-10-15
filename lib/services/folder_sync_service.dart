import 'dart:typed_data';

import '../models/playlist.dart';
import '../models/remote_track_record.dart';
import 'app_log.dart';
import 'database_helper.dart';
import 'folder_sync_format.dart';
import 'folder_sync_merge.dart';
import 'library_storage.dart';

class FolderSyncReport {
  final bool fileWritten;
  final bool backupWritten;
  final int backupsPruned;
  final int filesRead;
  final int filesSkipped;
  final int playlistsAdded;
  final int membershipsAdded;
  final int historyAdded;
  final int otherDeviceSongs;
  final String contentHash;
  final Object? importError;

  const FolderSyncReport({
    this.fileWritten = false,
    this.backupWritten = false,
    this.backupsPruned = 0,
    this.filesRead = 0,
    this.filesSkipped = 0,
    this.playlistsAdded = 0,
    this.membershipsAdded = 0,
    this.historyAdded = 0,
    this.otherDeviceSongs = 0,
    this.contentHash = '',
    this.importError,
  });
}

class FolderSyncWriteException implements Exception {
  final String message;
  const FolderSyncWriteException(this.message);

  @override
  String toString() => 'FolderSyncWriteException: $message';
}

typedef _Applied = ({int playlists, int memberships, int history, int others});

/// Sincronización serverless por carpeta: cada dispositivo escribe SOLO su
/// archivo en `.heardy/devices/` y lee los de los demás; la unión es aditiva.
/// No hay renombrado atómico en [LibraryStorage], así que un archivo a medio
/// escribir lo descarta el lector (JSON inválido) y se relee en la pasada
/// siguiente; tras escribir se verifica el tamaño.
class FolderSyncService {
  final LibraryStorage _storage;
  final DatabaseHelper _db;
  final String deviceId;
  final String deviceLabel;
  final DateTime Function() _clock;

  FolderSyncService({
    required LibraryStorage storage,
    required this.deviceId,
    required this.deviceLabel,
    DatabaseHelper? db,
    DateTime Function()? clock,
  })  : _storage = storage,
        _db = db ?? DatabaseHelper.instance,
        _clock = clock ?? DateTime.now;

  Future<LibraryEntry> _ensureDir(String rootUri, List<String> names) async {
    var uri = rootUri;
    late LibraryEntry entry;
    for (final name in names) {
      entry = await _storage.mkdirp(uri, name);
      uri = entry.uri;
    }
    return entry;
  }

  Future<LibraryEntry?> _findDir(String rootUri, List<String> names) async {
    var uri = rootUri;
    LibraryEntry? entry;
    for (final name in names) {
      entry = await _storage.child(uri, name);
      if (entry == null || !entry.isDir) return null;
      uri = entry.uri;
    }
    return entry;
  }

  Future<FolderSyncSnapshot> buildSnapshot() async {
    final index = await _db.getLibraryIndexRows(includeOnline: true);
    return FolderSyncSnapshot(
      deviceId: deviceId,
      deviceLabel: deviceLabel,
      exportedAtUtc: _clock().toUtc().toIso8601String(),
      songs: index['songs']!,
      playlists: index['playlists']!,
      playlistSongs: index['playlistSongs']!,
      history: await _db.getHistoryRowsForFolderSync(),
      remoteTracks: index['remoteTracks']!,
      playlistRemoteTracks: index['playlistRemoteTracks']!,
      remoteHistory: await _db.getRemotePlayRowsForSync(),
    );
  }

  /// Importa a los demás y exporta el propio. Los dos pasos son
  /// independientes: si importar falla, igualmente se exporta.
  Future<FolderSyncReport> sync(String rootUri, {String? lastExportedHash}) async {
    _Applied? applied;
    var filesRead = 0, filesSkipped = 0;
    Object? importError;
    try {
      final read = await _readOthers(rootUri);
      filesRead = read.snapshots.length;
      filesSkipped = read.skipped;
      applied = await _apply(read.snapshots);
    } catch (e) {
      appLog('FolderSyncService: falló la importación (${e.runtimeType})');
      importError = e;
    }
    final exported = await export(rootUri, lastExportedHash: lastExportedHash);
    return FolderSyncReport(
      fileWritten: exported.fileWritten,
      backupWritten: exported.backupWritten,
      backupsPruned: exported.backupsPruned,
      filesRead: filesRead,
      filesSkipped: filesSkipped,
      playlistsAdded: applied?.playlists ?? 0,
      membershipsAdded: applied?.memberships ?? 0,
      historyAdded: applied?.history ?? 0,
      otherDeviceSongs: applied?.others ?? 0,
      contentHash: exported.contentHash,
      importError: importError,
    );
  }

  Future<FolderSyncReport> export(String rootUri, {String? lastExportedHash}) async {
    final snapshot = await buildSnapshot();
    final hash = snapshotContentHash(snapshot);
    final devices = await _ensureDir(rootUri, [folderSyncRootDirName, folderSyncDevicesDirName]);
    final fileName = deviceFileName(deviceId);
    final existing = await _storage.child(devices.uri, fileName);

    final bytes = encodeSnapshot(snapshot);
    var written = false;
    if (existing == null || hash != lastExportedHash) {
      await _writeVerified(devices.uri, fileName, bytes);
      written = true;
    }

    final backups = await _ensureDir(rootUri, [folderSyncRootDirName, folderSyncBackupsDirName]);
    final backupName = backupFileName(deviceId, _clock());
    var backupWritten = false;
    if (await _storage.child(backups.uri, backupName) == null) {
      await _writeVerified(backups.uri, backupName, bytes, overwrite: false);
      backupWritten = true;
    }
    var pruned = 0;
    final entries = await _storage.list(backups.uri);
    for (final name in backupsToPrune([for (final e in entries) e.name], deviceId)) {
      final entry = entries.firstWhere((e) => e.name == name);
      try {
        await _storage.delete(entry.uri, isDir: false);
        pruned++;
      } catch (e) {
        appLog('FolderSyncService: no se pudo borrar un backup viejo (${e.runtimeType})');
      }
    }

    return FolderSyncReport(
      fileWritten: written,
      backupWritten: backupWritten,
      backupsPruned: pruned,
      contentHash: hash,
    );
  }

  Future<void> _writeVerified(String dirUri, String name, Uint8List bytes, {bool overwrite = true}) async {
    final file = await _storage.writeFileBytes(dirUri, name, 'application/json', bytes, overwrite: overwrite);
    final stat = await _storage.stat(file.uri, isDir: false);
    if (stat == null || stat.length != bytes.length) {
      throw FolderSyncWriteException('la verificación de "$name" falló');
    }
  }

  Future<({List<FolderSyncSnapshot> snapshots, int skipped})> _readOthers(String rootUri) async {
    final devices = await _findDir(rootUri, [folderSyncRootDirName, folderSyncDevicesDirName]);
    if (devices == null) return (snapshots: <FolderSyncSnapshot>[], skipped: 0);
    final own = deviceFileName(deviceId);
    final snapshots = <FolderSyncSnapshot>[];
    var skipped = 0;
    for (final entry in await _storage.list(devices.uri)) {
      if (entry.isDir || !entry.name.toLowerCase().endsWith('.json') || entry.name == own) continue;
      final snapshot = await _readSnapshot(entry);
      if (snapshot == null) {
        skipped++;
      } else if (snapshot.deviceId != deviceId) {
        snapshots.add(snapshot);
      }
    }
    return (snapshots: snapshots, skipped: skipped);
  }

  Future<FolderSyncSnapshot?> _readSnapshot(LibraryEntry entry) async {
    try {
      if (entry.length > folderSyncMaxFileBytes) {
        throw FolderSyncFormatException(FolderSyncErrorKind.tooLarge, '${entry.length} bytes');
      }
      return parseSnapshot(await _storage.readFileBytes(entry.uri));
    } catch (e) {
      final kind = e is FolderSyncFormatException ? e.kind.name : e.runtimeType;
      appLog('FolderSyncService: se omite un archivo de otro dispositivo ($kind)');
      return null;
    }
  }

  /// Canciones que los otros dispositivos tienen y este no. Solo lee.
  Future<List<Map<String, dynamic>>> otherDeviceSongs(String rootUri) async {
    final read = await _readOthers(rootUri);
    if (read.snapshots.isEmpty) return const [];
    final plan = planFolderImport(
      local: await _db.getLibraryIndexRows(includeOnline: true),
      snapshots: read.snapshots,
      localSourceUrls: await _db.getAllLocalSourceUrls(),
    );
    return plan.otherDeviceSongs;
  }

  Future<List<LibraryEntry>> listBackups(String rootUri) async {
    final dir = await _findDir(rootUri, [folderSyncRootDirName, folderSyncBackupsDirName]);
    if (dir == null) return const [];
    final entries = [
      for (final e in await _storage.list(dir.uri))
        if (!e.isDir && e.name.toLowerCase().endsWith('.json')) e,
    ]..sort((a, b) => b.name.compareTo(a.name));
    return entries;
  }

  /// Fusiona un backup elegido con el mismo código que la importación:
  /// nunca pisa ni borra.
  Future<FolderSyncReport> restoreBackup(LibraryEntry backup) async {
    final snapshot = await _readSnapshot(backup);
    if (snapshot == null) {
      throw const FolderSyncFormatException(FolderSyncErrorKind.malformed, 'backup ilegible');
    }
    final applied = await _apply([snapshot]);
    return FolderSyncReport(
      filesRead: 1,
      playlistsAdded: applied.playlists,
      membershipsAdded: applied.memberships,
      historyAdded: applied.history,
      otherDeviceSongs: applied.others,
    );
  }

  /// Fusiona el snapshot de otro dispositivo recibido por un canal ya
  /// autenticado (sincronización por Wi-Fi) con el mismo código que la carpeta.
  Future<FolderSyncReport> applyRemoteSnapshot(FolderSyncSnapshot snapshot) async {
    final applied = await _apply([snapshot]);
    return FolderSyncReport(
      filesRead: 1,
      playlistsAdded: applied.playlists,
      membershipsAdded: applied.memberships,
      historyAdded: applied.history,
      otherDeviceSongs: applied.others,
    );
  }

  Future<_Applied> _apply(List<FolderSyncSnapshot> snapshots) async {
    if (snapshots.isEmpty) return (playlists: 0, memberships: 0, history: 0, others: 0);
    final plan = planFolderImport(
      local: await _db.getLibraryIndexRows(includeOnline: true),
      snapshots: snapshots,
      localSourceUrls: await _db.getAllLocalSourceUrls(),
    );
    final now = _clock();
    for (final row in plan.newPlaylists) {
      await _db.insertPlaylist(Playlist(
        id: row['playlistId'] as String,
        name: row['name'] as String,
        creationDate: now,
        originalUrl: row['originalUrl'] as String?,
      ));
    }
    for (final row in plan.newMemberships) {
      await _db.addSongToPlaylist(
        row['playlistId'] as String,
        row['songId'] as String,
        (row['orderIndex'] as num).toInt(),
      );
    }
    var onlineMemberships = 0;
    for (final item in plan.onlinePlaylists) {
      if (item.isNew) {
        await _db.insertPlaylist(Playlist(
          id: item.playlistId,
          name: item.name,
          creationDate: now,
          originalUrl: item.originalUrl,
          kind: Playlist.kindOnline,
        ));
      }
      onlineMemberships += await _db.addRemoteTracksToPlaylist(
        item.playlistId,
        [for (final track in item.tracks) RemoteTrackRecord.fromMap(track)],
      );
    }
    var history = 0;
    if (plan.history.isNotEmpty) {
      final ctx = await _db.loadRestoreContext();
      history = await _db.insertRestoredPlays(
        plan.history,
        knownSongs: ctx.knownSongs,
        existingKeys: ctx.existingKeys,
      );
    }
    if (plan.remoteHistory.isNotEmpty) {
      history += await _db.insertRestoredRemotePlays(plan.remoteHistory);
    }
    return (
      playlists: plan.newPlaylists.length + plan.onlinePlaylists.where((i) => i.isNew).length,
      memberships: plan.newMemberships.length + onlineMemberships,
      history: history,
      others: plan.otherDeviceSongs.length,
    );
  }
}
