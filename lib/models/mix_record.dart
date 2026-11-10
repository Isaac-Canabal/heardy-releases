/// Un mix de Heardy Mixer guardado en almacenamiento privado de la app. No es
/// una fila de `songs` (no se sincroniza ni cuenta escuchas) hasta que el
/// usuario lo guarda en una playlist, y entonces [savedSongId] apunta a ella.
///
/// Cada lado viene de la biblioteca ([songAId]/[songBId], `Song.id`) o de una
/// búsqueda ([remoteAId]/[remoteBId], id de vídeo); los títulos y artistas se
/// copian para poder mostrarlo aunque la canción ya no esté.
class MixRecord {
  final String id;
  final String name;
  final String? songAId;
  final String? songBId;
  final String? remoteAId;
  final String? remoteBId;
  final String titleA;
  final String artistA;
  final String titleB;
  final String artistB;

  /// `MixMode.name`.
  final String mode;

  /// `MixQualityMode.name`.
  final String quality;
  final int durationMs;

  /// El .m4a, en almacenamiento privado de la app.
  final String filePath;

  /// Carátula en almacenamiento privado ('' = degradado del tema).
  final String artPath;
  final DateTime createdAt;
  final String? savedSongId;

  MixRecord({
    required this.id,
    required this.name,
    this.songAId,
    this.songBId,
    this.remoteAId,
    this.remoteBId,
    required this.titleA,
    required this.artistA,
    required this.titleB,
    required this.artistB,
    required this.mode,
    required this.quality,
    required this.durationMs,
    required this.filePath,
    required this.artPath,
    required this.createdAt,
    this.savedSongId,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'songAId': songAId,
        'songBId': songBId,
        'remoteAId': remoteAId,
        'remoteBId': remoteBId,
        'titleA': titleA,
        'artistA': artistA,
        'titleB': titleB,
        'artistB': artistB,
        'mode': mode,
        'quality': quality,
        'durationMs': durationMs,
        'filePath': filePath,
        'artPath': artPath,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'savedSongId': savedSongId,
      };

  factory MixRecord.fromMap(Map<String, dynamic> m) => MixRecord(
        id: m['id'] as String,
        name: m['name'] as String,
        songAId: m['songAId'] as String?,
        songBId: m['songBId'] as String?,
        remoteAId: m['remoteAId'] as String?,
        remoteBId: m['remoteBId'] as String?,
        titleA: m['titleA'] as String? ?? '',
        artistA: m['artistA'] as String? ?? '',
        titleB: m['titleB'] as String? ?? '',
        artistB: m['artistB'] as String? ?? '',
        mode: m['mode'] as String,
        quality: m['quality'] as String,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        filePath: m['filePath'] as String,
        artPath: m['artPath'] as String? ?? '',
        createdAt: DateTime.parse(m['createdAt'] as String),
        savedSongId: m['savedSongId'] as String?,
      );

  Map<String, dynamic> toJson() => toMap();

  factory MixRecord.fromJson(Map<String, dynamic> json) => MixRecord.fromMap(json);

  MixRecord copyWith({String? name, String? artPath, String? savedSongId}) => MixRecord(
        id: id,
        name: name ?? this.name,
        songAId: songAId,
        songBId: songBId,
        remoteAId: remoteAId,
        remoteBId: remoteBId,
        titleA: titleA,
        artistA: artistA,
        titleB: titleB,
        artistB: artistB,
        mode: mode,
        quality: quality,
        durationMs: durationMs,
        filePath: filePath,
        artPath: artPath ?? this.artPath,
        createdAt: createdAt,
        savedSongId: savedSongId ?? this.savedSongId,
      );
}
