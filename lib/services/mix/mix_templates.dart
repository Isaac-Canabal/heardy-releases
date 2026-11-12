// Plantillas del plan del Mix DJ: cada una reparte de otra forma las secciones y
// las voces entre la base y la otra canción. Un planificador devuelve `null`
// cuando la plantilla no se puede aplicar al par (canción corta, sin frases de
// voz, sin compases libres, modo que no lo permite); `planMixWith` cae entonces
// en classic. Puro Dart, determinista (sin azar ni reloj).
//
// Reglas comunes: la salida dura los compases de la base; los cortes y las
// duraciones van en múltiplos de 4 compases (salvo la cola del final); nunca
// suenan dos voces a la vez y una voz solo va sobre un instrumental; los modos
// "voces sobre música" solo admiten plantillas donde la otra canción aporta
// voces sobre la música de la base, así que las que meten secciones de la otra
// canción exigen el modo automático.
import 'dart:math' as math;

import 'mix_planner.dart';
import 'mix_song.dart';
import 'mix_types.dart';

typedef MixTemplatePlanner = List<MixSeg>? Function(MixSong base, MixSong o, MixMode mode);

final Map<MixTemplate, MixTemplatePlanner> kMixTemplatePlanners = {
  MixTemplate.classic: planClassic,
  MixTemplate.fullVocalOverlay: _fullVocalOverlay,
  MixTemplate.alternating16: _alternating16,
  MixTemplate.dropBuild: _dropBuild,
  MixTemplate.breakdown: _breakdown,
  MixTemplate.chorusHook: _chorusHook,
  MixTemplate.quickCuts: _quickCuts,
  MixTemplate.slowBurn: _slowBurn,
  MixTemplate.bookend: _bookend,
  MixTemplate.roleSwap: _roleSwap,
  MixTemplate.callAndResponse: _callAndResponse,
  MixTemplate.instrumentalBed: _instrumentalBed,
};

/// Plantillas que funcionan en los modos "voces sobre música": las demás meten
/// secciones de la otra canción y exigen el modo automático.
const kTemplatesInVocalModes = {MixTemplate.classic, MixTemplate.fullVocalOverlay, MixTemplate.breakdown};

bool templateSupportsMode(MixTemplate t, MixMode mode) => mode == MixMode.automatic || kTemplatesInVocalModes.contains(t);

bool _covers(MixSeg s, int k) => k >= s.out && k < s.out + s.bars;

/// Compases con voz clara de [s]: envolvente ≥ 60 % de la mediana y no muerto en el stem.
List<bool> vocalBarsOf(MixSong s) {
  final thr = s.vocalThr * 0.6;
  final st = s.stem(MixLayer.vocals);
  return [for (var k = 0; k < s.bars; k++) s.vocal[k] > 0 && s.vocal[k] >= thr && !st.dead(k)];
}

/// Trozos (inicio, compases) de las frases de voz de [s]: de hasta [maxLen]
/// compases, en múltiplos de 4 y de al menos [minLen].
List<(int, int)> vocalChunksOf(MixSong s, int maxLen, {int minLen = 8}) {
  final v = vocalBarsOf(s);
  final out = <(int, int)>[];
  var k = 0;
  while (k < v.length) {
    if (!v[k]) {
      k++;
      continue;
    }
    var e = k;
    while (e < v.length && v[e]) {
      e++;
    }
    var a = (k + 3) ~/ 4 * 4;
    while (e - a >= minLen) {
      final len = math.min(maxLen, (e - a) ~/ 4 * 4);
      out.add((a, len));
      a += len;
    }
    k = e;
  }
  return out;
}

/// Estribillo de [o]: el tramo de 8 compases con voz y mezcla utilizable más
/// fuerte (el primero en empate), ampliado hasta 16 mientras siga la voz.
(int, int)? chorusOf(MixSong o) {
  final v = vocalBarsOf(o);
  final mix = o.stem(MixLayer.mix);
  int? best;
  var bestL = -1e9;
  for (var b = 0; b + 8 <= o.bars; b += 4) {
    var ok = true;
    for (var k = b; k < b + 8 && ok; k++) {
      ok = v[k] && mix.usable(k);
    }
    if (!ok) continue;
    final l = mix.lufs(b, b + 8);
    if (l > bestL + 1e-9) {
      bestL = l;
      best = b;
    }
  }
  if (best == null) return null;
  var len = 8;
  while (len < 16 && best + len + 4 <= o.bars && [for (var k = 0; k < 4; k++) v[best + len + k]].every((x) => x)) {
    len += 4;
  }
  return (best, len);
}

