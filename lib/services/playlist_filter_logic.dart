import '../models/playlist.dart';

/// Filtro de Inicio: "Descargadas" son las playlists locales y "No
/// descargadas" las online.
enum PlaylistKindFilter { all, downloaded, notDownloaded }

List<Playlist> filterPlaylistsByKind(List<Playlist> playlists, PlaylistKindFilter filter) {
  switch (filter) {
    case PlaylistKindFilter.all:
      return List.of(playlists);
    case PlaylistKindFilter.downloaded:
      return playlists.where((p) => !p.isOnline).toList();
    case PlaylistKindFilter.notDownloaded:
      return playlists.where((p) => p.isOnline).toList();
  }
}

/// [query] llega ya en minúsculas y sin espacios en los bordes.
List<Playlist> filterHomePlaylists(List<Playlist> playlists, PlaylistKindFilter filter, String query) =>
    filterPlaylistsByKind(playlists, filter).where((p) => p.name.toLowerCase().contains(query)).toList();

/// [kind] null = sin filtro.
List<Playlist> playlistsOfKind(List<Playlist> playlists, String? kind) =>
    kind == null ? List.of(playlists) : playlists.where((p) => p.kind == kind).toList();

/// Las carpetas del escáner sólo pueden corresponder a playlists locales: una
/// carpeta con el nombre de una online no debe colgarle canciones descargadas.
Map<String, String> localPlaylistIdsByName(List<Playlist> playlists) => {
      for (final p in playlists)
        if (!p.isOnline) p.name: p.id,
    };
