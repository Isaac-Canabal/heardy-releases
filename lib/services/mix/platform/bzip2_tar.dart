// Descompresor bzip2 y lector tar mínimos, en Dart puro, para instalar el
// modelo de Spleeter (el release oficial solo lo publica como .tar.bz2 y la app
// no lleva `package:archive`). El archivo se trata como no confiable: ya se
// verificó su SHA-256 antes de llegar aquí, y aun así solo se extraen los
// nombres base pedidos, siempre dentro de [destDir], y luego se verifica el hash
// de cada archivo extraído. No comprueba los CRC de bzip2 (lo cubre el SHA-256).
import 'dart:io';
import 'dart:typed_data';

class _Bits {
  _Bits(this._d);
  final Uint8List _d;
  int _pos = 0;
  int _buf = 0;
  int _n = 0;

  int bits(int k) {
    while (_n < k) {
      if (_pos >= _d.length) throw const FormatException('bzip2 truncado');
      _buf = ((_buf << 8) | _d[_pos++]) & 0xffffffff;
      _n += 8;
    }
    _n -= k;
    return (_buf >> _n) & ((1 << k) - 1);
  }

  int bit() => bits(1);

  void alignToByte() => _n -= _n % 8;

  bool get atEnd => _pos >= _d.length && _n < 8;
}

const _maxCodeLen = 20;

class _Huffman {
  _Huffman(List<int> lengths) {
    final n = lengths.length;
    minLen = lengths.reduce((a, b) => a < b ? a : b);
    maxLen = lengths.reduce((a, b) => a > b ? a : b);
    perm = Int32List(n);
    var pp = 0;
    for (var i = minLen; i <= maxLen; i++) {
      for (var j = 0; j < n; j++) {
        if (lengths[j] == i) perm[pp++] = j;
      }
    }
    final base0 = Int32List(_maxCodeLen + 2);
    for (final l in lengths) {
      base0[l + 1]++;
    }
    for (var i = 1; i < base0.length; i++) {
      base0[i] += base0[i - 1];
    }
    limit = Int32List(_maxCodeLen + 2);
    base = Int32List(_maxCodeLen + 2);
    var vec = 0;
    for (var i = minLen; i <= maxLen; i++) {
      vec += base0[i + 1] - base0[i];
      limit[i] = vec - 1;
      vec <<= 1;
    }
    for (var i = minLen + 1; i <= maxLen; i++) {
      base[i] = ((limit[i - 1] + 1) << 1) - base0[i];
    }
    base[minLen] = base0[minLen];
  }

  late final int minLen, maxLen;
  late final Int32List perm, limit, base;

  int decode(_Bits b) {
    var zn = minLen;
    var zvec = b.bits(zn);
    while (zvec > limit[zn]) {
      if (++zn > maxLen) throw const FormatException('bzip2: código Huffman inválido');
      zvec = (zvec << 1) | b.bit();
    }
    final i = zvec - base[zn];
    if (i < 0 || i >= perm.length) throw const FormatException('bzip2: código Huffman inválido');
    return perm[i];
  }
}

/// Bloques descomprimidos de un stream bzip2 (o varios concatenados), en orden.
Iterable<Uint8List> bzip2Chunks(Uint8List data) sync* {
  final b = _Bits(data);
  var streams = 0;
  while (true) {
    if (streams > 0) {
      b.alignToByte();
      if (b.atEnd) return;
    }
    if (b.bits(8) != 0x42 || b.bits(8) != 0x5a || b.bits(8) != 0x68) {
      throw const FormatException('no es un stream bzip2');
    }
    final level = b.bits(8) - 0x30;
    if (level < 1 || level > 9) throw const FormatException('bzip2: nivel inválido');
    final tt = Int32List(level * 100000);
    streams++;
    while (true) {
      final m1 = b.bits(24), m2 = b.bits(24);
      b.bits(16); // CRC (32 bits, en dos lecturas: el buffer es de 32)
      b.bits(16);
      if (m1 == 0x177245 && m2 == 0x385090) break; // fin de stream
      if (m1 != 0x314159 || m2 != 0x265359) throw const FormatException('bzip2: bloque inválido');
      yield _block(b, tt);
    }
  }
}

