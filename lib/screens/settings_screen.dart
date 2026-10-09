import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/sync_provider.dart';
import '../screens/auth/login_screen.dart';
import '../screens/friends_screen.dart';
import '../screens/legal_screen.dart';
import '../screens/sync_status_screen.dart';
import '../services/audio_effects_service.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../services/artwork_repair_service.dart';
import '../services/download_source.dart';
import '../services/storage_service.dart';
import '../l10n/app_localizations.dart';
import '../models/statistics_data.dart';
import '../services/share_image_service.dart';
import '../services/statistics_service.dart';
import '../widgets/share_stats_card.dart';
import '../widgets/statistics_view.dart';
import '../widgets/username_claim_sheet.dart';
import '../services/friendly_error.dart';
import '../services/app_log.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// El audio real de las canciones importadas o descargadas vive en la
  /// carpeta SAF que eligió el usuario, no en un `File` que `dart:io` pueda
  /// leer (D1) — antes esto sólo sumaba `File(song.filePath)`, que para esas
  /// canciones está vacío, así que el número mostrado ignoraba casi todo lo
  /// que realmente ocupa espacio. Se suma aparte: el tamaño real de la
  /// carpeta (vía SAF) más lo que sigue siendo legítimamente un `File` —
  /// descargas heredadas pre-pivot y las miniaturas, que siempre viven en
  /// almacenamiento privado sin importar el origen de la canción (D5).
  Future<String> _calculateStorageUsage(BuildContext context, String? libraryRootUri) async {
    try {
      int totalBytes = 0;

      if (libraryRootUri != null) {
        totalBytes += await StorageService().calculateLibrarySize(libraryRootUri);
      }

      final songs = await DatabaseHelper.instance.getSongs();
      for (final song in songs) {
        if (song.uri == null || song.uri!.isEmpty) {
          try {
            final audioFile = File(song.filePath);
            if (await audioFile.exists()) {
              totalBytes += await audioFile.length();
            }
          } catch (_) {}
        }

        try {
          if (song.artPath.isNotEmpty) {
            final artFile = File(song.artPath);
            if (await artFile.exists()) {
              totalBytes += await artFile.length();
            }
          }
        } catch (_) {}
      }

      return _formatBytes(totalBytes);
    } catch (e) {
      return context.mounted ? AppLocalizations.of(context)!.settingsCalcError : 'Error calculando';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickLibraryFolder(BuildContext context) async {
    final storageService = StorageService();
    try {
      final rootUri = await storageService.pickLibraryRoot();
      if (!context.mounted) return;
      if (rootUri == null) return; // user cancelled the picker
      // Notify MusicProvider immediately so Bandeja (kept alive by the
      // bottom nav's IndexedStack) reflects the pick without the user
      // having to navigate away and back.
      context.read<MusicProvider>().setLibraryRootUri(rootUri);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderReadySnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderPickError(
              localizedErrorReport(AppLocalizations.of(context)!, e, area: 'FS'),
            )),
          backgroundColor: Colors.red.withValues(alpha: 0.8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final musicProvider = Provider.of<MusicProvider>(context);
    final l10n = AppLocalizations.of(context)!;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
        children: [
          Text(
            l10n.settingsTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.settingsAccountSectionTitle),
          const SizedBox(height: 10),
          const _AccountSection(),
          const SizedBox(height: 28),
          const _StatisticsSection(),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionStorage),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<String>(
              key: ValueKey(musicProvider.libraryRootUri),
              future: _calculateStorageUsage(context, musicProvider.libraryRootUri),
              builder: (context, snapshot) {
                final storage = snapshot.data ?? l10n.settingsCalculating;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.storage_rounded,
                          color: AppTheme.primaryLight,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.settingsSpaceUsed,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      storage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.settingsTotalDownloadedSongs,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionAppearance),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settingsThemeColor,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                ...AppThemePreset.values.map((preset) {
                  final selected = settings.preset == preset;
                  final isCustom = preset == AppThemePreset.custom;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => isCustom
                            ? _showCustomThemeSheet(context, settings)
                            : settings.setPreset(preset),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              _PresetDot(preset: preset),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  settings.presetLabel(context, preset),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (isCustom)
                                Icon(
                                  Icons.tune_rounded,
                                  color: selected
                                      ? AppTheme.primaryLight
                                      : Colors.white.withValues(alpha: 0.4),
                                  size: 20,
                                )
                              else if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: AppTheme.primaryLight,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionLanguage),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...AppLanguage.values.map((lang) {
                  final selected = settings.language == lang;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? AppTheme.primary.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => settings.setLanguage(lang),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.language_rounded,
                                color: selected ? AppTheme.primaryLight : Colors.white54,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  settings.languageLabel(lang),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: AppTheme.primaryLight,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionPlaylistOrder),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            child: musicProvider.playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l10n.settingsCreatePlaylistsHint,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: musicProvider.playlists.length,
                    onReorder: (oldIndex, newIndex) async {
                      if (newIndex > oldIndex) newIndex--;
                      final list = [...musicProvider.playlists];
                      final item = list.removeAt(oldIndex);
                      list.insert(newIndex, item);
                      await musicProvider.reorderPlaylists(list);
                    },
                    itemBuilder: (context, index) {
                      final p = musicProvider.playlists[index];
                      return ListTile(
                        key: ValueKey(p.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                        title: Text(
                          p.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Text(
                          '#${index + 1}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionLocalLibrary),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      color: AppTheme.primaryLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.settingsImportFromFolder,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsImportFolderBody,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.folder_rounded, size: 18),
                    label: Text(
                      l10n.settingsChooseFolder,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _pickLibraryFolder(context),
                  ),
                ),
                const SizedBox(height: 8),
                const _ArtworkRepairButton(),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionAudio),
          const SizedBox(height: 10),
          const _AudioEffectsSection(),
          const SizedBox(height: 28),
          _SectionTitle(l10n.serverSectionTitle),
          const SizedBox(height: 10),
          const _DownloadServerSection(),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionSearch),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: AppTheme.primaryLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.settingsMaxResults,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.settingsMaxResultsBody,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, size: 20),
                      color: AppTheme.primaryLight,
                      onPressed: settings.maxSearchResults > 10
                          ? () => settings.setMaxSearchResults(
                              settings.maxSearchResults - 10,
                            )
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        '${settings.maxSearchResults}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      color: AppTheme.primaryLight,
                      onPressed: settings.maxSearchResults < 100
                          ? () => settings.setMaxSearchResults(
                              settings.maxSearchResults + 10,
                            )
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionTitle(l10n.settingsSectionAbout),
          const SizedBox(height: 10),
          Container(
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Heardy',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.settingsAboutBody,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                const _AppVersionLabel(),
                const SizedBox(height: 10),
                Text(
                  l10n.settingsAboutExternalServices,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.gavel_rounded, size: 18),
                    label: Text(l10n.legalTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LegalScreen()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatisticsSection extends StatefulWidget {
  const _StatisticsSection();

  @override
  State<_StatisticsSection> createState() => _StatisticsSectionState();
}

class _StatisticsSectionState extends State<_StatisticsSection> {
  bool _isWeek = true;
  bool _isExpanded = false;

  /// El futuro vive en el `State`, NO dentro del `FutureBuilder`.
  ///
  /// Antes la carga se llamaba **dentro** de `FutureBuilder(future: ...)`, así
  /// que cada reconstrucción disparaba cuatro consultas nuevas a SQLite: cada
  /// toque del chevron, cada cambio de tema, y cada notificación de
  /// `MusicProvider` — a la que esta pantalla se suscribe, así que una descarga
  /// que terminaba en cualquier otra parte de la app también la reconstruía.
  late Future<StatisticsData> _future;

  SyncProvider? _sync;
  int _seenHistoryRevision = 0;

  @override
  void initState() {
    super.initState();
    _future = loadLocalStatistics(isWeek: _isWeek);
    try {
      _sync = context.read<SyncProvider>();
    } on ProviderNotFoundException {
      _sync = null;
    }
    final sync = _sync;
    if (sync != null) {
      _seenHistoryRevision = sync.historyRevision;
      sync.addListener(_onSyncChanged);
      // Sin await y estrangulado por dentro: abrir Estadísticas trae lo que
      // otros dispositivos hayan subido, sin temporizadores.
      unawaited(sync.syncIfStale());
    }
  }

  void _onSyncChanged() {
    final sync = _sync;
    if (sync == null || !mounted || sync.historyRevision == _seenHistoryRevision) return;
    _seenHistoryRevision = sync.historyRevision;
    setState(() => _future = loadLocalStatistics(isWeek: _isWeek));
  }

  @override
  void dispose() {
    _sync?.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _setPeriod(bool isWeek) {
    if (isWeek == _isWeek) return;
    setState(() {
      _isWeek = isWeek;
      _isExpanded = false;
      _future = loadLocalStatistics(isWeek: isWeek);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l10n.statsSectionTitle),
        const SizedBox(height: 10),
        FutureBuilder<StatisticsData>(
          future: _future,
          builder: (context, snapshot) {
            final loading = snapshot.connectionState == ConnectionState.waiting;
            final data = loading ? null : (snapshot.data ?? const StatisticsData.empty());
            return StatisticsView(
              data: data,
              isWeek: _isWeek,
              onPeriodChanged: _setPeriod,
              expanded: _isExpanded,
              onToggleExpanded: () => setState(() => _isExpanded = !_isExpanded),
              trailing: data == null || data.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.ios_share_rounded, color: Colors.white54, size: 20),
                      onPressed: () => _share(context, data),
                    ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context, StatisticsData data) async {
    final username = await ensureUsername(context);
    if (username == null || !context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ShareStatsSheet(username: username, initialData: data, initialIsWeek: _isWeek),
    );
  }
}

class _ShareStatsSheet extends StatefulWidget {
  final String username;
  final StatisticsData initialData;
  final bool initialIsWeek;

  const _ShareStatsSheet({required this.username, required this.initialData, required this.initialIsWeek});

  @override
  State<_ShareStatsSheet> createState() => _ShareStatsSheetState();
}

class _ShareStatsSheetState extends State<_ShareStatsSheet> {
  final _boundaryKey = GlobalKey();
  late bool _isWeek = widget.initialIsWeek;
  late StatisticsData _data = widget.initialData;
  bool _sharing = false;

  Future<void> _changePeriod(bool isWeek) async {
    setState(() => _isWeek = isWeek);
    final data = await loadLocalStatistics(isWeek: isWeek);
    if (mounted) setState(() => _data = data);
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      await waitForEndOfFrame();
      final bytes = await renderBoundaryPng(_boundaryKey);
      if (bytes == null) {
        // Antes esto simplemente no hacía nada — un fallo real (o los 10
        // reintentos agotados) tiene que verse, no desaparecer.
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.shareImageFailed)));
        }
        return;
      }
      await shareStatsImage(bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.shareStatsError(
              localizedErrorReport(AppLocalizations.of(context)!, e),
            )),
          ));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.shareStatsSheetTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          PeriodToggle(isWeek: _isWeek, onChanged: _changePeriod),
          const SizedBox(height: 16),
          // `FittedBox` con altura acotada, NO la tarjeta suelta dentro del
          // scroll de la hoja: la tarjeta crece con su contenido (top de
          // artistas + canciones) y puede pasar de largo la pantalla —
          // escalada, se ve entera en vez de exigir scroll para verla toda.
          // (El bug real que impedía compartir del todo era otro — un
          // `debugNeedsPaint` leído fuera de un `assert`, que Flutter mismo
          // documenta que lanza en release — ver share_image_service.dart.)
          SizedBox(
            height: 420,
            child: FittedBox(
              fit: BoxFit.contain,
              child: RepaintBoundary(
                key: _boundaryKey,
                child: ShareStatsCard(username: widget.username, data: _data, isWeek: _isWeek),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sharing ? null : _share,
              icon: _sharing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.ios_share_rounded, size: 18),
              label: Text(l10n.shareStatsAction),
            ),
          ),
        ],
      ),
    );
  }
}

/// Estado del microservidor de descargas (`server/` en este repo).
///
/// **Sólo diagnóstico: aquí no se configura nada.** La dirección y la clave
/// del servidor oficial van compiladas en el binario (ver `OfficialServer` y
/// `SettingsProvider.downloadServerUrl`), así que no hay campos que editar —
/// dejarlos editables sólo servía para que alguien se rompiera las descargas
/// sin saber cómo volver.
///
/// Lo que sí sigue siendo útil, y por eso esta sección existe, es responder
/// Cuenta de Firebase (Fase 2 del plan de seguridad): el único lugar de
/// Ajustes que necesita saber que existe [HeardyAuthProvider]. Sin sesión, sólo
/// invita a iniciarla — no bloquea nada acá, la biblioteca local no la
/// necesita para nada.
class _AccountSection extends StatelessWidget {
  const _AccountSection();

  String _formatLastSync(AppLocalizations l10n, DateTime? at) {
    if (at == null) return l10n.syncNeverSynced;
    final d = DateTime.now().difference(at);
    final when = d.inMinutes < 1
        ? '${d.inSeconds}s'
        : d.inHours < 1
            ? '${d.inMinutes}m'
            : d.inDays < 1
                ? '${d.inHours}h'
                : '${d.inDays}d';
    return l10n.syncLastSync(when);
  }

  Future<void> _confirmDeleteData(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.syncDeleteMyDataConfirmTitle),
        content: Text(l10n.syncDeleteMyDataConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.syncDeleteMyData, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<SyncProvider>().deleteCloudData();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.syncDeleteMyDataDone)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<HeardyAuthProvider>();
    final signedIn = auth.isReady;
    final sync = context.watch<SyncProvider>();

    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                signedIn ? Icons.verified_user_rounded : Icons.person_outline_rounded,
                color: AppTheme.primaryLight,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  signedIn ? l10n.settingsAccountSignedInAs(auth.email ?? '') : l10n.settingsAccountNotSignedIn,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: Icon(signedIn ? Icons.logout_rounded : Icons.login_rounded, size: 18),
              label: Text(
                signedIn ? l10n.authSignOutButton : l10n.settingsAccountManageButton,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: signedIn
                  ? () => context.read<HeardyAuthProvider>().signOut()
                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
            ),
          ),
          if (signedIn) ...[
            const Divider(height: 32, color: Colors.white12),
            Row(
              children: [
                Icon(Icons.badge_outlined, color: Colors.white.withValues(alpha: 0.6), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    sync.account?.username != null
                        ? '@${sync.account!.username}'
                        : l10n.accountNoUsernameYet,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
                  ),
                ),
                if (sync.account?.username == null)
                  TextButton(
                    onPressed: () async {
                      final username = await ensureUsername(context);
                      if (username != null && context.mounted) {
                        context.read<SyncProvider>().syncNow();
                      }
                    },
                    child: Text(l10n.accountChooseUsernameButton),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.people_alt_outlined, color: Colors.white.withValues(alpha: 0.6), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Colors.white),
                    onPressed: () async {
                      final username = await ensureUsername(context);
                      if (username == null || !context.mounted) return;
                      Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => const FriendsScreen()));
                    },
                    child: Text(l10n.friendsTitle),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              sync.isSyncing
                  ? l10n.syncInProgress
                  : sync.lastError != null
                      ? l10n.syncErrorLabel(sync.localizedLastError(l10n) ?? sync.lastError!)
                      : _formatLastSync(l10n, sync.lastSyncAt),
              style: TextStyle(
                color: sync.lastError != null ? Colors.redAccent : Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    onPressed: sync.isSyncing
                        ? null
                        : () async {
                            // Antes de esto no había forma de saber si "Sincronizar
                            // ahora" hizo algo o no: sin error visible, el usuario no
                            // tenía manera de distinguir "funcionó" de "no pasó nada".
                            final provider = context.read<SyncProvider>();
                            await provider.syncNow(fullHistory: true);
                            if (!context.mounted || provider.lastError != null) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(l10n.syncSuccessMessage)));
                          },
                    child: Text(l10n.syncNowButton),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: Colors.white70,
                    ),
                    icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const SyncStatusScreen())),
                    label: const Text('Restaurar desde tu cuenta'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppTheme.primaryLight,
              value: context.watch<SettingsProvider>().shareNowPlaying,
              title: Text(l10n.presenceShareTitle, style: const TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(
                l10n.presenceShareBody,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
              ),
              onChanged: (enabled) async {
                final messenger = ScaffoldMessenger.of(context);
                final sync = context.read<SyncProvider>();
                final notSaved = l10n.presenceShareNotSaved;
                await context.read<SettingsProvider>().setShareNowPlaying(enabled);
                final confirmed = await sync.setShareNowPlaying(enabled);
                if (confirmed == null) {
                  messenger.showSnackBar(SnackBar(content: Text(notSaved)));
                }
              },
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => _confirmDeleteData(context),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent, alignment: Alignment.centerLeft),
              child: Text(l10n.syncDeleteMyData),
            ),
          ],
        ],
      ),
    );
  }
}

