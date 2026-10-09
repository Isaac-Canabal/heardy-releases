import 'dart:io';
import 'dart:typed_data';

/// Arregla un bug real de `audio_metadata_reader` (1.7.1): su `Mp4Writer`
/// reescribe `moov/udta/meta/ilst` con las tags nuevas, cambiando el tamaño
/// de `moov`, pero nunca recalcula `stco`/`co64` (la tabla de offsets de
/// chunks de audio dentro de `mdat`). En un MP4 no fragmentado — justo lo
/// que produce el pipeline de Render, a diferencia del MP4 fragmentado
/// (DASH) que producía el servidor local — eso deja `stco` apuntando a la
/// posición vieja de cada chunk, que tras el resize cae dentro de
/// moov/mdat desplazado: el reproductor busca las muestras de audio en el
/// lugar equivocado y el resultado es silencio o ruido, no un error.
///
/// [originalBytes] debe ser el contenido de [file] tomado ANTES de llamar a
/// `updateMetadata`. La corrección es un no-op seguro si no se puede
/// interpretar la estructura del archivo, o si el tamaño no cambió.
/// Tope de tamaño (y de anidamiento) para no cargar en memoria ni recorrer
/// sin límite un archivo anómalo; por encima se deja el archivo como está.
const int maxMp4RepairBytes = 512 * 1024 * 1024;
const int _maxBoxDepth = 12;

void repairMp4ChunkOffsetsAfterTagWrite(File file, Uint8List originalBytes) {
  if (originalBytes.length > maxMp4RepairBytes) return;
  final originalMoovEnd = _findTopLevelBoxEnd(originalBytes, 'moov');
  if (originalMoovEnd == null) return;

  if (file.lengthSync() > maxMp4RepairBytes) return;
  final newBytes = file.readAsBytesSync();
  final delta = newBytes.length - originalBytes.length;
  if (delta == 0) return;

  final moov = _findTopLevelBox(newBytes, 'moov');
  if (moov == null) return;

  const containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'meta'};
  final offsetBoxes = _findBoxesRecursive(
    newBytes,
    moov.start,
    moov.end,
    const {'stco', 'co64'},
    containers,
  );
  if (offsetBoxes.isEmpty) return;

  final bd = ByteData.sublistView(newBytes);
  var patched = false;

  for (final box in offsetBoxes) {
    final entryCountOffset = box.start + 8 + 4; // header(8) + version/flags(4)
    if (entryCountOffset + 4 > box.end) continue;
    final entryCount = bd.getUint32(entryCountOffset);
    final entriesStart = entryCountOffset + 4;
    final entrySize = box.type == 'co64' ? 8 : 4;

    for (var i = 0; i < entryCount; i++) {
      final entryOffset = entriesStart + i * entrySize;
      if (entryOffset + entrySize > box.end) break;

      final oldValue = box.type == 'co64'
          ? bd.getUint64(entryOffset)
          : bd.getUint32(entryOffset);
      // Un chunk que ya vivía antes del moov original (mdat delante de
      // moov, poco común pero válido) no se desplazó — solo se movió lo
      // que estaba en o después de donde terminaba el moov viejo.
      if (oldValue < originalMoovEnd) continue;

      final newValue = oldValue + delta;
      if (box.type == 'co64') {
        bd.setUint64(entryOffset, newValue);
      } else {
        bd.setUint32(entryOffset, newValue);
      }
      patched = true;
    }
  }

  if (patched) {
    file.writeAsBytesSync(newBytes);
  }
}

class _Box {
  final String type;
  final int start;
  final int size;
  _Box(this.type, this.start, this.size);
  int get end => start + size;
}

_Box? _findTopLevelBox(Uint8List bytes, String type) {
  final matches = _findBoxesRecursive(bytes, 0, bytes.length, {type}, const {});
  return matches.isEmpty ? null : matches.first;
}

int? _findTopLevelBoxEnd(Uint8List bytes, String type) {
  final box = _findTopLevelBox(bytes, type);
  return box?.end;
}

/// Recorre boxes ISO-BMFF entre [start] y [end]. Cualquier box cuyo `type`
/// esté en [targetTypes] se agrega al resultado; cualquier box cuyo `type`
/// esté en [containerTypes] se recorre recursivamente buscando más
/// coincidencias dentro. Tamaños de box no estándar (0 = hasta fin de
/// archivo, 1 = largesize de 64 bits) no aparecen en audio descargado por
/// yt-dlp — si se encuentran, se corta el recorrido en ese punto en vez de
/// arriesgar una lectura mal alineada.
List<_Box> _findBoxesRecursive(
  Uint8List bytes,
  int start,
  int end,
  Set<String> targetTypes,
  Set<String> containerTypes, [
  int depth = 0,
]) {
  final found = <_Box>[];
  if (depth > _maxBoxDepth) return found;
  var offset = start;
  final bd = ByteData.sublistView(bytes);

  while (offset + 8 <= end) {
    final size = bd.getUint32(offset);
    if (size < 8 || offset + size > end) break;
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

    if (targetTypes.contains(type)) {
      found.add(_Box(type, offset, size));
    }
    if (containerTypes.contains(type)) {
      // 'meta' lleva 4 bytes de version/flags antes de sus hijos; el resto
      // de los contenedores que nos interesan (moov/trak/mdia/minf/stbl/udta)
      // son hijos directos tras el header de 8 bytes.
      final childStart = type == 'meta' ? offset + 12 : offset + 8;
      found.addAll(
        _findBoxesRecursive(bytes, childStart, offset + size, targetTypes, containerTypes, depth + 1),
      );
    }

    offset += size;
  }

  return found;
}
