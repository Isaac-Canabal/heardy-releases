import '../services/download_source.dart';
import 'song.dart';

/// Una entrada del historial de escuchado: una canción de la biblioteca
/// (`play_history`) o una pista reproducida por streaming (`stream_history`).
class HistoryEntry {
  final bool isStream;

  /// Id de la canción local; vacío en las de streaming.
  final String songId;

  /// Id de vídeo de YouTube (siempre en streaming; en las locales sólo si
  /// vienen de una descarga de YouTube).
  final String? videoId;
  final String title;
  final String artist;

  /// Carátula remota (streaming) o ruta local del archivo.
  final String artUrl;
  final String artPath;
  final int durationSeconds;
  final DateTime playedAt;

  /// La canción de la biblioteca (sólo en las locales; no se serializa).
  final Song? song;

  const HistoryEntry({
    required this.isStream,
    this.songId = '',
    this.videoId,
    required this.title,
    required this.artist,
    this.artUrl = '',
    this.artPath = '',
    this.durationSeconds = 0,
    required this.playedAt,
    this.song,
  });

  /// Identidad para deduplicar entre las dos fuentes.
  String get key => videoId != null && videoId!.isNotEmpty ? 'yt:$videoId' : 'song:$songId';

  Map<String, dynamic> toMap() => {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'durationSeconds': durationSeconds,
        'playedAt': playedAt.toIso8601String(),
      };

  factory HistoryEntry.fromStreamMap(Map<String, dynamic> map) => HistoryEntry(
        isStream: true,
        videoId: map['videoId'] as String,
        title: map['title'] as String? ?? '',
        artist: map['artist'] as String? ?? '',
        artUrl: map['artUrl'] as String? ?? '',
        durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
        playedAt: DateTime.parse(map['playedAt'] as String),
      );

  /// Pista remota para volver a reproducirla por streaming.
  RemoteTrack toRemoteTrack() => RemoteTrack(
        id: videoId ?? '',
        title: title,
        artist: artist,
        album: null,
        durationSeconds: durationSeconds,
        thumbnailUrl: artUrl,
        sourceUrl: 'https://www.youtube.com/watch?v=$videoId',
      );
}
