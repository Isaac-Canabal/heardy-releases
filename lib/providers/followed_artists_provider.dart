import 'package:flutter/foundation.dart';

import '../models/followed_artist.dart';
import '../services/app_log.dart';
import '../services/database_helper.dart';
import 'folder_sync_provider.dart';

/// Artistas seguidos en este dispositivo; no necesita sesión. Va aparte de
/// [ExploreProvider] porque lo usan el perfil y Explorar a la vez y debe
/// reaccionar al instante, sin los ciclos de carga de las estanterías.
class FollowedArtistsProvider extends ChangeNotifier {
  final DatabaseHelper _db;
  final DateTime Function() _now;

  List<FollowedArtist> _followed = const [];
  bool _isLoaded = false;
  int _revision = 0;

  FollowedArtistsProvider({DatabaseHelper? db, DateTime Function()? now})
      : _db = db ?? DatabaseHelper.instance,
        _now = now ?? DateTime.now;

  /// El más reciente primero.
  List<FollowedArtist> get followed => _followed;
  bool get isLoaded => _isLoaded;

  /// Cambia con cada cambio de la lista, para que Explorar sepa cuándo
  /// actualizar las novedades.
  int get revision => _revision;

  bool isFollowing(String channelId) => _followed.any((a) => a.channelId == channelId);

  Future<void> load() async {
    try {
      _followed = await _db.getFollowedArtists();
    } catch (e) {
      appLog('Artistas seguidos: no se pudieron leer (${e.runtimeType})');
    } finally {
      _isLoaded = true;
      _revision++;
      notifyListeners();
    }
  }

  Future<void> follow({required String channelId, required String name, String thumbnailUrl = ''}) async {
    if (channelId.isEmpty || isFollowing(channelId)) return;
    final artist = FollowedArtist(channelId: channelId, name: name, thumbnailUrl: thumbnailUrl, followedAt: _now());
    _apply([artist, ..._followed]);
    await _persist(() => _db.upsertFollowedArtist(artist));
  }

  Future<void> unfollow(String channelId) async {
    if (!isFollowing(channelId)) return;
    _apply([for (final a in _followed) if (a.channelId != channelId) a]);
    await _persist(() => _db.markArtistUnfollowed(channelId, _now()));
  }

  void _apply(List<FollowedArtist> next) {
    _followed = next;
    _revision++;
    notifyListeners();
  }

  /// La pantalla ya cambió antes de escribir; si la escritura falla, manda el disco.
  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      appLog('Artistas seguidos: no se pudo guardar (${e.runtimeType})');
      await load();
    }
  }
}

/// Recarga los seguidos cuando una sincronización por carpeta los cambió, como
/// `bindOnlinePlaylistsRefresh`: el cableado vive donde se crean ambos. El Wi-Fi
/// avisa por `FolderSyncService.onFollowedArtistsChanged`, porque ese servicio sí
/// se construye en `main.dart`. Devuelve el listener para poder quitarlo.
VoidCallback bindImportedFollowsRefresh(FolderSyncProvider sync, Future<void> Function() reload) {
  var seen = sync.lastReport;
  void listener() {
    final report = sync.lastReport;
    if (identical(report, seen)) return;
    seen = report;
    if (report != null && report.followedArtistsChanged > 0) reload();
  }

  sync.addListener(listener);
  return listener;
}
