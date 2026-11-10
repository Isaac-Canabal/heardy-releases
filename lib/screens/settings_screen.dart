import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/support_links.dart';
import '../providers/auth_provider.dart';
import '../providers/folder_sync_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/sync_provider.dart';
import '../screens/auth/login_screen.dart';
import '../screens/friends_screen.dart';
import '../screens/lan_sync_screen.dart';
import '../screens/legal_screen.dart';
import '../screens/sync_status_screen.dart';
import '../screens/cloud_library_screen.dart';
import '../screens/ignored_recommendations_screen.dart';
import '../screens/equalizer_screen.dart';
import '../services/audio_effects_service.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/library_storage.dart' show LibraryEntry;
import '../theme/app_theme.dart';
import '../theme/nav_tabs.dart';
import '../services/storage_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/max_width_center.dart';
import '../widgets/reorder_sheet.dart';
import '../models/nav_tab.dart';
import '../models/statistics_data.dart';
import '../services/share_image_service.dart';
import '../services/statistics_service.dart';
import '../widgets/area_colors_sheet.dart';
import '../widgets/now_playing_layout_sheet.dart';
import '../widgets/text_style_sheet.dart';
import '../widgets/color_picker_panel.dart';
import '../widgets/share_stats_card.dart';
import '../widgets/statistics_view.dart';
import '../widgets/username_claim_sheet.dart';
import '../services/friendly_error.dart';
import '../services/app_log.dart';

part 'settings_sections.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(kScreenGutter, 16, kScreenGutter, 90),
        children: [
          // `Wrap`: con texto grande la acción baja de línea en vez de desbordar.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(
                l10n.settingsTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextButton.icon(
                key: const Key('settings_reorder_sections'),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                icon: const Icon(Icons.swap_vert_rounded, size: 18),
                label: Text(l10n.settingsReorderSections),
                onPressed: () => _showSectionOrderSheet(context),
              ),
            ],
          ),
          // La acción mide 48 y el título 40: las secciones quedan donde siempre.
          const SizedBox(height: 16),
          for (final (index, id) in settings.settingsSectionOrder.indexed) ...[
            if (index > 0) const SizedBox(height: 28),
            ..._sectionChildren(l10n, id),
          ],
        ],
      ),
    );
  }
}

class _SupportCard extends StatelessWidget {
  const _SupportCard();

