import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/music_provider.dart';
import '../providers/notifications_provider.dart';
import '../models/playlist.dart';
import '../services/database_helper.dart';
import '../services/audio_player_handler.dart';
import '../services/friendly_error.dart';
import '../services/playlist_filter_logic.dart';
import '../services/stream_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/username_claim_sheet.dart';
import '../l10n/app_localizations.dart';
import '../widgets/max_width_center.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_kind_picker.dart';
import 'friends_screen.dart';
import 'history_screen.dart';
import 'notifications_screen.dart';
import 'online_playlist_detail_screen.dart';
import 'smart_lists_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  PlaylistKindFilter _kindFilter = PlaylistKindFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<SettingsProvider>(context);
    final l10n = AppLocalizations.of(context)!;
    final musicProvider = Provider.of<MusicProvider>(context);
    final playlists = filterHomePlaylists(musicProvider.playlists, _kindFilter, _query);

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
                  icon: Icons.history_rounded,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  ),
                ),
                const SizedBox(width: 10),
                _CircleIconButton(
                  icon: Icons.auto_awesome_rounded,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SmartListsScreen()),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 18, kScreenGutter, 4),
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
          _buildFilterRow(l10n),
          Expanded(
            child: playlists.isEmpty
                ? (musicProvider.playlists.isEmpty ? _buildEmptyState() : _buildNoMatchesState())

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

  Widget _buildFilterRow(AppLocalizations l10n) {
    final labels = {
      PlaylistKindFilter.all: l10n.homeFilterAll,
      PlaylistKindFilter.downloaded: l10n.homeFilterDownloaded,
      PlaylistKindFilter.notDownloaded: l10n.homeFilterNotDownloaded,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 4, kScreenGutter, 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in labels.entries) ...[
                    ChoiceChip(
                      key: Key('home_filter_${entry.key.name}'),
                      label: Text(entry.value),
                      selected: _kindFilter == entry.key,
                      showCheckmark: false,
                      selectedColor: AppTheme.primary,
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      side: BorderSide.none,
                      labelStyle: TextStyle(
                        color: Colors.white.withValues(alpha: _kindFilter == entry.key ? 1 : 0.7),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      onSelected: (_) => setState(() => _kindFilter = entry.key),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            key: const Key('home_new_playlist'),
            tooltip: l10n.homeNewPlaylistTitle,
            icon: Icon(Icons.add_rounded, color: AppTheme.primaryLight),
            onPressed: _createPlaylist,
          ),
        ],
      ),
    );
  }

  Future<void> _createPlaylist() async {
    final provider = context.read<MusicProvider>();
    final result = await showCreatePlaylistDialog(context, streamingAvailable: streamingSupported);
    if (result == null || !mounted) return;
    try {
      await provider.createPlaylist(result.name, kind: result.kind);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedErrorReport(AppLocalizations.of(context)!, e))),
      );
    }
  }

  Widget _buildNoMatchesState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          l10n.homeFilterNoMatches,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
        ),
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
        ({int songCount, int totalSeconds, String? coverArtPath, String? thumbnailUrl})>(
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
                    PlaylistCover(path: cover, url: summary?.thumbnailUrl),
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
                          Row(
                            children: [
                              if (playlist.isOnline) ...[
                                _OnlineBadge(label: l10n.onlinePlaylistBadge),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  l10n.homeSongsCount(count, AppTheme.formatDuration(duration)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.45),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
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
                              if (playlist.isOnline) {
                                playOnlinePlaylistWithFeedback(context, playlist.id);
                                return;
                              }
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
                                playlist.isOnline
                                    ? l10n.onlinePlaylistDeleteBody(playlist.name)
                                    : l10n.homeDeleteListBody(playlist.name),
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

class _OnlineBadge extends StatelessWidget {
  final String label;

  const _OnlineBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_queue_rounded, size: 12, color: AppTheme.primaryLight),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.primaryLight,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
