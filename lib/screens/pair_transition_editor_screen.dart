import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playlist_transitions_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/mix/mix_types.dart' show MixCancelToken;
import '../services/mix/mixer_labels.dart' show shortSongTitle;
import '../services/transition/platform/transition_job_runner.dart';
import '../services/transition/transition_analysis.dart' show hasUsableTempo;
import '../services/transition/transition_labels.dart';
import '../services/transition/transition_model.dart';
import '../services/transition/transition_presets.dart';
import '../services/transition/transition_suggest.dart';
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';
import '../widgets/transition_editor_logic.dart';
import '../widgets/transition_lane_view.dart';
import '../widgets/transition_preview_loop.dart';
import '../widgets/transition_preview_player.dart';

/// Editor de la transición de UN par de canciones: dos ondas ampliadas sobre la
/// mezcla (la que sale arriba, la que entra abajo) con su escala en dB, la
/// rejilla de ritmo, y las curvas de volumen, graves/medios/agudos y efecto
/// encima. Lo primero que se toca es el estilo; lo demás se ve cuando se pide.
class PairTransitionEditorScreen extends StatefulWidget {
  const PairTransitionEditorScreen({
    super.key,
    required this.playlistId,
    required this.pair,
    this.previewPlayer,
  });

  final String playlistId;
  final TransitionPair pair;

  /// Reproductor de la escucha; por defecto el de la app ([HandlerTransitionPreviewPlayer]).
  final TransitionPreviewPlayer? previewPlayer;

  static Route<void> route(String playlistId, TransitionPair pair) =>
      MaterialPageRoute<void>(
        builder: (_) =>
            PairTransitionEditorScreen(playlistId: playlistId, pair: pair),
      );

  @override
  State<PairTransitionEditorScreen> createState() =>
      _PairTransitionEditorScreenState();
}

