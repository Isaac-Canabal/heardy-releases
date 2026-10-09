import 'dart:convert';

class Playlist {
  final String id;
  final String name;
  final DateTime creationDate;
  final int sortOrder;
  final String? originalUrl;

  Playlist({
    required this.id,
    required this.name,
    required this.creationDate,
    this.sortOrder = 0,
    this.originalUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'creationDate': creationDate.toIso8601String(),
      'sortOrder': sortOrder,
      'originalUrl': originalUrl,
    };
  }

  factory Playlist.fromMap(Map<String, dynamic> map) {
    return Playlist(
      id: map['id'] as String,
      name: map['name'] as String,
      creationDate: DateTime.parse(map['creationDate'] as String),
      sortOrder: (map['sortOrder'] as int?) ?? 0,
      originalUrl: map['originalUrl'] as String?,
    );
  }

  Playlist copyWith({String? name, int? sortOrder, String? originalUrl}) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      creationDate: creationDate,
      sortOrder: sortOrder ?? this.sortOrder,
      originalUrl: originalUrl ?? this.originalUrl,
    );
  }

  String toJson() => json.encode(toMap());

  factory Playlist.fromJson(String source) =>
      Playlist.fromMap(json.decode(source) as Map<String, dynamic>);
}
