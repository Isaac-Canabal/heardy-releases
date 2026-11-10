// Planificador del Mix DJ, portado de tool/mix_spike/bin/render3.dart con las
// reglas medidas en el mashup de referencia (odd/notes/mix-dj-reference.md):
// una canción es la base a su tempo y posición nativos; la otra se estira y
// aporta voces y secciones cortas, con cortes en downbeats de frase.
import 'dart:math' as math;

import 'mix_song.dart';
import 'mix_types.dart';

/// Un tramo de la línea de tiempo: [bars] compases de [song]/[kind] desde
/// [src], colocados en [out]. [db] es la ganancia relativa a la de la canción.
class MixSeg {
  MixSeg(this.song, this.kind, this.src, this.out, this.bars, {this.db = 0, this.leadIn = 0, this.toEnd = false});
  final MixSong song;
  final MixLayer kind;
  final int src, out, bars;
  final double db;

  /// Compases que la voz se adelanta (con rampa desde -12 dB).
  final double leadIn;

  /// Sigue hasta el final del audio fuente (outro original).
  final bool toEnd;

  @override
  String toString() => '${song.name}.${kind.name}[$src+$bars]@$out${db != 0 ? ' ${db.toStringAsFixed(1)}dB' : ''}'
      '${leadIn > 0 ? ' lead-in $leadIn' : ''}';
}

int snap4(num x) => (x / 4).round() * 4;

/// Base elegida y por qué.
class BaseChoice {
  const BaseChoice(this.base, this.other, this.reason);
  final MixSong base, other;
  final String reason;
}

/// Regla de base: en automático, la de menor residuo de rejilla; si difieren
/// menos de un 10 %, la de intro + outro sin voz más largos (empate: A). En
/// "voces sobre música" la base es la música, por definición. Devuelve 'a' o
/// 'b' y el motivo.
(String, String) chooseBaseId({
  required MixMode mode,
  required double residualMsA,
  required double residualMsB,
  required int introOutroA,
  required int introOutroB,
}) {
  switch (mode) {
    case MixMode.vocalsAOverMusicB:
      return ('b', 'modo voces de A sobre la música de B');
    case MixMode.vocalsBOverMusicA:
      return ('a', 'modo voces de B sobre la música de A');
    case MixMode.automatic:
      final ra = residualMsA, rb = residualMsB;
      String ms(double x) => x.toStringAsFixed(1);
      if ((ra - rb).abs() < 0.1 * math.max(ra, rb)) {
        return (
          introOutroA >= introOutroB ? 'a' : 'b',
          'residuos de rejilla parecidos (${ms(ra)} y ${ms(rb)} ms, < 10 %): gana la intro + outro sin voz más '
              'larga ($introOutroA frente a $introOutroB compases)'
        );
      }
      return (ra < rb ? 'a' : 'b', 'menor residuo de rejilla (${ms(ra)} frente a ${ms(rb)} ms)');
  }
}

BaseChoice chooseBase(MixSong a, MixSong b, MixMode mode) {
  final (id, reason) = chooseBaseId(
    mode: mode,
    residualMsA: a.residualMs,
    residualMsB: b.residualMs,
    introOutroA: a.introOutro,
    introOutroB: b.introOutro,
  );
  return id == 'a' ? BaseChoice(a, b, reason) : BaseChoice(b, a, reason);
}

/// Estiramiento relativo de [other] para sonar al tempo de [base].
double stretchOf(MixSong base, MixSong other) => base.bpm / other.bpm - 1;

/// Tempo común y estiramiento de cada canción (positivo = más rápida).
class TempoPlan {
  const TempoPlan(this.commonBpm, this.stretchBase, this.stretchOther);
  final double commonBpm, stretchBase, stretchOther;

  /// La base cambia de velocidad (si no, suena a su tempo nativo).
  bool get shared => stretchBase != 0;
}

