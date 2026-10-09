// Exercises LibraryScanService's reconciliation against a fake in-memory SAF
// backend, no Android device needed. Uses sqflite_common_ffi so
// DatabaseHelper's real SQLite schema/queries run as-is on desktop, and a
// fake PathProviderPlatform (same pattern as download_smoke_test.dart) so
// MetadataService's temp-copy-and-read step works without a device. See
// CLAUDE.md D2/D3/D5 for the rules this verifies.
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/playlist.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/library_scan_service.dart';
import 'package:heardy/services/storage_service.dart';

import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/saf_library_storage.dart';

import 'fake_saf.dart';

// The SAF fakes live in fake_saf.dart so the identity and download tests can
// share them; these aliases keep the existing test bodies below unchanged.
typedef _FakeSafBackend = FakeSafBackend;
typedef _FakeSafUtil = FakeSafUtil;
typedef _FakeSafStream = FakeSafStream;

/// Same pattern as test/download_smoke_test.dart: MetadataService's only
/// plugin dependency is path_provider (for its temp copy and the extracted
/// thumbnails/ folder), so redirecting both to one sandbox dir is enough to
/// run it under `flutter test` with no device.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

Uint8List _id3v2Header(int tagBodySize) {
  final size = tagBodySize;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, // version 2.3.0
    0x00, // flags: no footer
    (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F, // syncsafe size
    ...List.filled(tagBodySize, 0x00), // padding — the spec's "no more frames" sentinel,
    // safe for both our own header-size skip and a real ID3v2 reader (MetadataService
    // now reads every new file's tags too, as of Stage 2).
  ]);
}

Uint8List _id3v1Trailer() {
  return Uint8List.fromList([0x54, 0x41, 0x47, ...List.filled(125, 0x00)]); // "TAG" + fields
}

Uint8List _buildMp3(Uint8List audioPayload, {required int tagBodySize}) {
  return Uint8List.fromList([
    ..._id3v2Header(tagBodySize),
    ...audioPayload,
    ..._id3v1Trailer(),
  ]);
}

