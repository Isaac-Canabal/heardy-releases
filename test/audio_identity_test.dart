// Verifies AudioIdentityService — the code the scanner and the downloader
// share so both agree on what a song *is*. See CLAUDE.md D2.
//
// The assertion that matters most for the download branch is the last one in
// the first group: the hash a scan persists in `songs.fileHash` must be
// exactly what AudioIdentityService.compute() returns when called directly.
// If those ever diverge, every download re-inserts itself as a duplicate on
// the next scan and silently loses its playlist membership.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/services/audio_identity.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/library_scan_service.dart';

import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/saf_library_storage.dart';

import 'fake_saf.dart';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// One top-level MP4 box: 4-byte big-endian size (header included) + 4-byte
/// type + payload.
Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

/// A minimal but structurally valid `.m4a`: `ftyp`, the tag box (`moov`) and
/// the audio payload (`mdat`). [moovFirst] flips the order because D2 notes
/// that MP4 metadata may sit before *or* after `mdat` — the payload hash must
/// not care either way.
Uint8List _buildM4a(Uint8List audioPayload, {required int moovSize, bool moovFirst = true}) {
  final ftyp = _box('ftyp', 'M4A isomM4A mp42'.codeUnits);
  final moov = _box('moov', List.filled(moovSize, 0x00));
  final mdat = _box('mdat', audioPayload);
  return Uint8List.fromList([
    ...ftyp,
    if (moovFirst) ...moov,
    ...mdat,
    if (!moovFirst) ...moov,
  ]);
}

Uint8List _id3v2Header(int tagBodySize) {
  final size = tagBodySize;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, // version 2.3.0
    0x00, // flags: no footer
    (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F,
    ...List.filled(tagBodySize, 0x00),
  ]);
}

Uint8List _buildMp3(Uint8List audioPayload, {required int tagBodySize}) {
  return Uint8List.fromList([
    ..._id3v2Header(tagBodySize),
    ...audioPayload,
    0x54, 0x41, 0x47, ...List.filled(125, 0x00), // ID3v1 "TAG" trailer
  ]);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Its own databases dir, not the shared default: `flutter test` runs test
    // files concurrently, and library_scan_service_test.dart deletes and
    // recreates `heardy.db` in setUpAll too.
    final dbDir = Directory.systemTemp.createTempSync('heardy_identity_db_');
    await databaseFactory.setDatabasesPath(dbDir.path);
    await databaseFactory.deleteDatabase(join(dbDir.path, 'heardy.db'));

    final sandbox = Directory.systemTemp.createTempSync('heardy_identity_test_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
  });

  group('AudioIdentityService', () {
    test('m4a: identity comes from the mdat payload, so tag edits and box order do not change it', () async {
      final backend = FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      SafUtilPlatform.instance = FakeSafUtil(backend);
      SafStreamPlatform.instance = FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final audio = Uint8List.fromList(List.generate(9000, (i) => (i * 53 + 7) % 256));
      final identity = AudioIdentityService();

      final small = backend.addFile(root, 'a.m4a', _buildM4a(audio, moovSize: 40), 100);
      final baseline = await identity.compute(uri: small.uri, length: small.bytes.length, ext: 'm4a');
      expect(baseline.kind, 'mp4-mdat');

      // Same audio, much bigger tag box (e.g. cover art embedded).
      final tagged = backend.addFile(root, 'b.m4a', _buildM4a(audio, moovSize: 4000), 100);
      final afterTagEdit = await identity.compute(uri: tagged.uri, length: tagged.bytes.length, ext: 'm4a');
      expect(afterTagEdit.hash, baseline.hash,
          reason: 'growing the moov box must not change identity — that is the whole point of hashing mdat');

      // Same audio, moov written after mdat instead of before it.
      final reordered = backend.addFile(root, 'c.m4a', _buildM4a(audio, moovSize: 40, moovFirst: false), 100);
      final afterReorder = await identity.compute(uri: reordered.uri, length: reordered.bytes.length, ext: 'm4a');
      expect(afterReorder.hash, baseline.hash,
          reason: 'D2: MP4 metadata may sit before or after mdat; the payload hash must not care');

      // Different audio must not collide.
      final other = Uint8List.fromList(List.generate(9000, (i) => (i * 53 + 8) % 256));
      final different = backend.addFile(root, 'd.m4a', _buildM4a(other, moovSize: 40), 100);
      final differentIdentity =
          await identity.compute(uri: different.uri, length: different.bytes.length, ext: 'm4a');
      expect(differentIdentity.hash, isNot(baseline.hash));
    });

    test('unparseable container falls back to raw-file rather than throwing', () async {
      final backend = FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      SafUtilPlatform.instance = FakeSafUtil(backend);
      SafStreamPlatform.instance = FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      // No ftyp/moov/mdat structure at all — the box walker finds no mdat.
      final junk = backend.addFile(root, 'roto.m4a', Uint8List.fromList(List.filled(300, 0x5A)), 100);
      final result = await AudioIdentityService()
          .compute(uri: junk.uri, length: junk.bytes.length, ext: 'm4a');
      expect(result.kind, 'raw-file');
      expect(result.hash, isNotEmpty);
    });

    test('extensionOf lowercases and audioExtensions gates the same set the scanner uses', () {
      expect(AudioIdentityService.extensionOf('Canción.M4A'), 'm4a');
      expect(AudioIdentityService.extensionOf('sin punto'), '');
      expect(AudioIdentityService.audioExtensions, {'mp3', 'mp4', 'm4a'});
    });

    test('a scan persists exactly the hash compute() returns — scanner and downloader must not diverge', () async {
      final backend = FakeSafBackend();
      final root = backend.addDir(null, 'Heardy');
      final playlistDir = backend.addDir(root, 'IdentidadCompartida');
      SafUtilPlatform.instance = FakeSafUtil(backend);
      SafStreamPlatform.instance = FakeSafStream(backend);
      debugOverrideLibraryStorageForTests(() => SafLibraryStorage());

      final m4aFile = backend.addFile(
        playlistDir,
        'pista.m4a',
        _buildM4a(Uint8List.fromList(List.generate(7000, (i) => (i * 29 + 3) % 256)), moovSize: 64),
        1000,
      );
      final mp3File = backend.addFile(
        playlistDir,
        'pista.mp3',
        _buildMp3(Uint8List.fromList(List.generate(6000, (i) => (i * 31 + 5) % 256)), tagBodySize: 32),
        1000,
      );

      final result = await LibraryScanService().scan(root.uri);
      expect(result.inserted, 2);

      final identity = AudioIdentityService();
      final db = DatabaseHelper.instance;

      for (final entry in {m4aFile: 'mp4-mdat', mp3File: 'mp3-audio'}.entries) {
        final file = entry.key;
        final expectedKind = entry.value;
        final direct = await identity.compute(
          uri: file.uri,
          length: file.bytes.length,
          ext: AudioIdentityService.extensionOf(file.name),
        );
        final stored = await db.getSongByUri(file.uri);

        expect(stored, isNotNull, reason: '${file.name} should have been inserted by the scan');
        expect(direct.kind, expectedKind);
        expect(stored!.hashKind, direct.kind);
        expect(stored.fileHash, direct.hash,
            reason: 'the downloader computes identity this way; the scanner must agree byte for byte');
        expect(stored.id, direct.hash, reason: 'imported songs are content-addressed by their payload hash');
      }
    });
  });
}
