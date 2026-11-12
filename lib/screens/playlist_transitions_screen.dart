import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/song.dart';
import '../providers/playlist_transitions_provider.dart';
import '../services/mix/mixer_labels.dart' show shortSongTitle;
import '../services/transition/transition_labels.dart';
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';
import 'pair_transition_editor_screen.dart';

/// Las canciones de una playlist en orden y, entre cada dos, el estado de su
/// transición. Tocar una transición abre su editor; "Preparar toda la
/// playlist" deja una automática en cada par sin tocar las personalizadas.
class PlaylistTransitionsScreen extends StatefulWidget {
  const PlaylistTransitionsScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
    required this.songs,
  });

  final String playlistId, playlistName;

  /// Canciones de la playlist en el orden en que suenan.
  final List<Song> songs;

  static Route<void> route({
    required String playlistId,
    required String playlistName,
    required List<Song> songs,
  }) => MaterialPageRoute<void>(
    builder: (_) => PlaylistTransitionsScreen(
      playlistId: playlistId,
      playlistName: playlistName,
      songs: songs,
    ),
  );

  @override
  State<PlaylistTransitionsScreen> createState() =>
      _PlaylistTransitionsScreenState();
}

class _PlaylistTransitionsScreenState extends State<PlaylistTransitionsScreen> {
  late final PlaylistTransitionsProvider _prov;
  AutoFillReport? _report;
  bool? _available;

  @override
  void initState() {
    super.initState();
    _prov = context.read<PlaylistTransitionsProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _prov.load(widget.playlistId, widget.songs);
      final ok = await _prov.available;
      if (mounted) setState(() => _available = ok);
    });
  }

  @override
  void dispose() {
    if (_prov.autoFillRunning) _prov.cancelAutoFill();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() => _report = null);
    final r = await _prov.autoFillPlaylist(widget.playlistId);
    if (mounted) setState(() => _report = r);
  }

  void _open(TransitionPair pair) {
    Navigator.of(
      context,
    ).push(PairTransitionEditorScreen.route(widget.playlistId, pair));
  }

  String _title(Song s) => shortSongTitle(s.title, max: 40, fallback: '?');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prov = context.watch<PlaylistTransitionsProvider>();
    final pid = widget.playlistId;
    final pairs = prov.pairs(pid);
    final enabled = prov.isEnabled(pid);
    final running = prov.autoFillRunning;
    final canUse = _available != false;
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, kScreenGutter, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.trScreenTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              widget.playlistName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: widget.songs.length < 2
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.trScreenNeedTwo,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            _enabledCard(l10n, prov, enabled),
                            if (!canUse)
                              _note(
                                l10n.trUnavailableDevice,
                                key: const Key('tr_unavailable'),
                              ),
                            _prepareCard(l10n, prov, running, canUse),
                            if (_report != null && !running)
                              _summaryCard(l10n, _report!),
                            _note(l10n.trEntrySkipNote),
                            const SizedBox(height: 4),
                            for (var i = 0; i < widget.songs.length; i++) ...[
                              _songRow(l10n, prov, i),
                              if (i < pairs.length)
                                _pairRow(l10n, pairs[i], canUse && !running),
                            ],
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

  Widget _box(Widget child, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(kScreenGutter, 6, kScreenGutter, 6),
    child: Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  );

  Widget _note(String text, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(
      kScreenGutter + 4,
      4,
      kScreenGutter + 4,
      4,
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white54, fontSize: 12),
    ),
  );

  Widget _enabledCard(
    AppLocalizations l10n,
    PlaylistTransitionsProvider prov,
    bool enabled,
  ) {
    return _box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('tr_enabled_switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.trEntryTitle,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
            subtitle: Text(
              !enabled
                  ? l10n.trEntryOffSubtitle
                  : (prov.preparedCount(widget.playlistId) == 0
                        ? l10n.trEntryOnEmptySubtitle
                        : l10n.trEntryOnSubtitle),
              style: const TextStyle(color: Colors.white60),
            ),
            value: enabled,
            onChanged: (v) => prov.setEnabled(widget.playlistId, v),
          ),
          if (!enabled)
            Text(
              l10n.trScreenOffBanner,
              key: const Key('tr_off_banner'),
              style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _prepareCard(
    AppLocalizations l10n,
    PlaylistTransitionsProvider prov,
    bool running,
    bool canUse,
  ) {
    return _box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (running) ...[
            Text(
              l10n.trPreparing(prov.autoFillDone, prov.autoFillTotal),
              key: const Key('tr_progress_text'),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: prov.autoFillTotal == 0
                  ? null
                  : prov.autoFillDone / prov.autoFillTotal,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('tr_prepare_cancel'),
                onPressed: prov.cancelAutoFill,
                child: Text(l10n.commonCancel),
              ),
            ),
          ] else ...[
            FilledButton.icon(
              key: const Key('tr_prepare_all'),
              onPressed: canUse ? _prepare : null,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(l10n.trPrepareAll),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.trPrepareAllHint,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryCard(AppLocalizations l10n, AutoFillReport r) {
    Widget line(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(t, style: const TextStyle(color: Colors.white70)),
    );
    return _box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.trSummaryTitle,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          line(l10n.trSummaryFilled(r.filled)),
          if (r.skippedCustom > 0) line(l10n.trSummaryCustom(r.skippedCustom)),
          if (r.skippedDisabled > 0) line(l10n.trSummaryDisabled(r.skippedDisabled)),
          if (r.skippedIneligible > 0)
            line(l10n.trSummaryUnavailable(r.skippedIneligible)),
          if (r.failed > 0) line(l10n.trSummaryFailed(r.failed)),
          if (r.cancelled) line(l10n.trSummaryCancelled),
        ],
      ),
      key: const Key('tr_summary'),
    );
  }

  Widget _songRow(
    AppLocalizations l10n,
    PlaylistTransitionsProvider prov,
    int i,
  ) {
    final s = widget.songs[i];
    final info = songInfoText(l10n, prov.analysisOf(s.id));
    return ListTile(
      key: Key('tr_song_$i'),
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: Colors.white12,
        child: Text(
          '${i + 1}',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
      title: Text(
        _title(s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        info == null ? s.artist : '${s.artist} · $info',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54),
      ),
    );
  }

  Widget _pairRow(AppLocalizations l10n, PairTransitionView v, bool enabled) {
    final kind = pairStateKindOf(v);
    final unavailable = kind == PairStateKind.unavailable;
    final color = switch (kind) {
      PairStateKind.custom => Colors.lightBlueAccent,
      PairStateKind.auto => Colors.tealAccent,
      PairStateKind.disabled => Colors.orangeAccent,
      _ => Colors.white38,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kScreenGutter + 12,
        vertical: 2,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('tr_pair_${v.pair.key}'),
          borderRadius: BorderRadius.circular(20),
          onTap: unavailable || !enabled ? null : () => _open(v.pair),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Icon(
                  unavailable
                      ? Icons.link_off_rounded
                      : Icons.swap_vert_rounded,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pairChipText(l10n, v),
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                if (!unavailable)
                  Icon(Icons.chevron_right_rounded, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
