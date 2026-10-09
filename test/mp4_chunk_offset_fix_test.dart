// `audio_metadata_reader` 1.7.1 reescribe `moov/udta/meta/ilst` con las tags
// nuevas pero nunca recalcula `stco`/`co64` cuando eso cambia el tamaño de
// `moov`. En un MP4 no fragmentado (justo lo que produce el pipeline de
// Render, a diferencia del MP4 fragmentado que producía el servidor local)
// eso deja `stco` apuntando a la posición vieja de cada chunk de audio, que
// tras el resize cae dentro de moov/mdat desplazado: silencio o ruido, no un
// error. Confirmado descargando un archivo real desde Render e inspeccionando
// sus bytes a mano antes de escribir este fix — ver la sesión que lo encontró.
//
// Estos tests construyen los bytes "antes"/"después" a mano en vez de pasar
// por la librería real, siguiendo la misma razón que ya dejó
// download_service_test.dart: su fixture .m4a sintética no es parseable por
// audio_metadata_reader, así que ejercitar la escritura real de tags no es
// viable aquí. Lo que se prueba es la función de reparación en sí, que es
// pura y no depende de esa librería.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/mp4_chunk_offset_fix.dart';

Uint8List _u32(int value) => Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);

Uint8List _u64(int value) {
  final bytes = ByteData(8);
  bytes.setUint64(0, value);
  return bytes.buffer.asUint8List();
}

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([..._u32(size), ...type.codeUnits, ...payload]);
}

/// stco con una sola entrada, apuntando a [offset].
Uint8List _stco(int offset) => _box('stco', [
      ..._u32(0), // version+flags
      ..._u32(1), // entry_count
      ..._u32(offset),
    ]);

Uint8List _co64(int offset) => _box('co64', [
      ..._u32(0),
      ..._u32(1),
      ..._u64(offset),
    ]);

/// `moov` mínimo con el camino real que recorre el fix:
/// moov > trak > mdia > minf > stbl > stco.
Uint8List _moov(Uint8List stcoOrCo64) {
  final stbl = _box('stbl', stcoOrCo64);
  final minf = _box('minf', stbl);
  final mdia = _box('mdia', minf);
  final trak = _box('trak', mdia);
  return _box('moov', trak);
}

