import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/audio_identity.dart';
import 'package:heardy/services/file_library_storage.dart';
import 'package:heardy/services/metadata_service.dart';
import 'package:heardy/services/mp4_chunk_offset_fix.dart';

Uint8List _u32(int v) => Uint8List.fromList([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

Uint8List _box(String type, List<int> payload) =>
    Uint8List.fromList([..._u32(8 + payload.length), ...type.codeUnits, ...payload]);

void main() {
  group('MetadataService: topes', () {
    test('no lee tags de archivos por encima del tope', () {
      expect(MetadataService.canReadTags(10 * 1024 * 1024), isTrue);
      expect(MetadataService.canReadTags(-1), isTrue);
      expect(MetadataService.canReadTags(MetadataService.maxTagReadBytes + 1), isFalse);
    });

    test('una carátula vacía o enorme no se guarda', () {
      expect(MetadataService.isReasonableArtwork(0), isFalse);
      expect(MetadataService.isReasonableArtwork(200 * 1024), isTrue);
      expect(MetadataService.isReasonableArtwork(MetadataService.maxArtworkBytes + 1), isFalse);
    });
  });

  group('mp4_chunk_offset_fix: anidamiento anómalo', () {
    test('cajas anidadas sin fin no desbordan la pila ni modifican el archivo', () async {
      final dir = await Directory.systemTemp.createTemp('heardy_mp4_deep_');
      addTearDown(() => dir.delete(recursive: true));

      var nested = _box('stco', List.filled(12, 0));
      for (var i = 0; i < 5000; i++) {
        nested = _box('trak', nested);
      }
      final moov = _box('moov', nested);
      final original = Uint8List.fromList(_box('moov', List.filled(4, 0)));
      final changed = Uint8List.fromList([..._box('ftyp', List.filled(8, 0)), ...moov]);
      final file = File('${dir.path}/deep.m4a')..writeAsBytesSync(changed);

      repairMp4ChunkOffsetsAfterTagWrite(file, original);

      expect(file.readAsBytesSync(), changed);
    });
  });

  group('AudioIdentityService: mdat declarado más grande que el archivo', () {
    test('cae a la identidad del archivo completo en vez de leer fuera de rango', () async {
      final dir = await Directory.systemTemp.createTemp('heardy_mdat_');
      addTearDown(() => dir.delete(recursive: true));

      final ftyp = _box('ftyp', 'M4A isomM4A mp42'.codeUnits);
      final bogusMdat = Uint8List.fromList([..._u32(0x7FFFFFF0), ...'mdat'.codeUnits, ...List.filled(64, 1)]);
      final bytes = Uint8List.fromList([...ftyp, ...bogusMdat]);
      final file = File('${dir.path}/bogus.m4a')..writeAsBytesSync(bytes);

      final identity = await AudioIdentityService(storage: FileLibraryStorage())
          .compute(uri: file.path, length: bytes.length, ext: 'm4a');

      expect(identity.kind, 'raw-file');
    });
  });
}
