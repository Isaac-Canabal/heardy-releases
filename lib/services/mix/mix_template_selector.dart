// Selector automático de plantilla del Mix DJ: puntúa cada plantilla aplicable
// al par a partir de rasgos de las dos canciones y de los avisos, y elige la de
// más puntos. Puro Dart y determinista: sin azar ni reloj; los empates (o casi)
// se resuelven con un hash estable del par, para que el mismo par dé siempre la
// misma plantilla y pares distintos puedan caer en plantillas distintas.
import 'dart:convert';
import 'dart:math' as math;

import 'mix_planner.dart';
import 'mix_song.dart';
import 'mix_templates.dart';
import 'mix_types.dart';

// --- Pesos (puntos) de cada regla. Cada rasgo va normalizado a 0..1. -----------

/// Diferencia máxima con la mejor puntuación para contar como empate.
const kTieEpsilon = 0.25;

/// classic: base fija; es la salida segura cuando nada destaca.
const kClassicBase = 2.0;
const kClassicShort = 1.0;

const kFullVocalVocals = 2.5;
const kFullVocalPhrases = 1.5;
const kFullVocalShort = 1.0;

const kAltMaterial = 3.0;
const kAltLong = 1.5;
const kAltSimilar = 1.0;

const kDropPhrases = 2.5;
const kDropVocals = 1.0;
const kDropContrast = 1.5;
const kDropLong = 0.5;

const kBreakPhrases = 2.0;
const kBreakBaseVocals = 1.0;

const kHookPhrases = 2.0;
const kHookVocals = 1.0;
const kHookIntro = 1.5;

const kQuickMaterial = 3.0;
const kQuickLong = 2.0;
const kQuickSimilar = 1.5;

const kSlowBase = 1.5;
const kSlowShort = 3.0;
const kSlowContrast = 1.0;

const kBookMaterial = 2.0;
const kBookIntroOutro = 2.0;

const kSwapBaseVocals = 3.5;
const kSwapMaterial = 1.0;

const kCallBoth = 3.0;
const kCallVocals = 1.0;

const kBedMaterial = 2.5;
const kBedLong = 1.0;
const kBedQuietOther = 1.0;

/// Avisos: las plantillas ocupadas (muchos cortes) pierden y las suaves ganan
/// cuando el par ya viene forzado. La gravedad suma por aviso y topa en 1.
const kBusyPenalty = 2.0;
const kLightBonus = 1.5;
const kSeverityForcedStretch = 1.0;
const kSeverityKeyClash = 0.7;
const kSeverityTempoFar = 0.5;

const _busy = {MixTemplate.quickCuts, MixTemplate.alternating16, MixTemplate.callAndResponse, MixTemplate.dropBuild};
const _light = {
  MixTemplate.fullVocalOverlay,
  MixTemplate.slowBurn,
  MixTemplate.instrumentalBed,
  MixTemplate.classic,
};

/// FNV-1a de 32 bits sobre los bytes UTF-8 de [s]: estable entre ejecuciones y
/// plataformas (a diferencia de `String.hashCode`).
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// Semilla de desempate del par: nombres, compases y duraciones de las dos canciones.
int pairSeed(MixSong base, MixSong o) => fnv1a32([
      base.name,
      o.name,
      base.bars,
      o.bars,
      (base.seconds * 1000).round(),
      (o.seconds * 1000).round(),
    ].join('|'));

class TemplateScore {
  const TemplateScore(this.template, this.score);
  final MixTemplate template;
  final double score;
}

class TemplateChoice {
  const TemplateChoice({
    required this.template,
    required this.reason,
    required this.topReasons,
    required this.runnerUp,
    required this.ranked,
    required this.tieBroken,
  });

  final MixTemplate template;

  /// Rasgo que más puntos dio a [template] (o [TemplateReason.onlyEligible] / [TemplateReason.balanced]).
  final TemplateReason reason;

  /// Hasta dos rasgos que más puntos dieron a [template], de mayor a menor.
  final List<TemplateReason> topReasons;

  /// Mejor plantilla aplicable distinta de [template], si hay.
  final MixTemplate? runnerUp;

  /// Plantillas aplicables al par, de más a menos puntos.
  final List<TemplateScore> ranked;

  /// `true` si hubo varias dentro de [kTieEpsilon] y decidió la semilla.
  final bool tieBroken;

  MixTemplateSelection get selection =>
      MixTemplateSelection(requested: template, automatic: true, reason: reason, runnerUp: runnerUp);
}

class _Contribution {
  const _Contribution(this.reason, this.points);
  final TemplateReason? reason;
  final double points;
}

