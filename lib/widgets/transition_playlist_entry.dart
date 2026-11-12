import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/song.dart';
import '../providers/playlist_transitions_provider.dart';
import '../screens/playlist_transitions_screen.dart';

/// Entrada a las transiciones desde la pantalla de una playlist: un interruptor
/// para encenderlas o apagarlas (lo guardado se conserva) y el camino a la
/// pantalla donde se preparan y se editan.
class PlaylistTransitionsEntry extends StatefulWidget {
  const PlaylistTransitionsEntry({
    super.key,
    required this.playlistId,
    required this.playlistName,
    required this.songs,
  });

  final String playlistId, playlistName;

  /// Canciones de la playlist en el orden en que suenan.
  final List<Song> songs;

  @override
  State<PlaylistTransitionsEntry> createState() =>
      _PlaylistTransitionsEntryState();
}

class _PlaylistTransitionsEntryState extends State<PlaylistTransitionsEntry> {
  late final PlaylistTransitionsProvider _prov;
  String _signature = '';

  static String _sig(List<Song> songs) =>
      songs.map((s) => '${s.id}:${s.missing ? 1 : 0}').join(',');

  @override
  void initState() {
    super.initState();
    _prov = context.read<PlaylistTransitionsProvider>();
    _reload();
  }

  @override
  void didUpdateWidget(PlaylistTransitionsEntry old) {
    super.didUpdateWidget(old);
    if (_sig(widget.songs) != _signature || old.playlistId != widget.playlistId)
      _reload();
  }

  void _reload() {
    _signature = _sig(widget.songs);
    final id = widget.playlistId;
    final songs = List<Song>.of(widget.songs);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prov.load(id, songs);
    });
  }

  void _open() {
    Navigator.of(context).push(
      PlaylistTransitionsScreen.route(
        playlistId: widget.playlistId,
        playlistName: widget.playlistName,
        songs: widget.songs,
      ),
    );
  }

  Future<void> _toggle(bool on) async {
    await _prov.setEnabled(widget.playlistId, on);
    if (!on || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final hasAny = _prov
        .pairs(widget.playlistId)
        .any((v) => v.transition != null);
    if (hasAny) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.trEntryEnabledSnack),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: l10n.trEntryPrepare, onPressed: _open),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prov = context.watch<PlaylistTransitionsProvider>();
    final enabled = prov.isEnabled(widget.playlistId);
    final nothingReady = prov.preparedCount(widget.playlistId) == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: const Key('tr_entry_open'),
                borderRadius: BorderRadius.circular(14),
                onTap: _open,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.blur_on_rounded,
                        color: enabled ? Colors.tealAccent : Colors.white54,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.trEntryTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              !enabled
                                  ? l10n.trEntryOffSubtitle
                                  : (nothingReady
                                        ? l10n.trEntryOnEmptySubtitle
                                        : l10n.trEntryOnSubtitle),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        l10n.trEntryEdit,
                        style: const TextStyle(
                          color: Colors.tealAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.tealAccent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Switch(
              key: const Key('tr_entry_switch'),
              value: enabled,
              onChanged: _toggle,
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