class _Slot {
  const _Slot(this.out, this.bars, this.kind, {this.wantVocal = false, this.required = true});
  final int out, bars;
  final MixLayer kind;
  final bool wantVocal, required;
}

/// Armado de un plan: base (intro, cuerpo, outro), secciones de la otra
/// canción y voces colocadas en huecos libres del instrumental de la base.
class _Builder {
  _Builder(this.base, this.o, this.mode)
      : n = base.bars,
        os = outroStartOf(base.bars);

  final MixSong base, o;
  final MixMode mode;
  final int n, os;
  final segs = <MixSeg>[];
  final mixBars = <int>{};
  final used = <int>{};

  /// Compases donde no puede haber voz aunque suene el instrumental de la base.
  final reserved = <int>{};
  int otherCount = 0;

  bool get auto => mode == MixMode.automatic;

  void intro() => segs.add(MixSeg(base, MixLayer.mix, 0, 0, 8));
  void outro() => segs.add(MixSeg(base, MixLayer.mix, os, os, n - os, toEnd: true));

  /// Cuerpo de la base en [a, b), por bloques de 4 compases: si algún compás del
  /// instrumental tiene hueco o casi silencio, el bloque entero usa la mezcla.
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

  double baseLufs(int out, int bars) => base.stem(MixLayer.mix).lufs(out, math.min(out + bars, n)) + base.gainDb;

  /// Mejor sección de [o] para [bars] compases en [ref] (la marca como usada), o `null`.
  int? pickO(MixLayer kind, int bars, {required int ref}) {
    final src = oSectionOrNull(o, bars, used, wantVocal: kind == MixLayer.mix, targetLufs: baseLufs(ref, bars));
    if (src != null) used.add(src);
    return src;
  }

  double otherDb(MixLayer kind, int src, int ref, int bars) =>
      (baseLufs(ref, bars) - (o.stem(kind).lufs(src, src + bars) + o.gainDb)).clamp(-3.0, 3.0);

  bool otherAt(MixLayer kind, int out, int bars) {
    final src = pickO(kind, bars, ref: out);
    if (src == null) return false;
    segs.add(MixSeg(o, kind, src, out, bars, db: otherDb(kind, src, out, bars)));
    otherCount++;
    return true;
  }

  /// Rellena [a, b) con la base salvo en [slots] (ordenados), que van a la otra
  /// canción. Un hueco que no se pueda cubrir cae en la base, salvo si es obligatorio.
  bool layout(int a, int b, List<_Slot> slots) {
    var cur = a;
    for (final s in slots) {
      if (s.out > cur) baseBody(cur, s.out);
      if (!otherAt(s.kind, s.out, s.bars)) {
        if (s.required) return false;
        baseBody(s.out, s.out + s.bars);
      }
      cur = s.out + s.bars;
    }
    if (cur < b) baseBody(cur, b);
    return true;
  }

  bool vocalAt(int k) => segs.any((s) => s.kind == MixLayer.vocals && _covers(s, k));

  bool free(int k) =>
      k >= 8 &&
      k < os &&
      !reserved.contains(k) &&
      segs.any((s) => s.song == base && s.kind == MixLayer.instrumental && _covers(s, k)) &&
      !segs.any((s) => _covers(s, k) && (s.song != base || s.kind == MixLayer.vocals));

