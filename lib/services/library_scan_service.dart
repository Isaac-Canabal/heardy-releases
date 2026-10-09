import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import 'audio_identity.dart';
import 'database_helper.dart';
import 'library_storage.dart';
import 'metadata_service.dart';

/// Scans the SAF-backed library folder into SQLite. See CLAUDE.md D2/D3 for
/// the reconciliation rules this implements — do not re-derive them here.
class LibraryScanResult {
  final int inserted;
  final int moved;
  final int updated;
  final int unchanged;
  final int unsupported;
  final int missing;

  const LibraryScanResult({
    required this.inserted,
    required this.moved,
    required this.updated,
    required this.unchanged,
    required this.unsupported,
    required this.missing,
  });
}

/// Thrown when the library root itself can't be listed — deleted from the
/// file explorer, its volume unmounted, or its permission revoked. The
/// caller should offer re-picking a folder rather than showing a raw
/// platform error.
class LibraryRootUnavailableException implements Exception {
  final String message;
  const LibraryRootUnavailableException([this.message = 'La carpeta de la biblioteca ya no está disponible']);

  @override
  String toString() => message;
}

enum _FileOutcome { inserted, moved, updated, unchanged, unsupported }

class LibraryScanService {
  final LibraryStorage _storage;
  final DatabaseHelper _db = DatabaseHelper.instance;
  final MetadataService _metadataService = MetadataService();
  final AudioIdentityService _identity = AudioIdentityService();

  LibraryScanService({LibraryStorage? storage}) : _storage = storage ?? defaultLibraryStorage();

  Future<LibraryScanResult> scan(String libraryRootUri) async {
    // Tombstone first: if the root itself turns out to be gone (below),
    // every previously-imported song is already correctly marked missing
    // by the time we find out — nothing left to un-tombstone it.
    await _db.markAllImportedSongsMissing();

    var inserted = 0, moved = 0, updated = 0, unchanged = 0, unsupported = 0;

    final playlistIdByName = <String, String>{};
    for (final playlist in await _db.getPlaylists()) {
      playlistIdByName[playlist.name] = playlist.id;
    }

    List<LibraryEntry> rootChildren;
    try {
      rootChildren = await _storage.list(libraryRootUri);
    } catch (e) {
      throw LibraryRootUnavailableException(
        'No se pudo acceder a la carpeta de la biblioteca: $e',
      );
    }
    for (final entry in rootChildren) {
      if (entry.isDir) {
        final playlistId = await _resolvePlaylistId(entry.name, playlistIdByName);
        final children = await _storage.list(entry.uri);
        for (final file in children) {
          if (file.isDir) continue; // nested subfolders aren't supported
          final outcome = await _reconcileFile(file, playlistId: playlistId, album: entry.name);
          switch (outcome) {
            case _FileOutcome.inserted:
              inserted++;
            case _FileOutcome.moved:
              moved++;
            case _FileOutcome.updated:
              updated++;
            case _FileOutcome.unchanged:
              unchanged++;
            case _FileOutcome.unsupported:
              unsupported++;
          }
        }
      } else {
        // Loose file directly in the library root: imported with no
        // playlist, so it lands in the inbox (D6).
        final outcome = await _reconcileFile(entry, playlistId: null, album: null);
        switch (outcome) {
          case _FileOutcome.inserted:
            inserted++;
          case _FileOutcome.moved:
            moved++;
          case _FileOutcome.updated:
            updated++;
          case _FileOutcome.unchanged:
            unchanged++;
          case _FileOutcome.unsupported:
            unsupported++;
        }
      }
    }

    final missing = await _db.getMissingImportedSongCount();
    return LibraryScanResult(
      inserted: inserted,
      moved: moved,
      updated: updated,
      unchanged: unchanged,
      unsupported: unsupported,
      missing: missing,
    );
  }

  Future<String> _resolvePlaylistId(String name, Map<String, String> cache) async {
    final cached = cache[name];
    if (cached != null) return cached;
    final id = const Uuid().v4();
    await _db.insertPlaylist(Playlist(id: id, name: name, creationDate: DateTime.now()));
    cache[name] = id;
    return id;
  }

  Future<_FileOutcome> _reconcileFile(
    LibraryEntry file, {
    required String? playlistId,
    required String? album,
  }) async {
    final ext = AudioIdentityService.extensionOf(file.name);
    if (!AudioIdentityService.audioExtensions.contains(ext)) return _FileOutcome.unsupported;

    // Matcher 1: same URI as last scan (D2). Covers the common no-change
    // case (skip hashing entirely) and in-place tag edits (same file,
    // different size/mtime).
    final existingByUri = await _db.getSongByUri(file.uri);
    if (existingByUri != null) {
      if (existingByUri.fileSize == file.length && existingByUri.modifiedAt == file.lastModified) {
        await _db.touchSongFound(
          existingByUri.id,
          uri: file.uri,
          fileSize: file.length,
          modifiedAt: file.lastModified,
        );
        return _FileOutcome.unchanged;
      }

      // Content changed under the same uri (typically a tag edit) — re-read
      // both the audio hash and the tags, since this is the one moment a
      // refresh is actually warranted (D5: cache once, but a real edit is
      // not "once" yet).
      final hash = await _identity.compute(
        uri: file.uri,
        length: file.length,
        ext: ext,
        debugName: file.name,
      );
      final meta = await _metadataService.extract(
        uri: file.uri,
        fileName: file.name,
        songId: existingByUri.id,
        folderAlbum: album,
      );
      await _db.touchSongFound(
        existingByUri.id,
        uri: file.uri,
        fileSize: file.length,
        modifiedAt: file.lastModified,
        fileHash: hash.hash,
        hashKind: hash.kind,
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        duration: meta.durationSeconds,
        artPath: meta.artPath.isNotEmpty ? meta.artPath : null,
      );
      return _FileOutcome.updated;
    }

    // Matcher 2: unknown URI, but the audio payload matches an existing
    // row (D2) — a move or rename. Playlist membership is left untouched;
    // per D3 the folder only assigns a playlist on first insert. Tags
    // aren't re-read: the audio payload — and therefore, ordinarily, its
    // tags — is unchanged from what's already cached.
    final hash = await _identity.compute(
      uri: file.uri,
      length: file.length,
      ext: ext,
      debugName: file.name,
    );
    final existingByHash = await _db.getSongByHash(hash.hash);
    if (existingByHash != null) {
      await _db.touchSongFound(
        existingByHash.id,
        uri: file.uri,
        fileSize: file.length,
        modifiedAt: file.lastModified,
        fileHash: hash.hash,
        hashKind: hash.kind,
      );
      return _FileOutcome.moved;
    }

    // Genuinely new song: read tags once now, cache the result in songs,
    // and never touch the file for metadata again (D5).
    final meta = await _metadataService.extract(
      uri: file.uri,
      fileName: file.name,
      songId: hash.hash,
      folderAlbum: album,
    );
    final song = Song(
      id: hash.hash,
      title: meta.title,
      artist: meta.artist,
      duration: meta.durationSeconds,
      filePath: '',
      artPath: meta.artPath,
      format: ext,
      downloadDate: DateTime.now(),
      uri: file.uri,
      fileHash: hash.hash,
      hashKind: hash.kind,
      fileSize: file.length,
      modifiedAt: file.lastModified,
      album: meta.album,
    );
    await _db.insertSong(song);

    if (playlistId != null) {
      final maxOrder = await _db.getMaxOrderForPlaylist(playlistId) ?? -1;
      await _db.addSongToPlaylist(playlistId, song.id, maxOrder + 1);
    }

    return _FileOutcome.inserted;
  }

}