Uint8List _block(_Bits b, Int32List tt) {
  if (b.bit() != 0) throw const FormatException('bzip2: bloques aleatorizados no soportados');
  final origPtr = b.bits(24);
  final used = b.bits(16);
  final seqToUnseq = <int>[];
  for (var i = 0; i < 16; i++) {
    if (used & (0x8000 >> i) == 0) continue;
    final bits = b.bits(16);
    for (var j = 0; j < 16; j++) {
      if (bits & (0x8000 >> j) != 0) seqToUnseq.add(i * 16 + j);
    }
  }
  if (seqToUnseq.isEmpty) throw const FormatException('bzip2: bloque sin símbolos');
  final alphaSize = seqToUnseq.length + 2;
  final nGroups = b.bits(3);
  if (nGroups < 2 || nGroups > 6) throw const FormatException('bzip2: grupos inválidos');
  final nSelectors = b.bits(15);
  if (nSelectors < 1) throw const FormatException('bzip2: sin selectores');
  final mtfGroups = List<int>.generate(nGroups, (i) => i);
  final selectors = Uint8List(nSelectors);
  for (var i = 0; i < nSelectors; i++) {
    var j = 0;
    while (b.bit() == 1) {
      if (++j >= nGroups) throw const FormatException('bzip2: selector inválido');
    }
    final v = mtfGroups.removeAt(j);
    mtfGroups.insert(0, v);
    selectors[i] = v;
  }
  final tables = <_Huffman>[];
  for (var t = 0; t < nGroups; t++) {
    var curr = b.bits(5);
    final lens = List<int>.filled(alphaSize, 0);
    for (var i = 0; i < alphaSize; i++) {
      while (true) {
        if (curr < 1 || curr > _maxCodeLen) throw const FormatException('bzip2: longitud inválida');
        if (b.bit() == 0) break;
        curr += b.bit() == 0 ? 1 : -1;
      }
      lens[i] = curr;
    }
    tables.add(_Huffman(lens));
  }

  final eob = alphaSize - 1;
  final mtf = List<int>.generate(256, (i) => i);
  final unzftab = Int32List(256);
  var nblock = 0, groupNo = -1, groupPos = 0;
  var runLen = 0, runBit = 1;
  late _Huffman table;
  void flushRun() {
    if (runLen == 0) return;
    final uc = seqToUnseq[mtf[0]];
    if (nblock + runLen > tt.length) throw const FormatException('bzip2: bloque demasiado largo');
    unzftab[uc] += runLen;
    for (var k = 0; k < runLen; k++) {
      tt[nblock++] = uc;
    }
    runLen = 0;
    runBit = 1;
  }

  while (true) {
    if (groupPos == 0) {
      if (++groupNo >= nSelectors) throw const FormatException('bzip2: selectores agotados');
      groupPos = 50;
      table = tables[selectors[groupNo]];
    }
    groupPos--;
    final sym = table.decode(b);
    if (sym <= 1) {
      runLen += sym == 0 ? runBit : 2 * runBit;
      runBit <<= 1;
      if (runLen > tt.length) throw const FormatException('bzip2: racha demasiado larga');
      continue;
    }
    flushRun();
    if (sym == eob) break;
    final v = mtf.removeAt(sym - 1);
    mtf.insert(0, v);
    final uc = seqToUnseq[v];
    if (nblock >= tt.length) throw const FormatException('bzip2: bloque demasiado largo');
    unzftab[uc]++;
    tt[nblock++] = uc;
  }
  if (origPtr >= nblock) throw const FormatException('bzip2: puntero de origen inválido');

  // BWT inversa: tt[i] guarda el byte en los 8 bits bajos y el enlace arriba.
  final cftab = Int32List(257);
  for (var i = 0; i < 256; i++) {
    cftab[i + 1] = cftab[i] + unzftab[i];
  }
  for (var i = 0; i < nblock; i++) {
    final uc = tt[i] & 0xff;
    tt[cftab[uc]] |= i << 8;
    cftab[uc]++;
  }
  // Deshace la RLE inicial: cuatro bytes iguales van seguidos de un contador.
  // Con copia: [buf] se reutiliza tras cada racha.
  final out = BytesBuilder();
  final buf = Uint8List(nblock);
  var bl = 0;
  var tPos = tt[origPtr] >> 8;
  var last = -1, same = 0;
  for (var k = 0; k < nblock; k++) {
    tPos = tt[tPos];
    final ch = tPos & 0xff;
    tPos >>= 8;
    if (same == 4) {
      if (ch > 0) {
        out.add(Uint8List.sublistView(buf, 0, bl));
        bl = 0;
        out.add(Uint8List(ch)..fillRange(0, ch, last));
      }
      same = 0;
      last = -1;
      continue;
    }
    if (ch == last) {
      same++;
    } else {
      same = 1;
      last = ch;
    }
    buf[bl++] = ch;
  }
  out.add(Uint8List.sublistView(buf, 0, bl));
  for (var i = 0; i < nblock; i++) {
    tt[i] = 0;
  }
  return out.takeBytes();
}

