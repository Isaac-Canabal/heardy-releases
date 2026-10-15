/// Formato en disco de la sincronización por carpeta (`.heardy/devices/` y
/// `.heardy/backups/`): un JSON por dispositivo con el índice y el historial,
/// sin `uri`, `filePath` ni `artPath`. Ver CLAUDE.md, "Cloud sync".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 2 suma playlists online, pistas remotas e historial de streaming. Un
/// archivo schema 2 lo omite una app que solo entienda schema 1.
const folderSyncSchema = 2;
const folderSyncMinSchema = 1;
const folderSyncMaxFileBytes = 50 * 1024 * 1024;
const folderSyncRootDirName = '.heardy';
const folderSyncDevicesDirName = 'devices';
const folderSyncBackupsDirName = 'backups';
const folderSyncMaxBackups = 10;

enum FolderSyncErrorKind { tooLarge, invalidJson, unknownSchema, malformed }

class FolderSyncFormatException implements Exception {
  final FolderSyncErrorKind kind;
  final String message;
  const FolderSyncFormatException(this.kind, this.message);

  @override
  String toString() => 'FolderSyncFormatException(${kind.name}): $message';
}

const _songColumns = [
  'songId',
  'title',
  'artist',
  'album',
  'durationSeconds',
  'fileHash',
  'hashKind',
  'sourceUrl',
];
const _playlistColumns = ['playlistId', 'name', 'sortOrder', 'originalUrl', 'kind'];
const _playlistSongColumns = ['playlistId', 'songId', 'orderIndex'];
const _historyColumns = ['fileHash', 'playedAtLocal', 'playedAtUtc', 'playSeconds'];
const _remoteTrackColumns = ['videoId', 'title', 'artist', 'album', 'durationSeconds', 'thumbnailUrl', 'sourceUrl'];
const _playlistRemoteTrackColumns = ['playlistId', 'videoId', 'orderIndex'];
const _remoteHistoryColumns = ['videoId', 'playedAtLocal', 'playedAtUtc', 'playSeconds'];

/// `kind` solo viaja en las online: una playlist local queda como en schema 1.
List<Map<String, dynamic>> _projectPlaylists(Object? rows) => [
      for (final row in _projectAll(rows, _playlistColumns, 'playlists'))
        {
          for (final e in row.entries)
            if (e.key != 'kind') e.key: e.value,
          if (row['kind'] == 'online') 'kind': 'online',
        },
    ];

List<Map<String, dynamic>> _projectAll(Object? rows, List<String> columns, String field) {
  if (rows == null) return const [];
  if (rows is! List) {
    throw FolderSyncFormatException(FolderSyncErrorKind.malformed, '"$field" no es una lista');
  }
  final out = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row is! Map) {
      throw FolderSyncFormatException(FolderSyncErrorKind.malformed, 'fila inválida en "$field"');
    }
    out.add({for (final c in columns) c: row[c]});
  }
  return out;
}

class FolderSyncSnapshot {
  final String deviceId;
  final String deviceLabel;
  final String exportedAtUtc;
  final List<Map<String, dynamic>> songs;
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> playlistSongs;
  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> remoteTracks;
  final List<Map<String, dynamic>> playlistRemoteTracks;
  final List<Map<String, dynamic>> remoteHistory;

  FolderSyncSnapshot({
    required this.deviceId,
    required this.deviceLabel,
    required this.exportedAtUtc,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
    required List<Map<String, dynamic>> history,
    List<Map<String, dynamic>> remoteTracks = const [],
    List<Map<String, dynamic>> playlistRemoteTracks = const [],
    List<Map<String, dynamic>> remoteHistory = const [],
  })  : songs = _projectAll(songs, _songColumns, 'songs'),
        playlists = _projectPlaylists(playlists),
        playlistSongs = _projectAll(playlistSongs, _playlistSongColumns, 'playlistSongs'),
        history = _projectAll(history, _historyColumns, 'history'),
        remoteTracks = _projectAll(remoteTracks, _remoteTrackColumns, 'remoteTracks'),
        playlistRemoteTracks =
            _projectAll(playlistRemoteTracks, _playlistRemoteTrackColumns, 'playlistRemoteTracks'),
        remoteHistory = _projectAll(remoteHistory, _remoteHistoryColumns, 'remoteHistory');

