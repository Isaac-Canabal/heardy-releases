/// Compara el índice de la nube contra el hash de audio de lo que ya hay en
/// este equipo — la estrategia híbrida decidida en la Etapa 16 (E-2) y el
/// entregable de W6 del plan de escritorio: "el PC sabe qué le falta".
///
/// Comparación deliberadamente por [fileHash], nunca por título/artista: es
/// el mismo criterio de identidad que ya gobierna todo lo demás en esta app
/// (D2, y la deduplicación de `DownloadService`) — dos copias del mismo
/// audio son la misma canción aunque el título difiera en mayúsculas o en un
/// "(Official Video)" de más.
library;

import 'cover_art.dart' show youtubeVideoIdFrom;
import 'download_source.dart' show RemoteTrack;

/// Enlaces de origen que este equipo ya tiene: los `sourceUrl` locales más los
/// de las filas de la nube cuyo audio ya está acá por hash (el escáner no
/// guarda `sourceUrl`, así que una canción presente puede no tener ninguno).
Set<String> knownLocalSourceUrls({
  required Set<String> localSourceUrls,
  required List<Map<String, dynamic>> cloudSongs,
  required Set<String> localFileHashes,
}) {
  final urls = <String>{};
  void add(String url) {
    urls.add(url);
    final id = youtubeVideoIdFrom(url);
    if (id != null) urls.add('yt:$id');
  }

  localSourceUrls.forEach(add);
  for (final song in cloudSongs) {
    final hash = song['fileHash'] as String?;
    final url = song['sourceUrl'] as String?;
    if (hash != null && localFileHashes.contains(hash) && url != null && url.isNotEmpty) {
      add(url);
    }
  }
  return urls;
}

/// `true` si [url] ya está entre [knownUrls] (de [knownLocalSourceUrls]),
/// comparando por id de vídeo cuando es de YouTube (`youtu.be/x`, `watch?v=x`
/// y `music.youtube.com` son el mismo vídeo) y literalmente si no.
bool sourceUrlAlreadyKnown(String url, Set<String> knownUrls) {
  if (url.isEmpty) return false;
  if (knownUrls.contains(url)) return true;
  final id = youtubeVideoIdFrom(url);
  return id != null && knownUrls.contains('yt:$id');
}

/// Cuántas canciones DISTINTAS hay en [cloudSongs], contando por `fileHash`
/// en vez de por fila. El índice de la nube puede tener más de una fila para
/// el mismo audio (una heredada de antes de que el id fuera el hash, y la
/// misma canción re-subida con el id nuevo — ver el comentario en
/// [unionCloudIntoLocalIndex]); sin este conteo, la pantalla de restauración
/// le mostraba al usuario un total inflado por esas filas repetidas. Una fila
/// sin hash cuenta por sí misma — no hay con qué agruparla.
int uniqueCloudSongCount(List<Map<String, dynamic>> cloudSongs) {
  final hashes = <String>{};
  var withoutHash = 0;
  for (final song in cloudSongs) {
    final hash = song['fileHash'] as String?;
    if (hash == null || hash.isEmpty) {
      withoutHash++;
    } else {
      hashes.add(hash);
    }
  }
  return hashes.length + withoutHash;
}

/// Filas del índice de la nube (misma forma que `CloudLibrary.songs`: al
/// menos `fileHash`, `title`, `artist`) cuyo `fileHash` no aparece en
/// [localFileHashes]. Conserva el orden de entrada.
List<Map<String, dynamic>> missingCloudSongs(
  List<Map<String, dynamic>> cloudSongs,
  Set<String> localFileHashes,
) {
  final seen = <String>{};
  return cloudSongs.where((song) {
    final hash = song['fileHash'] as String?;
    // Sin hash no hay forma de emparejar — nunca se asume "falta" ni
    // "está" sobre un dato que no está.
    if (hash == null || hash.isEmpty) return false;
    // Un mismo audio con dos filas en la nube falta una sola vez.
    return !localFileHashes.contains(hash) && seen.add(hash);
  }).toList();
}

