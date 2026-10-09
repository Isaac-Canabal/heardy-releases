// Cubre missingPlaylistEntries, la función que decide qué reencolar cuando
// el usuario pulsa "Actualizar desde YouTube" en una playlist con
// `originalUrl` (Fase 6).
//
// No es un test de widgets: PlaylistDetailScreen exige un AudioPlayerHandler
// real (que crea un AudioPlayer de just_audio con canales de plataforma de
// verdad), y este proyecto no tiene ningún fake para eso todavía. Probar la
// pantalla completa habría significado mockear el canal de método de
// just_audio desde cero — desproporcionado para verificar lo que en el fondo
// es una comparación de conjuntos. Por eso la función se extrajo aparte
// (`@visibleForTesting`) y se prueba aislada; la limitación de cobertura de
// la pantalla queda documentada, no escondida.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/screens/playlist_detail_screen.dart';
import 'package:heardy/services/download_source.dart';

RemoteTrack _entry(String id, {String title = 'T', String artist = 'A'}) {
  return RemoteTrack(
    id: id,
    title: title,
    artist: artist,
    album: null,
    durationSeconds: 100,
    thumbnailUrl: '',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
  );
}

Song _song({required String id, String? sourceUrl}) {
  return Song(
    id: id,
    title: 'Existente $id',
    artist: 'Artista',
    duration: 100,
    filePath: '',
    artPath: '',
    format: 'm4a',
    downloadDate: DateTime.now(),
    sourceUrl: sourceUrl,
  );
}

void main() {
  group('missingPlaylistEntries', () {
    test('sin canciones existentes, todas las entradas están pendientes', () {
      final remote = RemotePlaylist(
        id: 'PL1',
        name: 'Lista',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: [_entry('a'), _entry('b'), _entry('c')],
      );

      final missing = missingPlaylistEntries(remote, const []);

      expect(missing.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('las entradas cuyo sourceUrl ya está en la playlist se excluyen', () {
      final remote = RemotePlaylist(
        id: 'PL1',
        name: 'Lista',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: [_entry('a'), _entry('b'), _entry('c')],
      );
      final existing = [
        _song(id: 'hash-a', sourceUrl: 'https://www.youtube.com/watch?v=a'),
        _song(id: 'hash-c', sourceUrl: 'https://www.youtube.com/watch?v=c'),
      ];

      final missing = missingPlaylistEntries(remote, existing);

      expect(missing.map((e) => e.id), ['b']);
    });

    test('si ya están todas, no queda nada por encolar', () {
      final remote = RemotePlaylist(
        id: 'PL1',
        name: 'Lista',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: [_entry('a'), _entry('b')],
      );
      final existing = [
        _song(id: 'hash-a', sourceUrl: 'https://www.youtube.com/watch?v=a'),
        _song(id: 'hash-b', sourceUrl: 'https://www.youtube.com/watch?v=b'),
      ];

      expect(missingPlaylistEntries(remote, existing), isEmpty);
    });

    test('una canción sin sourceUrl (importada a mano, no descargada) nunca tapa una entrada remota', () {
      // Si el filtro comparara mal un `sourceUrl` nulo, una canción que el
      // usuario copió a mano a la carpeta podría "contar" como si ya
      // cubriera cualquier entrada remota — el `whereType<String>()` de
      // missingPlaylistEntries es justamente lo que evita eso.
      final remote = RemotePlaylist(
        id: 'PL1',
        name: 'Lista',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: [_entry('a')],
      );
      final existing = [_song(id: 'hash-manual', sourceUrl: null)];

      final missing = missingPlaylistEntries(remote, existing);

      expect(missing.map((e) => e.id), ['a']);
    });

    test('una playlist remota vacía no produce nada que encolar', () {
      final remote = RemotePlaylist(
        id: 'PL1',
        name: 'Lista vacía',
        sourceUrl: 'https://youtube.com/playlist?list=PL1',
        entries: const [],
      );

      expect(missingPlaylistEntries(remote, [_song(id: 'x', sourceUrl: 'https://y/x')]), isEmpty);
    });
  });
}
