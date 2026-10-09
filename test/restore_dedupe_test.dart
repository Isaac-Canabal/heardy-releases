// Restauración desde la nube sin duplicados: playlist borrada y vuelta a cargar,
// filas repetidas por hash y canciones que ya están en el equipo.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/library_diff.dart';

void main() {
  group('missingCloudSongs', () {
    test('dos filas con el mismo hash faltan una sola vez', () {
      final cloud = [
        {'songId': 'viejo', 'fileHash': 'a', 'title': 'Uno'},
        {'songId': 'nuevo', 'fileHash': 'a', 'title': 'Uno'},
      ];
      expect(missingCloudSongs(cloud, {}), hasLength(1));
    });
  });

  group('canonicalizeCloudIndex', () {
    test('playlist borrada y recreada (mismo nombre, otro id) queda una sola', () {
      final c = canonicalizeCloudIndex(
        [
          {'songId': 's1', 'fileHash': 'a', 'title': 'Uno'},
        ],
        [
          {'playlistId': 'p-viejo', 'name': 'Rock', 'originalUrl': null},
          {'playlistId': 'p-nuevo', 'name': ' rock ', 'originalUrl': 'https://yt/list'},
        ],
        [
          {'playlistId': 'p-viejo', 'songId': 's1', 'orderIndex': 0},
          {'playlistId': 'p-nuevo', 'songId': 's1', 'orderIndex': 0},
        ],
      );
      expect(c.playlists, hasLength(1));
      expect(c.playlists.single['playlistId'], 'p-viejo');
      expect(c.playlists.single['originalUrl'], 'https://yt/list');
      expect(c.playlistSongs, hasLength(1));
    });

    test('canción con id heredado y id nuevo: una fila y pertenencias reescritas', () {
      final c = canonicalizeCloudIndex(
        [
          {'songId': 'viejo', 'fileHash': 'a', 'title': 'Uno'},
          {'songId': 'nuevo', 'fileHash': 'a', 'title': 'Uno', 'sourceUrl': 'u'},
        ],
        [
          {'playlistId': 'p1', 'name': 'A'},
          {'playlistId': 'p2', 'name': 'B'},
        ],
        [
          {'playlistId': 'p1', 'songId': 'viejo', 'orderIndex': 0},
          {'playlistId': 'p2', 'songId': 'nuevo', 'orderIndex': 0},
        ],
      );
      expect(c.songs, hasLength(1));
      expect(c.songs.single['sourceUrl'], 'u');
      expect(c.playlistSongs.map((r) => r['songId']).toSet(), {'viejo'});
      expect(c.playlistSongs, hasLength(2));
    });

    test('no muta la entrada', () {
      final songs = [
        {'songId': 'a', 'fileHash': 'h'},
      ];
      canonicalizeCloudIndex(songs, const [], const []);
      expect(songs.single.containsKey('sourceUrl'), isFalse);
    });
  });

  group('localPlaylistIdByCloudId', () {
    test('usa la playlist local con el mismo nombre aunque el id difiera', () {
      final map = localPlaylistIdByCloudId(
        [
          {'playlistId': 'nube-1', 'name': 'Rock'},
          {'playlistId': 'nube-2', 'name': 'Pop'},
          {'playlistId': 'local-3', 'name': 'Otra'},
        ],
        [(id: 'local-1', name: 'rock'), (id: 'local-3', name: 'Distinto')],
      );
      expect(map, {'nube-1': 'local-1', 'local-3': 'local-3'});
    });
  });

  group('unionCloudIntoLocalIndex', () {
    test('una playlist de la nube con el nombre de una local no se agrega aparte', () {
      final merged = unionCloudIntoLocalIndex(
        local: {
          'songs': [
            {'songId': 'a', 'title': 'Uno', 'fileHash': 'a'},
          ],
          'playlists': [
            {'playlistId': 'local', 'name': 'Rock', 'sortOrder': 0},
          ],
          'playlistSongs': [
            {'playlistId': 'local', 'songId': 'a', 'orderIndex': 0},
          ],
        },
        cloudSongs: [
          {'songId': 'a', 'title': 'Uno', 'fileHash': 'a'},
          {'songId': 'b', 'title': 'Dos', 'fileHash': 'b'},
        ],
        cloudPlaylists: [
          {'playlistId': 'nube', 'name': 'Rock', 'sortOrder': 0},
        ],
        cloudPlaylistSongs: [
          {'playlistId': 'nube', 'songId': 'b', 'orderIndex': 1},
        ],
      );
      expect(merged['playlists'], hasLength(1));
      expect(
        merged['playlistSongs']!.map((r) => '${r['playlistId']} ${r['songId']}').toSet(),
        {'local a', 'local b'},
      );
    });
  });

  group('sourceUrlAlreadyKnown', () {
    test('mismo vídeo con otra forma de enlace ya está', () {
      final known = knownLocalSourceUrls(
        localSourceUrls: {'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
        cloudSongs: const [],
        localFileHashes: const {},
      );
      expect(sourceUrlAlreadyKnown('https://youtu.be/dQw4w9WgXcQ', known), isTrue);
      expect(sourceUrlAlreadyKnown('https://youtu.be/AAAAAAAAAAA', known), isFalse);
    });

    test('el enlace de una fila de la nube cuyo audio ya está localmente cuenta', () {
      final known = knownLocalSourceUrls(
        localSourceUrls: const {},
        cloudSongs: [
          {'fileHash': 'a', 'sourceUrl': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
          {'fileHash': 'b', 'sourceUrl': 'https://www.youtube.com/watch?v=AAAAAAAAAAA'},
        ],
        localFileHashes: {'a'},
      );
      expect(sourceUrlAlreadyKnown('https://www.youtube.com/watch?v=dQw4w9WgXcQ', known), isTrue);
      expect(sourceUrlAlreadyKnown('https://www.youtube.com/watch?v=AAAAAAAAAAA', known), isFalse);
    });
  });
}