/// Lo que la nube tiene y este equipo no: [missingCloudSongs] contra TODOS los
/// hashes locales (también los de filas `missing`, que siguen siendo "tuyas"),
/// menos lo que ya se conoce por el id de vídeo de su `sourceUrl` (un archivo
/// escaneado sin hash en común pero del mismo vídeo).
List<Map<String, dynamic>> cloudOnlySongs(
  List<Map<String, dynamic>> cloudSongs, {
  required Set<String> localFileHashes,
  Set<String> localSourceUrls = const {},
}) {
  final known = knownLocalSourceUrls(
    localSourceUrls: localSourceUrls,
    cloudSongs: cloudSongs,
    localFileHashes: localFileHashes,
  );
  return [
    for (final song in missingCloudSongs(cloudSongs, localFileHashes))
      if (!sourceUrlAlreadyKnown((song['sourceUrl'] as String?) ?? '', known)) song,
  ];
}

/// El trabajo de descarga de una fila de la nube, o `null` si no tiene
/// `sourceUrl` (entonces sólo se puede emparejar por duración, ver
/// `matchCloudSong`). Es un listado plano: el worker lo re-resuelve.
RemoteTrack? remoteTrackFromCloudSong(Map<String, dynamic> song) {
  final url = ((song['sourceUrl'] as String?) ?? '').trim();
  if (url.isEmpty) return null;
  return RemoteTrack(
    id: youtubeVideoIdFrom(url) ?? url,
    title: (song['title'] as String?) ?? '',
    artist: (song['artist'] as String?) ?? '',
    album: (song['album'] as String?)?.isEmpty ?? true ? null : song['album'] as String,
    durationSeconds: (song['durationSeconds'] as num?)?.toInt() ?? 0,
    thumbnailUrl: '',
    sourceUrl: url,
  );
}

/// Clave natural de una playlist: el nombre sin mayúsculas ni espacios de más
/// (misma regla que `MusicProvider.createPlaylist`, que ya la trata como
/// duplicada).
String playlistNameKey(String? name) => (name ?? '').trim().toLowerCase();

/// Índice de la nube sin filas repetidas: una por `fileHash` y una por nombre
/// de playlist, con las pertenencias reescritas a esos ids.
class CanonicalCloudIndex {
  final List<Map<String, dynamic>> songs;
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> playlistSongs;
  final List<Map<String, dynamic>> playlistRemoteTracks;
  const CanonicalCloudIndex(this.songs, this.playlists, this.playlistSongs, [this.playlistRemoteTracks = const []]);
}

/// Colapsa los duplicados que la nube acumula por ser aditiva: la misma
/// canción con dos ids (fila heredada + id nuevo) y la misma playlist con dos
/// ids (borrada y vuelta a crear con el mismo nombre). Sin esto la
/// restauración cuenta, empareja y encola cada copia por separado y recrea
/// la playlist dos veces. Gana la primera fila; sólo se rellenan `sourceUrl`
/// y `originalUrl` vacíos con los de las copias.
CanonicalCloudIndex canonicalizeCloudIndex(
  List<Map<String, dynamic>> songs,
  List<Map<String, dynamic>> playlists,
  List<Map<String, dynamic>> playlistSongs, [
  List<Map<String, dynamic>> playlistRemoteTracks = const [],
]) {
  final songRemap = <String, String>{};
  final songByHash = <String, Map<String, dynamic>>{};
  final outSongs = <Map<String, dynamic>>[];
  for (final song in songs) {
    final id = song['songId'] as String?;
    final hash = song['fileHash'] as String?;
    if (hash != null && hash.isNotEmpty) {
      final first = songByHash[hash];
      if (first != null) {
        if (id != null) songRemap[id] = first['songId'] as String;
        if ((first['sourceUrl'] as String?)?.isNotEmpty != true &&
            (song['sourceUrl'] as String?)?.isNotEmpty == true) {
          first['sourceUrl'] = song['sourceUrl'];
        }
        continue;
      }
      final copy = Map<String, dynamic>.from(song);
      songByHash[hash] = copy;
      outSongs.add(copy);
    } else {
      outSongs.add(Map<String, dynamic>.from(song));
    }
  }

  final playlistRemap = <String, String>{};
  final playlistByName = <String, Map<String, dynamic>>{};
  final outPlaylists = <Map<String, dynamic>>[];
  for (final playlist in playlists) {
    final id = playlist['playlistId'] as String?;
    final key = _kindedNameKey(playlist);
    if (key.isNotEmpty) {
      final first = playlistByName[key];
      if (first != null) {
        if (id != null) playlistRemap[id] = first['playlistId'] as String;
        if ((first['originalUrl'] as String?)?.isNotEmpty != true &&
            (playlist['originalUrl'] as String?)?.isNotEmpty == true) {
          first['originalUrl'] = playlist['originalUrl'];
        }
        continue;
      }
      final copy = Map<String, dynamic>.from(playlist);
      playlistByName[key] = copy;
      outPlaylists.add(copy);
    } else {
      outPlaylists.add(Map<String, dynamic>.from(playlist));
    }
  }

  final pairs = <String>{};
  final outPlaylistSongs = <Map<String, dynamic>>[];
  for (final row in playlistSongs) {
    final rawPlaylist = row['playlistId'] as String?;
    final rawSong = row['songId'] as String?;
    if (rawPlaylist == null || rawSong == null) continue;
    final playlistId = playlistRemap[rawPlaylist] ?? rawPlaylist;
    final songId = songRemap[rawSong] ?? rawSong;
    if (!pairs.add('$playlistId $songId')) continue;
    outPlaylistSongs.add({...row, 'playlistId': playlistId, 'songId': songId});
  }
  final remotePairs = <String>{};
  final outRemote = <Map<String, dynamic>>[];
  for (final row in playlistRemoteTracks) {
    final rawPlaylist = row['playlistId'] as String?;
    final videoId = row['videoId'] as String?;
    if (rawPlaylist == null || videoId == null) continue;
    final playlistId = playlistRemap[rawPlaylist] ?? rawPlaylist;
    if (!remotePairs.add('$playlistId\u0000$videoId')) continue;
    outRemote.add({...row, 'playlistId': playlistId});
  }
  return CanonicalCloudIndex(outSongs, outPlaylists, outPlaylistSongs, outRemote);
}

