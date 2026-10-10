import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/song.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/smart_lists.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';

String smartListTitle(AppLocalizations l10n, SmartListKind kind) => switch (kind) {
      SmartListKind.mostPlayed => l10n.smartListsMostPlayed,
      SmartListKind.recentlyAdded => l10n.smartListsRecentlyAdded,
      SmartListKind.neverPlayed => l10n.smartListsNeverPlayed,
      SmartListKind.forgotten => l10n.smartListsForgotten,
    };

String _smartListHint(AppLocalizations l10n, SmartListKind kind) => switch (kind) {
      SmartListKind.mostPlayed => l10n.smartListsMostPlayedHint,
      SmartListKind.recentlyAdded => l10n.smartListsRecentlyAddedHint,
      SmartListKind.neverPlayed => l10n.smartListsNeverPlayedHint,
      SmartListKind.forgotten => l10n.smartListsForgottenHint,
    };

IconData _smartListIcon(SmartListKind kind) => switch (kind) {
      SmartListKind.mostPlayed => Icons.local_fire_department_rounded,
      SmartListKind.recentlyAdded => Icons.new_releases_rounded,
      SmartListKind.neverPlayed => Icons.visibility_off_rounded,
      SmartListKind.forgotten => Icons.hourglass_bottom_rounded,
    };

/// Ruta empujada desde Inicio: listas derivadas de la biblioteca y el historial.
class SmartListsScreen extends StatefulWidget {
  const SmartListsScreen({super.key});

  @override
  State<SmartListsScreen> createState() => _SmartListsScreenState();
}

class _SmartListsScreenState extends State<SmartListsScreen> {
  Map<SmartListKind, int>? _counts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await DatabaseHelper.instance.getSongPlayStats();
      final now = DateTime.now();
      final counts = {
        for (final k in SmartListKind.values) k: buildSmartList(k, stats, now).length,
      };
      if (mounted) setState(() => _counts = counts);
    } catch (e) {
      print('Listas inteligentes: no se pudo cargar (${e.runtimeType})');
      if (mounted) setState(() => _counts = {for (final k in SmartListKind.values) k: 0});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final counts = _counts;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(l10n.smartListsTitle), backgroundColor: Colors.transparent),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: counts == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 24),
                    children: [
                      for (final kind in SmartListKind.values)
                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          decoration: AppTheme.glassCard(),
                          child: ListTile(
                            key: Key('smart_list_${kind.name}'),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            leading: Icon(_smartListIcon(kind), color: AppTheme.primaryLight),
                            title: Text(
                              smartListTitle(l10n, kind),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              '${_smartListHint(l10n, kind)} · ${l10n.smartListsSongCount(counts[kind] ?? 0)}',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
                            ),
                            trailing: Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => SmartListDetailScreen(kind: kind)),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class SmartListDetailScreen extends StatefulWidget {
  final SmartListKind kind;

  const SmartListDetailScreen({super.key, required this.kind});

  @override
  State<SmartListDetailScreen> createState() => _SmartListDetailScreenState();
}

class _SmartListDetailScreenState extends State<SmartListDetailScreen> {
  List<Song> _songs = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await DatabaseHelper.instance.getSongPlayStats();
      final list = buildSmartList(widget.kind, stats, DateTime.now());
      if (!mounted) return;
      setState(() {
        _songs = [for (final s in list) s.song];
        _failed = false;
      });
    } catch (e) {
      print('Listas inteligentes: no se pudo cargar (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(List<Song> queue, Song target) async {
    final handler = context.read<AudioPlayerHandler>();
    final label = smartListTitle(AppLocalizations.of(context)!, widget.kind);
    DesktopShellScope.maybeOf(context)?.openNowPlaying();
    await context.read<MusicProvider>().playSearchResults(queue, target, handler, label);
  }

  void _shuffle() {
    final queue = [..._songs]..shuffle();
    _play(queue, queue.first);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(smartListTitle(l10n, widget.kind)),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _songs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _failed ? l10n.smartListsLoadFailed : l10n.smartListsEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 16),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 24),
                    itemCount: _songs.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  key: const Key('smart_list_play'),
                                  onPressed: () => _play(_songs, _songs.first),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: Text(l10n.smartListsPlay),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  key: const Key('smart_list_shuffle'),
                                  onPressed: _shuffle,
                                  icon: const Icon(Icons.shuffle_rounded),
                                  label: Text(l10n.smartListsShuffle),
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      final song = _songs[i - 1];
                      return _SongTile(
                        song: song,
                        unknownArtist: l10n.commonUnknownArtist,
                        onTap: () => _play(_songs, song),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final Song song;
  final String unknownArtist;
  final VoidCallback onTap;

  const _SongTile({required this.song, required this.unknownArtist, required this.onTap});

  Widget _placeholder() => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(song.title)),
        child: const Icon(Icons.music_note_rounded, color: Colors.white70),
      );

  Widget _art() {
    if (song.artPath.isNotEmpty && File(song.artPath).existsSync()) {
      return Image.file(
        File(song.artPath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        cacheHeight: 144,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: AppTheme.glassCard(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(8), child: _art()),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist.isEmpty ? unknownArtist : song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
