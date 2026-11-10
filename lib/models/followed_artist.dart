/// Un artista que el usuario sigue, por su canal de YouTube Music. Dejar de
/// seguir no borra la fila: [unfollowedAt] la marca para que la sincronización
/// propague la baja en vez de resucitarla desde otro dispositivo.
class FollowedArtist {
  final String channelId;
  final String name;
  final String thumbnailUrl;
  final DateTime followedAt;
  final DateTime? unfollowedAt;

  const FollowedArtist({
    required this.channelId,
    required this.name,
    this.thumbnailUrl = '',
    required this.followedAt,
    this.unfollowedAt,
  });

  bool get isFollowing => unfollowedAt == null;

  Map<String, dynamic> toMap() => {
        'channelId': channelId,
        'name': name,
        'thumbnailUrl': thumbnailUrl,
        'followedAt': followedAt.toUtc().toIso8601String(),
        'unfollowedAt': unfollowedAt?.toUtc().toIso8601String(),
      };

  factory FollowedArtist.fromMap(Map<String, dynamic> map) => FollowedArtist(
        channelId: map['channelId'] as String,
        name: map['name'] as String,
        thumbnailUrl: map['thumbnailUrl'] as String? ?? '',
        followedAt: DateTime.parse(map['followedAt'] as String),
        unfollowedAt: map['unfollowedAt'] == null ? null : DateTime.parse(map['unfollowedAt'] as String),
      );

  Map<String, dynamic> toJson() => toMap();

  /// Frontera con datos de fuera: lo mal formado falla en vez de colarse.
  factory FollowedArtist.fromJson(Map<String, dynamic> json) {
    final channelId = json['channelId'];
    final name = json['name'];
    final thumbnailUrl = json['thumbnailUrl'];
    final followedAt = json['followedAt'];
    final unfollowedAt = json['unfollowedAt'];
    if (channelId is! String || channelId.isEmpty) throw const FormatException('channelId inválido');
    if (name is! String) throw const FormatException('name inválido');
    if (thumbnailUrl != null && thumbnailUrl is! String) throw const FormatException('thumbnailUrl inválido');
    if (followedAt is! String) throw const FormatException('followedAt inválido');
    if (unfollowedAt != null && unfollowedAt is! String) throw const FormatException('unfollowedAt inválido');
    return FollowedArtist(
      channelId: channelId,
      name: name,
      thumbnailUrl: thumbnailUrl as String? ?? '',
      followedAt: DateTime.parse(followedAt),
      unfollowedAt: unfollowedAt == null ? null : DateTime.parse(unfollowedAt as String),
    );
  }
}
