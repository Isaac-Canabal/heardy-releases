// Textos en lenguaje llano del editor de transiciones. El motor trae nombres y
// descripciones en inglés como marcador; aquí cada estilo y cada forma se
// traduce por su id estable (si aparece un id nuevo, se usa el del motor).
import '../../l10n/app_localizations.dart';
import '../../providers/playlist_transitions_provider.dart';
import '../mix/mix_analysis.dart' show SongAnalysis;
import 'platform/transition_job_runner.dart' show TransitionErrorKind;
import 'transition_analysis.dart' show hasUsableTempo;
import 'transition_model.dart';
import 'transition_presets.dart';
import 'transition_suggest.dart' show TransitionGridIssue;

String transitionPresetName(AppLocalizations l, String id) =>
    _presetName(l, id) ?? transitionPresetById(id)?.name ?? id;

String transitionPresetDescription(AppLocalizations l, String id) =>
    _presetDesc(l, id) ?? transitionPresetById(id)?.description ?? '';

String transitionShapeName(
  AppLocalizations l,
  TransitionLaneGroup g,
  String id,
) =>
    switch (g) {
      TransitionLaneGroup.volume => _volumeName(l, id),
      TransitionLaneGroup.eq => _eqName(l, id),
      TransitionLaneGroup.effect => _effectName(l, id),
    } ??
    transitionLaneShapeById(g, id)?.name ??
    id;

String transitionShapeDescription(
  AppLocalizations l,
  TransitionLaneGroup g,
  String id,
) =>
    switch (g) {
      TransitionLaneGroup.volume => _volumeDesc(l, id),
      TransitionLaneGroup.eq => _eqDesc(l, id),
      TransitionLaneGroup.effect => _effectDesc(l, id),
    } ??
    transitionLaneShapeById(g, id)?.description ??
    '';

String transitionShapeGroupTitle(AppLocalizations l, TransitionLaneGroup g) =>
    switch (g) {
      TransitionLaneGroup.volume => l.trShapeVolumeTitle,
      TransitionLaneGroup.eq => l.trShapeEqTitle,
      TransitionLaneGroup.effect => l.trShapeEffectTitle,
    };

/// En qué estado se ve un par en la lista.
enum PairStateKind { unavailable, none, disabled, auto, custom }

PairStateKind pairStateKindOf(PairTransitionView v) {
  if (!v.pair.eligible) return PairStateKind.unavailable;
  if (v.transition == null) return PairStateKind.none;
  if (v.disabled) return PairStateKind.disabled;
  return v.isCustom ? PairStateKind.custom : PairStateKind.auto;
}

String pairStateText(AppLocalizations l, PairStateKind k) => switch (k) {
  PairStateKind.unavailable => l.trStateUnavailable,
  PairStateKind.none => l.trStateNone,
  PairStateKind.disabled => l.trStateDisabled,
  PairStateKind.auto => l.trStateAuto,
  PairStateKind.custom => l.trStateCustom,
};

/// "Automática · Cambio de graves"; el estilo sólo si lo hay (una transición a mano lo pierde).
String pairChipText(AppLocalizations l, PairTransitionView v) {
  final kind = pairStateKindOf(v);
  final state = pairStateText(l, kind);
  final id = v.transition?.presetId;
  if (kind == PairStateKind.unavailable ||
      kind == PairStateKind.none ||
      kind == PairStateKind.disabled ||
      id == null)
    return state;
  return l.trPairChip(state, transitionPresetName(l, id));
}

String bpmText(double bpm) => bpm.round().toString();

/// "124 BPM · 8B", o que no se detectó el ritmo; `null` si no hay análisis todavía.
String? songInfoText(AppLocalizations l, SongAnalysis? a) {
  if (a == null) return null;
  if (!hasUsableTempo(a)) return l.trSongRhythmUnknown;
  return a.keyScore > 0
      ? l.trSongInfo(bpmText(a.bpm), a.camelot)
      : l.trSongBpmOnly(bpmText(a.bpm));
}

