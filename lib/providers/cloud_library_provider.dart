import 'package:flutter/foundation.dart';

import '../services/cloud_restore_match.dart';
import '../services/cloud_source.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/library_diff.dart';
import 'download_provider.dart';

enum CloudLibraryStatus { idle, loading, ready, noLibrary, error }

enum CloudDownloadResult { queued, alreadyQueued, noMatch, failed }

/// Una canción que la nube tiene y este equipo no.
class CloudLibraryEntry {
  final Map<String, dynamic> song;
  final bool queued;

  const CloudLibraryEntry(this.song, {this.queued = false});

  String get fileHash => (song['fileHash'] as String?) ?? '';
  String get title => (song['title'] as String?) ?? '';
  String get artist => (song['artist'] as String?) ?? '';
  bool get hasLink => ((song['sourceUrl'] as String?) ?? '').isNotEmpty;
}

/// Lista bajo demanda de "lo que tengo en mis otros dispositivos y acá no".
///
/// Sólo lee la nube cuando el usuario lo pide ([refresh]); nunca por su
/// cuenta (la sincronización es manual). Descarga encolando en la Bandeja,
/// con la misma cola y el mismo worker que cualquier otra descarga.
class CloudLibraryProvider extends ChangeNotifier {
  final CloudSource _cloud;
  final DownloadProvider _downloads;
  final DownloadSource _source;
  final DatabaseHelper _db;
  final void Function() _startProcessing;

  CloudLibraryProvider({
    required CloudSource cloud,
    required DownloadProvider downloads,
    required DownloadSource source,
    DatabaseHelper? db,
    void Function()? startProcessing,
  })  : _cloud = cloud,
        _downloads = downloads,
        _source = source,
        _db = db ?? DatabaseHelper.instance,
        _startProcessing = startProcessing ?? (() => downloads.processQueue());

  CloudLibraryStatus _status = CloudLibraryStatus.idle;
  Object? _error;
  List<Map<String, dynamic>> _songs = const [];
  final Set<String> _queuedHashes = {};

  CloudLibraryStatus get status => _status;

  /// La excepción original, para que la pantalla redacte el mensaje en el
  /// idioma elegido (nunca se muestra su texto crudo).
  Object? get error => _error;

  List<CloudLibraryEntry> get entries => [
        for (final s in _songs) CloudLibraryEntry(s, queued: _queuedHashes.contains(s['fileHash'])),
      ];

  /// Cuántas se bajarían con [downloadAll]: con enlace y todavía no encoladas.
  int get downloadableCount => entries.where((e) => e.hasLink && !e.queued).length;

  Future<void> refresh() async {
    _status = CloudLibraryStatus.loading;
    _error = null;
    notifyListeners();
    try {
      final account = await _cloud.getAccount();
      if (!account.hasLibrary) {
        _songs = const [];
        _status = CloudLibraryStatus.noLibrary;
        return;
      }
      final library = await _cloud.getLibrary();
      final canonical = canonicalizeCloudIndex(
        library?.songs ?? const [],
        library?.playlists ?? const [],
        library?.playlistSongs ?? const [],
      );
      _songs = cloudOnlySongs(
        canonical.songs,
        localFileHashes: await _db.getAllLocalFileHashes(),
        localSourceUrls: await _db.getAllLocalSourceUrls(),
      );
      _queuedHashes.removeWhere((h) => !_songs.any((s) => s['fileHash'] == h));
      _status = CloudLibraryStatus.ready;
    } catch (e) {
      debugPrint('CloudLibraryProvider: refresh falló (${e.runtimeType})');
      _songs = const [];
      _error = e;
      _status = CloudLibraryStatus.error;
    } finally {
      notifyListeners();
    }
  }

  Future<CloudDownloadResult> downloadOne(CloudLibraryEntry entry) async {
    if (_queuedHashes.contains(entry.fileHash)) return CloudDownloadResult.alreadyQueued;
    try {
      final direct = remoteTrackFromCloudSong(entry.song);
      final RemoteTrack track;
      var metadataComplete = false;
      if (direct != null) {
        track = direct;
      } else {
        final match = await matchCloudSong(entry.song, _source);
        if (!match.isAcceptable) return CloudDownloadResult.noMatch;
        track = match.youtubeTrack!;
        metadataComplete = match.metadataComplete;
      }
      final added = await _downloads.enqueueTrack(
        track,
        playlistId: inboxDownloadTarget,
        sourceType: 'restore',
        metadataComplete: metadataComplete,
      );
      _queuedHashes.add(entry.fileHash);
      notifyListeners();
      _startProcessing();
      return added ? CloudDownloadResult.queued : CloudDownloadResult.alreadyQueued;
    } catch (e) {
      debugPrint('CloudLibraryProvider: downloadOne falló (${e.runtimeType})');
      return CloudDownloadResult.failed;
    }
  }

  /// Encola las que tienen enlace; las que no lo tienen se piden una a una
  /// (cada una gasta una búsqueda). Devuelve cuántas se encolaron.
  Future<int> downloadAll() async {
    var count = 0;
    for (final entry in entries) {
      if (!entry.hasLink || entry.queued) continue;
      final track = remoteTrackFromCloudSong(entry.song);
      if (track == null) continue;
      final added = await _downloads.enqueueTrack(
        track,
        playlistId: inboxDownloadTarget,
        sourceType: 'restore',
        metadataComplete: false,
      );
      _queuedHashes.add(entry.fileHash);
      if (added) count++;
    }
    notifyListeners();
    if (count > 0) _startProcessing();
    return count;
  }
}
