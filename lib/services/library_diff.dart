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
  return cloudSongs.where((song) {
    final hash = song['fileHash'] as String?;
    // Sin hash no hay forma de emparejar — nunca se asume "falta" ni
    // "está" sobre un dato que no está.
    if (hash == null || hash.isEmpty) return false;
    return !localFileHashes.contains(hash);
  }).toList();
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

Map<String, dynamic> _project(Map<String, dynamic> row, List<String> columns) => {
      for (final column in columns) column: row[column],
    };

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

  final playlists = [for (final row in localPlaylists) _project(row, _playlistColumns)];
  final playlistIds = <String>{
    for (final row in playlists)
      if (row['playlistId'] is String) row['playlistId'] as String,
  };
  final playlistRowById = {
    for (final row in playlists)
      if (row['playlistId'] is String) row['playlistId'] as String: row,
  };
  for (final cloudPlaylist in cloudPlaylists) {
    final id = cloudPlaylist['playlistId'] as String?;
    final name = cloudPlaylist['name'] as String?;
    if (id == null || id.isEmpty || name == null || name.isEmpty) continue;
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
    playlists.add(_project(cloudPlaylist, _playlistColumns));
    playlistRowById[id] = playlists.last;
  }

  final playlistSongs = [
    for (final row in localPlaylistSongs) _project(row, _playlistSongColumns),
  ];
  final pairs = <String>{
    for (final row in playlistSongs) '${row['playlistId']} ${row['songId']}',
  };
  for (final cloudRow in cloudPlaylistSongs) {
    final playlistId = cloudRow['playlistId'] as String?;
    final rawSongId = cloudRow['songId'] as String?;
    if (playlistId == null || rawSongId == null) continue;
    final songId = songIdRemap[rawSongId] ?? rawSongId;
    // Una pertenencia sólo se conserva si sus dos extremos están en el
    // resultado: el servidor no tiene claves foráneas acá, así que una fila
    // huérfana se quedaría para siempre sin que nada la limpie.
    if (!playlistIds.contains(playlistId) || !songIds.contains(songId)) continue;
    if (!pairs.add('$playlistId $songId')) continue;
    playlistSongs.add({
      'playlistId': playlistId,
      'songId': songId,
      'orderIndex': cloudRow['orderIndex'],
    });
  }

  return {'songs': songs, 'playlists': playlists, 'playlistSongs': playlistSongs};
}