  /// Coloca una frase de voz de [voice] (por defecto la otra canción) sobre el
  /// instrumental de la base: desde [want], el primer hueco libre (pasos de 4)
  /// de al menos min([minBars], [bars]) compases, y antes de [before]. Con
  /// [exact] solo se prueba [want]. Devuelve el compás de salida o -1.
  int placeVocal(int want, int src, int bars, double rel,
      {MixSong? voice, double leadIn = 1, int minBars = 8, int? before, bool exact = false, double? db}) {
    final v = voice ?? o;
    final end = math.min(before ?? os, os);
    for (var st = want; st + math.min(minBars, bars) <= end; st += 4) {
      if (leadIn > 0 && vocalAt(st - 1)) {
        if (exact) return -1;
        continue;
      }
      var l = 0;
      while (l < bars && st + l < end && free(st + l)) {
        l++;
      }
      l -= l % 4;
      if (l >= math.min(minBars, bars)) {
        final inst = base.stem(MixLayer.instrumental).lufs(st, st + l) + base.gainDb;
        final voc = v.stem(MixLayer.vocals).lufs(src, src + l) + v.gainDb;
        segs.add(MixSeg(v, MixLayer.vocals, src, st, l, db: db ?? (inst + rel - voc).clamp(-15.0, 9.0), leadIn: leadIn));
        return st;
      }
      if (exact) return -1;
    }
    return -1;
  }

  /// El plan, o `null` si rompe alguna regla común (red de seguridad: cada
  /// plantilla las cumple por construcción).
  List<MixSeg>? finish() => _valid(segs, n) ? segs : null;
}

bool _valid(List<MixSeg> segs, int n) {
  for (final s in segs) {
    if (s.bars <= 0 || s.out < 0 || s.src < 0 || s.src + s.bars > s.song.bars || s.out + s.bars > n) return false;
  }
  final body = segs.where((s) => s.kind != MixLayer.vocals).toList()..sort((a, b) => a.out.compareTo(b.out));
  var at = 0;
  for (final s in body) {
    if (s.out != at) return false;
    at = s.out + s.bars;
  }
  if (at != n) return false;
  final voices = segs.where((s) => s.kind == MixLayer.vocals).toList()..sort((a, b) => a.out.compareTo(b.out));
  for (var i = 1; i < voices.length; i++) {
    if (voices[i].out - voices[i].leadIn.ceil() < voices[i - 1].out + voices[i - 1].bars) return false;
  }
  for (final v in voices) {
    for (var k = v.out; k < v.out + v.bars; k++) {
      if (!body.any((s) => s.kind == MixLayer.instrumental && _covers(s, k))) return false;
    }
  }
  return true;
}

List<MixSeg>? _fullVocalOverlay(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (b.os < 32) return null;
  final chunks = vocalChunksOf(o, 16);
  if (chunks.isEmpty) return null;
  b
    ..intro()
    ..baseBody(8, b.os)
    ..outro();
  var cursor = 12, i = 0, placed = 0;
  while (cursor + 8 <= b.os && i < 16) {
    final (src, len) = chunks[i % chunks.length];
    if (b.placeVocal(cursor, src, len, i == 0 ? -7 : -3) < 0) break;
    final v = b.segs.last;
    placed += v.bars;
    cursor = v.out + v.bars + 4;
    i++;
  }
  if (placed < 16 || placed * 5 < (b.os - 8) * 2) return null;
  return b.finish();
}

List<MixSeg>? _alternating16(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 32) return null;
  final slots = [
    for (var out = 24; out + 16 <= b.os; out += 32) _Slot(out, 16, MixLayer.instrumental, required: false)
  ];
  b.intro();
  if (!b.layout(8, b.os, slots) || b.otherCount == 0) return null;
  b.outro();
  final chunks = vocalChunksOf(o, 12);
  var i = 0;
  if (chunks.isNotEmpty) {
    for (var start = 8; start + 8 <= b.os; start += 32) {
      final (src, len) = chunks[i++ % chunks.length];
      b.placeVocal(start + 4, src, len, -5, before: math.min(start + 16, b.os));
    }
  }
  return b.finish();
}

List<MixSeg>? _dropBuild(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 40) return null;
  final chorus = chorusOf(o);
  if (chorus == null) return null;
  final t = snap4(8 + (b.os - 8) * 0.55);
  if (t - 8 < 16 || t + 8 > b.os) return null;
  b.intro();
  if (!b.layout(8, b.os, [_Slot(t - 8, 8, MixLayer.instrumental)])) return null;
  b.outro();
  final chunks = vocalChunksOf(o, 12);
  if (chunks.isNotEmpty) b.placeVocal(12, chunks.first.$1, chunks.first.$2, -7, before: t - 8);
  if (b.placeVocal(t, chorus.$1, math.min(chorus.$2, 12), -1, leadIn: 0, exact: true) != t) return null;
  return b.finish();
}

