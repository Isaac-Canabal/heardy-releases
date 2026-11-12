import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/heardy_mixer_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/mix/mix_edit_ops.dart';
import '../services/mix/mix_edit_plan.dart';
import '../services/mix/mix_types.dart';
import '../services/mix/mixer_labels.dart';
import '../services/mix/mixer_logic.dart' show MixerErrorKind;
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mix_editor_blocks.dart';
import '../widgets/mix_editor_controls.dart';
import '../widgets/mix_waveform_painter.dart';
import 'heardy_mixer_result_screen.dart';
import 'heardy_mixer_screen.dart'
    show MixerProgressPanel, MixerWarningsCard, mixerErrorText, mixerStageLabel, mixerStyleName;

/// Retocar el mix a mano: se ve como bloques de color con el título de cada
/// canción, se escucha sin salir, y los bloques se arrastran, se acortan, se
/// quitan o cambian de volumen. El estado vive en [HeardyMixerProvider]; esta
/// pantalla solo guarda lo de la vista (bloque elegido, punto marcado, trozo
/// marcado en cada canción) y la escucha.
class HeardyMixerEditorScreen extends StatefulWidget {
  const HeardyMixerEditorScreen({super.key, this.analyzeOnOpen = true, this.previewPlayer});

  /// Lanza el análisis al abrir si aún no hay uno (al volver a un editor ya analizado no hace falta).
  final bool analyzeOnOpen;

  /// Reproductor de la escucha; por defecto el de la app ([HandlerMixPreviewPlayer]).
  final MixPreviewPlayer? previewPlayer;

  static Route<void> route({bool analyze = true}) =>
      MaterialPageRoute<void>(builder: (_) => HeardyMixerEditorScreen(analyzeOnOpen: analyze));

  @override
  State<HeardyMixerEditorScreen> createState() => _HeardyMixerEditorScreenState();
}

class _HeardyMixerEditorScreenState extends State<HeardyMixerEditorScreen> {
  late final HeardyMixerProvider _mixer;
  MixerPhase? _lastPhase;
  MixLayer _layer = MixLayer.mix;
  ({int start, int end})? _selA, _selB;
  int _selected = -1;
  int? _cursor;

  MixPreviewPlayer? _player;
  bool _ownsPlayer = false;
  StreamSubscription<MixPreviewTick>? _ticks;
  MixPreviewTick? _tick;

