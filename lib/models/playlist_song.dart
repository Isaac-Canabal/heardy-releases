import 'dart:convert';

class PlaylistSong {
  final String playlistId;
  final String songId;
  final int orderIndex;

  PlaylistSong({
    required this.playlistId,
    required this.songId,
    required this.orderIndex,
  });

  Map<String, dynamic> toMap() {
    return {
      'playlistId': playlistId,
      'songId': songId,
      'orderIndex': orderIndex,
    };
  }

  factory PlaylistSong.fromMap(Map<String, dynamic> map) {
    return PlaylistSong(
      playlistId: map['playlistId'] as String,
      songId: map['songId'] as String,
      orderIndex: map['orderIndex'] as int,
    );
  }

  String toJson() => json.encode(toMap());

  factory PlaylistSong.fromJson(String source) => PlaylistSong.fromMap(json.decode(source) as Map<String, dynamic>);
}