/// Todo el contenido descomprimido (para datos pequeños y pruebas).
Uint8List bzip2Decompress(Uint8List data) {
  final out = BytesBuilder(copy: false);
  for (final c in bzip2Chunks(data)) {
    out.add(c);
  }
  return out.takeBytes();
}

String _cString(Uint8List h, int off, int len) {
  var e = off;
  while (e < off + len && h[e] != 0) {
    e++;
  }
  return String.fromCharCodes(h, off, e);
}

int _octal(Uint8List h, int off, int len) {
  final s = _cString(h, off, len).trim();
  if (s.isEmpty) return 0;
  final v = int.tryParse(s, radix: 8);
  if (v == null || v < 0) throw const FormatException('tar: tamaño inválido');
  return v;
}

/// Extrae de un .tar.bz2 solo los archivos regulares cuyo nombre base está en
/// [names], a `[destDir]/<nombre base>`. Ignora entradas con `..`. Devuelve los
/// nombres extraídos; falta alguno → [FormatException]. Síncrono: llamarlo en
/// un isolate.
Set<String> extractTarBz2Allowlist(String archivePath, String destDir, Set<String> names) {
  final data = File(archivePath).readAsBytesSync();
  final got = <String>{};
  final header = Uint8List(512);
  var hFill = 0;
  var remaining = 0, padding = 0;
  RandomAccessFile? sink;
  String? longName;
  BytesBuilder? longNameBuf;
  var zeroHeaders = 0;
  var done = false;
  try {
    for (final chunk in bzip2Chunks(data)) {
      var i = 0;
      while (i < chunk.length && !done) {
        if (remaining > 0) {
          final n = (chunk.length - i) < remaining ? chunk.length - i : remaining;
          final part = Uint8List.sublistView(chunk, i, i + n);
          sink?.writeFromSync(part);
          longNameBuf?.add(part);
          remaining -= n;
          i += n;
          if (remaining == 0) {
            sink?.closeSync();
            sink = null;
            if (longNameBuf != null) {
              final b = longNameBuf.takeBytes();
              longName = _cString(b, 0, b.length);
              longNameBuf = null;
            }
          }
          continue;
        }
        if (padding > 0) {
          final n = (chunk.length - i) < padding ? chunk.length - i : padding;
          padding -= n;
          i += n;
          continue;
        }
        final n = (chunk.length - i) < (512 - hFill) ? chunk.length - i : 512 - hFill;
        header.setRange(hFill, hFill + n, chunk, i);
        hFill += n;
        i += n;
        if (hFill < 512) continue;
        hFill = 0;
        if (header.every((x) => x == 0)) {
          if (++zeroHeaders == 2) done = true;
          continue;
        }
        zeroHeaders = 0;
        final size = _octal(header, 124, 12);
        final type = header[156];
        var name = _cString(header, 0, 100);
        final prefix = _cString(header, 345, 155);
        if (prefix.isNotEmpty && String.fromCharCodes(header, 257, 262) == 'ustar') name = '$prefix/$name';
        if (longName != null) {
          name = longName;
          longName = null;
        }
        remaining = size;
        padding = (512 - size % 512) % 512;
        if (type == 0x4c) {
          // Nombre largo de GNU para la entrada siguiente.
          if (size > 4096) throw const FormatException('tar: nombre largo inválido');
          longNameBuf = BytesBuilder();
        } else {
          final parts = name.split(RegExp(r'[\\/]'));
          final base = parts.isEmpty ? '' : parts.last;
          final regular = type == 0x30 || type == 0;
          if (regular && !parts.contains('..') && names.contains(base) && !got.contains(base)) {
            got.add(base);
            sink = File('$destDir${Platform.pathSeparator}$base').openSync(mode: FileMode.write);
          }
        }
        if (remaining == 0 && sink != null) {
          sink.closeSync();
          sink = null;
        }
      }
      if (done) break;
    }
  } finally {
    sink?.closeSync();
  }
  if (remaining > 0) throw const FormatException('tar truncado');
  if (!got.containsAll(names)) {
    throw FormatException('faltan en el archivo: ${names.difference(got).join(', ')}');
  }
  return got;
}
