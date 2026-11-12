// Controles del editor de Heardy Mixer, en lenguaje llano: lo que se hace con el
// bloque elegido, el tono de cada canción y las opciones menos usadas. Solo
// llaman a las operaciones puras de `mix_edit_ops.dart` y devuelven el plan
// nuevo; no tienen estado propio.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/mix/mix_edit_ops.dart';
import '../services/mix/mix_edit_plan.dart';
import '../services/mix/mix_types.dart';
import '../services/mix/mixer_labels.dart';
import '../theme/app_theme.dart';
import 'mix_editor_blocks.dart';
import 'mix_waveform_painter.dart';

String mixLayerLabel(AppLocalizations l10n, MixLayer layer) => switch (layer) {
      MixLayer.mix => l10n.editorLayerMix,
      MixLayer.vocals => l10n.editorLayerVocals,
      MixLayer.instrumental => l10n.editorLayerInstrumental,
    };

/// Frase llana de un problema del plan. Con [plan] y [titles] dice de qué
/// bloque habla por su contenido ("Voz de «Thunder» (0:10)"), no por un número.
String mixEditProblemText(AppLocalizations l10n, MixPlanProblem p, {MixEditPlan? plan, Map<String, String> titles = const {}}) {
  final text = switch (p.kind) {
    MixPlanProblemKind.emptyPlan => l10n.editorProblemEmpty,
    MixPlanProblemKind.pitchOutOfRange => l10n.editorProblemPitch,
    MixPlanProblemKind.unknownSong ||
    MixPlanProblemKind.invalidTempo ||
    MixPlanProblemKind.invalidBars ||
    MixPlanProblemKind.invalidValue =>
      l10n.editorProblemInvalid,
    MixPlanProblemKind.emptySegment => l10n.editorProblemEmptySegment,
    MixPlanProblemKind.segmentOutsideSource => l10n.editorProblemOutsideSource,
    MixPlanProblemKind.segmentOutsideTimeline => l10n.editorProblemOutsideTimeline,
    MixPlanProblemKind.overlappingVocals => l10n.editorProblemOverlapVocals,
    MixPlanProblemKind.overlappingBody => l10n.editorProblemOverlapBody,
    MixPlanProblemKind.vocalWithoutInstrumental => l10n.editorProblemVocalBare,
  };
  final i = p.segmentIndex;
  if (plan == null || i < 0 || i >= plan.segments.length) return text;
  final s = plan.segments[i];
  return l10n.editorProblemAt('${mixBlockSentence(l10n, s, titles)} (${barTime(s.outBar, plan.tempoBpm)})', text);
}

/// Cuánto se cambió el tono, con palabras ("sin cambios", "2 más agudo").
String mixPitchText(AppLocalizations l10n, int v) => v == 0
    ? l10n.editorPitchNormal
    : v > 0
        ? l10n.editorPitchHigherBy('$v')
        : l10n.editorPitchLowerBy('${-v}');

/// Volumen con signo para el texto pequeño ("+3.0").
String signedDb(double db) => '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)}';

const _hint = TextStyle(color: Colors.white60, fontSize: 12);

/// El tono de cada canción, de −12 a +12, nombrada por su título.
class MixPitchControls extends StatelessWidget {
  const MixPitchControls({super.key, required this.plan, required this.onPlan, this.titles = const {}});
  final MixEditPlan plan;
  final Map<String, String> titles;
  final void Function(MixEditPlan plan) onPlan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget row(String song) {
      final v = plan.semitonesOf(song);
      final title = shortSongTitle(titles[song] ?? '', fallback: song.toUpperCase());
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l10n.editorPitchValue(title, mixPitchText(l10n, v)),
            key: Key('editor_pitch_${song}_value'), style: TextStyle(color: mixSongColor(song))),
        Wrap(spacing: 8, children: [
          OutlinedButton(
            key: Key('editor_pitch_${song}_down'),
            onPressed: v <= -kMixMaxSemitones ? null : () => onPlan(setSemitones(plan, song, v - 1)),
            child: Text(l10n.editorPitchDown),
          ),
          OutlinedButton(
            key: Key('editor_pitch_${song}_up'),
            onPressed: v >= kMixMaxSemitones ? null : () => onPlan(setSemitones(plan, song, v + 1)),
            child: Text(l10n.editorPitchUp),
          ),
        ]),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l10n.editorPitchTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      row('a'),
      const SizedBox(height: 8),
      row('b'),
    ]);
  }
}

/// Lo que se hace con el bloque [index]: moverlo, quitarlo, duplicarlo,
/// dividirlo en [cursorBar] y cambiar su volumen.
class MixSegmentControls extends StatelessWidget {
  const MixSegmentControls({
    super.key,
    required this.plan,
    required this.index,
    required this.bounds,
    required this.cursorBar,
    required this.onPlan,
    required this.onDeleted,
    this.titles = const {},
    this.onLivePlan,
    this.onLiveEnd,
  });

  final MixEditPlan plan;
  final int index;
  final MixEditBounds bounds;
  final int? cursorBar;
  final Map<String, String> titles;
  final void Function(MixEditPlan plan) onPlan;

  /// Tras quitar el bloque, para que la pantalla suelte la selección.
  final VoidCallback onDeleted;

  /// Cambios continuos del deslizador de volumen; sin él se usa [onPlan].
  final void Function(MixEditPlan plan)? onLivePlan;

  /// El usuario soltó el deslizador (cierra el paso de deshacer del arrastre).
  final VoidCallback? onLiveEnd;

