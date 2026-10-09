import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/auth/login_screen.dart';
import '../services/download_source.dart';
import '../services/friendly_error.dart';
import '../services/spotify_match.dart';
import '../services/spotify_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_progress_card.dart';
import '../widgets/playlist_target_sheet.dart';
import '../l10n/app_localizations.dart';
import 'package:heardy/services/app_log.dart';
import '../services/input_sanitizer.dart';

/// What a pasted URL turned out to be, once analyzed.
enum _UrlKind { video, playlist, spotify }

/// "Pegar URL → vista previa → elegir playlist → encolar", plus the live
/// queue underneath. This is the second way music enters the library —
/// downloads land in the same SAF folder and go through the same
/// [DatabaseHelper]/[LibraryScanService] path as anything the user copies in
/// by hand (see CLAUDE.md DD2/DD3).
///
/// Talks to the server **only** through [DownloadSource] (never FastAPI
/// directly) and to the queue only through [DownloadProvider] — this screen
/// has no idea a Python process exists.
class ImportScreen extends StatefulWidget {
  /// Inyectable por lo mismo que [DownloadSource]/[DownloadProvider] lo son:
  /// permite un test que ejercite el flujo de Spotify entero sin red, con
  /// un fake que sustituya el scraping real. `SpotifyService` no pasa por
  /// `Provider` como las otras dependencias porque no tiene una interfaz
  /// abstracta que justifique una — solo existe una implementación real, y
  /// esto le basta para ser sustituible en pruebas.
  final SpotifyService spotifyService;

  ImportScreen({super.key, SpotifyService? spotifyService}) : spotifyService = spotifyService ?? SpotifyService();

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _urlController = TextEditingController();
  bool _isAnalyzing = false;
  String? _errorMessage;
  /// True sólo cuando [_errorMessage] viene de
  /// [DownloadSourceErrorKind.network] — el único caso en el que tiene
  /// sentido ofrecer "guardar para más tarde" en vez de simplemente mostrar
  /// el error: los demás (401, 404, formato no soportado) no se arreglan
  /// solos con que el servidor vuelva a estar disponible.
  bool _errorIsOffline = false;
  _UrlKind? _analyzedKind;
  RemoteTrack? _analyzedTrack;
  RemotePlaylist? _analyzedPlaylist;
  SpotifyAnalysisResult? _analyzedSpotify;
  List<SpotifyMatch>? _analyzedSpotifyMatches;

  /// Cupo diario de canciones (Fase 3 del plan de seguridad, D-2: mostrar el
  /// resto disponible para que no sea una sorpresa al chocarse contra el
  /// límite). `null` mientras no se conoce todavía; `UsageStatus.disabled`
  /// (dailyLimit == 0) esconde el indicador — no hay cupo activo, o no se
  /// pudo consultar, y ninguno de los dos amerita mostrar nada.
  UsageStatus? _usage;

  /// Guardado una vez en [initState], nunca vuelto a leer de [context] en
  /// [dispose] — hacerlo ahí es inseguro (el árbol de widgets ya puede estar
  /// desactivado cuando `dispose()` corre), y es exactamente el error que
  /// `flutter test` detectó al principio de esta implementación.
  late final DownloadProvider _downloadProvider;
  late final HeardyAuthProvider _authProvider;
  bool _wasAuthReady = false;

