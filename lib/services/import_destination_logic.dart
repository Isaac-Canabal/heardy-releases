import '../models/playlist.dart';
import '../models/remote_track_record.dart';
import 'download_source.dart';

/// Lógica pura del flujo "importar / añadir": decide qué pregunta hacer y qué
/// hacer según el tipo de la playlist destino. Va aparte de las pantallas para
/// poder probarla sin widgets.

enum ImportUrlShape { singleVideo, pureYoutubePlaylist, videoInPlaylist, other }

/// Cómo se ve un enlace de YouTube; `other` es todo lo que no tenga `list=` ni
/// pinta de vídeo (Spotify, texto suelto...).
ImportUrlShape classifyImportChoice(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasAuthority) return ImportUrlShape.other;
  final hasList = (uri.queryParameters['list'] ?? '').isNotEmpty;
  final host = uri.host.toLowerCase();
  final isShort = host == 'youtu.be' || host.endsWith('.youtu.be');
  final hasVideo = isShort
      ? uri.pathSegments.isNotEmpty
      : (uri.queryParameters['v'] ?? '').isNotEmpty ||
          (uri.pathSegments.length >= 2 && (uri.pathSegments.first == 'shorts' || uri.pathSegments.first == 'embed'));
  if (hasList && hasVideo) return ImportUrlShape.videoInPlaylist;
  if (hasList) return ImportUrlShape.pureYoutubePlaylist;
  if (hasVideo) return ImportUrlShape.singleVideo;
  return ImportUrlShape.other;
}

/// Sólo un vídeo que viaja dentro de una lista admite dos lecturas.
bool needsSongOrPlaylistQuestion(String url) =>
    classifyImportChoice(url) == ImportUrlShape.videoInPlaylist;

/// El mismo enlace sin `list`/`index`/`start_radio`, para resolver "sólo esta
/// canción".
String songOnlyUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return url;
  final params = Map<String, String>.of(uri.queryParameters)
    ..remove('list')
    ..remove('index')
    ..remove('start_radio');
  final cleaned = uri.replace(queryParameters: params).toString();
  return cleaned.endsWith('?') ? cleaned.substring(0, cleaned.length - 1) : cleaned;
}

enum DestinationAction { download, saveReferences }

/// Playlist local = descarga de siempre; online = sólo referencias.
DestinationAction destinationActionForKind(String kind) =>
    kind == Playlist.kindOnline ? DestinationAction.saveReferences : DestinationAction.download;

/// Tipo del destino elegido: el de la playlist existente (local si ya no
/// existe) o el que se fijó al crear la nueva.
String destinationKind({
  required String? existingPlaylistId,
  required String newPlaylistKind,
  required List<Playlist> playlists,
}) {
  if (existingPlaylistId == null) return newPlaylistKind;
  for (final p in playlists) {
    if (p.id == existingPlaylistId) return p.kind;
  }
  return Playlist.kindLocal;
}

/// Referencias a guardar para [tracks], en el mismo orden y sin repetir
/// vídeos ni entradas sin id.
List<RemoteTrackRecord> recordsFromTracks(Iterable<RemoteTrack> tracks) {
  final seen = <String>{};
  return [
    for (final t in tracks)
      if (t.id.isNotEmpty && seen.add(t.id)) RemoteTrackRecord.fromRemoteTrack(t),
  ];
}