  @override
  void initState() {
    super.initState();
    _mixer = context.read<HeardyMixerProvider>();
    _lastPhase = _mixer.phase;
    _mixer.addListener(_onMixerChanged);
    if (widget.analyzeOnOpen && !_mixer.hasAnalysis) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_mixer.hasAnalysis && _mixer.canAnalyze) _mixer.analyze();
      });
    }
  }

  @override
  void dispose() {
    _mixer.removeListener(_onMixerChanged);
    _mixer.discardPreview(notify: false);
    _ticks?.cancel();
    if (_ownsPlayer) _player?.dispose();
    super.dispose();
  }

  void _onMixerChanged() {
    final phase = _mixer.phase;
    final finished = _lastPhase != MixerPhase.succeeded && phase == MixerPhase.succeeded && _mixer.lastFromEditor;
    _lastPhase = phase;
    if (finished && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _openResult();
  }

  void _openResult() {
    final r = _mixer.lastRecord;
    if (r == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HeardyMixerResultScreen(record: r)));
  }

  // ---- Escuchar ----

  MixPreviewPlayer? _ensurePlayer() {
    if (_player != null) return _player;
    try {
      _player = widget.previewPlayer ?? HandlerMixPreviewPlayer(context.read<AudioPlayerHandler>());
      _ownsPlayer = widget.previewPlayer == null;
      _ticks = _player!.ticks.listen((t) {
        if (mounted) setState(() => _tick = t);
      });
    } catch (e) {
      print('Mix: no hay reproductor para escuchar en el editor (${e.runtimeType})');
    }
    return _player;
  }

  /// Lo que suena ahora mismo es la última escucha del editor.
  bool get _loaded {
    final r = _mixer.previewRecord;
    return r != null && _tick?.mediaId == mixPreviewMediaId(r);
  }

  Future<void> _playPreview() async {
    final r = _mixer.previewRecord, player = _ensurePlayer();
    if (r == null) return;
    try {
      if (player == null) throw StateError('sin reproductor');
      await player.play(r);
    } catch (e) {
      print('Mix: no se pudo escuchar el mix (${e.runtimeType})');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.mixerResultPlayFailed)));
      }
    }
  }

  Future<void> _listen() async {
    if (_mixer.previewStatus != MixPreviewStatus.fresh) {
      if (_loaded && (_tick?.playing ?? false)) unawaited(_player?.pause());
      await _mixer.preview();
      if (!mounted || _mixer.previewStatus != MixPreviewStatus.fresh) return;
      await _playPreview();
    } else if (!_loaded) {
      await _playPreview();
    } else if (_tick?.playing ?? false) {
      await _player?.pause();
    } else {
      await _player?.resume();
    }
  }

  // ---- Editar ----

  void _apply(MixEditPlan plan) => _mixer.updatePlan(plan);

  void _live(MixEditPlan plan) => _mixer.updatePlan(plan, coalesce: true);

  void _undo() {
    _mixer.undo();
    final count = _mixer.editPlan?.segments.length ?? 0;
    if (_selected >= count) setState(() => _selected = -1);
  }

  void _reset() {
    final auto = _mixer.editAnalysis?.auto.plan;
    if (auto == null) return;
    setState(() {
      _selected = -1;
      _cursor = null;
      _selA = _selB = null;
    });
    _mixer.updatePlan(auto);
  }

  void _changeBase(String song) {
    setState(() => _selected = -1);
    _mixer.changeBase(song);
  }

  MixEditBounds _bounds(MixEditPlan plan) {
    final an = _mixer.editAnalysis!.auto;
    return MixEditBounds.of(plan, barsA: an.summaryA.planBars, barsB: an.summaryB.planBars);
  }

  void _tapLane(MixEditPlan plan, int bar, int index) {
    setState(() {
      _cursor = bar;
      _selected = index >= 0 ? index : segmentAtBar(plan, bar);
    });
    if (_mixer.previewStatus == MixPreviewStatus.fresh && _loaded) {
      unawaited(_player?.seek(positionForBar(bar, plan.tempoBpm)));
    }
  }

  MixFragmentDrag? _fragment(String song) {
    final sel = song == 'a' ? _selA : _selB;
    return sel == null ? null : MixFragmentDrag(song: song, layer: _layer, fromBar: sel.start, bars: sel.end - sel.start);
  }

  /// Pone el trozo [f] en la línea [atBar] del mix y lo deja elegido.
  void _addFragment(MixFragmentDrag f, int atBar) {
    final plan = _mixer.editPlan;
    if (plan == null) return;
    final next = addFragment(plan,
        song: f.song, layer: f.layer, fromBar: f.fromBar, bars: f.bars, atBar: atBar, b: _bounds(plan));
    if (identical(next, plan)) return;
    _apply(next);
    setState(() => _selected = next.segments.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m = context.watch<HeardyMixerProvider>();
    final Widget content;
    if (m.phase == MixerPhase.running && !m.previewing) {
      content = ListView(padding: const EdgeInsets.all(kScreenGutter), children: [MixerProgressPanel(mixer: m)]);
    } else if (!m.hasAnalysis) {
      content = _noAnalysis(context, m);
    } else if (m.phase == MixerPhase.succeeded && m.lastFromEditor) {
      content = _rendered(context, m);
    } else {
      content = _editor(context, m);
    }
    final canEdit = m.hasAnalysis && m.phase != MixerPhase.running;
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
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(l10n.editorTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                    ),
                    if (canEdit)
                      TextButton.icon(
                        key: const Key('editor_undo'),
                        onPressed: m.canUndo ? _undo : null,
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: Text(l10n.editorUndo),
                      ),
                  ]),
                ),
                Expanded(child: content),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _noAnalysis(BuildContext context, HeardyMixerProvider m) {
    final l10n = AppLocalizations.of(context)!;
    final error = m.error;
    if (!m.editorAvailable) return _Message(l10n.editorUnavailable);
    return ListView(padding: const EdgeInsets.all(kScreenGutter), children: [
      if (error != null) ...[
        Text(mixerErrorText(l10n, error),
            key: const Key('editor_error'),
            style: TextStyle(color: error == MixerErrorKind.cancelled ? Colors.white70 : Colors.orangeAccent.shade100)),
        const SizedBox(height: 12),
      ],
      AppTheme.gradientButton(
        onPressed: m.canAnalyze ? m.analyze : null,
        child: Text(l10n.mixerRetry,
            key: const Key('editor_retry'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    ]);
  }

  Map<String, String> _titles(HeardyMixerProvider m) {
    final auto = m.editAnalysis!.auto;
    return {
      'a': m.slot(MixerSlotId.a)?.title ?? auto.summaryA.name,
      'b': m.slot(MixerSlotId.b)?.title ?? auto.summaryB.name,
    };
  }

  Widget _rendered(BuildContext context, HeardyMixerProvider m) {
    final l10n = AppLocalizations.of(context)!;
    final plan = m.editPlan!;
    final bounds = _bounds(plan);
    final titles = _titles(m);
    return ListView(padding: const EdgeInsets.all(kScreenGutter), children: [
      _SectionTitle(l10n.editorResultLaneRendered),
      MixResultLane(
        key: const Key('editor_result_lane'),
        segments: plan.segments,
        totalBars: bounds.timelineBars,
        envelope: m.outputEnvelope,
        labels: [for (final s in plan.segments) mixBlockLabel(l10n, s, titles)],
        onTapBar: (_) {},
      ),
      const SizedBox(height: 16),
      AppTheme.gradientButton(
        onPressed: _openResult,
        child: Text(l10n.editorViewResult,
            key: const Key('editor_view_result'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      TextButton(key: const Key('editor_back_to_editing'), onPressed: m.backToEditing, child: Text(l10n.editorBackToEditor)),
    ]);
  }

  Widget _listenPanel(AppLocalizations l10n, HeardyMixerProvider m) {
    final status = m.previewStatus;
    if (status == MixPreviewStatus.preparing) {
      final stage = m.stage;
      return Container(
        key: const Key('editor_listen_preparing'),
        decoration: AppTheme.glassCard(highlighted: true),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.editorListenPreparing, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          if (stage != null) Text(mixerStageLabel(l10n, stage), style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: m.fraction),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(key: const Key('editor_listen_cancel'), onPressed: m.cancel, child: Text(l10n.mixerCancel)),
          ),
        ]),
      );
    }
    final playing = _loaded && (_tick?.playing ?? false);
    final fresh = status == MixPreviewStatus.fresh;
    final label = switch (status) {
      MixPreviewStatus.stale => l10n.editorListenAgain,
      MixPreviewStatus.fresh when playing => l10n.editorPause,
      MixPreviewStatus.fresh when _loaded && (_tick?.position ?? Duration.zero) > Duration.zero => l10n.editorResume,
      _ => l10n.editorListen,
    };
    final note = switch (status) {
      MixPreviewStatus.stale => l10n.editorListenStale,
      MixPreviewStatus.fresh => l10n.editorListenFresh,
      _ => l10n.editorListenNone,
    };
    final record = m.previewRecord;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppTheme.gradientButton(
        onPressed: m.canStart ? _listen : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(fresh && playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, key: const Key('editor_listen'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
      ),
      const SizedBox(height: 6),
      Text(note,
          key: const Key('editor_listen_status'),
          style: TextStyle(
              color: status == MixPreviewStatus.stale ? Colors.orangeAccent.shade100 : Colors.white70, fontSize: 13)),
      if (fresh && _loaded && record != null)
        Text(
            l10n.editorListenPosition(clockText((_tick?.position.inMilliseconds ?? 0) / 1000), clockText(record.durationMs / 1000)),
            key: const Key('editor_listen_position'),
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
    ]);
  }

  Widget _editor(BuildContext context, HeardyMixerProvider m) {
    final l10n = AppLocalizations.of(context)!;
    final plan = m.editPlan!;
    final envs = m.editEnvelopes!;
    final bounds = _bounds(plan);
    final error = m.error;
    final problems = m.editProblems;
    final style = plan.template ?? m.editSelection?.requested;
    final selected = _selected < plan.segments.length ? _selected : -1;
    final titles = _titles(m);
    final tempo = plan.tempoBpm;
    final fresh = m.previewStatus == MixPreviewStatus.fresh;
    const hint = TextStyle(color: Colors.white60, fontSize: 12);

    // Mientras se prepara la escucha no se puede editar: se ve, pero apagado.
    Widget lock(Widget w, {Key? key}) =>
        IgnorePointer(key: key, ignoring: m.previewing, child: Opacity(opacity: m.previewing ? 0.45 : 1, child: w));

    Widget songLane(String song) {
      final env = envs.forSong(song);
      final sel = song == 'a' ? _selA : _selB;
      final title = shortSongTitle(titles[song]!, fallback: song.toUpperCase());
      final fragment = _fragment(song);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l10n.editorSongLane(title),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: mixSongColor(song), fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        MixWaveformLane(
          key: Key('editor_lane_$song'),
          points: env.layer(_layer),
          totalBars: env.bars,
          color: mixSongColor(song),
          selection: sel,
          onSelect: (s, e) => setState(() {
            if (song == 'a') {
              _selA = (start: s, end: e);
            } else {
              _selB = (start: s, end: e);
            }
          }),
        ),
        if (sel != null && fragment != null) ...[
          const SizedBox(height: 4),
          Text(l10n.editorSelectionBars(barTime(sel.start, tempo), barTime(sel.end, tempo), title),
              key: Key('editor_selection_$song'), style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Draggable<MixFragmentDrag>(
              key: Key('editor_drag_$song'),
              data: fragment,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: Material(
                color: Colors.transparent,
                child: _DragChip(color: mixSongColor(song), text: mixLayerLabel(l10n, _layer), lifted: true),
              ),
              child: _DragChip(color: mixSongColor(song), text: l10n.editorDragChip),
            ),
            FilledButton.tonal(
              key: Key('editor_add_$song'),
              onPressed: () => _addFragment(fragment, _cursor ?? nextFragmentBar(plan, selected)),
              child: Text(l10n.editorAddFragment),
            ),
          ]),
        ],
      ]);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 24),
      children: [
        Container(
          key: const Key('editor_guide'),
          decoration: AppTheme.glassCard(),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.editorGuideTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            for (final step in [l10n.editorGuide1, l10n.editorGuide2, l10n.editorGuide3])
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(step, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        if (error != null) ...[
          Text(mixerErrorText(l10n, error),
              key: const Key('editor_error'),
              style: TextStyle(color: error == MixerErrorKind.cancelled ? Colors.white70 : Colors.orangeAccent.shade100)),
          const SizedBox(height: 12),
        ],
        if (m.editWarnings.isNotEmpty) ...[
          MixerWarningsCard(
              warnings: m.editWarnings, titleA: shortSongTitle(titles['a']!), titleB: shortSongTitle(titles['b']!)),
          const SizedBox(height: 12),
        ],
        if (problems.isNotEmpty) ...[
          Container(
            key: const Key('editor_problems'),
            decoration: AppTheme.glassCard(),
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.editorProblemsTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              for (final p in problems) ...[
                const SizedBox(height: 6),
                Text(mixEditProblemText(l10n, p, plan: plan, titles: titles),
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
        ],
        _SectionTitle(l10n.editorResultLane),
        MixEditorLegend(titles: titles),
        const SizedBox(height: 6),
        MixBlocksLane(
          key: const Key('editor_result_lane'),
          segments: plan.segments,
          totalBars: bounds.timelineBars,
          labels: [for (final s in plan.segments) mixBlockLabel(l10n, s, titles)],
          selectedIndex: selected,
          cursorBar: _cursor,
          playheadBar: fresh && _loaded ? playheadBar(_tick!.position.inMilliseconds, tempo) : null,
          onTap: (bar, index) => _tapLane(plan, bar, index),
          onDragStart: (i) => setState(() => _selected = i),
          onMove: (i, bar) => _live(moveSegmentTo(_mixer.editPlan!, i, bar, bounds)),
          onResizeStart: (i, bar) => _live(resizeSegmentStart(_mixer.editPlan!, i, bar, bounds)),
          onResizeEnd: (i, bar) => _live(resizeSegmentEnd(_mixer.editPlan!, i, bar, bounds)),
          onDragEnd: _mixer.endCoalescing,
          onDropFragment: _addFragment,
        ),
        const SizedBox(height: 4),
        if (plan.segments.isEmpty)
          Text(l10n.editorNoSegments, style: hint.copyWith(fontSize: 13))
        else
          Text(l10n.editorLaneHint, style: hint),
        if (_cursor != null)
          Text(l10n.editorCursorAt(barTime(_cursor!, tempo)), key: const Key('editor_cursor'), style: hint),
        const SizedBox(height: 12),
        _listenPanel(l10n, m),
        const SizedBox(height: 16),
        lock(MixSegmentControls(
          key: const Key('editor_segment_controls'),
          plan: plan,
          index: selected,
          bounds: bounds,
          cursorBar: _cursor,
          titles: titles,
          onPlan: _apply,
          onLivePlan: _live,
          onLiveEnd: _mixer.endCoalescing,
          onDeleted: () => setState(() => _selected = -1),
        )),
        const SizedBox(height: 12),
        lock(key: const Key('editor_add_section_lock'), _Section(
          key: const Key('editor_add_section'),
          title: l10n.editorAddSection,
          children: [
            Text(l10n.editorAddHint, style: hint),
            const SizedBox(height: 8),
            Text(l10n.editorAddWhat, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            Wrap(spacing: 8, children: [
              for (final layer in MixLayer.values)
                ChoiceChip(
                  key: Key('editor_view_${layer.name}'),
                  label: Text(mixLayerLabel(l10n, layer)),
                  selected: _layer == layer,
                  onSelected: (_) => setState(() => _layer = layer),
                ),
            ]),
            const SizedBox(height: 8),
            songLane('a'),
            const SizedBox(height: 12),
            songLane('b'),
          ],
        )),
        const SizedBox(height: 12),
        lock(key: const Key('editor_more_lock'), _Section(
          key: const Key('editor_more'),
          title: l10n.editorMore,
          children: [
            if (style != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(l10n.mixerResultStyleUsed(mixerStyleName(l10n, style)),
                    key: const Key('editor_style'), style: const TextStyle(color: Colors.white70)),
              ),
            MixBlockAdvancedControls(plan: plan, index: selected, bounds: bounds, titles: titles, onPlan: _apply),
            if (selected >= 0) const SizedBox(height: 12),
            MixPitchControls(plan: plan, titles: titles, onPlan: _apply),
            const SizedBox(height: 12),
            Text(l10n.editorBaseSong, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            Text(l10n.editorBaseSongHint, style: hint),
            Wrap(spacing: 8, children: [
              for (final song in const ['a', 'b'])
                ChoiceChip(
                  key: Key('editor_base_$song'),
                  label: Text(l10n.editorSongLane(shortSongTitle(titles[song]!, fallback: song.toUpperCase()))),
                  selected: plan.baseSong == song,
                  onSelected: (_) => _changeBase(song),
                ),
            ]),
            const SizedBox(height: 12),
            Text(l10n.editorAllBlocks, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            for (var i = 0; i < plan.segments.length; i++)
              ListTile(
                key: Key('editor_segment_$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: i == selected,
                selectedTileColor: Colors.white12,
                onTap: () => setState(() => _selected = i),
                leading: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: mixSongColor(plan.segments[i].song), shape: BoxShape.circle)),
                title: Text(
                  '${mixBlockSentence(l10n, plan.segments[i], titles)} · ${mixBlockWhen(l10n, plan.segments[i], tempo)}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
          ],
        )),
        const SizedBox(height: 20),
        lock(AppTheme.gradientButton(
          onPressed: m.canStart
              ? () {
                  unawaited(() async {
                    if (!await m.keepPreviewAsMix()) await m.render(plan);
                  }());
                }
              : null,
          child: Text(l10n.editorRender,
              key: const Key('editor_render'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        )),
        lock(TextButton(key: const Key('editor_reset'), onPressed: _reset, child: Text(l10n.editorReset))),
      ],
    );
  }
}

/// Sección plegada del editor (lo que no hace falta ver al entrar).
class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: AppTheme.glassCard(),
        child: Material(
          type: MaterialType.transparency,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              iconColor: Colors.white,
              collapsedIconColor: Colors.white70,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              children: children,
            ),
          ),
        ),
      );
}

class _DragChip extends StatelessWidget {
  const _DragChip({required this.color, required this.text, this.lifted = false});
  final Color color;
  final String text;
  final bool lifted;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: lifted ? 0.9 : 0.35),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.drag_indicator_rounded, size: 18, color: Colors.white),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(kScreenGutter),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
        ),
      );
}
