import 'dart:convert';

class Song {
  final String id;
  final String title;
  final String artist;
  final int duration; // in seconds
  final String filePath; // legacy: app-private path for downloaded songs
  final String artPath; // local file path to downloaded thumbnail
  final String format; // e.g. 'm4a'
  final DateTime downloadDate;
  // Local-library fields (schema v8) — null/0 for legacy downloaded songs.
  final String? uri; // SAF content:// URI, for imported songs
  final String? fileHash; // hash of the audio payload, see hashKind
  final String? hashKind; // 'mp3-audio' | 'mp4-mdat' | 'raw-file'
  final int? fileSize;
  final int? modifiedAt; // epoch millis, from the SAF document
  final String? album;
  final bool missing; // tombstone: true if not seen in the last scan
  // Download branch (schema v11) — null for songs the user supplied himself.
  final String? sourceUrl; // canonical URL this song was downloaded from

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.filePath,
    required this.artPath,
    required this.format,
    required this.downloadDate,
    this.uri,
    this.fileHash,
    this.hashKind,
    this.fileSize,
    this.modifiedAt,
    this.album,
    this.missing = false,
    this.sourceUrl,
  });

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    int? duration,
    String? filePath,
    String? artPath,
    String? format,
    DateTime? downloadDate,
    String? uri,
    String? fileHash,
    String? hashKind,
    int? fileSize,
    int? modifiedAt,
    String? album,
    bool? missing,
    String? sourceUrl,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      filePath: filePath ?? this.filePath,
      artPath: artPath ?? this.artPath,
      format: format ?? this.format,
      downloadDate: downloadDate ?? this.downloadDate,
      uri: uri ?? this.uri,
      fileHash: fileHash ?? this.fileHash,
      hashKind: hashKind ?? this.hashKind,
      fileSize: fileSize ?? this.fileSize,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      album: album ?? this.album,
      missing: missing ?? this.missing,
      sourceUrl: sourceUrl ?? this.sourceUrl,
    );
  }

  /// Path/URI to actually hand to the audio player: imported songs use their
  /// SAF content:// URI, legacy downloaded songs fall back to filePath.
  String get playablePath => uri ?? filePath;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'duration': duration,
      'filePath': filePath,
      'artPath': artPath,
      'format': format,
      'downloadDate': downloadDate.toIso8601String(),
      'uri': uri,
      'fileHash': fileHash,
      'hashKind': hashKind,
      'fileSize': fileSize,
      'modifiedAt': modifiedAt,
      'album': album,
      'missing': missing ? 1 : 0,
      'sourceUrl': sourceUrl,
    };
  }

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String,
      duration: map['duration'] as int,
      filePath: map['filePath'] as String,
      artPath: map['artPath'] as String? ?? '',
      format: map['format'] as String,
      downloadDate: DateTime.parse(map['downloadDate'] as String),
      uri: map['uri'] as String?,
      fileHash: map['fileHash'] as String?,
      hashKind: map['hashKind'] as String?,
      fileSize: map['fileSize'] as int?,
      modifiedAt: map['modifiedAt'] as int?,
      album: map['album'] as String?,
      missing: (map['missing'] as int? ?? 0) != 0,
      sourceUrl: map['sourceUrl'] as String?,
    );
  }

  String toJson() => json.encode(toMap());

  factory Song.fromJson(String source) => Song.fromMap(json.decode(source) as Map<String, dynamic>);
}
