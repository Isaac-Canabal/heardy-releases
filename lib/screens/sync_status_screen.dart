import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../services/cloud_restore_match.dart';
import '../services/cloud_source.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/library_diff.dart';
import '../theme/app_theme.dart';
import '../services/friendly_error.dart';
import 'package:heardy/services/app_log.dart';

enum _Phase { loading, error, noCloudLibrary, upToDate, matching, review, enqueuing, done }

/// "El PC sabe qué le falta" (W6) + restaurarlo (W7) — la estrategia híbrida
/// de la Etapa 16 E-2: compara el índice de la nube contra el hash de audio
/// de lo que ya hay en este equipo, busca en YouTube un equivalente de cada
/// canción que falta (mismo criterio que el emparejamiento de Spotify: por
/// duración, nunca por texto), enseña el resultado una sola vez, y sólo al
/// confirmar recrea las playlists de la nube que no existan acá y encola las
/// descargas — nunca antes.
class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  int _cloudTotal = 0;
  String? _accountEmail;

  List<Map<String, dynamic>> _cloudPlaylists = const [];
  List<Map<String, dynamic>> _cloudPlaylistSongs = const [];

  // playlistId de la nube (o null = suelta, sin playlist) -> matches.
  Map<String?, List<CloudSongMatch>> _matchesByPlaylist = const {};
  int _matchedCount = 0;
  int _totalToMatch = 0;

  int _enqueuedCount = 0;

  bool _restoringHistory = false;
  String? _historyResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final cloudSource = context.read<CloudSource>();

      // Antes de asumir "no hay nada": `hasLibrary` distingue "el servidor
      // nunca recibió un push de ningún dispositivo para esta cuenta" (lo
      // más probable si esto es lo primero que se prueba en un equipo
      // nuevo) de "sincronizó y de verdad no hay nada". Mismo motivo por el
      // que un `[]` de la nube no debía leerse a ciegas como "está todo al
      // día" sin mirar esto primero.
      final account = await cloudSource.getAccount();
      if (!mounted) return;
      _accountEmail = context.read<HeardyAuthProvider>().email ??
          (account.username != null ? '@${account.username}' : account.identity);
      if (!account.hasLibrary) {
        setState(() => _phase = _Phase.noCloudLibrary);
        return;
      }

      final library = await cloudSource.getLibrary();
      final localHashes = await DatabaseHelper.instance.getLocalFileHashes();
      final localSourceUrls = await DatabaseHelper.instance.getLocalSourceUrls();
      // La nube es aditiva y acumula copias (misma canción con dos ids, misma
      // playlist borrada y recreada): se colapsan antes de comparar para no
      // emparejar, encolar ni recrear cada copia por separado.
      final canonical = canonicalizeCloudIndex(
        library?.songs ?? const [],
        library?.playlists ?? const [],
        library?.playlistSongs ?? const [],
      );
      final cloudSongs = canonical.songs;
      final missing = missingCloudSongs(cloudSongs, localHashes);
      if (!mounted) return;

      _cloudTotal = uniqueCloudSongCount(cloudSongs);
      _cloudPlaylists = canonical.playlists;
      _cloudPlaylistSongs = canonical.playlistSongs;

      // Sin corte por "no falta nada por hash" acá: una playlist con
      // `originalUrl` puede tener temas nuevos sumados al origen desde el
      // último push, que el índice de la nube todavía no conoce — eso sólo
      // se descubre re-expandiendo el enlace, no comparando hashes.
      // `_matchMissingSongs` decide `upToDate` al final si de verdad no hay
      // nada que hacer.
      await _matchMissingSongs(
        missing,
        knownLocalSourceUrls(
          localSourceUrls: localSourceUrls,
          cloudSongs: cloudSongs,
          localFileHashes: localHashes,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context)!.syncCompareError(localizedErrorReport(AppLocalizations.of(context)!, e));
        _phase = _Phase.error;
      });
    }
  }

  /// Reconstruye cada playlist que falta. Dos caminos distintos a propósito:
  ///
  /// - Con `originalUrl` (creada desde un link de YouTube en `ImportScreen`):
  ///   re-expandir ese link de una sola vez trae lo viejo Y lo nuevo — mismo
  ///   mecanismo que el botón "Actualizar desde YouTube" de
  ///   `PlaylistDetailScreen`. Emparejar canción por canción acá no tenía
  ///   sentido: nunca se enteraba de un tema sumado al origen después del
  ///   último push, y además arriesgaba una coincidencia por duración
  ///   pudiendo tener el enlace exacto de la playlist entera a mano.
  /// - Sin `originalUrl` (playlist armada a mano, o de antes de que este
  ///   campo se sincronizara): sigue igual que siempre, canción por canción
  ///   — enlace original de CADA canción primero, búsqueda por duración si
  ///   ya no resuelve.
  Future<void> _matchMissingSongs(
    List<Map<String, dynamic>> missing,
    Set<String> localSourceUrls,
  ) async {
    final source = context.read<DownloadSource>();

    final originalUrlByPlaylist = <String, String>{
      for (final p in _cloudPlaylists)
        if ((p['playlistId'] as String?)?.isNotEmpty == true &&
            (p['originalUrl'] as String?)?.isNotEmpty == true)
          p['playlistId'] as String: p['originalUrl'] as String,
    };

    final grouped = groupMissingSongsByPlaylist(missing, _cloudPlaylistSongs);
    // Lo que necesita emparejar canción por canción: todo lo que no
    // pertenece a una playlist con `originalUrl`, más lo que sí pertenecía a
    // una pero cuyo enlace ya no resuelve (ver más abajo).
    final searchGroups = <String?, List<Map<String, dynamic>>>{};
    grouped.forEach((playlistId, songs) {
      if (playlistId == null || !originalUrlByPlaylist.containsKey(playlistId)) {
        searchGroups[playlistId] = songs;
      }
    });

    setState(() {
      _phase = _Phase.matching;
      _matchedCount = 0;
      _totalToMatch =
          searchGroups.values.fold<int>(0, (n, l) => n + l.length) + originalUrlByPlaylist.length;
    });

    final matchesByPlaylist = <String?, List<CloudSongMatch>>{};

    for (final entry in originalUrlByPlaylist.entries) {
      final playlistId = entry.key;
      final originalUrl = entry.value;
      try {
        final remote = await source.resolvePlaylist(originalUrl);
        final seenTrackIds = <String>{};
        final matches = [
          for (final track in remote.entries)
            if (seenTrackIds.add(track.id) && !sourceUrlAlreadyKnown(track.sourceUrl, localSourceUrls))
              CloudSongMatch(
                cloudSong: {'title': track.title, 'artist': track.artist},
                youtubeTrack: track,
                durationDiffSeconds: 0,
                isExactSource: true,
                // extract_flat: falta re-resolver antes de bajar (DD6), igual
                // que en enqueuePlaylist/_updateFromYoutube.
                metadataComplete: false,
              ),
        ];
        if (matches.isNotEmpty) matchesByPlaylist[playlistId] = matches;
      } catch (e) {
        // El enlace de la playlist entera murió (borrada, hecha privada) —
        // no por eso se abandonan las canciones sueltas que sí faltan y que
        // todavía se pueden restaurar una por una.
        appLog('sync_status_screen: "$originalUrl" ya no resuelve ($e), se empareja canción por canción');
        final fallback = grouped[playlistId];
        if (fallback != null) searchGroups[playlistId] = fallback;
      }
      if (!mounted) return;
      setState(() => _matchedCount++);
    }

    // Dos filas de la nube pueden compartir el mismo fileHash (una fila
    // heredada de antes de que el id fuera el hash, y la fila nueva de la
    // misma canción re-subida con el id nuevo — unionCloudIntoLocalIndex las
    // fusiona al empujar, pero sólo si el dispositivo que empuja tiene AMBAS
    // localmente; si no, las dos quedan en la nube por separado para
    // siempre). Sin esta caché, cada duplicado se busca en YouTube por
    // separado — mismo título, mismo resultado, tiempo tirado. Con ella, el
    // segundo (y siguientes) duplicado del mismo hash reutiliza el match ya
    // encontrado; sigue apareciendo en cada playlist a la que pertenezca.
    final matchByHash = <String, CloudSongMatch>{};

    for (final entry in searchGroups.entries) {
      final matches = <CloudSongMatch>[];
      for (final song in entry.value) {
        final hash = song['fileHash'] as String?;
        final cached = hash == null ? null : matchByHash[hash];
        final match = cached ?? await matchCloudSong(song, source);
        if (hash != null) matchByHash.putIfAbsent(hash, () => match);
        matches.add(match);
        if (!mounted) return;
        setState(() => _matchedCount++);
      }
      if (matches.isEmpty) continue;
      matchesByPlaylist[entry.key] = [...?matchesByPlaylist[entry.key], ...matches];
    }

    if (!mounted) return;
    if (matchesByPlaylist.values.every((l) => l.isEmpty)) {
      setState(() => _phase = _Phase.upToDate);
      return;
    }
    setState(() {
      _matchesByPlaylist = matchesByPlaylist;
      _phase = _Phase.review;
    });
  }

  int get _acceptableCount => _matchesByPlaylist.values
      .expand((list) => list)
      .where((m) => m.isAcceptable)
      .length;

  Future<void> _confirmRestore() async {
    setState(() => _phase = _Phase.enqueuing);

    final restoredPlaylistName = AppLocalizations.of(context)!.restoreRestoredPlaylistName;
    final musicProvider = context.read<MusicProvider>();
    final downloadProvider = context.read<DownloadProvider>();
    final playlistNameById = {
      for (final p in _cloudPlaylists)
        p['playlistId'] as String: (p['name'] as String?) ?? '',
    };
    // Una playlist local con el mismo nombre ES la misma playlist: se reutiliza
    // en vez de recrearla con el id de la nube.
    final localIdByCloudId = localPlaylistIdByCloudId(
      _cloudPlaylists,
      [for (final p in musicProvider.playlists) (id: p.id, name: p.name)],
    );
    final existingLocalIds = musicProvider.playlists.map((p) => p.id).toSet();

    var enqueued = 0;
    for (final entry in _matchesByPlaylist.entries) {
      final cloudPlaylistId = entry.key;
      final acceptable = entry.value.where((m) => m.isAcceptable).toList();
      if (acceptable.isEmpty) continue;

      if (cloudPlaylistId == null) {
        final queuedLoose = <String>{};
        for (final match in acceptable) {
          if (!queuedLoose.add(match.youtubeTrack!.id)) continue;
          final ok = await downloadProvider.enqueueTrack(
            match.youtubeTrack!,
            playlistId: inboxDownloadTarget,
            sourceType: 'restore',
            metadataComplete: match.metadataComplete,
          );
          if (ok) enqueued++;
        }
        continue;
      }

      // Mismo id que en la nube a propósito: si esta playlist ya existe acá
      // (porque el usuario la creó en este mismo equipo, o una restauración
      // anterior ya la trajo), esto no hace nada — `insertPlaylist` ignora
      // conflictos de id. Conservar el id evita duplicar la misma playlist
      // con dos identidades distintas entre dispositivos.
      final targetPlaylistId = localIdByCloudId[cloudPlaylistId] ?? cloudPlaylistId;
      if (!existingLocalIds.contains(targetPlaylistId)) {
        final cloudPlaylist = _cloudPlaylists.firstWhere(
          (p) => p['playlistId'] == cloudPlaylistId,
          orElse: () => const {},
        );
        await DatabaseHelper.instance.insertPlaylist(
          Playlist(
            id: targetPlaylistId,
            name: playlistNameById[cloudPlaylistId] ?? restoredPlaylistName,
            creationDate: DateTime.now(),
            // Sin esto, una playlist restaurada pierde para siempre el botón
            // "Actualizar desde YouTube" — sólo aparece si originalUrl no es
            // nulo, y una playlist recreada acá nunca lo tendría por sí sola.
            originalUrl: cloudPlaylist['originalUrl'] as String?,
          ),
        );
        existingLocalIds.add(targetPlaylistId);
      }

      final queuedTrackIds = <String>{};
      for (final match in acceptable) {
        if (!queuedTrackIds.add(match.youtubeTrack!.id)) continue;
        final ok = await downloadProvider.enqueueTrack(
          match.youtubeTrack!,
          playlistId: targetPlaylistId,
          sourceType: 'restore',
          // Ver CloudSongMatch.metadataComplete: sólo el resolve completo de
          // UNA canción por su sourceUrl lo deja en true. Todo lo demás
          // (búsqueda, o re-expandir la playlist entera) es un listado
          // aplanado y se re-resuelve en el worker antes de bajar nada (DD6).
          metadataComplete: match.metadataComplete,
        );
        if (ok) enqueued++;
      }
    }

    await musicProvider.loadPlaylists();
    downloadProvider.processQueue();

    if (!mounted) return;
    setState(() {
      _enqueuedCount = enqueued;
      _phase = _Phase.done;
    });
  }

  /// Baja el historial de la cuenta y lo reinserta acá, página a página.
  /// Independiente de la biblioteca a propósito: el historial vive en la nube
  /// aunque el índice no (`push_history` es aditivo y nada salvo "borrar mis
  /// datos" lo toca), así que esto tiene sentido incluso cuando la
  /// comparación de arriba dice que no hay biblioteca que restaurar.
  Future<void> _restoreHistory() async {
    setState(() {
      _restoringHistory = true;
      _historyResult = null;
    });
    final cloudSource = context.read<CloudSource>();
    try {
      var restored = 0;
      var seen = 0;
      String? cursor;
      final ctx = await DatabaseHelper.instance.loadRestoreContext();
      do {
        final page = await cloudSource.getHistory(cursor: cursor);
        seen += page.rows.length;
        restored += await DatabaseHelper.instance.insertRestoredPlays(
          page.rows,
          knownSongs: ctx.knownSongs,
          existingKeys: ctx.existingKeys,
        );
        cursor = page.nextCursor;
      } while (cursor != null);

      if (!mounted) return;
      setState(() {
        // "Ya estaban" y "son de canciones que no tenés" se distinguen mal
        // entre sí y no aportan nada distinto al usuario; lo que importa es
        // que el servidor tenía datos y cuántos entraron.
        final l10n = AppLocalizations.of(context)!;
        _historyResult = seen == 0
            ? l10n.restoreHistoryNone
            : restored == 0
                ? l10n.restoreHistoryAllPresent(seen)
                : l10n.restoreHistoryRecovered(restored, seen);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _historyResult = AppLocalizations.of(context)!.syncHistoryRestoreError(localizedErrorReport(AppLocalizations.of(context)!, e)));
    } finally {
      if (mounted) setState(() => _restoringHistory = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.restoreTitle),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    final l10n = AppLocalizations.of(context)!;
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case _Phase.error:
        return _buildMessage(_error!, retry: true);
      case _Phase.noCloudLibrary:
        return _buildMessage(
          l10n.restoreNoCloudLibrary(_accountEmail ?? l10n.restoreUnknownAccount),
          retry: true,
        );
      case _Phase.upToDate:
        return _buildMessage(
          _cloudTotal == 0 ? l10n.restoreCloudEmpty : l10n.restoreUpToDate(_cloudTotal),
        );
      case _Phase.matching:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: _totalToMatch == 0 ? null : _matchedCount / _totalToMatch,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.restoreMatching(_matchedCount, _totalToMatch),
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        );
      case _Phase.review:
        return _buildReview();
      case _Phase.enqueuing:
        return const Center(child: CircularProgressIndicator());
      case _Phase.done:
        return _buildMessage(
          _enqueuedCount == 0 ? l10n.restoreDoneNone : l10n.restoreDoneQueued(_enqueuedCount),
        );
    }
  }

  Widget _buildMessage(String text, {bool retry = false}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (retry) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: Text(AppLocalizations.of(context)!.restoreRetry)),
            ],
            const Divider(height: 40, color: Colors.white12),
            _buildHistoryRestore(),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryRestore() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.restoreHistoryExplain,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          ),
          icon: _restoringHistory
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history_rounded, size: 18),
          onPressed: _restoringHistory ? null : _restoreHistory,
          label: Text(l10n.restoreHistoryButton),
        ),
        if (_historyResult != null) ...[
          const SizedBox(height: 12),
          Text(
            _historyResult!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildReview() {
    final l10n = AppLocalizations.of(context)!;
    final acceptable = _acceptableCount;
    final totalMatched = _matchesByPlaylist.values.fold<int>(0, (n, l) => n + l.length);
    final skipped = totalMatched - acceptable;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            skipped == 0 ? l10n.restoreFound(acceptable) : l10n.restoreFoundSkipped(acceptable, skipped),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final entry in _matchesByPlaylist.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    entry.key == null
                        ? l10n.restoreLooseHeader
                        : (_cloudPlaylists.firstWhere(
                              (p) => p['playlistId'] == entry.key,
                              orElse: () => const {},
                            )['name'] as String? ??
                            l10n.restoreDefaultPlaylist),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final match in entry.value) _MatchRow(match: match),
              ],
              const Divider(height: 40, color: Colors.white12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _buildHistoryRestore(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: acceptable == 0 ? null : _confirmRestore,
                child: Text(l10n.restoreDownloadCount(acceptable)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MatchRow extends StatelessWidget {
  final CloudSongMatch match;
  const _MatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (icon, color, subtitle) = switch (match) {
      CloudSongMatch(isExactSource: true) => (
          Icons.verified_rounded,
          Colors.greenAccent,
          l10n.restoreRowExact(match.artist),
        ),
      CloudSongMatch(isGoodMatch: true) => (
          Icons.check_circle_rounded,
          Colors.greenAccent,
          match.artist,
        ),
      CloudSongMatch(isAcceptable: true) => (
          Icons.check_circle_outline_rounded,
          Colors.orangeAccent,
          l10n.restoreRowReview(match.artist, match.durationDiffSeconds ?? 0),
        ),
      _ => (
          Icons.cancel_outlined,
          Colors.white38,
          l10n.restoreRowNoMatch(match.artist),
        ),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(match.title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }
}