class _PairTransitionEditorScreenState
    extends State<PairTransitionEditorScreen> {
  late final PlaylistTransitionsProvider _prov;
  final _cancel = MixCancelToken();
  MixCancelToken? _renderCancel;

  TransitionPairAnalysis? _analysis;
  TransitionErrorKind? _error;

  SongTransition? _draft;
  SongTransition? _baseline;
  bool _baselineAuto = true;
  final _history = TransitionDraftHistory();

  TransitionSnap _snap = TransitionSnap.bar;
  TransitionCurveKind? _editKind;
  bool _showBands = false;
  LaneLimit _limitOut = LaneLimit.none, _limitIn = LaneLimit.none;

  bool _rendering = false;
  bool _busy = false;
  TransitionClip? _clip;
  SongTransition? _renderedDraft;
  bool _loop = true;
  TransitionPreviewLoop? _loopCtl;
  TransitionPreviewPlayer? _player;
  bool _ownsPlayer = false;
  StreamSubscription<TransitionPreviewTick>? _ticks;
  TransitionPreviewTick? _tick;

  @override
  void initState() {
    super.initState();
    _prov = context.read<PlaylistTransitionsProvider>();
    // Un aviso flotante de la pantalla anterior taparía los botones de abajo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
    });
    _analyze();
  }

  @override
  void dispose() {
    _cancel.cancel();
    _renderCancel?.cancel();
    _ticks?.cancel();
    if (_loaded && (_tick?.playing ?? false)) unawaited(_player?.pause());
    unawaited(_loopCtl?.end());
    if (_ownsPlayer) _player?.dispose();
    super.dispose();
  }

  // ---- Carga ----

  Future<void> _analyze() async {
    setState(() {
      _error = null;
      _analysis = null;
    });
    try {
      final a = await _prov.analyzePair(widget.pair, cancel: _cancel);
      if (!mounted) return;
      final saved = _prov.savedTransition(
        widget.playlistId,
        widget.pair.from.id,
        widget.pair.to.id,
      );
      var auto = true;
      for (final v in _prov.pairs(widget.playlistId)) {
        if (v.pair.key == widget.pair.key) auto = v.isAuto;
      }
      final start = saved ?? a.suggestion.transition;
      setState(() {
        _analysis = a;
        _draft = start;
        _baseline = start;
        _baselineAuto = saved == null ? true : auto;
        _snap = a.suggestion.beatGridTrusted
            ? TransitionSnap.bar
            : TransitionSnap.beat;
      });
    } on TransitionException catch (e) {
      if (mounted && !_cancel.isCancelled) setState(() => _error = e.kind);
    } catch (_) {
      if (mounted && !_cancel.isCancelled)
        setState(() => _error = TransitionErrorKind.analysisFailed);
    }
  }

  // ---- Borrador ----

  bool get _dirty => _draft != null && !sameTransition(_draft, _baseline);

  void _pushUndo() {
    final d = _draft;
    if (d == null) return;
    if (_history.last != null && sameTransition(_history.last, d)) return;
    _history.push(d);
  }

  void _set(SongTransition next, {bool undoable = true}) {
    if (undoable) _pushUndo();
    setState(() => _draft = next);
  }

  void _undo() {
    final prev = _history.pop();
    if (prev == null) return;
    setState(() => _draft = prev);
  }

  double get _outDur => _analysis!.outgoing.durationSec;
  double get _inDur => _analysis!.incoming.durationSec;

  void _nudge(bool outgoing, double deltaSec) {
    final d = _draft!;
    final len = d.clampedLengthSec;
    final range = outgoing
        ? outgoingStartRange(outDurationSec: _outDur, lengthSec: len)
        : incomingStartRange(
            inDurationSec: _inDur,
            lengthSec: len,
            tempoMatch: d.tempoMatch,
          );
    final r = nudgeLaneStart(
      sec: outgoing ? d.outStartSec : d.inStartSec,
      deltaSec: deltaSec,
      minSec: range.min,
      maxSec: range.max,
    );
    setState(() => outgoing ? _limitOut = r.limit : _limitIn = r.limit);
    _set(
      outgoing ? d.copyWith(outStartSec: r.sec) : d.copyWith(inStartSec: r.sec),
    );
  }

  void _setLength(double sec) => _set(
    transitionWithLength(
      _draft!,
      sec,
      outDurationSec: _outDur,
      inDurationSec: _inDur,
    ),
  );

  void _setTempo(bool on) {
    final d = _draft!;
    final next = d.copyWith(
      tempoMatch: on
          ? TransitionTempoMatch.matchIncoming
          : TransitionTempoMatch.none,
    );
    _set(
      transitionWithLength(
        next,
        next.lengthSec,
        outDurationSec: _outDur,
        inDurationSec: _inDur,
      ),
    );
  }

  // ---- Escuchar ----

  TransitionPreviewPlayer? _ensurePlayer() {
    if (_player != null) return _player;
    try {
      _player =
          widget.previewPlayer ??
          HandlerTransitionPreviewPlayer(context.read<AudioPlayerHandler>());
      _ownsPlayer = widget.previewPlayer == null;
      _loopCtl = TransitionPreviewLoop(player: _player!, replay: _playClip)..setEnabled(_loop);
      _ticks = _player!.ticks.listen(_onTick);
    } catch (e) {
      print('Transición: no hay reproductor para escuchar (${e.runtimeType})');
    }
    return _player;
  }

  bool get _loaded =>
      _clip != null && _tick?.mediaId == transitionPreviewMediaId(_clip!.key);

  bool get _fresh => _clip != null && sameTransition(_renderedDraft, _draft);

  void _onTick(TransitionPreviewTick t) {
    if (!mounted) return;
    setState(() => _tick = t);
    unawaited(_loopCtl?.onTick(t));
  }

  Future<void> _playClip() async {
    final clip = _clip, player = _ensurePlayer();
    if (clip == null) return;
    try {
      if (player == null) throw StateError('sin reproductor');
      final clipLength = Duration(milliseconds: (clip.info.clipSec * 1000).round());
      await player.play(
        id: transitionPreviewMediaId(clip.key),
        wavPath: clip.wavPath,
        title: AppLocalizations.of(context)!.trEditorTitle,
        duration: clipLength,
      );
      await _loopCtl?.begin(transitionPreviewMediaId(clip.key), clipLength);
    } catch (e) {
      print('Transición: no se pudo escuchar (${e.runtimeType})');
      if (mounted) _snack(AppLocalizations.of(context)!.trErrRender);
    }
  }

  Future<void> _listen() async {
    final draft = _draft;
    if (draft == null || _rendering) return;
    if (_fresh) {
      final clip = _clip!;
      if (_loaded && (_tick?.playing ?? false)) {
        await _player?.pause();
      } else if (_loaded &&
          (_tick?.position.inMilliseconds ?? 0) <
              (clip.info.clipSec - 0.25) * 1000) {
        await _player?.resume();
      } else {
        await _playClip();
      }
      return;
    }
    if (_loaded && (_tick?.playing ?? false)) unawaited(_player?.pause());
    final token = _renderCancel = MixCancelToken();
    setState(() => _rendering = true);
    try {
      final r = await _prov.preview(
        widget.playlistId,
        widget.pair,
        override: draft,
        cancel: token,
      );
      if (!mounted) return;
      if (token.isCancelled) return;
      if (r.ok) {
        setState(() {
          _clip = r.clip;
          _renderedDraft = draft;
        });
        await _playClip();
      } else {
        _snack(
          transitionErrorText(
            AppLocalizations.of(context)!,
            r.error ?? TransitionErrorKind.renderFailed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  // ---- Guardar y salir ----

  Future<void> _save() async {
    final d = _draft;
    if (d == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _prov.setTransition(widget.playlistId, widget.pair, d);
      if (!mounted) return;
      _snack(AppLocalizations.of(context)!.trSaved);
      setState(() {
        _baseline = d;
        _baselineAuto = false;
      });
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Apaga o enciende la transición de este par al instante (no espera a
  /// «Guardar»): lo guardado se conserva y los demás cambios del borrador quedan como están.
  Future<void> _setPairEnabled(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _prov.setPairEnabled(
        widget.playlistId,
        widget.pair,
        on,
        fallback: _baseline,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetToAuto() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final t = await _prov.resetToAuto(
        widget.playlistId,
        widget.pair,
        cancel: _cancel,
      );
      if (!mounted) return;
      _history.clear();
      setState(() {
        _draft = t;
        _baseline = t;
        _baselineAuto = true;
      });
      _snack(l10n.trResetDone);
    } catch (_) {
      if (mounted) _snack(l10n.trResetFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.trDiscardTitle),
        content: Text(l10n.trDiscardBody),
        actions: [
          TextButton(
            key: const Key('tr_keep_editing'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.trKeepEditing),
          ),
          TextButton(
            key: const Key('tr_discard_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.trDiscard),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---- Construcción ----

  String _title(String raw) => shortSongTitle(raw, max: 32, fallback: '?');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ready = _analysis != null && _draft != null;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: Container(
          decoration: AppTheme.gradientScaffold(),
          child: SafeArea(
            child: MaxWidthCenter(
              maxWidth: 720,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _topBar(context, l10n, ready),
                  Expanded(
                    child: ready ? _body(context, l10n) : _loading(l10n),
                  ),
                  if (ready) _bottomBar(context, l10n),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, AppLocalizations l10n, bool ready) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            key: const Key('tr_close'),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              l10n.trEditorTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (ready) ...[
            IconButton(
              key: const Key('tr_undo'),
              tooltip: l10n.trUndo,
              icon: const Icon(Icons.undo_rounded),
              color: Colors.white,
              onPressed: _history.canUndo ? _undo : null,
            ),
            PopupMenuButton<String>(
              key: const Key('tr_menu'),
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
              onSelected: (v) {
                if (v == 'auto') _resetToAuto();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'auto',
                  enabled: !_busy,
                  child: Text(l10n.trResetAuto),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _loading(AppLocalizations l10n) {
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                transitionErrorText(l10n, err),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('tr_retry'),
                onPressed: _analyze,
                child: Text(l10n.trRetry),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(l10n.trAnalyzing, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _card(String? title, List<Widget> children, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(kScreenGutter, 6, kScreenGutter, 6),
    child: Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ...children,
          ],
        ),
      ),
    ),
  );

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final a = _analysis!;
    final d = _draft!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _enabledCard(l10n),
        _statusRow(l10n),
        _presetsCard(l10n, d),
        _lanesCard(l10n, a, d),
        _lengthCard(l10n, a, d),
        _curvesCard(l10n, d),
        _tempoCard(l10n, a, d),
        _warningsCard(l10n, a, d),
      ],
    );
  }

  Widget _enabledCard(AppLocalizations l10n) {
    final on = _prov.isPairEnabled(widget.playlistId, widget.pair);
    return _card(null, [
      SwitchListTile(
        key: const Key('tr_pair_enabled_switch'),
        contentPadding: EdgeInsets.zero,
        title: Text(
          l10n.trPairEnabledTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            on ? l10n.trPairEnabledOnSub : l10n.trPairEnabledOffSub,
            key: const Key('tr_pair_enabled_sub'),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        value: on,
        onChanged: _busy ? null : _setPairEnabled,
      ),
    ]);
  }

  Widget _statusRow(AppLocalizations l10n) {
    final custom = _dirty || !_baselineAuto;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 4, kScreenGutter, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            key: const Key('tr_state_chip'),
            label: Text(custom ? l10n.trStateCustom : l10n.trStateAuto),
            visualDensity: VisualDensity.compact,
          ),
          if (_dirty)
            Text(
              l10n.trUnsaved,
              key: const Key('tr_unsaved'),
              style: const TextStyle(color: Colors.amberAccent),
            ),
        ],
      ),
    );
  }

  Widget _presetsCard(AppLocalizations l10n, SongTransition d) {
    final id = presetIdOf(d);
    return _card(l10n.trPresetsTitle, [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final p in kTransitionPresets)
            ChoiceChip(
              key: Key('tr_preset_${p.id}'),
              label: Text(transitionPresetName(l10n, p.id)),
              selected: id == p.id,
              onSelected: (_) => _set(applyPreset(p.id, d)),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        id == null
            ? l10n.trPresetCustom
            : transitionPresetDescription(l10n, id),
        key: const Key('tr_preset_desc'),
        style: const TextStyle(color: Colors.white70),
      ),
      if (_analysis!.suggestion.keysCompatible != null) ...[
        const SizedBox(height: 4),
        Text(
          _analysis!.suggestion.keysCompatible!
              ? l10n.trKeysCompatible
              : l10n.trKeysClash,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    ]);
  }

  bool _laneHasGrid(TransitionPairAnalysis a, bool outgoing) {
    final issue = a.suggestion.gridIssue;
    final p = outgoing ? a.outgoing : a.incoming;
    if (!hasUsableTempo(p.analysis)) return false;
    if (issue == TransitionGridIssue.outgoingGridUnknown) return false;
    if (!outgoing && issue == TransitionGridIssue.incomingGridUnknown)
      return false;
    return true;
  }

  double? _playhead(SongTransition d) {
    final clip = _clip;
    if (clip == null || !_loaded || !_fresh) return null;
    final t = _tick!;
    if (!t.playing && t.position == Duration.zero) return null;
    return playheadFraction(
      positionSec: t.position.inMilliseconds / 1000,
      overlapStartInClipSec: clip.info.overlapStartInClipSec,
      overlapSec: clip.info.overlapSec,
    );
  }

  Widget _laneBlock(
    AppLocalizations l10n,
    TransitionPairAnalysis a,
    SongTransition d, {
    required bool outgoing,
  }) {
    final song = outgoing ? widget.pair.from : widget.pair.to;
    final profile = outgoing ? a.outgoing : a.incoming;
    final start = outgoing ? d.outStartSec : d.inStartSec;
    final grid = _laneHasGrid(a, outgoing);
    final limit = outgoing ? _limitOut : _limitIn;
    final title = _title(song.title);
    final info = songInfoText(l10n, profile.analysis);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                outgoing ? l10n.trLaneOut(title) : l10n.trLaneIn(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (info != null)
              Text(
                info,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 4),
        TransitionOverviewStrip(
          profile: profile,
          startSec: start,
          lengthSec: d.clampedLengthSec,
          outgoing: outgoing,
        ),
        const SizedBox(height: 4),
        TransitionLane(
          key: Key(outgoing ? 'tr_lane_out' : 'tr_lane_in'),
          profile: profile,
          outgoing: outgoing,
          transition: d,
          title: title,
          showGrid: grid,
          showBands: _showBands,
          editKind: _editKind,
          snap: grid ? _snap : TransitionSnap.free,
          playheadFraction: _playhead(d),
          onGestureBegin: _pushUndo,
          onStartChanged: (sec) => setState(
            () => _draft = outgoing
                ? _draft!.copyWith(outStartSec: sec)
                : _draft!.copyWith(inStartSec: sec),
          ),
          onCurveChanged: (k, c) => setState(
            () => _draft = transitionWithCurve(
              _draft!,
              outgoing: outgoing,
              k: k,
              curve: c,
            ),
          ),
          onLimit: (v) {
            if ((outgoing ? _limitOut : _limitIn) != v)
              setState(() => outgoing ? _limitOut = v : _limitIn = v);
          },
        ),
        Row(
          children: [
            IconButton(
              key: Key(outgoing ? 'tr_nudge_out_minus' : 'tr_nudge_in_minus'),
              tooltip: l10n.trNudgeEarlier,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left_rounded),
              color: Colors.white,
              onPressed: () => _nudge(outgoing, -0.01),
            ),
            Expanded(
              child: Text(
                outgoing
                    ? l10n.trOutStarts(timeWithTenths(start))
                    : l10n.trInStarts(timeWithTenths(start)),
                key: Key(outgoing ? 'tr_out_time' : 'tr_in_time'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            IconButton(
              key: Key(outgoing ? 'tr_nudge_out_plus' : 'tr_nudge_in_plus'),
              tooltip: l10n.trNudgeLater,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right_rounded),
              color: Colors.white,
              onPressed: () => _nudge(outgoing, 0.01),
            ),
          ],
        ),
        if (limit != LaneLimit.none)
          Text(
            limit == LaneLimit.start ? l10n.trLimitStart : l10n.trLimitEnd,
            key: Key(outgoing ? 'tr_limit_out' : 'tr_limit_in'),
            style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
          ),
      ],
    );
  }

  Widget _lanesCard(
    AppLocalizations l10n,
    TransitionPairAnalysis a,
    SongTransition d,
  ) {
    final anyGrid = _laneHasGrid(a, true) || _laneHasGrid(a, false);
    return _card(l10n.trPositionTitle, [
      Text(
        l10n.trPositionHint,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      const SizedBox(height: 8),
      _laneBlock(l10n, a, d, outgoing: true),
      const SizedBox(height: 10),
      _laneBlock(l10n, a, d, outgoing: false),
      const SizedBox(height: 8),
      if (anyGrid)
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.trSnapTitle,
              style: const TextStyle(color: Colors.white70),
            ),
            for (final (s, label) in [
              (TransitionSnap.bar, l10n.trSnapBar),
              (TransitionSnap.beat, l10n.trSnapBeat),
              (TransitionSnap.free, l10n.trSnapFree),
            ])
              ChoiceChip(
                key: Key('tr_snap_${s.name}'),
                label: Text(label),
                selected: _snap == s,
                onSelected: (_) => setState(() => _snap = s),
              ),
          ],
        ),
      SwitchListTile(
        key: const Key('tr_bands_switch'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          l10n.trShowBands,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        value: _showBands,
        onChanged: (v) => setState(() => _showBands = v),
      ),
    ]);
  }

  Widget _lengthCard(
    AppLocalizations l10n,
    TransitionPairAnalysis a,
    SongTransition d,
  ) {
    final s = a.suggestion;
    final options = transitionLengthOptions(
      outBpm: a.outgoing.analysis.bpm,
      beatGridTrusted: s.beatGridTrusted,
      maxSec: [
        kTransitionMaxLengthSec,
        _outDur,
        _inDur,
      ].reduce((x, y) => x < y ? x : y),
    );
    final sel = selectedLengthIndex(options, d.clampedLengthSec);
    final why = gridIssueText(
      l10n,
      s.gridIssue,
      outTitle: _title(widget.pair.from.title),
      inTitle: _title(widget.pair.to.title),
      outBpm: hasUsableTempo(a.outgoing.analysis)
          ? a.outgoing.analysis.bpm
          : null,
      inBpm: hasUsableTempo(a.incoming.analysis)
          ? a.incoming.analysis.bpm
          : null,
    );
    String secText(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return _card(l10n.trLengthTitle, [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (var i = 0; i < options.length; i++)
            ChoiceChip(
              key: Key('tr_length_$i'),
              label: Text(
                options[i].bars != null
                    ? l10n.trLengthBars(options[i].bars!)
                    : l10n.trLengthSeconds(secText(options[i].seconds)),
              ),
              selected: i == sel,
              onSelected: (_) => _setLength(options[i].seconds),
            ),
        ],
      ),
      if (why != null) ...[
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: Colors.amberAccent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                why,
                key: const Key('tr_grid_reason'),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    ]);
  }

  Widget _curvesCard(AppLocalizations l10n, SongTransition d) {
    String kindLabel(TransitionCurveKind k) => switch (k) {
      TransitionCurveKind.volume => l10n.trCurveVolume,
      TransitionCurveKind.low => l10n.trCurveLow,
      TransitionCurveKind.mid => l10n.trCurveMid,
      TransitionCurveKind.high => l10n.trCurveHigh,
      TransitionCurveKind.filter => l10n.trCurveFilter,
      TransitionCurveKind.echo => l10n.trCurveEcho,
    };
    String? shapeId(TransitionLaneGroup g) => switch (g) {
      TransitionLaneGroup.volume => d.volumeShapeId,
      TransitionLaneGroup.eq => d.eqShapeId,
      TransitionLaneGroup.effect => d.effectShapeId,
    };
    Widget shapeMenu(TransitionLaneGroup g) {
      final id = shapeId(g);
      return PopupMenuButton<String>(
        key: Key('tr_shape_${g.name}'),
        tooltip: transitionShapeGroupTitle(l10n, g),
        onSelected: (v) => _set(applyLaneShape(g, v, d)),
        itemBuilder: (_) => [
          for (final s in transitionLaneShapes(g))
            PopupMenuItem<String>(
              key: Key('tr_shape_${g.name}_${s.id}'),
              value: s.id,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    transitionShapeName(l10n, g, s.id),
                    style: TextStyle(
                      fontWeight: id == s.id
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                  Text(
                    transitionShapeDescription(l10n, g, s.id),
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  transitionShapeGroupTitle(l10n, g),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              Text(
                id == null
                    ? l10n.trStateCustom
                    : transitionShapeName(l10n, g, id),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Icon(Icons.arrow_drop_down_rounded, color: Colors.white70),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 6, kScreenGutter, 6),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('tr_curves_tile'),
            title: Text(
              l10n.trCurvesTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            iconColor: Colors.white70,
            collapsedIconColor: Colors.white70,
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final g in TransitionLaneGroup.values) shapeMenu(g),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    key: const Key('tr_kind_none'),
                    label: Text(l10n.trCurveOnlyMove),
                    selected: _editKind == null,
                    onSelected: (_) => setState(() => _editKind = null),
                  ),
                  for (final k in TransitionCurveKind.values)
                    ChoiceChip(
                      key: Key('tr_kind_${k.name}'),
                      avatar: CircleAvatar(
                        radius: 6,
                        backgroundColor: transitionCurveColor(k),
                      ),
                      label: Text(kindLabel(k)),
                      selected: _editKind == k,
                      onSelected: (_) => setState(() => _editKind = k),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.trCurvesHint,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tempoCard(
    AppLocalizations l10n,
    TransitionPairAnalysis a,
    SongTransition d,
  ) {
    final s = a.suggestion;
    final can = s.beatGridTrusted;
    final on = d.tempoMatch == TransitionTempoMatch.matchIncoming;
    final pct = (kTransitionMaxTempoShift * 100).round();
    return _card(null, [
      SwitchListTile(
        key: const Key('tr_tempo_switch'),
        contentPadding: EdgeInsets.zero,
        title: Text(
          l10n.trTempoTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            can ? l10n.trTempoSub(pct) : l10n.trTempoUnavailable,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        value: can && on,
        onChanged: can ? _setTempo : null,
      ),
      if (can)
        Text(
          l10n.trTempoNow(
            bpmText(a.outgoing.analysis.bpm),
            bpmText(a.incoming.analysis.bpm),
          ),
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
    ]);
  }

  Widget _warningsCard(
    AppLocalizations l10n,
    TransitionPairAnalysis a,
    SongTransition d,
  ) {
    final problems = validateTransition(
      d,
      outDurationSec: _outDur,
      inDurationSec: _inDur,
      knownPresetIds: kTransitionPresets.map((p) => p.id),
    );
    if (problems.isEmpty) return const SizedBox.shrink();
    return _card(l10n.trWarningsTitle, [
      for (final p in problems)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Colors.amberAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  transitionProblemText(
                    l10n,
                    p,
                    outTitle: _title(widget.pair.from.title),
                    inTitle: _title(widget.pair.to.title),
                  ),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
    ], key: const Key('tr_warnings'));
  }

  Widget _bottomBar(BuildContext context, AppLocalizations l10n) {
    final playing = _loaded && (_tick?.playing ?? false) && _fresh;
    final stale = _clip != null && !_fresh;
    final label = playing
        ? l10n.trListenPause
        : (stale ? l10n.trListenAgain : l10n.trListen);
    final clip = _clip;
    final progress = clip != null && _loaded && _fresh && clip.info.clipSec > 0
        ? ((_tick?.position.inMilliseconds ?? 0) / 1000 / clip.info.clipSec)
              .clamp(0.0, 1.0)
              .toDouble()
        : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 10),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_rendering)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.trListenPreparing,
                      key: const Key('tr_rendering'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _renderCancel?.cancel(),
                    child: Text(AppLocalizations.of(context)!.commonCancel),
                  ),
                ],
              ),
            )
          else if (stale)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                l10n.trListenChanged,
                key: const Key('tr_stale'),
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            )
          else if (progress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: progress, minHeight: 3),
            ),
          Row(
            children: [
              FilledButton.tonalIcon(
                key: const Key('tr_listen'),
                onPressed: _rendering ? null : _listen,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(label),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        key: const Key('tr_loop_switch'),
                        value: _loop,
                        onChanged: (v) {
                          setState(() => _loop = v);
                          unawaited(_loopCtl?.setEnabled(v));
                        },
                      ),
                      Text(
                        l10n.trListenLoop,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              FilledButton(
                key: const Key('tr_save'),
                onPressed: _dirty && !_busy ? _save : null,
                child: Text(l10n.trSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