  @override
  void initState() {
    super.initState();
    _downloadProvider = context.read<DownloadProvider>();
    _authProvider = context.read<HeardyAuthProvider>();
    _wasAuthReady = _authProvider.isReady;
    _authProvider.addListener(_onAuthChanged);
    _refreshUsage();
    // Una descarga real (no sólo encolarla) es lo que de verdad cambia el
    // cupo usado — se entera server-side recién cuando /audio entrega los
    // bytes. `isProcessing` pasando a false es la señal más barata de "la
    // cola acaba de dejar de trabajar", sin inventar un polling propio.
    _downloadProvider.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    _downloadProvider.removeListener(_onQueueChanged);
    _authProvider.removeListener(_onAuthChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onQueueChanged() {
    if (!_downloadProvider.isProcessing) _refreshUsage();
  }

  /// El cupo se consulta con la identidad de quien esté en sesión, así que
  /// la consulta de [initState] se va con un 401 (y queda en
  /// `UsageStatus.disabled`) si la pantalla se abrió sin sesión lista. Esta
  /// pantalla vive en un IndexedStack y no se reconstruye al volver del
  /// login, así que sin esto la línea "te quedan N de 150" no aparecería
  /// hasta después de la primera descarga. Sólo en el flanco false -> true:
  /// [HeardyAuthProvider] notifica también en cada refresco de token, y no
  /// hace falta repreguntar por eso.
  void _onAuthChanged() {
    final ready = _authProvider.isReady;
    if (ready == _wasAuthReady) return;
    _wasAuthReady = ready;
    if (ready) _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    final result = await context.read<DownloadSource>().usage();
    if (!mounted) return;
    setState(() => _usage = result);
  }

  void _clearAnalysis() {
    _analyzedKind = null;
    _analyzedTrack = null;
    _analyzedPlaylist = null;
    _analyzedSpotify = null;
    _analyzedSpotifyMatches = null;
    _errorMessage = null;
    _errorIsOffline = false;
  }

  bool _looksLikePlaylist(String url) {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters['list'] != null;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _urlController.text = text;
    _urlController.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _analyze() async {
    final url = sanitizeUrlInput(_urlController.text);
    if (url.isEmpty) return;

    setState(() {
      _isAnalyzing = true;
      _clearAnalysis();
    });

    try {
      final source = context.read<DownloadSource>();
      if (SpotifyService.isSpotifyUrl(url)) {
        // Se resuelve aparte de YouTube: analiza el enlace de Spotify (sin
        // tocar el servidor propio) y después busca en YouTube el
        // equivalente de cada pista, una por una, por proximidad de
        // duración — nunca por título/artista. El resultado elegido se
        // enseña siempre antes de descargar; nada se resuelve en silencio.
        final spotify = await widget.spotifyService.analyze(url);
        final matches = <SpotifyMatch>[];
        for (final track in spotify.tracks) {
          matches.add(await matchSpotifyTrack(track, source));
        }
        if (!mounted) return;
        setState(() {
          _analyzedKind = _UrlKind.spotify;
          _analyzedSpotify = spotify;
          _analyzedSpotifyMatches = matches;
        });
      } else if (_looksLikePlaylist(url)) {
        final playlist = await source.resolvePlaylist(url);
        if (!mounted) return;
        setState(() {
          _analyzedKind = _UrlKind.playlist;
          _analyzedPlaylist = playlist;
        });
      } else {
        final track = await source.resolve(url);
        if (!mounted) return;
        setState(() {
          _analyzedKind = _UrlKind.video;
          _analyzedTrack = track;
        });
      }
    } on DownloadSourceException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = localizedErrorReport(AppLocalizations.of(context)!, e);
        _errorIsOffline = e.kind == DownloadSourceErrorKind.network;
      });
    } catch (e) {
      if (!mounted) return;
      // El texto crudo al log; la pantalla sólo ve la frase y el código.
      appLog('ImportScreen: fallo al analizar el enlace (${e.runtimeType}) -> $e');
      final l10n = AppLocalizations.of(context)!;
      final report = localizedErrorReport(l10n, e, area: 'IMP');
      setState(() {
        _errorMessage = SpotifyService.isSpotifyUrl(url) ? report : l10n.importAnalyzeError(report);
      });
    } finally {
      // Un único punto de reset — la pantalla que reemplaza a ésta (la vieja
      // add_from_youtube_screen.dart) tenía un bug justo por resetear el
      // flag en cada `return` en vez de en un solo `finally`.
      if (mounted) setState(() => _isAnalyzing = false);
      // El servidor acaba de responder con éxito: buen momento, sin necesidad
      // de un polling propio, para vaciar lo que haya quedado en la lista de
      // espera de una vez anterior en la que no respondía.
      if (mounted && _errorMessage == null) {
        context.read<DownloadProvider>().retryPendingImports();
      }
    }
  }

  Future<void> _saveForLater() async {
    final url = sanitizeUrlInput(_urlController.text);
    if (url.isEmpty) return;
    final isPlaylist = _looksLikePlaylist(url);

    final choice = await pickTargetPlaylist(context);
    if (choice == null || !mounted) return;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;

    final provider = context.read<DownloadProvider>();
    final added = await provider.addPendingImport(
      sourceUrl: url,
      playlistId: playlistId,
      isPlaylist: isPlaylist,
    );
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();

    final l10n = AppLocalizations.of(context)!;
    _showSnack(
      added ? l10n.importSavedForLaterSnack : l10n.importAlreadyInWaitlistSnack,
    );
  }

