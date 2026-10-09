import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'library_storage.dart';
import 'app_log.dart';

/// The stable identity of a song's audio content: a hash of the audio
/// payload only, plus the strategy used to locate that payload.
///
/// [kind] is persisted in `songs.hashKind` (`mp3-audio` / `mp4-mdat` /
/// `raw-file`) so a later parser fix can selectively invalidate rows.
class AudioIdentity {
  final String hash;
  final String kind;
  const AudioIdentity(this.hash, this.kind);
}

class _ByteRange {
  final int start;
  final int length;
  const _ByteRange(this.start, this.length);
}

/// Computes song identity from the audio payload of a SAF document,
/// deliberately skipping tag blocks so an ID3/APE/`ilst` edit doesn't
/// change the identity of an otherwise-untouched file. See CLAUDE.md D2 —
/// do not re-derive those rules here.
///
/// **This is shared by the library scanner and the downloader on purpose.**
/// Both must produce byte-identical hashes for the same file, or a freshly
/// downloaded song is re-inserted as a duplicate on the next scan and loses
/// its playlist membership. Always hash by reading back over SAF — never
/// over a local temp copy — so the downloader hashes exactly what the
/// scanner will later hash.
class AudioIdentityService {
  /// Extensions the library indexes. Anything else is skipped as
  /// unsupported by both the scanner and the downloader.
  static const Set<String> audioExtensions = {'mp3', 'mp4', 'm4a'};

  static const _headTailSize = 64 * 1024;

  final LibraryStorage _storage;

  AudioIdentityService({LibraryStorage? storage}) : _storage = storage ?? defaultLibraryStorage();

  /// Lowercased extension of [name], without the dot; `''` if there is none.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Hashes the audio payload of the SAF document at [uri], whose total
  /// size is [length] and whose extension is [ext].
  ///
  /// Falls back to hashing the whole file (`raw-file`) if the container
  /// can't be parsed, so an odd file still gets a stable identity.
  Future<AudioIdentity> compute({
    required String uri,
    required int length,
    required String ext,
    String? debugName,
  }) async {
    try {
      if (ext == 'mp3') {
        final bounds = await _mp3PayloadBounds(uri, length);
        final hash = await _hashRange(uri, bounds);
        return AudioIdentity(hash, 'mp3-audio');
      }
      if (ext == 'mp4' || ext == 'm4a') {
        final bounds = await _mp4MdatBounds(uri, length);
        if (bounds != null) {
          final hash = await _hashRange(uri, bounds);
          return AudioIdentity(hash, 'mp4-mdat');
        }
      }
    } catch (e) {
      appLog('AudioIdentityService: falling back to raw-file hash for ${debugName ?? uri}: $e');
    }
    final hash = await _hashRange(uri, _ByteRange(0, length));
    return AudioIdentity(hash, 'raw-file');
  }

  Future<String> _hashRange(String uri, _ByteRange range) async {
    final builder = BytesBuilder();
    final lengthPrefix = ByteData(8)..setUint64(0, range.length, Endian.big);
    builder.add(lengthPrefix.buffer.asUint8List());

    if (range.length <= _headTailSize * 2) {
      builder.add(await _storage.readFileBytes(uri, start: range.start, count: range.length));
    } else {
      builder.add(await _storage.readFileBytes(uri, start: range.start, count: _headTailSize));
      builder.add(await _storage.readFileBytes(
        uri,
        start: range.start + range.length - _headTailSize,
        count: _headTailSize,
      ));
    }

    return md5.convert(builder.toBytes()).toString();
  }

  /// ID3v2 header (start) + ID3v1/APEv2 (end) bounds around the raw MPEG
  /// audio frames.
  Future<_ByteRange> _mp3PayloadBounds(String uri, int fileLength) async {
    var headerSize = 0;
    if (fileLength >= 10) {
      final header = await _storage.readFileBytes(uri, start: 0, count: 10);
      if (header.length == 10 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
        // ID3v2: 4 syncsafe bytes (7 bits each), optional 10-byte footer.
        final size = ((header[6] & 0x7F) << 21) |
            ((header[7] & 0x7F) << 14) |
            ((header[8] & 0x7F) << 7) |
            (header[9] & 0x7F);
        final hasFooter = (header[5] & 0x10) != 0;
        headerSize = 10 + size + (hasFooter ? 10 : 0);
      }
    }

    var trailerSize = 0;
    final tailWindow = fileLength < 160 ? fileLength : 160;
    if (tailWindow >= 32) {
      final tail = await _storage.readFileBytes(uri, start: fileLength - tailWindow, count: tailWindow);
      if (tail.length >= 128 &&
          tail[tail.length - 128] == 0x54 &&
          tail[tail.length - 127] == 0x41 &&
          tail[tail.length - 126] == 0x47) {
        trailerSize = 128; // ID3v1: literal "TAG" + 125 bytes
      }
      final beforeTrailer = tail.length - trailerSize;
      if (beforeTrailer >= 32) {
        final footer = tail.sublist(beforeTrailer - 32, beforeTrailer);
        if (_bytesStartWithAscii(footer, 'APETAGEX')) {
          // APEv2 footer: tag size at offset 12, little-endian, includes
          // the optional header but not this footer.
          final tagSize = footer[12] | (footer[13] << 8) | (footer[14] << 16) | (footer[15] << 24);
          trailerSize += 32 + tagSize;
        }
      }
    }

    final payloadLength = fileLength - headerSize - trailerSize;
    if (payloadLength <= 0) {
      throw StateError('mp3 tag bounds collapsed the payload (file=$fileLength header=$headerSize trailer=$trailerSize)');
    }
    return _ByteRange(headerSize, payloadLength);
  }

  /// Walks top-level MP4 boxes to find `mdat`'s payload, without reading
  /// the metadata boxes (`moov`/`udta`/`ilst`) that tag edits rewrite.
  Future<_ByteRange?> _mp4MdatBounds(String uri, int fileLength) async {
    var offset = 0;
    var iterations = 0;
    while (offset < fileLength && iterations < 64) {
      iterations++;
      final header = await _storage.readFileBytes(uri, start: offset, count: 16);
      if (header.length < 8) return null;

      final size32 = _readUint32BE(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));

      int boxSize;
      var headerLen = 8;
      if (size32 == 1) {
        if (header.length < 16) return null;
        boxSize = _readUint64BE(header, 8);
        headerLen = 16;
      } else if (size32 == 0) {
        boxSize = fileLength - offset;
      } else {
        boxSize = size32;
      }
      if (boxSize <= 0) return null;

      if (type == 'mdat') {
        final payloadStart = offset + headerLen;
        final payloadLength = boxSize - headerLen;
        if (payloadLength <= 0 || payloadStart + payloadLength > fileLength) return null;
        return _ByteRange(payloadStart, payloadLength);
      }
      offset += boxSize;
    }
    return null;
  }

  bool _bytesStartWithAscii(Uint8List bytes, String ascii) {
    if (bytes.length < ascii.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  int _readUint32BE(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
  }

  int _readUint64BE(Uint8List bytes, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}