String transitionErrorText(AppLocalizations l, TransitionErrorKind k) =>
    switch (k) {
      TransitionErrorKind.missingFile => l.trErrMissing,
      TransitionErrorKind.decoderFailed => l.trErrDecoder,
      TransitionErrorKind.analysisFailed => l.trErrAnalysis,
      TransitionErrorKind.renderFailed => l.trErrRender,
      TransitionErrorKind.cancelled => l.trErrCancelled,
    };

/// Por qué no se ofrecen compases; `null` cuando sí se ofrecen.
String? gridIssueText(
  AppLocalizations l,
  TransitionGridIssue issue, {
  required String outTitle,
  required String inTitle,
  double? outBpm,
  double? inBpm,
}) => switch (issue) {
  TransitionGridIssue.none => null,
  TransitionGridIssue.outgoingGridUnknown => l.trGridOutgoingUnknown(outTitle),
  TransitionGridIssue.incomingGridUnknown => l.trGridIncomingUnknown(inTitle),
  TransitionGridIssue.tempoTooFar => l.trGridTempoFar(
    outBpm == null ? '?' : bpmText(outBpm),
    inBpm == null ? '?' : bpmText(inBpm),
  ),
};

/// Aviso de [p] en español llano (nunca el texto en inglés del motor).
String transitionProblemText(
  AppLocalizations l,
  TransitionProblem p, {
  required String outTitle,
  required String inTitle,
}) => switch (p.kind) {
  TransitionProblemKind.invalidNumber => l.trWarnInvalidNumber,
  TransitionProblemKind.negativeStart => l.trWarnNegativeStart,
  TransitionProblemKind.lengthOutOfRange => l.trWarnLengthRange,
  TransitionProblemKind.overlapBeyondOutgoing => l.trWarnOverlapOut(outTitle),
  TransitionProblemKind.overlapBeyondIncoming => l.trWarnOverlapIn(inTitle),
  TransitionProblemKind.valueOutOfRange => l.trWarnValueRange,
  TransitionProblemKind.unknownPreset => l.trWarnUnknownPreset,
  TransitionProblemKind.unsupportedVersion => l.trWarnVersion,
  TransitionProblemKind.outgoingAlteredAtStart => l.trWarnOutAltered(outTitle),
  TransitionProblemKind.outgoingAudibleAtEnd => l.trWarnOutAudibleEnd(outTitle),
  TransitionProblemKind.incomingAudibleAtStart => l.trWarnInAudibleStart(
    inTitle,
  ),
  TransitionProblemKind.incomingAlteredAtEnd => l.trWarnInAltered(inTitle),
};

String? _presetName(AppLocalizations l, String? id) {
  switch (id) {
    case 'classic':
      return l.trPresetClassicName;
    case 'bassSwap':
      return l.trPresetBassSwapName;
    case 'longBlend':
      return l.trPresetLongBlendName;
    case 'lift':
      return l.trPresetLiftName;
    case 'washOut':
      return l.trPresetWashOutName;
    case 'echoOut':
      return l.trPresetEchoOutName;
    case 'hardCut':
      return l.trPresetHardCutName;
    case 'drop':
      return l.trPresetDropName;
    case 'sweep':
      return l.trPresetSweepName;
    default:
      return null;
  }
}

String? _presetDesc(AppLocalizations l, String? id) {
  switch (id) {
    case 'classic':
      return l.trPresetClassicDesc;
    case 'bassSwap':
      return l.trPresetBassSwapDesc;
    case 'longBlend':
      return l.trPresetLongBlendDesc;
    case 'lift':
      return l.trPresetLiftDesc;
    case 'washOut':
      return l.trPresetWashOutDesc;
    case 'echoOut':
      return l.trPresetEchoOutDesc;
    case 'hardCut':
      return l.trPresetHardCutDesc;
    case 'drop':
      return l.trPresetDropDesc;
    case 'sweep':
      return l.trPresetSweepDesc;
    default:
      return null;
  }
}