/// Si la otra canción cabe en [maxStretch] (8 %), la base se queda a su tempo
/// nativo y solo se estira la otra, como en la referencia aprobada. Si no, las
/// dos van a la media geométrica de sus tempos (mismo estiramiento relativo en
/// cada una) con un tope de [maxShared] por canción. `null` si ni así cabe.
TempoPlan? planTempo(double baseBpm, double otherBpm, {required double maxStretch, required double maxShared}) {
  final direct = baseBpm / otherBpm - 1;
  if (direct.abs() <= maxStretch) return TempoPlan(baseBpm, 0, direct);
  final common = math.sqrt(baseBpm * otherBpm);
  final sb = common / baseBpm - 1, so = common / otherBpm - 1;
  if (sb.abs() > maxShared || so.abs() > maxShared) return null;
  return TempoPlan(common, sb, so);
}

/// Plegado a medio tiempo de cada canción antes de planificar. Por defecto, el
/// de siempre (un tempo de 100 BPM o más se cuenta a la mitad: compás doble de
/// 8 pulsos). Si con eso el par no cabe en [maxStretch], se prueba también
/// plegar o no cada una (p. ej. 99 y 100 BPM, que de otro modo serían 99 y 50)
/// y se elige la combinación con tempos más cercanos. Devuelve (plegarA, plegarB).
(bool, bool) chooseTempoFold(double bpmA, double bpmB, {required double maxStretch, required double maxShared}) {
  const lo = 40.0, hi = 130.0;
  final defA = bpmA >= 100, defB = bpmB >= 100;
  double gap(bool fa, bool fb) => (math.log((fa ? bpmA / 2 : bpmA) / (fb ? bpmB / 2 : bpmB))).abs();
  final fits = math.log(1 + maxStretch);
  if (gap(defA, defB) <= fits) return (defA, defB);
  var best = (defA, defB);
  var bestGap = gap(defA, defB);
  for (final fa in [defA, !defA]) {
    for (final fb in [defB, !defB]) {
      final a = fa ? bpmA / 2 : bpmA, b = fb ? bpmB / 2 : bpmB;
      if (a < lo || a > hi || b < lo || b > hi) continue;
      final g = gap(fa, fb);
      if (g < bestGap - 1e-9) {
        best = (fa, fb);
        bestGap = g;
      }
    }
  }
  return best;
}

/// Elige las frases de voz de [o]: la primera con voz (estrofa) y la más fuerte
/// (estribillo), en compases de inicio.
(int, int) vocalSources(MixSong o) {
  final starts = <int>[];
  for (var b = 0; b + 12 <= o.bars; b += 4) {
    var v = 0.0;
    for (var k = b; k < b + 8; k++) {
      v += o.vocal[k];
    }
    if (v / 8 >= o.vocalThr && !o.stem(MixLayer.vocals).dead(b)) starts.add(b);
  }
  if (starts.isEmpty) return (8, 16);
  final verse = starts.first;
  var chorus = starts.last;
  var best = -1e9;
  for (final s in starts) {
    if ((s - verse).abs() < 12) continue;
    final l = o.stem(MixLayer.mix).lufs(s, s + 8);
    if (l > best) {
      best = l;
      chorus = s;
    }
  }
  return (verse, chorus);
}

/// Mejor sección de [o] para sustituir a la base: válida, fuerte, con poca voz
/// (o con voz si [wantVocal]) y sin repetir.
int oSection(MixSong o, int bars, Set<int> used, {required bool wantVocal, double? targetLufs}) {
  var best = 8, bestS = -1e9;
  final kind = wantVocal ? MixLayer.mix : MixLayer.instrumental;
  for (var b = 4; b + bars <= o.bars - 4; b += 4) {
    if (used.any((u) => (u - b).abs() < bars)) continue;
    var dead = 0;
    var v = 0.0;
    for (var k = b; k < b + bars; k++) {
      if (!o.stem(kind).usable(k)) dead++;
      v += o.vocal[k];
    }
    if (dead > 0) continue;
    final l = o.stem(kind).lufs(b, b + bars) + o.gainDb;
    // Con [targetLufs] (la base en ese sitio) se prefiere la sección que quede
    // dentro de ±3 dB de ajuste: así el salto de nivel no pasa de ~4 LU.
    final s = (targetLufs == null ? l : -math.max(0, (l - targetLufs).abs() - 2.5) * 3) +
        (wantVocal ? 4 * v / bars : -4 * v / bars);
    if (s > bestS) {
      bestS = s;
      best = b;
    }
  }
  used.add(best);
  return best;
}

/// Inicio del outro original de la base, en compases.
int outroStartOf(int bars) => math.max(snap4(bars - 8), 16);

