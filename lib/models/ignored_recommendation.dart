/// Una canción de "En tus otros dispositivos" que el usuario no quiere instalar
/// en este dispositivo. Es una preferencia local: nunca se sincroniza ni entra
/// en ningún snapshot ni hash. Se identifica por el `fileHash` del audio.
class IgnoredRecommendation {
  final String fileHash;
  final String title;
  final String artist;
  final DateTime ignoredAt;

  const IgnoredRecommendation({
    required this.fileHash,
    required this.title,
    required this.artist,
    required this.ignoredAt,
  });

  IgnoredRecommendation copyWith({DateTime? ignoredAt}) => IgnoredRecommendation(
        fileHash: fileHash,
        title: title,
        artist: artist,
        ignoredAt: ignoredAt ?? this.ignoredAt,
      );

  Map<String, dynamic> toMap() => {
        'fileHash': fileHash,
        'title': title,
        'artist': artist,
        'ignoredAt': ignoredAt.toUtc().toIso8601String(),
      };

  factory IgnoredRecommendation.fromMap(Map<String, dynamic> map) => IgnoredRecommendation(
        fileHash: map['fileHash'] as String,
        title: (map['title'] as String?) ?? '',
        artist: (map['artist'] as String?) ?? '',
        ignoredAt: DateTime.parse(map['ignoredAt'] as String),
      );
}