String? _volumeName(AppLocalizations l, String? id) {
  switch (id) {
    case 'smooth':
      return l.trShapeVolumeSmoothName;
    case 'linear':
      return l.trShapeVolumeLinearName;
    case 'overlap':
      return l.trShapeVolumeOverlapName;
    case 'fadeInFadeOut':
      return l.trShapeVolumeFadeInFadeOutName;
    case 'cutInFadeOut':
      return l.trShapeVolumeCutInFadeOutName;
    case 'fadeInCutOut':
      return l.trShapeVolumeFadeInCutOutName;
    case 'centerCut':
      return l.trShapeVolumeCenterCutName;
    case 'dropIn':
      return l.trShapeVolumeDropInName;
    case 'none':
      return l.trShapeVolumeNoneName;
    default:
      return null;
  }
}

String? _volumeDesc(AppLocalizations l, String? id) {
  switch (id) {
    case 'smooth':
      return l.trShapeVolumeSmoothDesc;
    case 'linear':
      return l.trShapeVolumeLinearDesc;
    case 'overlap':
      return l.trShapeVolumeOverlapDesc;
    case 'fadeInFadeOut':
      return l.trShapeVolumeFadeInFadeOutDesc;
    case 'cutInFadeOut':
      return l.trShapeVolumeCutInFadeOutDesc;
    case 'fadeInCutOut':
      return l.trShapeVolumeFadeInCutOutDesc;
    case 'centerCut':
      return l.trShapeVolumeCenterCutDesc;
    case 'dropIn':
      return l.trShapeVolumeDropInDesc;
    case 'none':
      return l.trShapeVolumeNoneDesc;
    default:
      return null;
  }
}

String? _eqName(AppLocalizations l, String? id) {
  switch (id) {
    case 'centerBassSwap':
      return l.trShapeEqCenterBassSwapName;
    case 'endBassSwap':
      return l.trShapeEqEndBassSwapName;
    case 'threeBandFade':
      return l.trShapeEqThreeBandFadeName;
    case 'quickBassCut':
      return l.trShapeEqQuickBassCutName;
    case 'none':
      return l.trShapeEqNoneName;
    default:
      return null;
  }
}

String? _eqDesc(AppLocalizations l, String? id) {
  switch (id) {
    case 'centerBassSwap':
      return l.trShapeEqCenterBassSwapDesc;
    case 'endBassSwap':
      return l.trShapeEqEndBassSwapDesc;
    case 'threeBandFade':
      return l.trShapeEqThreeBandFadeDesc;
    case 'quickBassCut':
      return l.trShapeEqQuickBassCutDesc;
    case 'none':
      return l.trShapeEqNoneDesc;
    default:
      return null;
  }
}

String? _effectName(AppLocalizations l, String? id) {
  switch (id) {
    case 'lowPassOut':
      return l.trShapeEffectLowPassOutName;
    case 'highPassIn':
      return l.trShapeEffectHighPassInName;
    case 'lowPassIn':
      return l.trShapeEffectLowPassInName;
    case 'highPassOut':
      return l.trShapeEffectHighPassOutName;
    case 'echoOut':
      return l.trShapeEffectEchoOutName;
    case 'none':
      return l.trShapeEffectNoneName;
    default:
      return null;
  }
}

String? _effectDesc(AppLocalizations l, String? id) {
  switch (id) {
    case 'lowPassOut':
      return l.trShapeEffectLowPassOutDesc;
    case 'highPassIn':
      return l.trShapeEffectHighPassInDesc;
    case 'lowPassIn':
      return l.trShapeEffectLowPassInDesc;
    case 'highPassOut':
      return l.trShapeEffectHighPassOutDesc;
    case 'echoOut':
      return l.trShapeEffectEchoOutDesc;
    case 'none':
      return l.trShapeEffectNoneDesc;
    default:
      return null;
  }
}