/// Plan de tramos (sin ordenar) para [base] y [o].
List<MixSeg> planMix(MixSong base, MixSong o, MixMode mode) {
  final n = base.bars;
  final outroStart = outroStartOf(n);
  final segs = <MixSeg>[];
  final mixBars = <int>{};
  // Material de la base en [a, b), por bloques de 4 compases (8 reales): si
  // algún compás del instrumental tiene hueco o casi silencio, el bloque entero
  // usa la mezcla (con su voz).
  void baseBody(int a, int b) {
    bool blockMix(int s) {
      for (var k = s - s % 4; k < math.min(b, s - s % 4 + 4); k++) {
        if (!base.stem(MixLayer.instrumental).usable(k)) return true;
      }
      return false;
    }

    var s = a;
    while (s < b) {
      final useMix = blockMix(s);
      var e = s + 1;
      while (e < b && blockMix(e) == useMix) {
        e++;
      }
      segs.add(MixSeg(base, useMix ? MixLayer.mix : MixLayer.instrumental, s, s, e - s));
      if (useMix) mixBars.addAll([for (var k = s; k < e; k++) k]);
      s = e;
    }
  }

  segs.add(MixSeg(base, MixLayer.mix, 0, 0, 8));
  final body = outroStart - 8;
  final (verse, chorus) = vocalSources(o);
  final vocals = <(int, int, int, double)>[]; // (out, src, bars, dB rel. inst)
  if (mode == MixMode.automatic) {
    // ~8 secciones: intro · O (4) · base · base+voz · O inst (8) · base+voz · base · O inst (8) · outro.
    final used = <int>{};
    final s1 = oSection(o, 4, used, wantVocal: true);
    final mid = snap4(8 + body * 0.45);
    final late = outroStart - 8;
    segs.add(MixSeg(o, MixLayer.mix, s1, 8, 4));
    baseBody(12, mid);
    double baseAt(int b0) => base.stem(MixLayer.mix).lufs(b0, b0 + 8) + base.gainDb;
    segs.add(MixSeg(o, MixLayer.instrumental,
        oSection(o, 8, used, wantVocal: false, targetLufs: baseAt(mid)), mid, 8));
    baseBody(mid + 8, late);
    segs.add(MixSeg(o, MixLayer.instrumental,
        oSection(o, 8, used, wantVocal: false, targetLufs: baseAt(late)), late, 8));
    vocals.add((16, verse, math.min(8, mid - 16), -7));
    vocals.add((mid + 8, chorus, math.min(12, late - mid - 8), -1));
  } else {
    baseBody(8, outroStart);
    final step = snap4(body / 3);
    vocals.add((12, verse, math.min(12, step), -7));
    vocals.add((12 + step + 4, chorus, math.min(12, step), -1));
    if (12 + 2 * step + 8 + 8 <= outroStart) vocals.add((12 + 2 * step + 8, verse + 12, 8, -4));
  }
  segs.add(MixSeg(base, MixLayer.mix, outroStart, outroStart, n - outroStart, toEnd: true));
  // Nunca dos voces: la voz de O solo va sobre el instrumental de la base. Si el
  // sitio previsto choca con la mezcla de la base o con una sección de O, se
  // busca hacia delante (en pasos de 4) el primer hueco libre de ≥ 8 compases.
  bool free(int k) =>
      k >= 8 &&
      k < outroStart &&
      !mixBars.contains(k) &&
      !segs.any((s) => s.song == o && k >= s.out && k < s.out + s.bars);
  for (final (want, src, bars, rel) in vocals) {
    var out = -1, len = 0;
    for (var st = want; st + 8 <= outroStart; st += 4) {
      var l = 0;
      while (l < bars && free(st + l)) {
        l++;
      }
      if (l >= 8 || l == bars) {
        out = st;
        len = l;
        break;
      }
    }
    if (out < 0) continue;
    final inst = base.stem(MixLayer.instrumental).lufs(out, out + len) + base.gainDb;
    final voc = o.stem(MixLayer.vocals).lufs(src, src + len) + o.gainDb;
    segs.add(MixSeg(o, MixLayer.vocals, src, out, len, db: (inst + rel - voc).clamp(-15.0, 9.0), leadIn: 1));
  }
  // Secciones de O: ajuste ±3 dB hacia la sonoridad de la base en ese sitio.
  return [
    for (final s in segs)
      if (s.song == o && s.kind != MixLayer.vocals)
        MixSeg(s.song, s.kind, s.src, s.out, s.bars,
            db: ((base.stem(MixLayer.mix).lufs(s.out, s.out + s.bars) + base.gainDb) -
                    (o.stem(s.kind).lufs(s.src, s.src + s.bars) + o.gainDb))
                .clamp(-3.0, 3.0))
      else
        s
  ];
}

