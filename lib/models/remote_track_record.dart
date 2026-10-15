import 'dart:convert';

import '../services/download_source.dart';

/// Referencia persistida a una pista de YouTube guardada en una playlist
/// online (tabla `remote_tracks`). No hay archivo detrás: suena por streaming.
class RemoteTrackRecord {
  final String videoId;
  final String title;
  final String? artist;
  final String? album;
  final int? durationSeconds;
  final String? thumbnailUrl;
  final String? sourceUrl;

  const RemoteTrackRecord({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.thumbnailUrl,
    required this.sourceUrl,
  });

  factory RemoteTrackRecord.fromRemoteTrack(RemoteTrack track) => RemoteTrackRecord(
        videoId: track.id,
        title: track.title,
        artist: track.artist.isEmpty ? null : track.artist,
        album: track.album,
        durationSeconds: track.durationSeconds > 0 ? track.durationSeconds : null,
        thumbnailUrl: track.thumbnailUrl.isEmpty ? null : track.thumbnailUrl,
        sourceUrl: track.sourceUrl.isEmpty ? null : track.sourceUrl,
      );

  RemoteTrack toRemoteTrack() => RemoteTrack(
        id: videoId,
        title: title,
        artist: artist ?? '',
        album: album,
        durationSeconds: durationSeconds ?? 0,
        thumbnailUrl: thumbnailUrl ?? '',
        sourceUrl: sourceUrl ?? 'https://www.youtube.com/watch?v=$videoId',
      );

  Map<String, dynamic> toMap() => {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        'sourceUrl': sourceUrl,
      };

  factory RemoteTrackRecord.fromMap(Map<String, dynamic> map) => RemoteTrackRecord(
        videoId: map['videoId'] as String,
        title: (map['title'] as String?) ?? '',
        artist: map['artist'] as String?,
        album: map['album'] as String?,
        durationSeconds: (map['durationSeconds'] as num?)?.toInt(),
        thumbnailUrl: map['thumbnailUrl'] as String?,
        sourceUrl: map['sourceUrl'] as String?,
      );

  String toJson() => json.encode(toMap());

  factory RemoteTrackRecord.fromJson(String source) =>
      RemoteTrackRecord.fromMap(json.decode(source) as Map<String, dynamic>);
}