/// A qué playlist local corresponde cada playlist de la nube: el mismo id, o
/// si no, la local con el mismo nombre. Una playlist borrada y restaurada, o
/// creada por el escáner desde su carpeta, tiene otro id pero es la misma —
/// recrearla con el id de la nube la dejaba duplicada. Las que no tienen
/// equivalente local no aparecen en el resultado.
Map<String, String> localPlaylistIdByCloudId(
  List<Map<String, dynamic>> cloudPlaylists,
  Iterable<({String id, String name})> localPlaylists,
) {
  final localIds = {for (final p in localPlaylists) p.id};
  final localIdByName = <String, String>{};
  for (final p in localPlaylists) {
    final key = playlistNameKey(p.name);
    if (key.isNotEmpty) localIdByName.putIfAbsent(key, () => p.id);
  }
  final result = <String, String>{};
  for (final cloud in cloudPlaylists) {
    final id = cloud['playlistId'] as String?;
    if (id == null) continue;
    if (localIds.contains(id)) {
      result[id] = id;
      continue;
    }
    final byName = localIdByName[playlistNameKey(cloud['name'] as String?)];
    if (byName != null) result[id] = byName;
  }
  return result;
}

/// Las columnas EXACTAS que acepta cada lista de `PUT /library`. Los modelos
/// de Pydantic del servidor llevan `extra="forbid"`
/// (`server/app/library_store.py`), así que una clave de más no se ignora:
/// devuelve 422 y tira la subida entera. Por eso cada fila se reproyecta acá
/// en vez de reenviarse tal como vino.
const _songColumns = [
  'songId',
  'title',
  'artist',
  'album',
  'durationSeconds',
  'fileHash',
  'hashKind',
  // El enlace del que se descargó, cuando lo hubo. Es lo que hace que
  // "actualizar" sobreviva a una reinstalación y que la restauración baje el
  // original exacto en vez de buscar una coincidencia por duración.
  'sourceUrl',
];
const _playlistColumns = [
  'playlistId',
  'name',
  'sortOrder',
  // El enlace de YouTube del que se expandió, cuando lo hubo. Mismo motivo
  // que sourceUrl en _songColumns: sin esto, restaurar una playlist en otro
  // equipo pierde el botón "Actualizar desde YouTube" para siempre, porque
  // sólo aparece cuando originalUrl no es nulo.
  'originalUrl',
];
const _playlistSongColumns = ['playlistId', 'songId', 'orderIndex'];
const _remoteTrackColumns = [
  'videoId',
  'title',
  'artist',
  'album',
  'durationSeconds',
  'thumbnailUrl',
  'sourceUrl',
];
const _playlistRemoteTrackColumns = ['playlistId', 'videoId', 'orderIndex'];

