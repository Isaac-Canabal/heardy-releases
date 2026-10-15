import 'dart:convert';

class Playlist {
  /// Playlist de canciones descargadas (archivos en la biblioteca).
  static const String kindLocal = 'local';

  /// Playlist de referencias a YouTube que suenan por streaming.
  static const String kindOnline = 'online';

  final String id;
  final String name;
  final DateTime creationDate;
  final int sortOrder;
  final String? originalUrl;
  final String kind;

  Playlist({
    required this.id,
    required this.name,
    required this.creationDate,
    this.sortOrder = 0,
    this.originalUrl,
    this.kind = kindLocal,
  });

  bool get isOnline => kind == kindOnline;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'creationDate': creationDate.toIso8601String(),
      'sortOrder': sortOrder,
      'originalUrl': originalUrl,
      'kind': kind,
    };
  }

  factory Playlist.fromMap(Map<String, dynamic> map) {
    return Playlist(
      id: map['id'] as String,
      name: map['name'] as String,
      creationDate: DateTime.parse(map['creationDate'] as String),
      sortOrder: (map['sortOrder'] as int?) ?? 0,
      originalUrl: map['originalUrl'] as String?,
      kind: map['kind'] == kindOnline ? kindOnline : kindLocal,
    );
  }

  Playlist copyWith({String? name, int? sortOrder, String? originalUrl}) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      creationDate: creationDate,
      sortOrder: sortOrder ?? this.sortOrder,
      originalUrl: originalUrl ?? this.originalUrl,
      kind: kind,
    );
  }

  String toJson() => json.encode(toMap());

  factory Playlist.fromJson(String source) =>
      Playlist.fromMap(json.decode(source) as Map<String, dynamic>);
}