/// "¿por qué no me descarga?" sin salir de la app: "Probar conexión"
/// distingue *inalcanzable* (el servidor está caído o no hay red) de *clave
/// inválida* (este build de la app quedó sin clave) de *conectado pero sin
/// proveedor de PO tokens* (llega, pero las descargas van a fallar igual).
/// Cada uno se arregla en un sitio distinto, y un "error" genérico no diría
/// en cuál.
/// Estabilizar audio y ecualizador se aplican en el propio [AudioEffectsService]
/// (Android vía los efectos oficiales de `just_audio`, escritorio vía `af` de
/// mpv) — esta sección sólo lee/escribe sus toggles y preset, sin saber nada
/// de la plataforma debajo.
class _AudioEffectsSection extends StatelessWidget {
  const _AudioEffectsSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fx = context.watch<AudioEffectsService>();

    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppTheme.primaryLight,
            value: fx.stabilizeEnabled,
            title: Text(l10n.audioFxStabilizeTitle, style: const TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: Text(
              l10n.audioFxStabilizeBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            onChanged: (enabled) => fx.setStabilizeEnabled(enabled),
          ),
          const Divider(height: 24, color: Colors.white12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppTheme.primaryLight,
            value: fx.equalizerEnabled,
            title: Text(l10n.audioFxEqualizerTitle, style: const TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: Text(
              l10n.audioFxEqualizerBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            onChanged: (enabled) => fx.setEqualizerEnabled(enabled),
          ),
          if (fx.equalizerEnabled) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _EqPresetChip(
                  label: l10n.audioFxPresetFlat,
                  preset: EqualizerPreset.flat,
                  selected: fx.preset,
                  onSelected: fx.setPreset,
                ),
                _EqPresetChip(
                  label: l10n.audioFxPresetVocalBoost,
                  preset: EqualizerPreset.vocalBoost,
                  selected: fx.preset,
                  onSelected: fx.setPreset,
                ),
                _EqPresetChip(
                  label: l10n.audioFxPresetTrebleFocus,
                  preset: EqualizerPreset.trebleFocus,
                  selected: fx.preset,
                  onSelected: fx.setPreset,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EqPresetChip extends StatelessWidget {
  final String label;
  final EqualizerPreset preset;
  final EqualizerPreset selected;
  final ValueChanged<EqualizerPreset> onSelected;

  const _EqPresetChip({
    required this.label,
    required this.preset,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = preset == selected;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(preset),
      selectedColor: AppTheme.primary.withValues(alpha: 0.3),
      backgroundColor: Colors.white.withValues(alpha: 0.06),
      labelStyle: TextStyle(color: Colors.white.withValues(alpha: isSelected ? 1 : 0.7), fontSize: 12),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
    );
  }
}

class _DownloadServerSection extends StatefulWidget {
  const _DownloadServerSection();

  @override
  State<_DownloadServerSection> createState() => _DownloadServerSectionState();
}

class _DownloadServerSectionState extends State<_DownloadServerSection> {
  bool _testing = false;
  DownloadSourceStatus? _lastStatus;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _lastStatus = null;
    });

    // El `DownloadSource` del árbol de Providers, no uno nuevo: así lo que se
    // prueba es exactamente la fuente que usan las descargas reales, y no una
    // copia que podría estar configurada de otra forma.
    final source = context.read<DownloadSource>();
    try {
      final status = await source.probe();
      if (!mounted) return;
      setState(() => _lastStatus = status);
    } finally {
      // Un único finally, no un reset por cada salida: la convención existe
      // porque una ruta de salida sin probar dejaba la UI bloqueada.
      if (mounted) setState(() => _testing = false);
    }
  }

  String _problemText(DownloadSourceStatus status) {
    final l10n = AppLocalizations.of(context)!;
    return switch (status.problem) {
      DownloadProbeProblem.noServer => l10n.probeNoServer,
      DownloadProbeProblem.unreachable => l10n.probeUnreachable,
      DownloadProbeProblem.timeout => l10n.probeTimeout,
      DownloadProbeProblem.capacity => l10n.dlCapacity,
      DownloadProbeProblem.serviceDown =>
        '${l10n.errorServiceUnavailable}\n${l10n.errorCodeLine(downloadErrorCode(DownloadSourceErrorKind.extraction, statusCode: status.statusCode))}',
      DownloadProbeProblem.keyInvalid => l10n.probeKeyInvalid,
      DownloadProbeProblem.potDown => l10n.probePotDown,
      null => status.detail,
    };
  }

  ({Color color, IconData icon, String text})? _statusLine() {
    final status = _lastStatus;
    if (status == null) return null;
    if (!status.reachable) {
      return (
        color: Colors.redAccent,
        icon: Icons.cloud_off_rounded,
        text: _problemText(status),
      );
    }
    if (!status.authenticated) {
      return (
        color: Colors.orangeAccent,
        icon: Icons.key_off_rounded,
        text: _problemText(status),
      );
    }
    if (!status.potProviderReachable) {
      return (
        color: Colors.orangeAccent,
        icon: Icons.warning_amber_rounded,
        text: _problemText(status),
      );
    }
    return (
      color: Colors.greenAccent,
      icon: Icons.cloud_done_rounded,
      text: AppLocalizations.of(context)!.serverConnectedStatus(status.version ?? '?'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final line = _statusLine();

    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dns_rounded, color: AppTheme.primaryLight, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.serverIntroBody,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(
                _testing ? l10n.serverTestingButton : l10n.serverTestButton,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: _testing ? null : _test,
            ),
          ),
          if (line != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(line.icon, color: line.color, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    line.text,
                    style: TextStyle(
                      color: line.color,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Sólo la versión (`1.2.3`), sin el build number interno (`+N`) — ese
/// número no significa nada para quien lee esto, es lo que ya compara
/// `GithubAppUpdateSource.isNewerVersion` contra los tags de GitHub.
class _AppVersionLabel extends StatefulWidget {
  const _AppVersionLabel();

  @override
  State<_AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<_AppVersionLabel> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final version = _version;
    if (version == null) return const SizedBox.shrink();
    return Text(
      AppLocalizations.of(context)!.settingsAboutVersion(version),
      style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.primaryLight.withValues(alpha: 0.95),
        fontWeight: FontWeight.w700,
        fontSize: 14,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _PresetDot extends StatelessWidget {
  final AppThemePreset preset;
  const _PresetDot({required this.preset});

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.previewColors(preset);
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: colors),
      ),
    );
  }
}

// --- PERSONALIZACIÓN DE COLORES ---

const _customThemeSwatches = <Color>[
  Color(0xFFEF4444), // red
  Color(0xFFF97316), // orange
  Color(0xFFF59E0B), // amber
  Color(0xFFEAB308), // yellow
  Color(0xFF84CC16), // lime
  Color(0xFF22C55E), // green
  Color(0xFF10B981), // emerald
  Color(0xFF14B8A6), // teal
  Color(0xFF06B6D4), // cyan
  Color(0xFF0EA5E9), // sky
  Color(0xFF3B82F6), // blue
  Color(0xFF6366F1), // indigo
  Color(0xFF8B5CF6), // violet
  Color(0xFFA855F7), // purple
  Color(0xFFD946EF), // fuchsia
  Color(0xFFEC4899), // pink
  Color(0xFFF43F5E), // rose
  Color(0xFF64748B), // slate (neutro)
];

Future<void> _showCustomThemeSheet(
  BuildContext context,
  SettingsProvider settings,
) async {
  final result = await showModalBottomSheet<(Color, Color, bool)>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CustomThemeSheet(
      initialPrimary: settings.customPrimary,
      initialSecondary: settings.customSecondary,
      initialCombined: settings.customCombined,
    ),
  );
  if (result == null) return;
  await settings.setCustomColors(
    primary: result.$1,
    secondary: result.$2,
    combined: result.$3,
  );
}

class _CustomThemeSheet extends StatefulWidget {
  final Color initialPrimary;
  final Color initialSecondary;
  final bool initialCombined;

  const _CustomThemeSheet({
    required this.initialPrimary,
    required this.initialSecondary,
    required this.initialCombined,
  });

  @override
  State<_CustomThemeSheet> createState() => _CustomThemeSheetState();
}

class _CustomThemeSheetState extends State<_CustomThemeSheet> {
  late Color _primary = widget.initialPrimary;
  late Color _secondary = widget.initialSecondary;
  late bool _combined = widget.initialCombined;
  late final _primaryHexController = TextEditingController(text: _hex(_primary));
  late final _secondaryHexController = TextEditingController(text: _hex(_secondary));

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

  Color? _parseHex(String input) {
    var s = input.trim().replaceFirst('#', '');
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length != 6) return null;
    final value = int.tryParse(s, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }

  @override
  void dispose() {
    _primaryHexController.dispose();
    _secondaryHexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.themeCustomizeTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                _buildPreview(),
                const SizedBox(height: 20),
                Text(
                  l10n.themePrimaryColorLabel,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                ),
                const SizedBox(height: 10),
                _buildSwatchGrid(_primary, (c) {
                  setState(() {
                    _primary = c;
                    _primaryHexController.text = _hex(c);
                  });
                }),
                const SizedBox(height: 8),
                _buildHexField(_primaryHexController, (c) => setState(() => _primary = c)),
                const SizedBox(height: 20),
                Text(
                  l10n.themeSecondaryColorLabel,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                ),
                const SizedBox(height: 10),
                _buildSwatchGrid(_secondary, (c) {
                  setState(() {
                    _secondary = c;
                    _secondaryHexController.text = _hex(c);
                  });
                }),
                const SizedBox(height: 8),
                _buildHexField(_secondaryHexController, (c) => setState(() => _secondary = c)),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: _primary,
                  title: Text(l10n.themeCombinedToggle, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    _combined ? l10n.themeCombinedOnHint : l10n.themeCombinedOffHint,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                  ),
                  value: _combined,
                  onChanged: (v) => setState(() => _combined = v),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context, (_primary, _secondary, _combined)),
                    child: Text(l10n.commonConfirm),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      height: 56,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
      child: _combined
          ? DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [_primary, _secondary]),
              ),
            )
          : Row(
              children: [
                Expanded(child: ColoredBox(color: _primary)),
                Expanded(child: ColoredBox(color: _secondary)),
              ],
            ),
    );
  }