  Map<String, dynamic> toJson() => {
        'schema': folderSyncSchema,
        'deviceId': deviceId,
        'deviceLabel': deviceLabel,
        'exportedAtUtc': exportedAtUtc,
        'songs': songs,
        'playlists': playlists,
        'playlistSongs': playlistSongs,
        'history': history,
        'remoteTracks': remoteTracks,
        'playlistRemoteTracks': playlistRemoteTracks,
        'remoteHistory': remoteHistory,
      };

  factory FolderSyncSnapshot.fromJson(Map<String, dynamic> json) {
    final schema = json['schema'];
    if (schema is! int || schema < folderSyncMinSchema || schema > folderSyncSchema) {
      throw FolderSyncFormatException(FolderSyncErrorKind.unknownSchema, 'schema $schema');
    }
    final deviceId = json['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const FolderSyncFormatException(FolderSyncErrorKind.malformed, 'falta deviceId');
    }
    return FolderSyncSnapshot(
      deviceId: deviceId,
      deviceLabel: json['deviceLabel'] is String ? json['deviceLabel'] as String : '',
      exportedAtUtc: json['exportedAtUtc'] is String ? json['exportedAtUtc'] as String : '',
      songs: _asRows(json['songs'], 'songs'),
      playlists: _asRows(json['playlists'], 'playlists'),
      playlistSongs: _asRows(json['playlistSongs'], 'playlistSongs'),
      history: _asRows(json['history'], 'history'),
      remoteTracks: _asRows(json['remoteTracks'], 'remoteTracks'),
      playlistRemoteTracks: _asRows(json['playlistRemoteTracks'], 'playlistRemoteTracks'),
      remoteHistory: _asRows(json['remoteHistory'], 'remoteHistory'),
    );
  }
}

List<Map<String, dynamic>> _asRows(Object? rows, String field) {
  if (rows == null) return const [];
  if (rows is! List) {
    throw FolderSyncFormatException(FolderSyncErrorKind.malformed, '"$field" no es una lista');
  }
  return [
    for (final row in rows)
      if (row is Map) Map<String, dynamic>.from(row) else throw FolderSyncFormatException(FolderSyncErrorKind.malformed, 'fila inválida en "$field"'),
  ];
}

Uint8List encodeSnapshot(FolderSyncSnapshot snapshot) => Uint8List.fromList(utf8.encode(jsonEncode(snapshot.toJson())));

/// Frontera de parseo: falla con [FolderSyncFormatException] tipada. Quien
/// recorre varios archivos captura y sigue con el siguiente.
FolderSyncSnapshot parseSnapshot(Uint8List bytes) {
  if (bytes.length > folderSyncMaxFileBytes) {
    throw FolderSyncFormatException(FolderSyncErrorKind.tooLarge, '${bytes.length} bytes');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw FolderSyncFormatException(FolderSyncErrorKind.invalidJson, e.message);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FolderSyncFormatException(FolderSyncErrorKind.malformed, 'la raíz no es un objeto');
  }
  final snapshot = FolderSyncSnapshot.fromJson(decoded);
  _validate(decoded, snapshot);
  return snapshot;
}

const folderSyncMaxRowsPerArray = 50000;
const _maxIdChars = 128;
const _maxTextChars = 512;
const _maxStampChars = 64;
const _maxUrlChars = 2048;
const _maxSeconds = 10000000;
const _maxOrder = 10000000;
final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

FolderSyncFormatException _bad(String field, String why) =>
    FolderSyncFormatException(FolderSyncErrorKind.malformed, '"$field": $why');