  Future<void> _open(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(Uri.parse(supportDonationUrl), mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (e) {
      appLog('SettingsScreen: no se pudo abrir el enlace de apoyo: $e');
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.supportOpenError)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.supportBody,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12, height: 1.4),
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
              icon: const Icon(Icons.favorite_border_rounded, size: 18),
              label: Text(l10n.supportButton, style: const TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () => _open(context),
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
class _FolderSyncSection extends StatefulWidget {
  const _FolderSyncSection();

  @override
  State<_FolderSyncSection> createState() => _FolderSyncSectionState();
}

class _FolderSyncSectionState extends State<_FolderSyncSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FolderSyncProvider>().refresh();
    });
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<FolderSyncProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final chosen = await showDialog<LibraryEntry>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.folderSyncRestoreTitle),
        content: provider.backups.isEmpty
            ? Text(l10n.folderSyncNoBackups)
            : SizedBox(
                width: 320,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(l10n.folderSyncRestoreBody),
                    ),
                    for (final backup in provider.backups)
                      ListTile(
                        dense: true,
                        title: Text(backup.name),
                        onTap: () => Navigator.pop(ctx, backup),
                      ),
                  ],
                ),
              ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.commonCancel))],
      ),
    );
    if (chosen == null) return;
    await provider.restoreBackup(chosen);
    messenger.showSnackBar(SnackBar(
      content: Text(provider.outcome == FolderSyncOutcome.ok ? l10n.folderSyncRestored : l10n.folderSyncFailed),
    ));
  }

  String? _status(AppLocalizations l10n, FolderSyncProvider sync) {
    if (sync.isBusy) return l10n.folderSyncInProgress;
    switch (sync.outcome) {
      case FolderSyncOutcome.noLibraryFolder:
        return l10n.folderSyncNoFolder;
      case FolderSyncOutcome.failed:
        return l10n.folderSyncFailed;
      case FolderSyncOutcome.ok:
        final r = sync.lastReport;
        if (r != null) return l10n.folderSyncDone(r.playlistsAdded, r.historyAdded);
      case FolderSyncOutcome.none:
        break;
    }
    final at = sync.lastSyncAt;
    return at == null ? null : l10n.folderSyncLast(MaterialLocalizations.of(context).formatShortDate(at));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sync = context.watch<FolderSyncProvider>();
    final status = _status(l10n, sync);
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.folderSyncBody, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: sync.isBusy ? null : () => context.read<FolderSyncProvider>().syncNow(),
                  icon: const Icon(Icons.folder_copy_outlined, size: 18),
                  label: Text(l10n.folderSyncButton),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: sync.isBusy ? null : _restore,
                child: Text(l10n.folderSyncRestoreButton),
              ),
            ],
          ),
          if (status != null) ...[
            const SizedBox(height: 8),
            Text(status, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
          ],
          if (sync.otherDeviceSongs.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Colors.white),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const CloudLibraryScreen())),
              child: Text(l10n.folderSyncOtherSongs(sync.otherDeviceSongs.length)),
            ),
        ],
      ),
    );
  }
}

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
                    label: Text(l10n.restoreTitle),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: Colors.white70,
                    ),
                    icon: const Icon(Icons.devices_rounded, size: 18),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const CloudLibraryScreen())),
                    label: Text(l10n.cloudLibTitle),
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
/// Estabilizar audio se aplica en el propio [AudioEffectsService]
/// (Android con un efecto de sistema, escritorio con una ganancia por pista
/// vía mpv) — esta sección sólo lee/escribe su toggle, sin saber nada
/// de la plataforma debajo.
class _AudioEffectsSection extends StatelessWidget {
  const _AudioEffectsSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fx = context.watch<AudioEffectsService>();
    final settings = context.watch<SettingsProvider>();
    final handler = context.read<AudioPlayerHandler>();

    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (handler.supportsSkipSilence) ...[
            SwitchListTile(
              key: const Key('skip_silence_switch'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppTheme.primaryLight,
              value: settings.skipSilence,
              title: Text(
                l10n.settingsSkipSilence,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: Text(
                l10n.settingsSkipSilenceBody,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
              ),
              onChanged: (v) {
                settings.setSkipSilence(v);
                handler.setSkipSilence(v);
              },
            ),
            const Divider(height: 24, color: Colors.white12),
          ],
          SwitchListTile(
            key: const Key('track_fade_switch'),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppTheme.primaryLight,
            value: settings.trackFade,
            title: Text(
              l10n.settingsTrackFade,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsTrackFadeBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            onChanged: (v) {
              settings.setTrackFade(v);
              handler.setTrackFade(v);
            },
          ),
          const Divider(height: 24, color: Colors.white12),
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
          ListTile(
            key: const Key('equalizer_tile'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.equalizerTitle, style: const TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: Text(
              fx.equalizerEnabled ? equalizerPresetLabel(l10n, fx.equalizerPreset) : l10n.equalizerSettingsBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white54),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EqualizerScreen())),
          ),
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
  bool _primaryPickerOpen = false;
  bool _secondaryPickerOpen = false;
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
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 20, kScreenGutter, 20),
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
                _buildColorSection(
                  label: l10n.themePrimaryColorLabel,
                  color: _primary,
                  controller: _primaryHexController,
                  expanded: _primaryPickerOpen,
                  onToggle: () => setState(() => _primaryPickerOpen = !_primaryPickerOpen),
                  onColor: (c) => setState(() => _primary = c),
                ),
                const SizedBox(height: 20),
                _buildColorSection(
                  label: l10n.themeSecondaryColorLabel,
                  color: _secondary,
                  controller: _secondaryHexController,
                  expanded: _secondaryPickerOpen,
                  onToggle: () => setState(() => _secondaryPickerOpen = !_secondaryPickerOpen),
                  onColor: (c) => setState(() => _secondary = c),
                ),
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

  Widget _buildColorSection({
    required String label,
    required Color color,
    required TextEditingController controller,
    required bool expanded,
    required VoidCallback onToggle,
    required ValueChanged<Color> onColor,
  }) {
    final l10n = AppLocalizations.of(context)!;
    void set(Color c) {
      controller.text = _hex(c);
      onColor(c);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
        ),
        const SizedBox(height: 10),
        _buildSwatchGrid(color, set),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildHexField(controller, onColor),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onToggle,
              icon: Icon(expanded ? Icons.expand_less : Icons.palette_outlined, size: 18),
              label: Text(expanded ? l10n.themePickerHideLabel : l10n.themePickExactColor),
            ),
          ],
        ),
        if (expanded) ...[
          const SizedBox(height: 10),
          ColorPickerPanel(
            color: color,
            onChanged: set,
            hueLabel: l10n.themePickerHueLabel,
            saturationValueLabel: l10n.themePickerSaturationValueLabel,
          ),
        ],
      ],
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
        onChanged: (value) {
          if (value.trim().replaceFirst('#', '').length != 6) return;
          final c = _parseHex(value);
          if (c != null) onValid(c);
        },
        onSubmitted: (value) {
          final c = _parseHex(value);
          if (c != null) onValid(c);
        },
      ),
    );
  }
}