  Widget _buildSwatchGrid(Color selected, ValueChanged<Color> onSelect) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _customThemeSwatches.map((c) {
        final isSelected = c.toARGB32() == selected.toARGB32();
        return GestureDetector(
          onTap: () => onSelect(c),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: isSelected ? Border.all(color: Colors.white, width: 2.5) : null,
              boxShadow: isSelected
                  ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 8)]
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHexField(TextEditingController controller, ValueChanged<Color> onValid) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: const InputDecoration(isDense: true, hintText: '#RRGGBB'),
        onSubmitted: (value) {
          final c = _parseHex(value);
          if (c != null) onValid(c);
        },
      ),
    );
  }
}


/// Vuelve a bajar las carátulas de las canciones descargadas que no la
/// tienen (ver ArtworkRepairService). Un solo toque, progreso en el propio
/// botón, y las listas se refrescan al terminar.
class _ArtworkRepairButton extends StatefulWidget {
  const _ArtworkRepairButton();

  @override
  State<_ArtworkRepairButton> createState() => _ArtworkRepairButtonState();
}

class _ArtworkRepairButtonState extends State<_ArtworkRepairButton> {
  bool _working = false;
  int _done = 0;
  int _total = 0;

  Future<void> _repair() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final music = context.read<MusicProvider>();
    setState(() {
      _working = true;
      _done = 0;
      _total = 0;
    });
    var repaired = 0;
    try {
      repaired = await ArtworkRepairService().repairMissing(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
    } catch (e) {
      appLog('SettingsScreen: no se pudieron recuperar carátulas: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (repaired > 0) music.notifyLibraryChanged();
    messenger.showSnackBar(SnackBar(content: Text(l10n.settingsRepairArtworkDone(repaired))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settingsRepairArtworkBody,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: _working
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.image_search_rounded, size: 18),
            label: Text(
              _working && _total > 0
                  ? l10n.settingsRepairArtworkWorking(_done, _total)
                  : l10n.settingsRepairArtwork,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            onPressed: _working ? null : _repair,
          ),
        ),
      ],
    );
  }
}
