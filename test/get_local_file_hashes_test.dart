// Cubre DatabaseHelper.getLocalFileHashes — el lado local de la comparación
// híbrida de W6 (plan de escritorio / Etapa 16 E-2).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/services/database_helper.dart';

Song _song(String id, {String? fileHash, bool missing = false}) => Song(
      id: id,
      title: id,
      artist: 'Artista',
      duration: 180,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime(2026, 1, 1),
      uri: 'content://fake/$id',
      fileHash: fileHash,
      hashKind: fileHash != null ? 'mp4-mdat' : null,
      missing: missing,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final sandbox = Directory.systemTemp.createTempSync('heardy_hashes_test_');
    await databaseFactory.setDatabasesPath(sandbox.path);
    await databaseFactory.deleteDatabase(join(sandbox.path, 'heardy.db'));
  });

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('songs');
  });

  test('devuelve sólo los hashes de canciones presentes, sin vacíos ni nulos', () async {
    final helper = DatabaseHelper.instance;
    await helper.insertSong(_song('s1', fileHash: 'hash-1'));
    await helper.insertSong(_song('s2', fileHash: 'hash-2'));
    await helper.insertSong(_song('s3', fileHash: null));
    await helper.insertSong(_song('s4', fileHash: 'hash-4', missing: true));

    final hashes = await helper.getLocalFileHashes();

    expect(hashes, {'hash-1', 'hash-2'});
  });

  test('biblioteca vacía devuelve un set vacío', () async {
    expect(await DatabaseHelper.instance.getLocalFileHashes(), isEmpty);
  });
}