const kPlaylistKindOnline = 'online';

Map<String, dynamic> _project(Map<String, dynamic> row, List<String> columns) => {
      for (final column in columns) column: row[column],
    };

/// `kind` sólo viaja cuando es 'online': una playlist local no lleva la
/// clave, así que un servidor anterior a las playlists online (que rechaza
/// campos desconocidos) sigue recibiendo exactamente lo de siempre.
Map<String, dynamic> _projectPlaylist(Map<String, dynamic> row) => {
      ..._project(row, _playlistColumns),
      if (isOnlinePlaylistRow(row)) 'kind': kPlaylistKindOnline,
    };

bool isOnlinePlaylistRow(Map<String, dynamic> row) => row['kind'] == kPlaylistKindOnline;

/// Una playlist local y una online con el mismo nombre NO son la misma.
String _kindedNameKey(Map<String, dynamic> row) {
  final key = playlistNameKey(row['name'] as String?);
  if (key.isEmpty) return '';
  return isOnlinePlaylistRow(row) ? 'o|$key' : 'l|$key';
}

/// Une el índice de la nube DENTRO del índice local, produciendo un payload
/// que siempre es un superconjunto de lo que la nube ya tiene.
///
/// **Por qué existe esto.** `PUT /library` es un push de índice completo y el
/// servidor borra lo ausente (`library_store.py:push_library`: `DELETE ...
/// WHERE NOT (song_id = ANY($2))`, y `library_playlist_songs` se reemplaza
/// entera). Sin esta unión, cualquier equipo cuyo índice local sea más pobre
/// que el de la nube —una instalación recién hecha, un teléfono con la
/// tarjeta SD desmontada, un PC que todavía no descargó nada— borra del
/// servidor lo que sólo vive en otro dispositivo con sólo arrancar la app.
/// Es exactamente lo que CLAUDE.md prohíbe en dos sitios distintos: "Sync
/// between the app and any of its data stores is additive, never destructive
/// by default" (Core rules) y "nothing is ever deleted just because a fresh
/// install hasn't seen it yet" (Cloud sync).
///
/// El emparejamiento es por `fileHash`, igual que [missingCloudSongs] y que
/// la deduplicación de `DownloadService` — nunca por título/artista. Cuando
/// una canción de la nube ya está acá con OTRO id (una fila heredada, de
/// antes de que el id fuera el hash), gana el id local y las pertenencias de
/// la nube se reescriben a ese id: si no, la misma canción acabaría dos veces
/// en el índice con dos identidades.
///
/// **Playlists online** (`kind: 'online'`): sus pistas son referencias por
/// `videoId` (`remoteTracks` / `playlistRemoteTracks`), no archivos. Misma
/// regla aditiva: si la playlist ya existe acá se unen las pistas (el orden
/// local primero, las que sólo tiene la nube al final en el orden de la
/// nube) y nunca se quita ninguna. Una playlist online y una local jamás se
/// emparejan por nombre. El resultado lleva siempre `remoteTracks` y
/// `playlistRemoteTracks` (vacías si no hay).
///
/// Contrapartida aceptada, y es la que manda la regla aditiva: borrar una
/// canción en este equipo ya no la borra de la nube. Un borrado explícito
/// tendría que viajar como tal (una lápida), no como la ausencia de una fila
/// en el siguiente push — que es justo lo que no se puede distinguir de "este
/// equipo todavía no la tiene".
Map<String, List<Map<String, dynamic>>> unionCloudIntoLocalIndex({
  required Map<String, List<Map<String, dynamic>>> local,
  required List<Map<String, dynamic>> cloudSongs,
  required List<Map<String, dynamic>> cloudPlaylists,
  required List<Map<String, dynamic>> cloudPlaylistSongs,
  List<Map<String, dynamic>> cloudOnlinePlaylists = const [],
  List<Map<String, dynamic>> cloudRemoteTracks = const [],
  List<Map<String, dynamic>> cloudPlaylistRemoteTracks = const [],
}) {
  final localSongs = local['songs'] ?? const [];
  final localPlaylists = local['playlists'] ?? const [];
  final localPlaylistSongs = local['playlistSongs'] ?? const [];

  final songs = [for (final row in localSongs) _project(row, _songColumns)];
  final songIds = <String>{};
  final localIdByHash = <String, String>{};
  final rowById = <String, Map<String, dynamic>>{};
  for (final row in songs) {
    final id = row['songId'] as String?;
    if (id == null || id.isEmpty) continue;
    songIds.add(id);
    rowById[id] = row;
    final hash = row['fileHash'] as String?;
    if (hash != null && hash.isNotEmpty) localIdByHash.putIfAbsent(hash, () => id);
  }

  // cloudSongId -> el id con el que esa canción se conoce acá. Identidad
  // salvo cuando el hash coincide con una fila local de otro id.
  final songIdRemap = <String, String>{};
  for (final cloudSong in cloudSongs) {
    final id = cloudSong['songId'] as String?;
    final title = cloudSong['title'] as String?;
    // El servidor exige songId y title no vacíos; una fila que no los tenga
    // haría fallar el push entero con 422 en vez de subir el resto.
    if (id == null || id.isEmpty || title == null || title.isEmpty) continue;

    final hash = cloudSong['fileHash'] as String?;
    final localId = (hash != null && hash.isNotEmpty) ? localIdByHash[hash] : null;
    if (localId != null) {
      songIdRemap[id] = localId;
      // Lo local gana en todo salvo en `sourceUrl` cuando acá no hay: el
      // escáner de disco no puede saber de qué enlace salió un archivo, así
      // que un equipo que reconstruyó su biblioteca escaneando siempre lo
      // tiene vacío y, sin esto, lo borraría del índice de todos los demás.
      final row = rowById[localId];
      final cloudSourceUrl = cloudSong['sourceUrl'] as String?;
      if (row != null &&
          cloudSourceUrl != null &&
          cloudSourceUrl.isNotEmpty &&
          (row['sourceUrl'] as String?)?.isNotEmpty != true) {
        row['sourceUrl'] = cloudSourceUrl;
      }
      continue;
    }
    if (songIds.contains(id)) continue;

    songs.add(_project(cloudSong, _songColumns));
    songIds.add(id);
    rowById[id] = songs.last;
    if (hash != null && hash.isNotEmpty) localIdByHash.putIfAbsent(hash, () => id);
  }

  final playlists = [for (final row in localPlaylists) _projectPlaylist(row)];
  final playlistIds = <String>{
    for (final row in playlists)
      if (row['playlistId'] is String) row['playlistId'] as String,
  };
  final playlistRowById = {
    for (final row in playlists)
      if (row['playlistId'] is String) row['playlistId'] as String: row,
  };
  // Misma playlist con otro id (borrada y vuelta a crear, o creada por el
  // escáner desde su carpeta): gana la local, igual que con las canciones.
  // Sólo dentro del mismo tipo.
  final localIdByName = <String, String>{};
  for (final row in playlists) {
    final key = _kindedNameKey(row);
    final id = row['playlistId'];
    if (key.isNotEmpty && id is String) localIdByName.putIfAbsent(key, () => id);
  }
  final playlistIdRemap = <String, String>{};
  final allCloudPlaylists = [
    ...cloudPlaylists,
    for (final row in cloudOnlinePlaylists) {...row, 'kind': kPlaylistKindOnline},
  ];
  for (final cloudPlaylist in allCloudPlaylists) {
    var id = cloudPlaylist['playlistId'] as String?;
    final name = cloudPlaylist['name'] as String?;
    if (id == null || id.isEmpty || name == null || name.isEmpty) continue;
    final nameKey = _kindedNameKey(cloudPlaylist);
    final sameNameId = playlistIds.contains(id) ? null : localIdByName[nameKey];
    if (sameNameId != null) {
      playlistIdRemap[id] = sameNameId;
      id = sameNameId;
    }
    if (!playlistIds.add(id)) {
      // Ya existe acá: igual que con sourceUrl en las canciones, sólo se
      // rellena el hueco si este equipo no tiene originalUrl y la nube sí
      // (una restauración anterior recreó la playlist sin él) — nunca se
      // pisa lo local.
      final row = playlistRowById[id];
      final cloudOriginalUrl = cloudPlaylist['originalUrl'] as String?;
      if (row != null &&
          cloudOriginalUrl != null &&
          cloudOriginalUrl.isNotEmpty &&
          (row['originalUrl'] as String?)?.isNotEmpty != true) {
        row['originalUrl'] = cloudOriginalUrl;
      }
      continue;
    }
    playlists.add(_projectPlaylist(cloudPlaylist));
    playlistRowById[id] = playlists.last;
    if (nameKey.isNotEmpty) localIdByName.putIfAbsent(nameKey, () => id!);
  }
  final onlinePlaylistIds = <String>{
    for (final row in playlists)
      if (isOnlinePlaylistRow(row) && row['playlistId'] is String) row['playlistId'] as String,
  };

  final playlistSongs = [
    for (final row in localPlaylistSongs) _project(row, _playlistSongColumns),
  ];
  final pairs = <String>{
    for (final row in playlistSongs) '${row['playlistId']}\u0000${row['songId']}',
  };
  for (final cloudRow in cloudPlaylistSongs) {
    final rawPlaylistId = cloudRow['playlistId'] as String?;
    final rawSongId = cloudRow['songId'] as String?;
    if (rawPlaylistId == null || rawSongId == null) continue;
    final playlistId = playlistIdRemap[rawPlaylistId] ?? rawPlaylistId;
    final songId = songIdRemap[rawSongId] ?? rawSongId;
    // Una pertenencia sólo se conserva si sus dos extremos están en el
    // resultado: el servidor no tiene claves foráneas acá, así que una fila
    // huérfana se quedaría para siempre sin que nada la limpie.
    if (!playlistIds.contains(playlistId) || !songIds.contains(songId)) continue;
    if (onlinePlaylistIds.contains(playlistId)) continue;
    if (!pairs.add('$playlistId\u0000$songId')) continue;
    playlistSongs.add({
      'playlistId': playlistId,
      'songId': songId,
      'orderIndex': cloudRow['orderIndex'],
    });
  }

  final remoteTracks = [
    for (final row in local['remoteTracks'] ?? const <Map<String, dynamic>>[])
      _project(row, _remoteTrackColumns),
  ];
  final remoteById = <String, Map<String, dynamic>>{
    for (final row in remoteTracks)
      if (row['videoId'] is String) row['videoId'] as String: row,
  };
  for (final cloudTrack in cloudRemoteTracks) {
    final id = cloudTrack['videoId'] as String?;
    final title = cloudTrack['title'] as String?;
    if (id == null || id.isEmpty || title == null || title.isEmpty) continue;
    final existing = remoteById[id];
    if (existing != null) {
      // Lo local gana; sólo se rellenan los huecos.
      for (final column in const ['artist', 'album', 'thumbnailUrl', 'sourceUrl']) {
        if ((existing[column] as String?)?.isNotEmpty != true &&
            (cloudTrack[column] as String?)?.isNotEmpty == true) {
          existing[column] = cloudTrack[column];
        }
      }
      existing['durationSeconds'] ??= cloudTrack['durationSeconds'];
      continue;
    }
    remoteTracks.add(_project(cloudTrack, _remoteTrackColumns));
    remoteById[id] = remoteTracks.last;
  }

  final playlistRemoteTracks = [
    for (final row in local['playlistRemoteTracks'] ?? const <Map<String, dynamic>>[])
      _project(row, _playlistRemoteTrackColumns),
  ];
  final remotePairs = <String>{
    for (final row in playlistRemoteTracks) '${row['playlistId']}\u0000${row['videoId']}',
  };
  final nextRemoteOrder = <String, int>{};
  for (final row in playlistRemoteTracks) {
    final id = '${row['playlistId']}';
    final order = (row['orderIndex'] as num?)?.toInt() ?? 0;
    if (order + 1 > (nextRemoteOrder[id] ?? 0)) nextRemoteOrder[id] = order + 1;
  }
  // Orden estable por el orden de la nube (el índice original desempata).
  final cloudMembership = [
    for (var i = 0; i < cloudPlaylistRemoteTracks.length; i++) (i, cloudPlaylistRemoteTracks[i]),
  ]..sort((a, b) {
      final byOrder = ((a.$2['orderIndex'] as num?)?.toInt() ?? 0)
          .compareTo((b.$2['orderIndex'] as num?)?.toInt() ?? 0);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });
  for (final (_, cloudRow) in cloudMembership) {
    final rawPlaylistId = cloudRow['playlistId'] as String?;
    final videoId = cloudRow['videoId'] as String?;
    if (rawPlaylistId == null || videoId == null) continue;
    final playlistId = playlistIdRemap[rawPlaylistId] ?? rawPlaylistId;
    if (!onlinePlaylistIds.contains(playlistId) || !remoteById.containsKey(videoId)) continue;
    if (!remotePairs.add('$playlistId\u0000$videoId')) continue;
    final next = nextRemoteOrder[playlistId] ?? 0;
    nextRemoteOrder[playlistId] = next + 1;
    playlistRemoteTracks.add({'playlistId': playlistId, 'videoId': videoId, 'orderIndex': next});
  }

  return {
    'songs': songs,
    'playlists': playlists,
    'playlistSongs': playlistSongs,
    'remoteTracks': remoteTracks,
    'playlistRemoteTracks': playlistRemoteTracks,
  };
}

