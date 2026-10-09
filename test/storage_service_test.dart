// Verifica que borrar una playlist también borre su carpeta física cuando
// quedó vacía, y que nunca toque una carpeta con contenido — ver CLAUDE.md,
// "Playlists live in SQLite; folders are an import mechanism only".
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import 'package:heardy/services/library_storage.dart';
import 'package:heardy/services/saf_library_storage.dart';
import 'package:heardy/services/storage_service.dart';

import 'fake_saf.dart';

void main() {
  late FakeSafBackend backend;
  late StorageService storage;
  late String rootUri;

  setUp(() {
    backend = FakeSafBackend();
    SafUtilPlatform.instance = FakeSafUtil(backend);
    SafStreamPlatform.instance = FakeSafStream(backend);
    debugOverrideLibraryStorageForTests(() => SafLibraryStorage());
    storage = StorageService();
    rootUri = backend.addDir(null, 'Heardy').uri;
  });

  test('borra la carpeta si quedó vacía', () async {
    await storage.resolvePlaylistFolder(rootUri, 'Para correr');
    expect(await storage.listChildren(rootUri), hasLength(1));

    await storage.deletePlaylistFolderIfEmpty(rootUri, 'Para correr');

    expect(await storage.listChildren(rootUri), isEmpty);
  });

  test('no borra una carpeta que todavía tiene un archivo', () async {
    final folderUri = await storage.resolvePlaylistFolder(rootUri, 'Para correr');
    backend.addFile(backend.dirs[folderUri]!, 'cancion.mp3', Uint8List(0), 0);

    await storage.deletePlaylistFolderIfEmpty(rootUri, 'Para correr');

    expect(await storage.listChildren(rootUri), hasLength(1));
  });

  test('no falla si la carpeta nunca existió (playlist sin descargas)', () async {
    await storage.deletePlaylistFolderIfEmpty(rootUri, 'Playlist vacía');
    expect(await storage.listChildren(rootUri), isEmpty);
  });
}
