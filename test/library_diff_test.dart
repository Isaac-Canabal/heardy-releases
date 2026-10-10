// Cubre missingCloudSongs, la comparación pura de W6 del plan de escritorio
// (estrategia híbrida, Etapa 16 E-2) — sin base de datos ni red.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/library_diff.dart';

void main() {
  group('missingCloudSongs', () {
    test('las canciones cuyo hash ya está localmente no faltan', () {
      final cloud = [
        {'fileHash': 'a', 'title': 'Uno', 'artist': 'X'},
        {'fileHash': 'b', 'title': 'Dos', 'artist': 'Y'},
      ];

      final missing = missingCloudSongs(cloud, {'a'});

      expect(missing, hasLength(1));
      expect(missing.single['title'], 'Dos');
    });

    test('compara por hash, no por título/artista', () {
      final cloud = [
        {'fileHash': 'a', 'title': 'Título distinto', 'artist': 'Otro nombre'},
      ];

      // Mismo audio (mismo hash), aunque los tags no coincidan en texto.
      final missing = missingCloudSongs(cloud, {'a'});

      expect(missing, isEmpty);
    });

    test('una fila sin hash nunca cuenta como que falta', () {
      final cloud = [
        {'fileHash': null, 'title': 'Sin hash'},
        {'fileHash': '', 'title': 'Hash vacío'},
      ];

      expect(missingCloudSongs(cloud, {}), isEmpty);
    });

    test('conserva el orden de entrada', () {
      final cloud = [
        {'fileHash': 'a', 'title': 'A'},
        {'fileHash': 'b', 'title': 'B'},
        {'fileHash': 'c', 'title': 'C'},
      ];

      final missing = missingCloudSongs(cloud, {});

      expect(missing.map((s) => s['title']), ['A', 'B', 'C']);
    });

    test('biblioteca en la nube vacía nunca falta nada', () {
      expect(missingCloudSongs([], {'a', 'b'}), isEmpty);
    });
  });

  group('unionCloudIntoLocalIndex', () {
    Map<String, dynamic> song(String id, {String? hash, String title = 'T'}) => {
          'songId': id,
          'title': title,
          'artist': 'A',
          'album': null,
          'durationSeconds': 180,
          'fileHash': hash ?? id,
          'hashKind': 'mp4-mdat',
        };

    Map<String, List<Map<String, dynamic>>> index({
      List<Map<String, dynamic>> songs = const [],
      List<Map<String, dynamic>> playlists = const [],
      List<Map<String, dynamic>> playlistSongs = const [],
    }) =>
        {'songs': songs, 'playlists': playlists, 'playlistSongs': playlistSongs};

    test('un índice local vacío conserva entera la biblioteca de la nube', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(),
        cloudSongs: [song('a'), song('b')],
        cloudPlaylists: [
          {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0},
        ],
        cloudPlaylistSongs: [
          {'playlistId': 'p1', 'songId': 'a', 'orderIndex': 0},
          {'playlistId': 'p1', 'songId': 'b', 'orderIndex': 1},
        ],
      );

      expect(merged['songs'], hasLength(2));
      expect(merged['playlists'], hasLength(1));
      expect(merged['playlistSongs'], hasLength(2));
    });

    test('el orden de la nube sobrevive cuando este equipo no tiene la canción', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(),
        cloudSongs: [song('a'), song('b')],
        cloudPlaylists: [
          {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 3},
        ],
        cloudPlaylistSongs: [
          {'playlistId': 'p1', 'songId': 'b', 'orderIndex': 0},
          {'playlistId': 'p1', 'songId': 'a', 'orderIndex': 1},
        ],
      );

      final rows = merged['playlistSongs']!;
      expect(rows.firstWhere((r) => r['songId'] == 'b')['orderIndex'], 0);
      expect(rows.firstWhere((r) => r['songId'] == 'a')['orderIndex'], 1);
      expect(merged['playlists']!.single['sortOrder'], 3);
    });

    test('la misma canción en los dos lados no se duplica y gana lo local', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(songs: [song('a', title: 'Título local')]),
        cloudSongs: [song('a', title: 'Título viejo de la nube')],
        cloudPlaylists: const [],
        cloudPlaylistSongs: const [],
      );

      expect(merged['songs'], hasLength(1));
      expect(merged['songs']!.single['title'], 'Título local');
    });

    test('emparejada por hash, una fila heredada con otro id no se duplica', () {
      // La fila local es de antes de que el id fuera el hash (D2: las filas
      // heredadas conservan el id con el que nacieron).
      final merged = unionCloudIntoLocalIndex(
        local: index(
          songs: [song('id-viejo', hash: 'h1')],
          playlists: [
            {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0},
          ],
        ),
        cloudSongs: [song('h1', hash: 'h1')],
        cloudPlaylists: const [],
        cloudPlaylistSongs: [
          {'playlistId': 'p1', 'songId': 'h1', 'orderIndex': 0},
        ],
      );

      expect(merged['songs'], hasLength(1));
      expect(merged['songs']!.single['songId'], 'id-viejo');
      // La pertenencia de la nube se reescribe al id con el que la canción se
      // conoce acá; si no, apuntaría a una canción que no está en el payload.
      expect(merged['playlistSongs']!.single['songId'], 'id-viejo');
    });

    test('una pertenencia huérfana de la nube se descarta', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(),
        cloudSongs: const [],
        cloudPlaylists: const [],
        cloudPlaylistSongs: [
          {'playlistId': 'fantasma', 'songId': 'fantasma', 'orderIndex': 0},
        ],
      );

      expect(merged['playlistSongs'], isEmpty);
    });

    test('una fila de la nube sin id o sin título no entra en el payload', () {
      // El servidor exige ambos (min_length=1): colarlos haría fallar el
      // push entero con 422 en vez de subir el resto.
      final merged = unionCloudIntoLocalIndex(
        local: index(),
        cloudSongs: [
          {'songId': '', 'title': 'Sin id'},
          {'songId': 'x', 'title': ''},
        ],
        cloudPlaylists: [
          {'playlistId': 'p', 'name': ''},
        ],
        cloudPlaylistSongs: const [],
      );

      expect(merged['songs'], isEmpty);
      expect(merged['playlists'], isEmpty);
    });

    test('sólo se emiten las columnas que el servidor acepta', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(songs: [
          {...song('a'), 'uri': 'content://x/a', 'artPath': '/data/art.jpg', 'missing': 0},
        ]),
        cloudSongs: const [],
        cloudPlaylists: const [],
        cloudPlaylistSongs: const [],
      );

      expect(
        merged['songs']!.single.keys.toSet(),
        {'songId', 'title', 'artist', 'album', 'durationSeconds', 'fileHash', 'hashKind', 'sourceUrl'},
      );
    });

    test('un equipo que escaneó el disco no borra el sourceUrl que subió otro', () {
      // El escáner no puede saber de qué enlace salió un archivo, así que un
      // equipo reconstruido desde disco siempre lo tiene vacío. Sin esta
      // regla, su push lo borraría del índice de todos los demás y la opción
      // de "actualizar" desaparecería para siempre.
      final merged = unionCloudIntoLocalIndex(
        local: index(songs: [
          {...song('a'), 'sourceUrl': null},
        ]),
        cloudSongs: [
          {...song('a'), 'sourceUrl': 'https://www.youtube.com/watch?v=abc'},
        ],
        cloudPlaylists: const [],
        cloudPlaylistSongs: const [],
      );

      expect(merged['songs']!.single['sourceUrl'], 'https://www.youtube.com/watch?v=abc');
    });

    test('un sourceUrl local no lo pisa el de la nube', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(songs: [
          {...song('a'), 'sourceUrl': 'https://www.youtube.com/watch?v=nuevo'},
        ]),
        cloudSongs: [
          {...song('a'), 'sourceUrl': 'https://www.youtube.com/watch?v=viejo'},
        ],
        cloudPlaylists: const [],
        cloudPlaylistSongs: const [],
      );

      expect(merged['songs']!.single['sourceUrl'], 'https://www.youtube.com/watch?v=nuevo');
    });

    test('sólo se emiten las columnas de playlist que el servidor acepta', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(),
        cloudSongs: const [],
        cloudPlaylists: [
          {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0, 'originalUrl': null},
        ],
        cloudPlaylistSongs: const [],
      );

      expect(
        merged['playlists']!.single.keys.toSet(),
        {'playlistId', 'name', 'sortOrder', 'originalUrl'},
      );
    });

    test('una playlist restaurada sin originalUrl lo recupera de la nube', () {
      // Una restauración anterior (antes de que originalUrl se sincronizara,
      // o porque el enlace ya no resolvía) recreó la playlist sin él — sin
      // este relleno, el botón "Actualizar desde YouTube" no vuelve a
      // aparecer nunca, aunque la nube sí sepa el enlace original.
      final merged = unionCloudIntoLocalIndex(
        local: index(playlists: [
          {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0, 'originalUrl': null},
        ]),
        cloudSongs: const [],
        cloudPlaylists: [
          {
            'playlistId': 'p1',
            'name': 'Favoritas',
            'sortOrder': 0,
            'originalUrl': 'https://www.youtube.com/playlist?list=abc',
          },
        ],
        cloudPlaylistSongs: const [],
      );

      expect(merged['playlists']!.single['originalUrl'], 'https://www.youtube.com/playlist?list=abc');
    });

    test('un originalUrl local no lo pisa el de la nube', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(playlists: [
          {
            'playlistId': 'p1',
            'name': 'Favoritas',
            'sortOrder': 0,
            'originalUrl': 'https://www.youtube.com/playlist?list=nuevo',
          },
        ]),
        cloudSongs: const [],
        cloudPlaylists: [
          {
            'playlistId': 'p1',
            'name': 'Favoritas',
            'sortOrder': 0,
            'originalUrl': 'https://www.youtube.com/playlist?list=viejo',
          },
        ],
        cloudPlaylistSongs: const [],
      );

      expect(merged['playlists']!.single['originalUrl'], 'https://www.youtube.com/playlist?list=nuevo');
    });

    test('un par que ya existe localmente no se duplica desde la nube', () {
      final merged = unionCloudIntoLocalIndex(
        local: index(
          songs: [song('a')],
          playlists: [
            {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0},
          ],
          playlistSongs: [
            {'playlistId': 'p1', 'songId': 'a', 'orderIndex': 5},
          ],
        ),
        cloudSongs: [song('a')],
        cloudPlaylists: [
          {'playlistId': 'p1', 'name': 'Favoritas', 'sortOrder': 0},
        ],
        cloudPlaylistSongs: [
          {'playlistId': 'p1', 'songId': 'a', 'orderIndex': 0},
        ],
      );

      expect(merged['playlistSongs'], hasLength(1));
      // Gana el orden local: es el que el usuario ve en este equipo.
      expect(merged['playlistSongs']!.single['orderIndex'], 5);
    });
  });

  group('uniqueCloudSongCount', () {
    test('cuenta filas con distinto hash como canciones distintas', () {
      final cloud = [
        {'fileHash': 'a', 'title': 'Uno'},
        {'fileHash': 'b', 'title': 'Dos'},
      ];
      expect(uniqueCloudSongCount(cloud), 2);
    });

    test('dos filas con el mismo hash (id heredado + id nuevo) cuentan una sola vez', () {
      final cloud = [
        {'fileHash': 'a', 'title': 'Uno (id viejo)'},
        {'fileHash': 'a', 'title': 'Uno (id nuevo)'},
        {'fileHash': 'b', 'title': 'Dos'},
      ];
      expect(uniqueCloudSongCount(cloud), 2);
    });

    test('una fila sin hash cuenta por sí misma, nunca se agrupa con otra', () {
      final cloud = [
        {'fileHash': null, 'title': 'Sin hash 1'},
        {'fileHash': '', 'title': 'Sin hash 2'},
      ];
      expect(uniqueCloudSongCount(cloud), 2);
    });
  });

  group('cloudOnlySongs', () {
    test('excluye lo que ya está por hash, incluso si la fila local está missing', () {
      final cloud = [
        {'songId': '1', 'fileHash': 'a', 'title': 'Uno'},
        {'songId': '2', 'fileHash': 'b', 'title': 'Dos'},
      ];
      final result = cloudOnlySongs(cloud, localFileHashes: {'a'});
      expect(result.map((s) => s['title']), ['Dos']);
    });

    test('excluye lo que ya se conoce por id de vídeo del sourceUrl', () {
      final cloud = [
        {'songId': '1', 'fileHash': 'a', 'title': 'Uno', 'sourceUrl': 'https://youtu.be/dQw4w9WgXcQ'},
        {'songId': '2', 'fileHash': 'b', 'title': 'Dos', 'sourceUrl': 'https://youtu.be/aaaaaaaaaaa'},
      ];
      final result = cloudOnlySongs(
        cloud,
        localFileHashes: const {},
        localSourceUrls: {'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
      );
      expect(result.map((s) => s['title']), ['Dos']);
    });

    test('sin sourceUrl se conserva y filas repetidas por hash salen una vez', () {
      final cloud = [
        {'songId': '1', 'fileHash': 'a', 'title': 'Uno'},
        {'songId': '2', 'fileHash': 'a', 'title': 'Uno'},
      ];
      expect(cloudOnlySongs(cloud, localFileHashes: const {}), hasLength(1));
    });
  });

  group('remoteTrackFromCloudSong', () {
    test('construye el RemoteTrack desde el sourceUrl de YouTube', () {
      final track = remoteTrackFromCloudSong({
        'title': 'Uno',
        'artist': 'X',
        'album': 'Disco',
        'durationSeconds': 200,
        'sourceUrl': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      });
      expect(track, isNotNull);
      expect(track!.id, 'dQw4w9WgXcQ');
      expect(track.title, 'Uno');
      expect(track.artist, 'X');
      expect(track.album, 'Disco');
      expect(track.durationSeconds, 200);
      expect(track.sourceUrl, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    test('sin sourceUrl no hay track', () {
      expect(remoteTrackFromCloudSong({'title': 'Uno'}), isNull);
      expect(remoteTrackFromCloudSong({'title': 'Uno', 'sourceUrl': ''}), isNull);
    });
  });
}