/// Segunda pasada tras el parseo y antes de cualquier escritura en la base:
/// tamaños, tipos estrictos, forma de los ids de video y URLs https. Un valor
/// fuera de regla invalida el archivo entero (nada se aplica a medias); solo
/// las URLs no https se dejan en blanco, porque son prescindibles.
void _validate(Map<String, dynamic> json, FolderSyncSnapshot s) {
  final deviceLabel = json['deviceLabel'];
  if (deviceLabel != null && (deviceLabel is! String || deviceLabel.length > _maxIdChars)) {
    throw _bad('deviceLabel', 'inválido');
  }
  final exportedAt = json['exportedAtUtc'];
  if (exportedAt != null && (exportedAt is! String || exportedAt.length > _maxStampChars)) {
    throw _bad('exportedAtUtc', 'inválido');
  }
  if ((json['deviceId'] as String).length > _maxIdChars) throw _bad('deviceId', 'demasiado largo');

  final arrays = {
    'songs': s.songs,
    'playlists': s.playlists,
    'playlistSongs': s.playlistSongs,
    'history': s.history,
    'remoteTracks': s.remoteTracks,
    'playlistRemoteTracks': s.playlistRemoteTracks,
    'remoteHistory': s.remoteHistory,
  };
  for (final e in arrays.entries) {
    if (e.value.length > folderSyncMaxRowsPerArray) throw _bad(e.key, 'demasiadas filas');
  }

  for (final r in s.songs) {
    _text(r, 'songId', 'songs', _maxIdChars, required: true);
    _text(r, 'title', 'songs', _maxTextChars);
    _text(r, 'artist', 'songs', _maxTextChars);
    _text(r, 'album', 'songs', _maxTextChars);
    _text(r, 'fileHash', 'songs', _maxIdChars);
    _text(r, 'hashKind', 'songs', 32);
    _number(r, 'durationSeconds', 'songs', _maxSeconds);
    _httpsOnly(r, 'sourceUrl', 'songs');
  }
  for (final r in s.playlists) {
    _text(r, 'playlistId', 'playlists', _maxIdChars, required: true);
    _text(r, 'name', 'playlists', _maxTextChars, required: true);
    _number(r, 'sortOrder', 'playlists', _maxOrder);
    _httpsOnly(r, 'originalUrl', 'playlists');
    final kind = r['kind'];
    if (kind != null && kind != 'online') throw _bad('playlists', 'kind desconocido');
  }
  for (final r in s.playlistSongs) {
    _text(r, 'playlistId', 'playlistSongs', _maxIdChars, required: true);
    _text(r, 'songId', 'playlistSongs', _maxIdChars, required: true);
    _number(r, 'orderIndex', 'playlistSongs', _maxOrder);
  }
  for (final r in s.history) {
    _text(r, 'fileHash', 'history', _maxIdChars, required: true);
    _text(r, 'playedAtLocal', 'history', _maxStampChars, required: true);
    _text(r, 'playedAtUtc', 'history', _maxStampChars);
    _number(r, 'playSeconds', 'history', _maxSeconds);
  }
  for (final r in s.remoteTracks) {
    _videoId(r, 'remoteTracks');
    _text(r, 'title', 'remoteTracks', _maxTextChars);
    _text(r, 'artist', 'remoteTracks', _maxTextChars);
    _text(r, 'album', 'remoteTracks', _maxTextChars);
    _number(r, 'durationSeconds', 'remoteTracks', _maxSeconds);
    _httpsOnly(r, 'thumbnailUrl', 'remoteTracks');
    _httpsOnly(r, 'sourceUrl', 'remoteTracks');
  }
  for (final r in s.playlistRemoteTracks) {
    _text(r, 'playlistId', 'playlistRemoteTracks', _maxIdChars, required: true);
    _videoId(r, 'playlistRemoteTracks');
    _number(r, 'orderIndex', 'playlistRemoteTracks', _maxOrder);
  }
  for (final r in s.remoteHistory) {
    _videoId(r, 'remoteHistory');
    _text(r, 'playedAtLocal', 'remoteHistory', _maxStampChars, required: true);
    _text(r, 'playedAtUtc', 'remoteHistory', _maxStampChars);
    _number(r, 'playSeconds', 'remoteHistory', _maxSeconds);
  }
}