void main() {
  late Directory fixtureDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbPath = join(await databaseFactory.getDatabasesPath(), 'heardy.db');
    await databaseFactory.deleteDatabase(dbPath);

    final sandbox = Directory.systemTemp.createTempSync('heardy_scan_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
    fixtureDir = Directory.systemTemp.createTempSync('heardy_fixtures_');
  });

  test('rename and tag-edit both preserve song identity and playlist membership; missing files are tombstoned, not deleted', () async {
    final backend = _FakeSafBackend();
    final root = backend.addDir(null, 'Heardy');
    final playlistDir = backend.addDir(root, 'MiPlaylist');

    // A loose file directly in the root has no playlist folder — it should
    // land in the library with no playlist_songs row (the future inbox, D6).
    backend.addFile(root, 'suelta.mp3', _buildMp3(Uint8List.fromList(List.filled(200, 0x11)), tagBodySize: 0), 500);

    // A file type outside .mp3/.mp4/.m4a (D4 scope) must be skipped, not crash the scan.
    backend.addFile(playlistDir, 'readme.txt', Uint8List.fromList('not audio'.codeUnits), 500);

    final audioPayload = Uint8List.fromList(List.generate(5000, (i) => (i * 37 + 11) % 256));
    final originalBytes = _buildMp3(audioPayload, tagBodySize: 20);
    var file = backend.addFile(playlistDir, 'cancion.mp3', originalBytes, 1000);

    SafUtilPlatform.instance = _FakeSafUtil(backend);
    SafStreamPlatform.instance = _FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

    final service = LibraryScanService();
    final db = DatabaseHelper.instance;

    // --- 1. First scan: two new songs, one unsupported file skipped.
    var result = await service.scan(root.uri);
    expect(result.inserted, 2);
    expect(result.unsupported, 1);

    var playlists = await db.getPlaylists();
    expect(playlists.map((p) => p.name), ['MiPlaylist']); // loose file didn't create a playlist
    final playlistId = playlists.first.id;

    var playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.length, 1);
    final song = playlistSongs.first;
    expect(song.uri, file.uri);
    expect(song.hashKind, 'mp3-audio');
    expect(song.missing, false);
    final originalId = song.id;
    final originalHash = song.fileHash;

    // --- 2. Second scan, nothing changed: fast path, no re-hash needed.
    result = await service.scan(root.uri);
    expect(result.unchanged, 2);
    expect(result.inserted, 0);
    expect((await db.getSongById(originalId))!.missing, false);

    // --- 3. Rename: SAF gives the file a brand-new document uri, bytes identical.
    backend.unlink(playlistDir, file.uri);
    final renamed = backend.addFile(playlistDir, 'cancion (1).mp3', originalBytes, 1000);
    result = await service.scan(root.uri);
    expect(result.moved, 1);

    var reloaded = await db.getSongById(originalId);
    expect(reloaded, isNotNull, reason: 'the rename must update the existing row, not create a new one');
    expect(reloaded!.uri, renamed.uri);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'playlist membership must survive a rename');

    // --- 4. Tag edit: same uri, tag body grows (e.g. embedded cover art added), audio payload untouched.
    final editedBytes = _buildMp3(audioPayload, tagBodySize: 500);
    final editedFile = backend.files[renamed.uri]!;
    editedFile.bytes = editedBytes;
    editedFile.mtime = 2000;
    result = await service.scan(root.uri);
    expect(result.updated, 1);

    reloaded = await db.getSongById(originalId);
    expect(reloaded!.fileHash, originalHash, reason: 'hashing the audio payload only must survive a tag edit');
    expect(reloaded.fileSize, editedBytes.length);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'playlist membership must survive a tag edit');

    // --- 5. File removed from disk: tombstoned, not deleted.
    backend.unlink(playlistDir, renamed.uri);
    result = await service.scan(root.uri);
    expect(result.missing, greaterThanOrEqualTo(1));

    reloaded = await db.getSongById(originalId);
    expect(reloaded, isNotNull, reason: 'a missing file must be tombstoned, never deleted outright');
    expect(reloaded!.missing, true);
    playlistSongs = await db.getSongsForPlaylist(playlistId);
    expect(playlistSongs.map((s) => s.id), contains(originalId), reason: 'tombstoning must not drop playlist membership');

    // --- 6. File reappears: tombstone clears.
    backend.relink(playlistDir, renamed.uri);
    result = await service.scan(root.uri);
    expect(result.unchanged, greaterThanOrEqualTo(1));
    reloaded = await db.getSongById(originalId);
    expect(reloaded!.missing, false);
  });

  group('metadata extraction (Stage 2, D5)', () {
    test('full tags: uses tag title/artist/album and extracts the embedded cover', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      final playlistDir = backend.addDir(root, 'Favoritas');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final audioPayload = Uint8List.fromList(List.generate(3000, (i) => (i * 13 + 7) % 256));
      final src = File('${fixtureDir.path}/full_tags_src.mp3');
      src.writeAsBytesSync(_buildMp3(audioPayload, tagBodySize: 0));
      final coverBytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
      updateMetadata(src, (m) {
        m.setTitle('Total Eclipse of the Heart');
        m.setArtist('Bonnie Tyler');
        m.setAlbum('Faster Than the Speed of Night');
        m.setPictures([Picture(coverBytes, 'image/jpeg', PictureType.coverFront)]);
      });

      backend.addFile(playlistDir, '01 - cancion cruda.mp3', src.readAsBytesSync(), 1000);

      await LibraryScanService().scan(root.uri);

      final playlist = (await DatabaseHelper.instance.getPlaylists()).firstWhere((p) => p.name == 'Favoritas');
      final songs = await DatabaseHelper.instance.getSongsForPlaylist(playlist.id);
      expect(songs.length, 1);
      final song = songs.first;

      expect(song.title, 'Total Eclipse of the Heart');
      expect(song.artist, 'Bonnie Tyler');
      expect(song.album, 'Faster Than the Speed of Night');
      expect(song.artPath, isNotEmpty);
      expect(File(song.artPath).existsSync(), true, reason: 'the embedded cover must be extracted to a real file');
      expect(File(song.artPath).readAsBytesSync(), coverBytes);
    });

    test('no tags: falls back to parsing "Artist - Título" from the filename, junk stripped', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      final playlistDir = backend.addDir(root, 'SinTags');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final audioPayload = Uint8List.fromList(List.generate(3000, (i) => (i * 19 + 3) % 256));
      final bytes = _buildMp3(audioPayload, tagBodySize: 0); // empty ID3v2 shell, no frames at all

      backend.addFile(
        playlistDir,
        '03 - Bonnie Tyler - Total Eclipse of the Heart [Official Video]_320kbps.mp3',
        bytes,
        1000,
      );

      await LibraryScanService().scan(root.uri);

      final playlist = (await DatabaseHelper.instance.getPlaylists()).firstWhere((p) => p.name == 'SinTags');
      final songs = await DatabaseHelper.instance.getSongsForPlaylist(playlist.id);
      final song = songs.first;

      expect(song.title, 'Total Eclipse of the Heart', reason: 'leading track number and bracket/bitrate junk must be stripped');
      expect(song.artist, 'Bonnie Tyler', reason: 'the "Artist - Title" filename pattern must be recognized');
      expect(song.album, 'SinTags', reason: 'with no album tag, the containing folder name is used');
      expect(song.artPath, isEmpty);
    });

    test('partial tags: tag title wins, missing artist tag falls back to "Desconocido"', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      final playlistDir = backend.addDir(root, 'Parciales');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final audioPayload = Uint8List.fromList(List.generate(3000, (i) => (i * 29 + 5) % 256));
      final src = File('${fixtureDir.path}/partial_tags_src.mp3');
      src.writeAsBytesSync(_buildMp3(audioPayload, tagBodySize: 0));
      updateMetadata(src, (m) {
        m.setTitle('Solo Título En Los Tags');
        // No artist tag set on purpose, and the filename below has no
        // "Artist - Title" pattern either, so it must fall to "Desconocido".
      });

      backend.addFile(playlistDir, 'pista suelta.mp3', src.readAsBytesSync(), 1000);

      await LibraryScanService().scan(root.uri);

      final playlist = (await DatabaseHelper.instance.getPlaylists()).firstWhere((p) => p.name == 'Parciales');
      final songs = await DatabaseHelper.instance.getSongsForPlaylist(playlist.id);
      final song = songs.first;

      expect(song.title, 'Solo Título En Los Tags', reason: 'the present tag field must be used as-is');
      expect(song.artist, 'Desconocido', reason: 'a missing tag field falls back independently, not all-or-nothing');
      expect(song.album, 'Parciales');
    });
  });

  group('inbox (Stage 4, D6)', () {
    test('a loose root file lands in the inbox; ignoring and batch-assigning both remove it', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final payloadA = Uint8List.fromList(List.generate(2000, (i) => (i * 7 + 1) % 256));
      final payloadB = Uint8List.fromList(List.generate(2000, (i) => (i * 11 + 2) % 256));
      backend.addFile(root, 'suelta_a.mp3', _buildMp3(payloadA, tagBodySize: 0), 100);
      backend.addFile(root, 'suelta_b.mp3', _buildMp3(payloadB, tagBodySize: 0), 100);

      await LibraryScanService().scan(root.uri);

      final db = DatabaseHelper.instance;
      final before = await db.getInboxSongs();
      final loose = before.where((s) => s.title == 'suelta_a' || s.title == 'suelta_b').toList();
      expect(loose.length, 2, reason: 'files dropped directly in the root have no playlist and must show up in the inbox');

      final songA = loose.firstWhere((s) => s.title == 'suelta_a');
      final songB = loose.firstWhere((s) => s.title == 'suelta_b');

      // Ignore A: hidden from the inbox from now on, but the row (and file) stay untouched.
      await db.ignoreSongsFromInbox([songA.id]);
      final afterIgnore = await db.getInboxSongs();
      expect(afterIgnore.any((s) => s.id == songA.id), false);
      expect(await db.getSongById(songA.id), isNotNull, reason: 'ignoring must not delete the song');

      // A second scan must NOT bring the ignored song back — the scanner never
      // touches ignoredFromInbox, only the user does.
      await LibraryScanService().scan(root.uri);
      final afterRescan = await db.getInboxSongs();
      expect(afterRescan.any((s) => s.id == songA.id), false, reason: 'an ignored song must not reappear on rescan');
      expect((await db.getIgnoredSongs()).any((s) => s.id == songA.id), true,
          reason: 'an ignored song must be visible in the "Ignoradas" list');

      // Ignoring must be reversible — a dismiss is not a dead end.
      await db.unignoreSongsFromInbox([songA.id]);
      expect((await db.getIgnoredSongs()).any((s) => s.id == songA.id), false);
      expect((await db.getInboxSongs()).any((s) => s.id == songA.id), true,
          reason: 'restoring an ignored song must put it back in the regular inbox');

      // Batch-assign B to a brand new playlist ("crear nueva" path).
      await db.insertPlaylist(Playlist(id: 'pl-new', name: 'NuevaPlaylist', creationDate: DateTime.now()));
      await db.assignSongsToPlaylists([songB.id], ['pl-new']);
      final afterAssign = await db.getInboxSongs();
      expect(afterAssign.any((s) => s.id == songB.id), false, reason: 'an assigned song must leave the inbox');
      final playlistSongs = await db.getSongsForPlaylist('pl-new');
      expect(playlistSongs.map((s) => s.id), contains(songB.id));
    });

    test('an in-app playlist assignment survives a later physical move to a different folder (D3)', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final payload = Uint8List.fromList(List.generate(2000, (i) => (i * 13 + 9) % 256));
      final looseFile = backend.addFile(root, 'huerfana.mp3', _buildMp3(payload, tagBodySize: 0), 100);

      await LibraryScanService().scan(root.uri);

      final db = DatabaseHelper.instance;
      final song = (await db.getInboxSongs()).firstWhere((s) => s.title == 'huerfana');

      await db.insertPlaylist(Playlist(id: 'pl-elegida', name: 'ElegidaPorElUsuario', creationDate: DateTime.now()));
      await db.assignSongsToPlaylists([song.id], ['pl-elegida']);

      // The user now moves the physical file into a DIFFERENT folder, which
      // also happens to be a playlist folder — SAF assigns it a new document
      // uri, same bytes.
      final otraCarpeta = backend.addDir(root, 'OtraCarpeta');
      backend.unlink(root, looseFile.uri);
      backend.addFile(otraCarpeta, 'huerfana.mp3', looseFile.bytes, 100);

      await LibraryScanService().scan(root.uri);

      // The app never writes to disk (only the fake test harness moved the
      // file above, simulating the user doing it via the file explorer) —
      // and the in-app assignment must win: still only in the playlist the
      // user picked, never auto-added to "OtraCarpeta" just because the file
      // now physically sits there.
      final elegida = await db.getSongsForPlaylist('pl-elegida');
      expect(elegida.map((s) => s.id), contains(song.id), reason: "the user's own assignment must survive the move");

      final otraCarpetaPlaylist = (await db.getPlaylists()).firstWhere((p) => p.name == 'OtraCarpeta');
      final otraCarpetaSongs = await db.getSongsForPlaylist(otraCarpetaPlaylist.id);
      expect(otraCarpetaSongs.map((s) => s.id), isNot(contains(song.id)),
          reason: 'a move must never re-assign playlist membership — only a first import does that (D3)');
    });
  });

  group('library root lifecycle (bug fixes 2026-07-31)', () {
    test('picking the already-initialized Heardy folder itself does not nest another Heardy inside it', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _FakeSafBackend();
      final fakeUtil = _FakeSafUtil(backend);
      SafUtilPlatform.instance = fakeUtil;
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
      final storage = StorageService();

      final parent = backend.addDir(null, 'Music');
      fakeUtil.nextPick = SafDocumentFile(uri: parent.uri, name: parent.name, isDir: true, length: 0, lastModified: 0);
      final firstRoot = await storage.pickLibraryRoot();
      expect(firstRoot, isNotNull);

      // User re-runs the picker, navigates INTO the Heardy folder just
      // created, and selects it directly as the "new" root.
      final heardyDir = backend.dirs[firstRoot]!;
      fakeUtil.nextPick = SafDocumentFile(uri: heardyDir.uri, name: heardyDir.name, isDir: true, length: 0, lastModified: 0);
      final secondRoot = await storage.pickLibraryRoot();

      expect(secondRoot, firstRoot, reason: 'picking the Heardy folder itself must resolve to itself, not create Heardy/Heardy');
      final nestedHeardyCount = heardyDir.childUris.where((u) => backend.dirs[u]?.name == 'Heardy').length;
      expect(nestedHeardyCount, 0, reason: 'no nested Heardy/ should exist inside the root');
    });

    test('picking the same parent folder twice does not create two Heardy folders', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _FakeSafBackend();
      final fakeUtil = _FakeSafUtil(backend);
      SafUtilPlatform.instance = fakeUtil;
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
      final storage = StorageService();

      final parent = backend.addDir(null, 'Music2');
      fakeUtil.nextPick = SafDocumentFile(uri: parent.uri, name: parent.name, isDir: true, length: 0, lastModified: 0);
      final first = await storage.pickLibraryRoot();

      // Re-pick the exact same parent again.
      fakeUtil.nextPick = SafDocumentFile(uri: parent.uri, name: parent.name, isDir: true, length: 0, lastModified: 0);
      final second = await storage.pickLibraryRoot();

      expect(second, first, reason: 're-picking the same parent must reuse the existing Heardy/, not create a second one');
      final heardyCount = backend.dirs[parent.uri]!.childUris.where((u) => backend.dirs[u]?.name == 'Heardy').length;
      expect(heardyCount, 1);
    });

    test('a Heardy-named folder without the marker is recognized by name and gets the marker retroactively', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _FakeSafBackend();
      final fakeUtil = _FakeSafUtil(backend);
      SafUtilPlatform.instance = fakeUtil;
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
      final storage = StorageService();

      // A root from before the marker existed: just named "Heardy", no marker file.
      final preExisting = backend.addDir(null, 'Heardy');
      fakeUtil.nextPick =
          SafDocumentFile(uri: preExisting.uri, name: preExisting.name, isDir: true, length: 0, lastModified: 0);

      final root = await storage.pickLibraryRoot();

      expect(root, preExisting.uri, reason: 'a folder literally named Heardy must be used as-is');
      final nestedCount = preExisting.childUris.where((u) => backend.dirs[u]?.name == 'Heardy').length;
      expect(nestedCount, 0);
      final marker =
          preExisting.childUris.map((u) => backend.files[u]).where((f) => f?.name == '.heardy_root').firstOrNull;
      expect(marker, isNotNull, reason: 'the marker must be retrofitted so a future pick recognizes this folder directly');
    });

    test('scan throws LibraryRootUnavailableException and tombstones existing songs when the root is deleted', () async {
      final backend = _FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      final playlistDir = backend.addDir(root, 'PlaylistDeCarpetaBorrada');
      SafUtilPlatform.instance = _FakeSafUtil(backend);
      SafStreamPlatform.instance = _FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final payload = Uint8List.fromList(List.generate(2000, (i) => (i * 3 + 1) % 256));
      backend.addFile(playlistDir, 'cancion.mp3', _buildMp3(payload, tagBodySize: 0), 100);

      final service = LibraryScanService();
      await service.scan(root.uri);

      final db = DatabaseHelper.instance;
      final playlist = (await db.getPlaylists()).firstWhere((p) => p.name == 'PlaylistDeCarpetaBorrada');
      final before = await db.getSongsForPlaylist(playlist.id);
      expect(before.length, 1);
      expect(before.first.missing, false);
      final songId = before.first.id;

      // Simulate the root folder being deleted from the file explorer.
      backend.markDeleted(root.uri);

      await expectLater(() => service.scan(root.uri), throwsA(isA<LibraryRootUnavailableException>()));

      final after = await db.getSongById(songId);
      expect(after, isNotNull, reason: 'songs must survive a deleted root — tombstoned, not removed');
      expect(after!.missing, true,
          reason: 'a deleted root must tombstone every previously-imported song, same mechanism as any other missing file');
      final stillInPlaylist = await db.getSongsForPlaylist(playlist.id);
      expect(stillInPlaylist.map((s) => s.id), contains(songId), reason: 'playlist membership must survive too');
    });
  });
}