List<MixSeg>? _breakdown(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (b.os < 32) return null;
  final chunks = vocalChunksOf(o, 16);
  if (chunks.isEmpty) return null;
  final p = snap4(8 + (b.os - 8) * 0.5);
  if (p - 12 < 8 || b.os - (p + 4) < 8) return null;
  b.reserved.addAll([for (var k = p; k < p + 4; k++) k]);
  b.intro();
  b.layout(8, b.os, [if (b.auto) _Slot(p, 4, MixLayer.instrumental, required: false)]);
  b.outro();
  final first = chunks.first, last = chunks.last;
  if (b.placeVocal(12, first.$1, math.min(first.$2, (p - 12) ~/ 4 * 4), -7, before: p) < 0) return null;
  if (b.placeVocal(p + 4, last.$1, last.$2, -2) < 0) return null;
  return b.finish();
}

List<MixSeg>? _chorusHook(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 32) return null;
  final chorus = chorusOf(o);
  if (chorus == null) return null;
  final hook = chorus.$1;
  b.segs
    ..add(MixSeg(o, MixLayer.mix, hook, 0, 8, db: b.otherDb(MixLayer.mix, hook, 0, 8)))
    ..add(MixSeg(base, MixLayer.mix, 0, 8, 8));
  b
    ..baseBody(16, b.os)
    ..outro();
  final chunks = vocalChunksOf(o, 12).where((c) => c.$1 + c.$2 <= hook || c.$1 >= hook + 8).toList();
  if (chunks.isNotEmpty) {
    b.placeVocal(20, chunks.first.$1, chunks.first.$2, -7);
    if (chunks.length > 1) b.placeVocal(snap4(16 + (b.os - 16) * 0.6), chunks.last.$1, chunks.last.$2, -1);
  }
  return b.finish();
}

List<MixSeg>? _quickCuts(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 48) return null;
  const z0 = 16;
  final len = (b.os - 8 - z0) ~/ 8 * 8;
  if (len < 16) return null;
  final slots = [
    for (var out = z0; out + 4 <= z0 + len; out += 8) _Slot(out, 4, MixLayer.instrumental, required: false)
  ];
  b.intro();
  if (!b.layout(8, b.os, slots) || b.otherCount < 2) return null;
  b.outro();
  final chunks = vocalChunksOf(o, 8);
  if (chunks.isNotEmpty) b.placeVocal(z0 + len, chunks.last.$1, chunks.last.$2, -2);
  return b.finish();
}

List<MixSeg>? _slowBurn(MixSong base, MixSong o, MixMode mode) {
  if (mode != MixMode.automatic) return null;
  final os = outroStartOf(base.bars);
  if (os < 32) return null;
  final t = snap4(8 + (os - 8) * 0.6);
  final room = (os - 4 - t) ~/ 4 * 4;
  for (final len in [24, 16, 12, 8]) {
    if (len > room) continue;
    final b = _Builder(base, o, mode)..intro();
    if (!b.layout(8, b.os, [_Slot(t, len, MixLayer.mix, wantVocal: true)])) continue;
    b.outro();
    return b.finish();
  }
  return null;
}