/// Número Camelot (1-12) y si es menor.
(int, bool) camelotParts(int root, bool minor) {
  final rel = minor ? (root + 3) % 12 : root;
  return (((rel * 7) % 12 + 7) % 12 + 1, minor);
}

/// Compatibilidad armónica Camelot: mismo número, o ±1 con la misma letra.
bool keysCompatible(int rootA, bool minorA, int rootB, bool minorB) {
  final (na, ma) = camelotParts(rootA, minorA);
  final (nb, mb) = camelotParts(rootB, minorB);
  if (na == nb) return true;
  if (ma != mb) return false;
  final d = (na - nb) % 12;
  return d == 1 || d == 11;
}

/// Semitonos para la canción que no es base. Sin transponer salvo que ambas
/// tonalidades sean fiables (r ≥ [minKeyScore]) e incompatibles; entonces el
/// desplazamiento más corto (hasta ±3, la bajada gana el empate) que las haga
/// compatibles, o 0 si no hay ninguno.
int chooseSemitones({
  required int baseRoot,
  required bool baseMinor,
  required double baseScore,
  required int otherRoot,
  required bool otherMinor,
  required double otherScore,
  double minKeyScore = 0.6,
}) {
  if (baseScore < minKeyScore || otherScore < minKeyScore) return 0;
  if (keysCompatible(baseRoot, baseMinor, otherRoot, otherMinor)) return 0;
  for (var d = 1; d <= 3; d++) {
    for (final s in [-d, d]) {
      if (keysCompatible(baseRoot, baseMinor, (otherRoot + s) % 12, otherMinor)) return s;
    }
  }
  return 0;
}

/// Frases de la base (inicio en compases, de [phrase] compases) que se quitan
/// para acercar la duración a [targetSec]. Nunca toca la intro (primeros 8
/// compases) ni el outro (desde [outroStartOf]); deja al menos [minBodyBars] de
/// cuerpo. Quita una frase mientras eso acerque la duración al objetivo, y
/// elige la que deja el empalme más parejo en sonoridad ([lufs] de un tramo de
/// compases) entre las frases vecinas que quedan; el empate va a la más tardía.
List<int> phrasesToDrop({
  required int bars,
  required double barSec,
  required double extraSec,
  required double targetSec,
  required double Function(int b0, int b1) lufs,
  int phrase = 8,
  int minBodyBars = 32,
}) {
  final outroStart = outroStartOf(bars);
  final dropped = <int>{};
  final candidates = [for (var p = 8; p + phrase <= outroStart; p += phrase) p];
  var duration = bars * barSec + extraSec;
  final phraseSec = phrase * barSec;
  var body = outroStart - 8;
  while (duration - targetSec > phraseSec / 2 && body - phrase >= minBodyBars) {
    int? best;
    var bestScore = double.infinity;
    for (final p in candidates) {
      if (dropped.contains(p)) continue;
      // Frases vecinas que quedarían a cada lado del empalme.
      var prev = p - phrase;
      while (prev >= 8 && dropped.contains(prev)) {
        prev -= phrase;
      }
      var next = p + phrase;
      while (next < outroStart && dropped.contains(next)) {
        next += phrase;
      }
      final before = prev < 8 ? lufs(0, 8) : lufs(prev, prev + phrase);
      final after = next >= outroStart ? lufs(outroStart, outroStart + phrase) : lufs(next, next + phrase);
      final score = (before - after).abs();
      if (score <= bestScore) {
        bestScore = score;
        best = p;
      }
    }
    if (best == null) break;
    dropped.add(best);
    duration -= phraseSec;
    body -= phrase;
  }
  return dropped.toList()..sort();
}