  /// Compases que mueve cada botón grande y cada botón pequeño.
  static const bigStep = 4, smallStep = 1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (index < 0 || index >= plan.segments.length) {
      return Text(l10n.editorSelectSegmentHint, key: const Key('editor_select_hint'), style: _hint.copyWith(fontSize: 13));
    }
    final s = plan.segments[index];
    final canSplit = cursorBar != null && cursorBar! > s.outBar && cursorBar! < s.endBar;

    Widget big(String keyTag, int delta, String label) => Expanded(
          child: FilledButton.tonal(
            key: Key('editor_move_$keyTag'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => onPlan(moveSegment(plan, index, delta, bounds)),
            child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        );
    Widget small(String keyTag, int delta, String label) => TextButton(
          key: Key('editor_move_$keyTag'),
          onPressed: () => onPlan(moveSegment(plan, index, delta, bounds)),
          child: Text(label),
        );

    return Container(
      decoration: AppTheme.glassCard(highlighted: true),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: mixSongColor(s.song), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(mixBlockSentence(l10n, s, titles),
                key: const Key('editor_block_title'),
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
        Text(mixBlockWhen(l10n, s, plan.tempoBpm), key: const Key('editor_block_when'), style: _hint.copyWith(fontSize: 13)),
        const SizedBox(height: 10),
        Row(children: [
          big('back_$bigStep', -bigStep, l10n.editorMoveEarlier),
          const SizedBox(width: 8),
          big('fwd_$bigStep', bigStep, l10n.editorMoveLater),
        ]),
        Wrap(spacing: 8, children: [
          small('back_$smallStep', -smallStep, l10n.editorMoveSmallEarlier),
          small('fwd_$smallStep', smallStep, l10n.editorMoveSmallLater),
        ]),
        Text(l10n.editorMoveHint(moveStepSeconds(bigStep, plan.tempoBpm).round().toString()), style: _hint),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            key: const Key('editor_delete'),
            onPressed: () {
              onPlan(deleteSegment(plan, index));
              onDeleted();
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(l10n.editorDelete),
          ),
          OutlinedButton.icon(
            key: const Key('editor_duplicate'),
            onPressed: () => onPlan(duplicateSegment(plan, index, bounds)),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(l10n.editorDuplicate),
          ),
          OutlinedButton.icon(
            key: const Key('editor_split'),
            onPressed: canSplit ? () => onPlan(splitSegment(plan, index, cursorBar!)) : null,
            icon: const Icon(Icons.content_cut_rounded, size: 18),
            label: Text(l10n.editorSplit),
          ),
        ]),
        if (!canSplit) Padding(padding: const EdgeInsets.only(top: 4), child: Text(l10n.editorSplitHint, style: _hint)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text(l10n.editorGain, style: const TextStyle(color: Colors.white))),
          Text(l10n.editorGainDb(signedDb(s.gainDb)), key: const Key('editor_gain_db'), style: _hint.copyWith(fontSize: 11)),
        ]),
        Row(children: [
          Text(l10n.editorGainLower, style: _hint),
          Expanded(
            child: Slider(
              key: const Key('editor_gain'),
              min: kEditMinGainDb,
              max: kEditMaxGainDb,
              divisions: ((kEditMaxGainDb - kEditMinGainDb) * 2).round(),
              value: s.gainDb.clamp(kEditMinGainDb, kEditMaxGainDb).toDouble(),
              onChanged: (v) => (onLivePlan ?? onPlan)(setSegmentGain(plan, index, v)),
              onChangeEnd: (_) => onLiveEnd?.call(),
            ),
          ),
          Text(l10n.editorGainHigher, style: _hint),
        ]),
      ]),
    );
  }
}

/// Opciones poco usadas del bloque [index]: qué suena en él, de qué canción es
/// y volver a unirlo con el siguiente. No ocupa sitio sin bloque elegido.
class MixBlockAdvancedControls extends StatelessWidget {
  const MixBlockAdvancedControls({
    super.key,
    required this.plan,
    required this.index,
    required this.bounds,
    required this.onPlan,
    this.titles = const {},
  });

  final MixEditPlan plan;
  final int index;
  final MixEditBounds bounds;
  final Map<String, String> titles;
  final void Function(MixEditPlan plan) onPlan;

  @override
  Widget build(BuildContext context) {
    if (index < 0 || index >= plan.segments.length) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final s = plan.segments[index];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l10n.editorSegmentLayer, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final layer in MixLayer.values)
          ChoiceChip(
            key: Key('editor_layer_${layer.name}'),
            label: Text(mixLayerLabel(l10n, layer)),
            selected: s.layer == layer,
            onSelected: (_) => onPlan(setSegmentLayer(plan, index, layer)),
          ),
      ]),
      const SizedBox(height: 8),
      Text(l10n.editorSegmentSong, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final song in const ['a', 'b'])
          ChoiceChip(
            key: Key('editor_song_$song'),
            label: Text(l10n.editorSongLane(shortSongTitle(titles[song] ?? '', fallback: song.toUpperCase()))),
            selected: s.song == song,
            selectedColor: mixSongColor(song).withValues(alpha: 0.5),
            backgroundColor: AppTheme.surface,
            onSelected: (_) => onPlan(setSegmentSong(plan, index, song, bounds)),
          ),
      ]),
      if (mergeCandidate(plan, index) >= 0)
        TextButton(
          key: const Key('editor_merge'),
          onPressed: () => onPlan(mergeSegment(plan, index)),
          child: Text(l10n.editorMerge),
        ),
    ]);
  }
}