void _text(Map<String, dynamic> row, String key, String field, int max, {bool required = false}) {
  final v = row[key];
  if (v == null) {
    if (required) throw _bad(field, 'falta $key');
    return;
  }
  if (v is! String) throw _bad(field, '$key no es texto');
  if (required && v.isEmpty) throw _bad(field, 'falta $key');
  if (v.length > max) throw _bad(field, '$key demasiado largo');
}

void _number(Map<String, dynamic> row, String key, String field, int max) {
  final v = row[key];
  if (v == null) return;
  if (v is! num || !v.isFinite || v < 0 || v > max) throw _bad(field, '$key fuera de rango');
}

void _videoId(Map<String, dynamic> row, String field) {
  final v = row['videoId'];
  if (v is! String || !_videoIdPattern.hasMatch(v)) throw _bad(field, 'videoId inválido');
}

void _httpsOnly(Map<String, dynamic> row, String key, String field) {
  final v = row[key];
  if (v == null) return;
  if (v is! String) throw _bad(field, '$key no es texto');
  final uri = v.length > _maxUrlChars ? null : Uri.tryParse(v);
  final ok = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && !RegExp(r'[\s\x00-\x1F]').hasMatch(v);
  if (!ok) row[key] = null;
}

/// Hash del contenido sin `exportedAtUtc` ni `deviceLabel`, en orden estable:
/// el mismo índice no reescribe el archivo.
String snapshotContentHash(FolderSyncSnapshot s) {
  int cmp(String a, String b) => a.compareTo(b);
  String k(Map<String, dynamic> r, List<String> cols) => cols.map((c) => '${r[c]}').join('\u0001');
  List<Map<String, dynamic>> sorted(List<Map<String, dynamic>> rows, List<String> cols) =>
      [...rows]..sort((a, b) => cmp(k(a, cols), k(b, cols)));
  final bytes = utf8.encode(jsonEncode({
    's': sorted(s.songs, _songColumns),
    'p': sorted(s.playlists, _playlistColumns),
    'ps': sorted(s.playlistSongs, _playlistSongColumns),
    'h': sorted(s.history, _historyColumns),
    if (s.remoteTracks.isNotEmpty) 'rt': sorted(s.remoteTracks, _remoteTrackColumns),
    if (s.playlistRemoteTracks.isNotEmpty) 'prt': sorted(s.playlistRemoteTracks, _playlistRemoteTrackColumns),
    if (s.remoteHistory.isNotEmpty) 'rh': sorted(s.remoteHistory, _remoteHistoryColumns),
  }));
  return md5.convert(bytes).toString();
}

String deviceFileName(String deviceId) => '$deviceId.json';

String _two(int n) => n.toString().padLeft(2, '0');

String backupFileName(String deviceId, DateTime when) {
  final d = when.toUtc();
  return '$deviceId-${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}.json';
}

/// Backups de [deviceId] que sobran: todos menos los [keep] más recientes.
/// Ignora los de otros dispositivos y cualquier nombre ajeno al patrón.
List<String> backupsToPrune(Iterable<String> names, String deviceId, {int keep = folderSyncMaxBackups}) {
  final pattern = RegExp('^${RegExp.escape(deviceId)}-' r'\d{8}\.json$');
  final mine = [for (final n in names) if (pattern.hasMatch(n)) n]..sort((a, b) => b.compareTo(a));
  return mine.length <= keep ? const [] : mine.sublist(keep);
}