/// Qué hay que crear o completar en la base local para que las playlists
/// online del índice unido ([merged], salida de [unionCloudIntoLocalIndex])
/// existan también acá.
class OnlinePlaylistImport {
  final String playlistId;
  final String name;
  final String? originalUrl;

  /// `true` si la playlist no existe localmente y hay que crearla.
  final bool isNew;

  /// Pistas que a la playlist local le faltan, en el orden del índice unido
  /// (que es: lo local primero, lo de la nube después). Cada una con las
  /// columnas de `remote_tracks`.
  final List<Map<String, dynamic>> tracks;

  const OnlinePlaylistImport({
    required this.playlistId,
    required this.name,
    required this.originalUrl,
    required this.isNew,
    required this.tracks,
  });
}

/// Compara el índice unido contra el local y devuelve sólo lo que falta
/// materializar de las playlists online. Puro y aditivo: nunca incluye nada
/// que quitar. [local] es la salida de `getLibraryIndexRows(includeOnline:
/// true)`.
List<OnlinePlaylistImport> planOnlineMaterialization({
  required Map<String, List<Map<String, dynamic>>> local,
  required Map<String, List<Map<String, dynamic>>> merged,
}) {
  final localPlaylistIds = {
    for (final row in local['playlists'] ?? const <Map<String, dynamic>>[])
      if (row['playlistId'] is String) row['playlistId'] as String,
  };
  final localPairs = {
    for (final row in local['playlistRemoteTracks'] ?? const <Map<String, dynamic>>[])
      '${row['playlistId']}\u0000${row['videoId']}',
  };
  final trackById = {
    for (final row in merged['remoteTracks'] ?? const <Map<String, dynamic>>[])
      if (row['videoId'] is String) row['videoId'] as String: row,
  };
  final membersByPlaylist = <String, List<Map<String, dynamic>>>{};
  for (final row in merged['playlistRemoteTracks'] ?? const <Map<String, dynamic>>[]) {
    membersByPlaylist.putIfAbsent('${row['playlistId']}', () => []).add(row);
  }

  final plan = <OnlinePlaylistImport>[];
  for (final playlist in merged['playlists'] ?? const <Map<String, dynamic>>[]) {
    if (!isOnlinePlaylistRow(playlist)) continue;
    final id = playlist['playlistId'] as String?;
    if (id == null) continue;
    final members = [...(membersByPlaylist[id] ?? const <Map<String, dynamic>>[])]
      ..sort((a, b) => ((a['orderIndex'] as num?)?.toInt() ?? 0)
          .compareTo((b['orderIndex'] as num?)?.toInt() ?? 0));
    final missing = [
      for (final member in members)
        if (!localPairs.contains('$id\u0000${member['videoId']}') && trackById[member['videoId']] != null)
          trackById[member['videoId']]!,
    ];
    final isNew = !localPlaylistIds.contains(id);
    if (!isNew && missing.isEmpty) continue;
    plan.add(OnlinePlaylistImport(
      playlistId: id,
      name: (playlist['name'] as String?) ?? '',
      originalUrl: playlist['originalUrl'] as String?,
      isNew: isNew,
      tracks: missing,
    ));
  }
  return plan;
}
