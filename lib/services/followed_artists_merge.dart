/// Unión de artistas seguidos entre dispositivos, por `channelId`. Pura: no toca
/// disco ni SQLite, para que la usen igual la carpeta, el Wi-Fi y la nube.
library;

import '../models/followed_artist.dart';

final _isoInstant = RegExp(
  r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$',
);

/// El instante en UTC, o `null` si no lo es. Exige hora y zona porque
/// `DateTime.parse` tomaría lo demás como hora local y el orden entre
/// dispositivos dependería de su huso.
DateTime? parseFollowedArtistDate(Object? value) {
  if (value is! String || !_isoInstant.hasMatch(value)) return null;
  return DateTime.tryParse(value)?.toUtc();
}

/// La fila en su forma normal, o `null` si no aporta ninguna fecha válida. Una
/// fecha inválida cuenta como ausente, y la baja anterior a un seguimiento de la
/// misma fila ya quedó superada. A igual instante dentro de una fila manda la
/// baja: solo se marca sobre una fila que ya existía.
FollowedArtist? _normalize(Map<String, dynamic> row) {
  final channelId = row['channelId'];
  if (channelId is! String || channelId.isEmpty) return null;
  final followedAt = parseFollowedArtistDate(row['followedAt']);
  final unfollowedAt = parseFollowedArtistDate(row['unfollowedAt']);
  final firstValid = followedAt ?? unfollowedAt;
  if (firstValid == null) return null;
  final name = row['name'];
  final thumbnailUrl = row['thumbnailUrl'];
  final isTombstone = unfollowedAt != null && !firstValid.isAfter(unfollowedAt);
  return FollowedArtist(
    channelId: channelId,
    name: name is String ? name : '',
    thumbnailUrl: thumbnailUrl is String ? thumbnailUrl : '',
    followedAt: firstValid,
    unfollowedAt: isTombstone ? unfollowedAt : null,
  );
}

/// Orden total, así el resultado no depende de quién une a quién: el último
/// evento, en empate seguir, y lo demás solo para desempatar igual en todos lados.
int _compare(FollowedArtist a, FollowedArtist b) {
  final byEvent = (a.unfollowedAt ?? a.followedAt).compareTo(b.unfollowedAt ?? b.followedAt);
  if (byEvent != 0) return byEvent;
  if (a.isFollowing != b.isFollowing) return a.isFollowing ? 1 : -1;
  final byFollow = a.followedAt.compareTo(b.followedAt);
  if (byFollow != 0) return byFollow;
  final byName = a.name.compareTo(b.name);
  return byName != 0 ? byName : a.thumbnailUrl.compareTo(b.thumbnailUrl);
}

/// Una fila por artista, ordenadas por `channelId`, con fechas en ISO UTC. Las
/// bajas se conservan aunque el artista sea desconocido aquí, para que sigan
/// propagándose. Propagarlas no rompe la regla de "sincronizar es aditivo": una
/// baja es una acción explícita del usuario y no la falta de una fila; lo que no
/// llega en el otro lado nunca se toca.
List<Map<String, dynamic>> mergeFollowedArtists(
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote,
) {
  final winners = <String, FollowedArtist>{};
  for (final row in [...local, ...remote]) {
    final artist = _normalize(row);
    if (artist == null) continue;
    final current = winners[artist.channelId];
    if (current == null || _compare(artist, current) > 0) winners[artist.channelId] = artist;
  }
  final ids = winners.keys.toList()..sort();
  return [for (final id in ids) winners[id]!.toMap()];
}

final _cloudChannelId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _unsafeUrlChars = RegExp(r'[\s\x00-\x1F]');
const _maxCloudName = 512;
const _maxCloudUrl = 2048;

/// Las filas tal como las admite `PUT /library`. Una sola fila que el servidor
/// rechazara tumbaría la subida con 422 y dejaría fuera todos los seguidos, así
/// que lo que no cabe se adapta o se queda en este dispositivo.
List<Map<String, dynamic>> followedArtistsForCloud(List<Map<String, dynamic>> rows) => [
      for (final row in mergeFollowedArtists(rows, const []))
        if (_cloudChannelId.hasMatch(row['channelId'] as String) &&
            _isCloudDate(row['followedAt']) &&
            (row['unfollowedAt'] == null || _isCloudDate(row['unfollowedAt'])))
          {
            ...row,
            'name': String.fromCharCodes((row['name'] as String).runes.take(_maxCloudName)),
            'thumbnailUrl': _cloudUrl(row['thumbnailUrl'] as String),
          },
    ];

/// El año 0 cabe en Dart y no en el servidor.
bool _isCloudDate(Object? value) => (parseFollowedArtistDate(value)?.year ?? 0) >= 1;

String? _cloudUrl(String url) {
  if (url.length > _maxCloudUrl || _unsafeUrlChars.hasMatch(url)) return null;
  final uri = Uri.tryParse(url);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? url : null;
}

/// Las filas de la unión que hay que escribir sobre [local]. Compara ya
/// normalizado: otra grafía de la misma fecha no es un cambio.
List<Map<String, dynamic>> followedArtistChanges(
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote,
) {
  final current = {for (final row in mergeFollowedArtists(local, const [])) row['channelId']: row};
  return [
    for (final row in mergeFollowedArtists(local, remote))
      if (!row.entries.every((e) => current[row['channelId']]?[e.key] == e.value)) row,
  ];
}