  Future<void> _downloadTrack(RemoteTrack track) async {
    final choice = await pickTargetPlaylist(context);
    if (choice == null || !mounted) return;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;

    final provider = context.read<DownloadProvider>();
    final added = await provider.enqueueTrack(
      track,
      playlistId: playlistId,
      // Viene de /resolve — la vista previa YA es la metadata definitiva,
      // así que el worker no debe volver a resolverla (DD6).
      metadataComplete: true,
    );
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();
    provider.processQueue();

    final l10n = AppLocalizations.of(context)!;
    _showSnack(added ? l10n.searchAddedToQueueSnack(track.title) : l10n.searchAlreadyQueuedSnack);
  }

  Future<void> _downloadPlaylist(RemotePlaylist playlist) async {
    final choice = await pickTargetPlaylist(context, suggestedName: playlist.name);
    if (choice == null || !mounted) return;

    // Si se crea una playlist nueva a partir de esta importación, guardamos
    // la URL de origen — es lo que activa "Actualizar desde YouTube" en
    // playlist_detail_screen.dart. Si el destino es una playlist YA
    // existente, no la tocamos: podría no ser de origen YouTube.
    final isNewPlaylist = choice.existingPlaylistId == null;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;
    if (isNewPlaylist && playlist.sourceUrl.isNotEmpty) {
      await context.read<MusicProvider>().updatePlaylistUrl(playlistId, playlist.sourceUrl);
    }

    final provider = context.read<DownloadProvider>();
    final added = await provider.enqueuePlaylist(playlist, playlistId: playlistId);
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();
    provider.processQueue();

    final l10n = AppLocalizations.of(context)!;
    _showSnack(
      l10n.importSongsQueuedSnack(added) +
          (exceedsPlaylistBatch(playlist.entries.length)
              ? l10n.importBatchCappedSuffix(maxPlaylistBatch)
              : ''),
    );
  }

