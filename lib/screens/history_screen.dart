import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../models/history_entry.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/database_helper.dart';
import '../services/history_logic.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import '../widgets/remote_track_actions_mixin.dart';

/// Marca de "historial borrado": lo anterior no se muestra. `play_history`
/// alimenta estadísticas y sincronización, así que nunca se borra desde aquí.
const String historyClearedAtKey = 'history_cleared_at';

/// Ruta empujada desde Mis playlists: lo escuchado, más reciente primero,
/// incluidas las reproducciones por streaming (que no tienen fila en `songs`).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with RemoteTrackActionsMixin<HistoryScreen> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    initRemoteTrackActions();
    _load();
  }

  @override
  void dispose() {
    disposeRemoteTrackActions();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = DatabaseHelper.instance;
      final prefs = await SharedPreferences.getInstance();
      final clearedAt = DateTime.tryParse(prefs.getString(historyClearedAtKey) ?? '');
      final merged = mergeHistory(
        await db.getLocalHistory(),
        await db.getStreamHistory(),
        since: clearedAt,
      );
      if (!mounted) return;
      setState(() {
        _entries = merged;
        _failed = false;
      });
    } catch (e) {
      print('Historial: no se pudo cargar (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.historyClearTitle, style: const TextStyle(color: Colors.white)),
        content: Text(l10n.historyClearBody, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.historyClearConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(historyClearedAtKey, DateTime.now().toIso8601String());
      await DatabaseHelper.instance.clearStreamHistory();
    } catch (e) {
      print('Historial: no se pudo borrar (${e.runtimeType})');
    }
    if (!mounted) return;
    setState(() => _entries = const []);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.historyClearedSnack), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _play(HistoryEntry entry) async {
    final song = entry.song;
    if (!entry.isStream && song != null) {
      final handler = context.read<AudioPlayerHandler>();
      final label = AppLocalizations.of(context)!.historyTitle;
      final shell = DesktopShellScope.maybeOf(context);
      shell?.openNowPlaying();
      await context.read<MusicProvider>().playSearchResults([song], song, handler, label);
      return;
    }
    // Si la pista ya está en la biblioteca suena el archivo local; si no,
    // streaming, y un fallo ofrece descargarla.
    await playRemoteTrack(entry.toRemoteTrack());
  }

  String _ageLabel(AppLocalizations l10n, HistoryEntry entry) {
    final age = historyAge(entry.playedAt, DateTime.now());
    return switch (age.kind) {
      HistoryAgeKind.justNow => l10n.historyAgeJustNow,
      HistoryAgeKind.minutes => l10n.historyAgeMinutes(age.value),
      HistoryAgeKind.hours => l10n.historyAgeHours(age.value),
      HistoryAgeKind.yesterday => l10n.historyAgeYesterday,
      HistoryAgeKind.days => l10n.historyAgeDays(age.value),
      HistoryAgeKind.date => MaterialLocalizations.of(context).formatShortDate(entry.playedAt),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.historyTitle),
        backgroundColor: Colors.transparent,
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: l10n.historyClearTooltip,
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                ? _message(
                    _failed ? l10n.historyLoadFailed : l10n.historyEmptyTitle,
                    _failed ? null : l10n.historyEmptyBody,
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 24),
                      itemCount: _entries.length,
                      itemBuilder: (context, i) => _HistoryTile(
                        entry: _entries[i],
                        age: _ageLabel(l10n, _entries[i]),
                        streamLabel: l10n.historyStreamLabel,
                        busy: streamingTrackId != null && streamingTrackId == _entries[i].videoId,
                        onTap: () => _play(_entries[i]),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _message(String title, String? body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 72, color: Colors.white.withValues(alpha: 0.15)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final HistoryEntry entry;
  final String age;
  final String streamLabel;
  final bool busy;
  final VoidCallback onTap;

  const _HistoryTile({
    required this.entry,
    required this.age,
    required this.streamLabel,
    required this.busy,
    required this.onTap,
  });

  Widget _placeholder() => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(entry.title)),
    child: const Icon(Icons.music_note_rounded, color: Colors.white70),
  );

  Widget _art() {
    if (entry.artPath.isNotEmpty && File(entry.artPath).existsSync()) {
      return Image.file(
        File(entry.artPath),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        cacheHeight: 144,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    final url = Uri.tryParse(entry.artUrl);
    if (url != null && (url.scheme == 'https' || url.scheme == 'http')) {
      return Image.network(
        entry.artUrl,
        key: ValueKey(entry.artUrl),
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
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: AppTheme.glassCard(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: busy ? null : onTap,
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
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.artist.isEmpty ? l10n.commonUnknownArtist : entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (busy)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(age, style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12)),
                      if (entry.isStream)
                        Tooltip(
                          message: streamLabel,
                          child: Icon(Icons.stream_rounded, size: 16, color: Colors.white.withValues(alpha: 0.45)),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
