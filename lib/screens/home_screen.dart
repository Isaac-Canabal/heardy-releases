import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/music_provider.dart';
import '../providers/notifications_provider.dart';
import '../models/playlist.dart';
import '../services/database_helper.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/username_claim_sheet.dart';
import '../l10n/app_localizations.dart';
import '../widgets/max_width_center.dart';
import 'friends_screen.dart';
import 'history_screen.dart';
import 'notifications_screen.dart';
import '../services/friendly_error.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _playlistNameController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _playlistNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<SettingsProvider>(context);
    final l10n = AppLocalizations.of(context)!;
    final musicProvider = Provider.of<MusicProvider>(context);
    final playlists = musicProvider.playlists
        .where((p) => p.name.toLowerCase().contains(_query))
        .toList();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 12, kScreenGutter, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.homeTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Badge(
                  isLabelVisible: context.watch<NotificationsProvider>().unreadCount > 0,
                  label: Text('${context.watch<NotificationsProvider>().unreadCount}'),
                  child: _CircleIconButton(
                    icon: Icons.notifications_rounded,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _CircleIconButton(
                  icon: Icons.people_alt_rounded,
                  onTap: () => _openFriends(context),
                ),
                const SizedBox(width: 10),
                _CircleIconButton(
                  icon: Icons.add_rounded,
                  onTap: () => _showCreatePlaylistDialog(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 18, kScreenGutter, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: l10n.homeSearchHint,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: AppTheme.primaryLight,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const _HistoryEntryRow(),
          Expanded(
            child: playlists.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 90),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      return _PlaylistCard(playlist: playlists[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 72,
              color: Colors.white.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.homeEmptyTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.homeEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// E-5 de la Etapa 16: abrir Amigos es uno de los dos únicos sitios donde
  /// se pide el nombre de usuario (el otro es compartir estadísticas).
  Future<void> _openFriends(BuildContext context) async {
    final username = await ensureUsername(context);
    if (username == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendsScreen()));
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    _playlistNameController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.homeNewPlaylistTitle, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: _playlistNameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(hintText: l10n.commonName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel, style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
          ),
          TextButton(
            onPressed: () async {
              final name = _playlistNameController.text.trim();
              if (name.isNotEmpty) {
                try {
                  await Provider.of<MusicProvider>(context, listen: false)
                      .createPlaylist(name);
                  Navigator.pop(context);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(localizedErrorReport(AppLocalizations.of(context)!, e)),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
            child: Text(l10n.commonCreate, style: TextStyle(color: AppTheme.primaryLight, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// Acceso al historial de escuchado, bajo el buscador.
class _HistoryEntryRow extends StatelessWidget {
  const _HistoryEntryRow();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 0, kScreenGutter, 4),
      child: ListTile(
        key: const Key('home_history_row'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(Icons.history_rounded, color: AppTheme.primaryLight),
        title: Text(
          l10n.historyTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.4)),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const HistoryScreen()),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.primary,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;

  const _PlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final audioHandler = Provider.of<AudioPlayerHandler>(context, listen: false);
    final musicProvider = Provider.of<MusicProvider>(context, listen: false);

    return FutureBuilder<
        ({int songCount, int totalSeconds, String? coverArtPath})>(
      future: DatabaseHelper.instance.getPlaylistSummary(playlist.id),
      builder: (context, snapshot) {
        final summary = snapshot.data;
        final count = summary?.songCount ?? 0;
        final duration = summary?.totalSeconds ?? 0;
        final cover = summary?.coverArtPath;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: AppTheme.playlistCard(),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => Navigator.pushNamed(
                context,
                '/playlist',
                arguments: playlist.id,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _CoverThumb(path: cover),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.homeSongsCount(count, AppTheme.formatDuration(duration)),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (count > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Material(
                          color: AppTheme.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              DesktopShellScope.maybeOf(context)?.openNowPlaying();
                              musicProvider.playPlaylistFromStart(
                                playlist.id,
                                audioHandler,
                              );
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                      color: AppTheme.surface,
                      onSelected: (value) async {
                        if (value == 'rename') {
                          _renamePlaylist(context, playlist);
                        } else if (value == 'delete') {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppTheme.surface,
                              title: Text(l10n.homeDeleteListTitle, style: const TextStyle(color: Colors.white)),
                              content: Text(
                                l10n.homeDeleteListBody(playlist.name),
                                style: const TextStyle(color: Colors.white70),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(l10n.commonCancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(
                                    l10n.commonDelete,
                                    style: const TextStyle(color: Colors.redAccent),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await musicProvider.deletePlaylist(playlist.id);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.homeDeletedSnack(playlist.name)),
                                ),
                              );
                            }
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(l10n.commonRename, style: const TextStyle(color: Colors.white)),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(l10n.commonDelete, style: const TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _renamePlaylist(BuildContext context, Playlist playlist) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.commonRename, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Provider.of<MusicProvider>(context, listen: false)
                    .renamePlaylist(playlist.id, name);
              }
              Navigator.pop(ctx);
            },
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }
}

class _CoverThumb extends StatelessWidget {
  final String? path;

  const _CoverThumb({this.path});

  @override
  Widget build(BuildContext context) {
    if (path != null && File(path!).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(path!),
          width: 58,
          height: 58,
          fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.queue_music_rounded, color: Colors.white70),
    );
  }
}