  Future<void> _downloadSpotifyMatches(SpotifyAnalysisResult spotify, List<SpotifyMatch> matches) async {
    final acceptable = matches.where((m) => m.isAcceptable).toList();
    if (acceptable.isEmpty) return;

    final choice = await pickTargetPlaylist(
      context,
      suggestedName: spotify.isCollection ? spotify.name : null,
    );
    if (choice == null || !mounted) return;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;

    final provider = context.read<DownloadProvider>();
    var added = 0;
    for (final match in acceptable.take(maxPlaylistBatch)) {
      final ok = await provider.enqueueTrack(
        match.youtubeTrack!,
        playlistId: playlistId,
        sourceType: 'spotify',
        // El match viene de /search (extract_flat): mismo motivo que la
        // pestaña de búsqueda (DD6) — se resuelve en el worker antes de
        // bajar nada, no aquí.
        metadataComplete: false,
      );
      if (ok) added++;
    }
    if (!mounted) return;

    setState(_clearAnalysis);
    _urlController.clear();
    provider.processQueue();

    final skipped = matches.length - acceptable.length;
    final l10n = AppLocalizations.of(context)!;
    _showSnack(
      (skipped == 0
              ? l10n.importSongsQueuedSnack(added)
              : l10n.importSongsQueuedSnack(added) + l10n.importSpotifySkippedSuffix(skipped)) +
          (exceedsPlaylistBatch(acceptable.length) ? l10n.importBatchCappedSuffix(maxPlaylistBatch) : ''),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final libraryRootUri = context.watch<MusicProvider>().libraryRootUri;
    final l10n = AppLocalizations.of(context)!;

    if (!settings.hasDownloadServer) return _buildNoServerState();
    // Fase 2 del plan de seguridad: descargar exige sesión (identidad real
    // en vez de la clave compilada de antes); el resto de la app —
    // biblioteca local, playlists, reproducción— no. Este chequeo vive sólo
    // en esta pantalla y en SearchScreen, no como un gate global.
    if (!context.watch<HeardyAuthProvider>().isReady) return _buildAuthRequiredState();
    if (libraryRootUri == null) return _buildNoFolderState();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              l10n.importScreenTitle,
              style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
          ),
          if (_usage != null && _usage!.isEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(
                _usage!.isMonthly
                    ? l10n.importMonthlyQuotaRemaining(_usage!.remaining, _usage!.monthlyLimit)
                    : l10n.importDailyQuotaRemaining(_usage!.remaining, _usage!.dailyLimit),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('import_url_field'),
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: (_) => _analyze(),
                    decoration: InputDecoration(
                      hintText: l10n.importUrlHint,
                      prefixIcon: Icon(Icons.link_rounded, color: AppTheme.primaryLight),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        tooltip: l10n.importPasteTooltip,
                        onPressed: _pasteFromClipboard,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Material(
                  key: const Key('analyze_button'),
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _isAnalyzing ? null : _analyze,
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: _isAnalyzing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
              children: [
                if (_errorMessage != null)
                  _buildErrorBanner(_errorMessage!, onSaveForLater: _errorIsOffline ? _saveForLater : null),
                if (_analyzedKind == _UrlKind.video && _analyzedTrack != null)
                  _buildTrackPreview(_analyzedTrack!),
                if (_analyzedKind == _UrlKind.playlist && _analyzedPlaylist != null)
                  _buildPlaylistPreview(_analyzedPlaylist!),
                if (_analyzedKind == _UrlKind.spotify && _analyzedSpotify != null && _analyzedSpotifyMatches != null)
                  _buildSpotifyPreview(_analyzedSpotify!, _analyzedSpotifyMatches!),
                _buildQueueSection(),
                _buildPendingImportsSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoServerState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              l10n.searchNoServerTitle,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.importNoServerBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthRequiredState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, size: 56, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              l10n.authRequiredTitle,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.authRequiredBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
              child: Text(l10n.authRequiredButton),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoFolderState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_rounded, size: 56, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              l10n.importNoFolderTitle,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.importNoFolderBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message, {VoidCallback? onSaveForLater}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(message, style: TextStyle(color: Colors.red.shade100, fontSize: 13, height: 1.35)),
              ),
            ],
          ),
          if (onSaveForLater != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('save_for_later_button'),
              onPressed: onSaveForLater,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
              ),
              icon: const Icon(Icons.schedule_rounded, size: 16),
              label: Text(AppLocalizations.of(context)!.importSaveForLaterButton),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPendingImportsSection() {
    final downloadProvider = context.watch<DownloadProvider>();
    final pending = downloadProvider.pendingImports;
    if (pending.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final musicProvider = context.watch<MusicProvider>();
    String playlistName(String id) {
      for (final p in musicProvider.playlists) {
        if (p.id == id) return p.name;
      }
      return l10n.importDeletedPlaylistFallback;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_rounded, color: Colors.white.withValues(alpha: 0.5), size: 15),
              const SizedBox(width: 6),
              Text(
                l10n.importWaitlistTitle,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => downloadProvider.retryPendingImports(),
                child: Text(l10n.importRetryNowButton),
              ),
            ],
          ),
          ...pending.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  decoration: AppTheme.glassCard(),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        p.isPlaylist ? Icons.queue_music_rounded : Icons.music_note_rounded,
                        color: Colors.white.withValues(alpha: 0.4),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.sourceUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '→ ${playlistName(p.playlistId)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.4), size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => downloadProvider.removePendingImport(p.id),
                      ),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildTrackPreview(RemoteTrack track) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Thumb(url: track.thumbnailUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppTheme.formatDuration(track.durationSeconds),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('download_track_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(l10n.importDownloadButton),
              onPressed: () => _downloadTrack(track),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistPreview(RemotePlaylist playlist) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.importVideosCount(playlist.entries.length),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('download_playlist_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: Text(l10n.importDownloadCountButton(playlist.entries.length)),
              onPressed: playlist.entries.isEmpty ? null : () => _downloadPlaylist(playlist),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpotifyPreview(SpotifyAnalysisResult spotify, List<SpotifyMatch> matches) {
    final l10n = AppLocalizations.of(context)!;
    final acceptable = matches.where((m) => m.isAcceptable).length;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Thumb(url: spotify.thumbnailUrl ?? '', size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.podcasts_rounded, color: Colors.green.shade400, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'Spotify',
                          style: TextStyle(color: Colors.green.shade400, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      spotify.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    if (spotify.subtitle != null)
                      Text(
                        spotify.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // El resultado elegido en YouTube para cada pista se enseña
          // siempre acá, antes de descargar nada — nunca se resuelve en
          // silencio (ver CLAUDE.md, Fase 8).
          ...matches.map((m) => _SpotifyMatchRow(match: m)),
          const SizedBox(height: 4),
          Text(
            acceptable == matches.length
                ? l10n.importSpotifyGoodMatchSummary(acceptable, matches.length)
                : l10n.importSpotifyPartialMatchSummary(acceptable, matches.length),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('download_spotify_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(acceptable == 0 ? l10n.importSpotifyNoMatchesButton : l10n.importDownloadCountButton(acceptable)),
              onPressed: acceptable == 0 ? null : () => _downloadSpotifyMatches(spotify, matches),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueSection() {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<DownloadProvider>();
    final current = provider.current;
    final pending = provider.queue.where((j) => current == null || j.queueId != current.queueId).toList();
    final failures = provider.failures;

    if (current == null && pending.isEmpty && failures.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: DownloadProgressCard(
              title: current.displayTitle,
              subtitle: current.artist,
              phase: provider.phase,
              progress: provider.progress,
              queueRemaining: pending.length,
              onCancel: () => provider.cancelJob(current.queueId),
              onCancelAll: provider.cancelAll,
            ),
          ),
        if (current == null && pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(
                  l10n.importQueueSectionTitle,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton(
                  onPressed: provider.cancelAll,
                  child: Text(l10n.importCancelAllButton),
                ),
              ],
            ),
          ),
        ...pending.map((job) => _QueueItemRow(
              job: job,
              onCancel: () => provider.cancelJob(job.queueId),
            )),
        if (failures.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                l10n.importFailuresTitle,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(onPressed: provider.clearFailures, child: Text(l10n.importDismissButton)),
            ],
          ),
          ...failures.map((f) => _FailureRow(failure: f)),
        ],
      ],
    );
  }
}

/// Una fila del emparejamiento Spotify -> YouTube: el original y en qué se
/// convirtió, con el semáforo de confianza que decide si entra en el lote.
class _SpotifyMatchRow extends StatelessWidget {
  final SpotifyMatch match;
  const _SpotifyMatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (icon, color, label) = switch (match) {
      SpotifyMatch(isGoodMatch: true) => (Icons.check_circle_rounded, Colors.greenAccent, l10n.importMatchGood(match.durationDiffSeconds!)),
      SpotifyMatch(isAcceptable: true) => (
          Icons.warning_amber_rounded,
          Colors.amberAccent,
          l10n.importMatchReview(match.durationDiffSeconds!),
        ),
      _ => (Icons.block_rounded, Colors.redAccent, l10n.importMatchNone),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${match.original.artist} - ${match.original.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (match.youtubeTrack != null)
                  Text(
                    '→ ${match.youtubeTrack!.artist} - ${match.youtubeTrack!.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                  )
                else
                  Text(
                    l10n.importMatchNoResult,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _QueueItemRow extends StatelessWidget {
  final DownloadJob job;
  final VoidCallback onCancel;

  const _QueueItemRow({required this.job, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: AppTheme.glassCard(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            _Thumb(url: job.thumbnailUrl, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (job.artist.isNotEmpty)
                    Text(
                      job.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.4), size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureRow extends StatelessWidget {
  final DownloadFailure failure;
  const _FailureRow({required this.failure});

  @override
  Widget build(BuildContext context) {
    // Un aviso de cuota no es un fallo del trabajo: sigue en la cola y se
    // reintentará solo cuando pase el tiempo indicado. Se distingue con
    // ámbar en vez de rojo para no leerse como "esto se rompió".
    final isQuotaWait = failure.retryAfterSeconds != null;
    final tint = isQuotaWait ? Colors.amber : Colors.red;
    final icon = isQuotaWait
        ? Icons.hourglass_bottom_rounded
        : (failure.permanent ? Icons.block_rounded : Icons.wifi_off_rounded);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tint.withValues(alpha: 0.2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tint.shade100, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    failure.error != null
                        ? localizedFriendlyError(AppLocalizations.of(context)!, failure.error!).message
                        : failure.message,
                    style: TextStyle(color: tint.shade100, fontSize: 11),
                  ),
                  if (failure.code != null)
                    Text(
                      AppLocalizations.of(context)!.errorCodeLine(failure.code!),
                      style: TextStyle(color: tint.shade100.withValues(alpha: 0.7), fontSize: 10),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String url;
  final double size;
  const _Thumb({required this.url, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final radius = size >= 48 ? 10.0 : 8.0;
    if (url.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: Icon(Icons.music_note_rounded, color: Colors.white70, size: size * 0.4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
          child: Icon(Icons.music_note_rounded, color: Colors.white70, size: size * 0.4),
        ),
      ),
    );
  }
}