class _Features {
  _Features(MixSong base, MixSong o) {
    final n = base.bars, os = outroStartOf(n);
    final ov = vocalBarsOf(o);
    otherVocals = _clamp01((ov.where((x) => x).length / math.max(1, o.bars) - 0.2) / 0.5);
    otherPhrases = _clamp01(vocalChunksOf(o, 16).length / 6);
    basePhrases = _clamp01(
        vocalChunksOf(base, 16).where((c) => c.$1 >= 12 && c.$1 + c.$2 <= os - 4).length / 3);
    final inst = o.stem(MixLayer.instrumental);
    // Música aprovechable sin voz: el instrumental suena limpio y la voz calla.
    var clean = 0;
    for (var k = 4; k < o.bars - 4; k++) {
      if (!ov[k] && inst.usable(k)) clean++;
    }
    material = _clamp01(clean / math.max(1, o.bars - 8) / 0.45);
    longBase = _clamp01((n - 40) / 24);
    shortBase = _clamp01((48 - n) / 20);
    baseIntro = _clamp01(math.min(base.introBars, 8) / 8);
    otherIntroOutro = _clamp01((math.min(o.introBars, 8) + math.min(o.outroBars, 8)) / 16);
    contour = _contourCorrelation(base, o);
  }

  late final double otherVocals, otherPhrases, basePhrases, material, longBase, shortBase, baseIntro, otherIntroOutro;

  /// Correlación (-1..1) entre los recorridos de energía de las dos canciones.
  late final double contour;

  double get similar => math.max(contour, 0);
  double get contrasting => math.max(-contour, 0);
}

double _clamp01(double x) => x.clamp(0.0, 1.0);

/// Correlación de Pearson entre la sonoridad por compás de las dos canciones,
/// remuestreada a 16 tramos para que su longitud no cuente.
double _contourCorrelation(MixSong a, MixSong b) {
  List<double> curve(MixSong s) {
    final l = s.stem(MixLayer.mix).barLufs;
    final med = s.stem(MixLayer.mix).median;
    final v = [for (final x in l) x > -70 ? x : med];
    return [
      for (var i = 0; i < 16; i++)
        () {
          final a0 = i * v.length ~/ 16, a1 = math.max(a0 + 1, (i + 1) * v.length ~/ 16);
          var t = 0.0;
          for (var k = a0; k < math.min(a1, v.length); k++) {
            t += v[k];
          }
          return t / math.max(1, math.min(a1, v.length) - a0);
        }()
    ];
  }

  final x = curve(a), y = curve(b);
  final mx = x.reduce((p, q) => p + q) / 16, my = y.reduce((p, q) => p + q) / 16;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < 16; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) * (x[i] - mx);
    syy += (y[i] - my) * (y[i] - my);
  }
  if (sxx < 1e-9 || syy < 1e-9) return 0;
  return (sxy / math.sqrt(sxx * syy)).clamp(-1.0, 1.0);
}

double _severity(List<MixWarning> warnings) {
  var s = 0.0;
  for (final w in warnings) {
    s += switch (w.kind) {
      MixWarningKind.forcedStretch => kSeverityForcedStretch,
      MixWarningKind.keyClash => kSeverityKeyClash,
      MixWarningKind.tempoFar => kSeverityTempoFar,
      _ => 0.0,
    };
  }
  return math.min(s, 1.0);
}