Uint8List _buildFile({required Uint8List moov, required List<int> mdatPayload}) {
  final ftyp = _box('ftyp', 'M4A isomM4A mp42'.codeUnits);
  final mdat = _box('mdat', mdatPayload);
  return Uint8List.fromList([...ftyp, ...moov, ...mdat]);
}

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mp4_offset_fix_test_');
  });

  tearDown(() {
    sandbox.deleteSync(recursive: true);
  });

  test('repara stco cuando moov creció al escribir tags (el bug real de Render)', () {
    final payload = List.generate(2000, (i) => (i * 7 + 1) % 256);

    // "Antes": stco apunta correctamente al inicio real de mdat.
    final ftypLen = 8 + 'M4A isomM4A mp42'.length;
    final moovBefore = _moov(_stco(0)); // offset se corrige después de saber su tamaño real
    final mdatStart = ftypLen + moovBefore.length;
    final mdatContentStart = mdatStart + 8;
    final moovFixed = _moov(_stco(mdatContentStart));
    final originalBytes = _buildFile(moov: moovFixed, mdatPayload: payload);

    // "Después": el writer real de audio_metadata_reader creció moov (aquí,
    // simulando 54 bytes de tags nuevas) pero dejó stco con el valor viejo —
    // exactamente el bug reproducido contra el archivo real de Render.
    const delta = 54;
    final grownMoov = _box('trak', [
      ..._box('mdia', [
        ..._box('minf', [
          ..._box('stbl', _stco(mdatContentStart)), // valor viejo, sin corregir
        ]),
      ]),
      ...List.filled(delta, 0), // relleno para que moov crezca exactamente delta
    ]);
    final buggyMoov = _box('moov', grownMoov);
    expect(buggyMoov.length, moovFixed.length + delta,
        reason: 'el fixture debe simular exactamente el mismo delta que se está probando');
    final buggyBytes = _buildFile(moov: buggyMoov, mdatPayload: payload);

    final file = File('${sandbox.path}/buggy.m4a')..writeAsBytesSync(buggyBytes);

    repairMp4ChunkOffsetsAfterTagWrite(file, originalBytes);

    final repaired = file.readAsBytesSync();
    // stco debe apuntar ahora al inicio real de mdat en el archivo reparado,
    // no al offset viejo (que ahora cae dentro de moov/udta desplazado).
    final expectedOffset = mdatContentStart + delta;
    final stcoValueOffset = _findFirstStcoEntryOffset(repaired);
    final actualOffset = ByteData.sublistView(repaired).getUint32(stcoValueOffset);
    expect(actualOffset, expectedOffset);

    // Y en esa posición corregida vive de verdad el payload original, byte a
    // byte — no basta con que el número cuadre, tiene que apuntar al audio.
    final atCorrectedOffset = repaired.sublist(actualOffset, actualOffset + payload.length);
    expect(atCorrectedOffset, payload);
  });

  test('no toca nada si moov no cambió de tamaño (delta 0)', () {
    final payload = List.generate(500, (i) => i % 256);
    final ftypLen = 8 + 'M4A isomM4A mp42'.length;
    final moov = _moov(_stco(0));
    final mdatContentStart = ftypLen + moov.length + 8;
    final moovFixed = _moov(_stco(mdatContentStart));
    final bytes = _buildFile(moov: moovFixed, mdatPayload: payload);

    final file = File('${sandbox.path}/unchanged.m4a')..writeAsBytesSync(bytes);
    final before = file.readAsBytesSync();

    repairMp4ChunkOffsetsAfterTagWrite(file, bytes);

    expect(file.readAsBytesSync(), before, reason: 'sin cambio de tamaño no hay nada que reparar');
  });

  test('co64 (offsets de 64 bits) se repara igual que stco', () {
    final payload = List.generate(1500, (i) => (i * 13 + 4) % 256);
    final ftypLen = 8 + 'M4A isomM4A mp42'.length;
    final moovBefore = _moov(_co64(0));
    final mdatContentStart = ftypLen + moovBefore.length + 8;
    final moovFixed = _moov(_co64(mdatContentStart));
    final originalBytes = _buildFile(moov: moovFixed, mdatPayload: payload);

    const delta = 30;
    final grownMoov = _box('trak', [
      ..._box('mdia', [
        ..._box('minf', [
          ..._box('stbl', _co64(mdatContentStart)), // valor viejo
        ]),
      ]),
      ...List.filled(delta, 0),
    ]);
    final buggyMoov = _box('moov', grownMoov);
    expect(buggyMoov.length, moovFixed.length + delta);
    final buggyBytes = _buildFile(moov: buggyMoov, mdatPayload: payload);

    final file = File('${sandbox.path}/buggy_co64.m4a')..writeAsBytesSync(buggyBytes);

    repairMp4ChunkOffsetsAfterTagWrite(file, originalBytes);

    final repaired = file.readAsBytesSync();
    final stcoValueOffset = _findFirstCo64EntryOffset(repaired);
    final actualOffset = ByteData.sublistView(repaired).getUint64(stcoValueOffset);
    expect(actualOffset, mdatContentStart + delta);
  });
}

int _findFirstStcoEntryOffset(Uint8List bytes) {
  final idx = _indexOfBoxType(bytes, 'stco');
  return idx + 8 + 4 + 4; // header + version/flags + entry_count
}

int _findFirstCo64EntryOffset(Uint8List bytes) {
  final idx = _indexOfBoxType(bytes, 'co64');
  return idx + 8 + 4 + 4;
}

int _indexOfBoxType(Uint8List bytes, String type) {
  final needle = type.codeUnits;
  for (var i = 0; i + 4 <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < 4; j++) {
      if (bytes[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i - 4; // el tipo empieza 4 bytes después del inicio del box
  }
  throw StateError('no se encontró el box $type');
}