List<MixSeg>? _bookend(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 32) return null;
  final e = b.os - 4, cl = b.n - e;
  if (o.bars < 16 + cl) return null;
  final open = b.pickO(MixLayer.instrumental, 8, ref: 8);
  if (open == null) return null;
  final inst = o.stem(MixLayer.instrumental);
  var close = o.bars - cl;
  final natural =
      (close - open).abs() >= math.max(8, cl) && [for (var k = close; k < o.bars; k++) inst.usable(k)].every((x) => x);
  if (natural) {
    b.used.add(close);
  } else {
    final p = b.pickO(MixLayer.instrumental, cl, ref: e);
    if (p == null) return null;
    close = p;
  }
  b.segs
    ..add(MixSeg(o, MixLayer.instrumental, open, 0, 8, db: b.otherDb(MixLayer.instrumental, open, 8, 8)))
    ..add(MixSeg(base, MixLayer.mix, 0, 8, 8));
  b.baseBody(16, e);
  b.segs.add(MixSeg(o, MixLayer.instrumental, close, e, cl, db: b.otherDb(MixLayer.instrumental, close, e, cl)));
  final chunks = vocalChunksOf(o, 12);
  if (chunks.isNotEmpty) {
    b.placeVocal(24, chunks.first.$1, chunks.first.$2, -6);
    if (chunks.length > 1) b.placeVocal(snap4(16 + (e - 16) * 0.55), chunks.last.$1, chunks.last.$2, -2);
  }
  return b.finish();
}

List<MixSeg>? _roleSwap(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 32) return null;
  final target = snap4(8 + (b.os - 8) * 0.3);
  final chunks = vocalChunksOf(base, 16).where((c) => c.$1 >= 12 && c.$1 + c.$2 <= b.os - 4).toList();
  if (chunks.isEmpty) return null;
  final (src, len) = chunks.firstWhere((c) => c.$1 >= target, orElse: () => chunks.first);
  b.intro();
  if (!b.layout(8, b.os, [_Slot(src, len, MixLayer.instrumental)])) return null;
  b.outro();
  final under = b.segs.firstWhere((s) => s.song == o);
  final inst = o.stem(MixLayer.instrumental).lufs(under.src, under.src + len) + o.gainDb + under.db;
  final voc = base.stem(MixLayer.vocals).lufs(src, src + len) + base.gainDb;
  b.segs.add(MixSeg(base, MixLayer.vocals, src, src, len, db: (inst - 2 - voc).clamp(-15.0, 9.0)));
  return b.finish();
}

List<MixSeg>? _callAndResponse(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 32) return null;
  final theirs = vocalChunksOf(o, 4, minLen: 4);
  final bv = vocalBarsOf(base);
  if (theirs.isEmpty) return null;
  b
    ..intro()
    ..baseBody(8, b.os)
    ..outro();
  var j = 0, mine = 0, other = 0;
  for (var out = 16, i = 0; out + 4 <= b.os - 4; out += 4, i++) {
    if (i.isEven) {
      if (![for (var k = out; k < out + 4; k++) bv[k]].every((x) => x)) continue;
      if (b.placeVocal(out, out, 4, 0, voice: base, leadIn: 0, minBars: 4, exact: true, db: 0) == out) mine++;
    } else {
      final (src, len) = theirs[j++ % theirs.length];
      if (b.placeVocal(out, src, len, -3, leadIn: 0, minBars: 4, exact: true) == out) other++;
    }
  }
  if (mine < 2 || other < 2) return null;
  return b.finish();
}

List<MixSeg>? _instrumentalBed(MixSong base, MixSong o, MixMode mode) {
  final b = _Builder(base, o, mode);
  if (!b.auto || b.os < 40) return null;
  final bl = b.os - 8 >= 48 ? 16 : 8;
  final total = 2 * bl + 4;
  var t = snap4(8 + (b.os - 8) * 0.3);
  if (t + total + 8 > b.os) t = snap4(b.os - 8 - total);
  if (t < 12) return null;
  b
    ..intro()
    ..baseBody(8, t);
  if (!b.otherAt(MixLayer.instrumental, t, bl)) return null;
  final stab = t + bl;
  b.segs.add(MixSeg(base, MixLayer.mix, stab, stab, 4));
  b.mixBars.addAll([for (var k = stab; k < stab + 4; k++) k]);
  if (!b.otherAt(MixLayer.instrumental, stab + 4, bl)) b.baseBody(stab + 4, stab + 4 + bl);
  b
    ..baseBody(t + total, b.os)
    ..outro();
  final chunks = vocalChunksOf(o, 12);
  if (chunks.isNotEmpty) {
    b.placeVocal(12, chunks.first.$1, chunks.first.$2, -7, before: t);
    b.placeVocal(t + total, chunks.last.$1, chunks.last.$2, -3);
  }
  return b.finish();
}