List<_Contribution> _contributions(MixTemplate t, _Features f, double severity) {
  _Contribution c(TemplateReason? r, double w, double x) => _Contribution(r, w * x);
  final list = switch (t) {
    MixTemplate.classic => [
        c(null, kClassicBase, 1),
        c(TemplateReason.shortBase, kClassicShort, f.shortBase),
      ],
    MixTemplate.fullVocalOverlay => [
        c(TemplateReason.otherVocals, kFullVocalVocals, f.otherVocals),
        c(TemplateReason.otherVocals, kFullVocalPhrases, f.otherPhrases),
        c(TemplateReason.shortBase, kFullVocalShort, f.shortBase),
      ],
    MixTemplate.alternating16 => [
        c(TemplateReason.instrumentalMaterial, kAltMaterial, f.material),
        c(TemplateReason.longBase, kAltLong, f.longBase),
        c(TemplateReason.similarEnergy, kAltSimilar, f.similar),
      ],
    MixTemplate.dropBuild => [
        c(TemplateReason.otherVocals, kDropPhrases, f.otherPhrases),
        c(TemplateReason.otherVocals, kDropVocals, f.otherVocals),
        c(TemplateReason.contrastingEnergy, kDropContrast, f.contrasting),
        c(TemplateReason.longBase, kDropLong, f.longBase),
      ],
    MixTemplate.breakdown => [
        c(TemplateReason.otherVocals, kBreakPhrases, f.otherPhrases),
        c(TemplateReason.baseVocals, kBreakBaseVocals, f.basePhrases),
      ],
    MixTemplate.chorusHook => [
        c(TemplateReason.otherVocals, kHookPhrases, f.otherPhrases),
        c(TemplateReason.otherVocals, kHookVocals, f.otherVocals),
        c(TemplateReason.introOutro, kHookIntro, f.baseIntro),
      ],
    MixTemplate.quickCuts => [
        c(TemplateReason.instrumentalMaterial, kQuickMaterial, f.material),
        c(TemplateReason.longBase, kQuickLong, f.longBase),
        c(TemplateReason.similarEnergy, kQuickSimilar, f.similar),
      ],
    MixTemplate.slowBurn => [
        c(null, kSlowBase, 1),
        c(TemplateReason.shortBase, kSlowShort, f.shortBase),
        c(TemplateReason.contrastingEnergy, kSlowContrast, f.contrasting),
      ],
    MixTemplate.bookend => [
        c(TemplateReason.instrumentalMaterial, kBookMaterial, f.material),
        c(TemplateReason.introOutro, kBookIntroOutro, f.otherIntroOutro),
      ],
    MixTemplate.roleSwap => [
        c(TemplateReason.baseVocals, kSwapBaseVocals, f.basePhrases),
        c(TemplateReason.instrumentalMaterial, kSwapMaterial, f.material),
      ],
    MixTemplate.callAndResponse => [
        c(TemplateReason.bothVocals, kCallBoth, math.min(f.otherPhrases, f.basePhrases)),
        c(TemplateReason.bothVocals, kCallVocals, f.otherVocals),
      ],
    MixTemplate.instrumentalBed => [
        c(TemplateReason.instrumentalMaterial, kBedMaterial, f.material),
        c(TemplateReason.longBase, kBedLong, f.longBase),
        // Una otra canción con poca voz da una cama más limpia.
        c(TemplateReason.instrumentalMaterial, kBedQuietOther, 1 - f.otherVocals),
      ],
  };
  if (severity > 0) {
    if (_busy.contains(t)) list.add(c(null, -kBusyPenalty, severity));
    if (_light.contains(t)) list.add(c(TemplateReason.gentleForClash, kLightBonus, severity));
  }
  return list;
}

/// Elige la mejor plantilla para [base] y [o] (ya recortada la base). Solo
/// puntúa las que el modo permite y cuyo planificador devuelve un plan para
/// este par, así que nunca elige una que caería en classic en silencio.
TemplateChoice selectTemplate({
  required MixSong base,
  required MixSong o,
  required MixMode mode,
  List<MixWarning> warnings = const [],
  int? seed,
  double tieEpsilon = kTieEpsilon,
}) {
  final f = _Features(base, o);
  final severity = _severity(warnings);
  final scored = <(MixTemplate, double, List<_Contribution>)>[];
  for (final t in MixTemplate.values) {
    if (!templateSupportsMode(t, mode)) continue;
    if (t != MixTemplate.classic) {
      List<MixSeg>? plan;
      try {
        plan = kMixTemplatePlanners[t]?.call(base, o, mode);
      } catch (_) {
        plan = null;
      }
      if (plan == null) continue;
    }
    final cs = _contributions(t, f, severity);
    scored.add((t, cs.fold(0.0, (s, c) => s + c.points), cs));
  }
  scored.sort((x, y) {
    final d = y.$2.compareTo(x.$2);
    return d != 0 ? d : x.$1.index.compareTo(y.$1.index);
  });
  final ties = [for (final s in scored) if (s.$2 >= scored.first.$2 - tieEpsilon) s];
  final pick = ties.length == 1 ? ties.first : ties[(seed ?? pairSeed(base, o)) % ties.length];
  final top = [...pick.$3.where((c) => c.reason != null && c.points > 1e-9)]
    ..sort((a, b) => b.points.compareTo(a.points));
  final reasons = <TemplateReason>[];
  for (final c in top) {
    if (!reasons.contains(c.reason)) reasons.add(c.reason!);
  }
  final runner = scored.where((s) => s.$1 != pick.$1).firstOrNull;
  return TemplateChoice(
    template: pick.$1,
    reason: scored.length == 1
        ? TemplateReason.onlyEligible
        : reasons.isEmpty
            ? TemplateReason.balanced
            : reasons.first,
    topReasons: reasons.take(2).toList(),
    runnerUp: runner?.$1,
    ranked: [for (final s in scored) TemplateScore(s.$1, s.$2)],
    tieBroken: ties.length > 1,
  );
}
