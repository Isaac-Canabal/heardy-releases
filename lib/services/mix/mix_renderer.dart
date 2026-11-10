// Render del plan del Mix DJ, portado de tool/mix_spike/bin/render3.dart: la
// base suena desde su muestra 0 a su tempo nativo; la otra canción se estira
// (WSOLA). Cortes de ≤1 pulso centrados en el downbeat, grave saliente fuera
// 1.5 pulsos antes, voz entrante adelantada desde -12 dB.
import 'dart:math' as math;
import 'dart:typed_data';

import 'mix_analysis.dart' show MixTick;
import 'mix_dsp.dart';
import 'mix_planner.dart';
import 'mix_song.dart';
import 'mix_types.dart';

/// Bus renderizado (sin master) y la geometría que hace falta para el informe.
class RenderedBus {
  const RenderedBus(this.l, this.r, {required this.startSample, required this.offset, required this.targetBar});
  final Float32List l, r;

  /// Muestras de silencio inicial recortadas.
  final int startSample;

  /// Posición del downbeat 0 de la base en el bus.
  final int offset;

  /// Compás del plan, en muestras.
  final int targetBar;

  /// Muestra de la salida en la que empieza el compás [bar] del plan.
  int sampleOfBar(int bar) => offset + bar * targetBar - startSample;
}

/// [soloSong] solo sirve para medir: suma únicamente lo que aporta esa canción,
/// con los pesos del plan completo, y no recorta silencios (así dos renders en
/// solitario quedan alineados muestra a muestra).
RenderedBus renderPlan(List<MixSeg> segs, MixSong base,
    {double? tempoBpm,
    double semitones = 0,
    MixTick? tick,
    MixBandSplit bandSplit = MixBandSplit.linkwitzRiley4,
    String? soloSong}) {
  const sr = kMixSampleRate;
  // Tempo del plan: el nativo de la base salvo que el estiramiento se reparta
  // entre las dos canciones; entonces la base también se escala (WSOLA).
  final tempo = tempoBpm ?? base.bpm;
  final baseScale = base.bpm / tempo;
  final baseStretched = (baseScale - 1).abs() > 1e-9;
  final targetBar = (240 / tempo * sr).round();
  final totalBars = base.bars;
  final tailExtra = base.stem(MixLayer.mix).length - base.barSample(totalBars);
  final off = (base.downbeat * sr * baseScale).round(); // la base suena desde su muestra 0
  final int len = totalBars * targetBar + (math.max<int>(0, tailExtra) * baseScale).round() + off;
  final busL = Float32List(math.max(0, len)), busR = Float32List(math.max(0, len));
  final pulse = targetBar / 8; // pulso real (8 por compás a medio tiempo)
  final hp = (pulse / 2).round(), bassLead = (1.5 * pulse).round(), ramp = (0.015 * sr).round();
  var done = 0;
  for (final s in segs) {
    final song = s.song;
    if (soloSong != null && song.id != soloSong) {
      tick?.call(++done / segs.length);
      continue;
    }
    final st = song.stem(s.kind);
    // El grave solo se adelanta a salir si lo siguiente es otra canción.
    final nextOther = s.kind != MixLayer.vocals &&
        segs.any((x) => x.kind != MixLayer.vocals && x.out == s.out + s.bars && x.song != song);
    final prevOther = s.kind != MixLayer.vocals &&
        segs.any((x) => x.kind != MixLayer.vocals && x.out + x.bars == s.out && x.song != song);
    final first = s.out == 0, last = s.toEnd;
    final preBars = first ? 0.0 : (s.kind == MixLayer.vocals ? s.leadIn : hp / targetBar);
    final postBars = last ? 0.0 : hp / targetBar;
    final s0 = first && song == base ? 0 : song.barSample(s.src - preBars);
    final s1 = last ? st.length : song.barSample(s.src + s.bars + postBars);
    final o0 = first && song == base ? 0 : off + ((s.out - preBars) * targetBar).round();
    Clip clip;
    if (song == base) {
      clip = slice(st.l, st.r, s0, s1);
      if (baseStretched) clip = wsola(clip, (clip.length * baseScale).round());
    } else {
      final outLen = ((s.bars + preBars + postBars) * targetBar).round();
      clip = stretchPitch(slice(st.l, st.r, s0, s1), outLen, semitones);
    }
    if (s.kind == MixLayer.vocals) {
      final h1 = Biquad.highpass(130, sr), h2 = Biquad.highpass(130, sr);
      clip = Clip(h2.apply(h1.apply(clip.l)), h2.apply(h1.apply(clip.r)));
    }
    Clip? low, high;
    if (s.kind != MixLayer.vocals) {
      (low, high) = splitBands(clip, sr, mode: bandSplit);
    }
    final g = fromDb(song.gainDb + s.db);
    final startB = first ? 0 : (preBars * targetBar).round(); // índice del downbeat de entrada
    final endB = startB + (first && song == base ? off : 0) + s.bars * targetBar; // downbeat de salida
    final tw = TransitionWeights(
      first: first,
      last: last,
      vocal: s.kind == MixLayer.vocals,
      prevOther: prevOther,
      nextOther: nextOther,
      startB: startB,
      endB: endB,
      hp: hp,
      bassLead: bassLead,
      ramp: ramp,
    );
    for (var i = 0; i < clip.length; i++) {
      final o = o0 + i;
      if (o < 0 || o >= len) continue;
      tw.at(i);
      final w = tw.w, wb = tw.wb;
      if (low != null && high != null) {
        busL[o] += g * (high.l[i] * w + low.l[i] * wb);
        busR[o] += g * (high.r[i] * w + low.r[i] * wb);
      } else {
        busL[o] += g * clip.l[i] * w;
        busR[o] += g * clip.r[i] * w;
      }
    }
    tick?.call(++done / segs.length);
  }
  if (soloSong != null) {
    return RenderedBus(busL, busR, startSample: 0, offset: off, targetBar: targetBar);
  }
  // Recorta el silencio final de la fuente.
  var end = busL.length;
  while (end > 1 && busL[end - 1].abs() < 1e-5 && busR[end - 1].abs() < 1e-5) {
    end--;
  }
  // Y el silencio inicial (ventanas de 50 ms 36 dB por debajo del pico, que tras
  // el master quedarían por debajo de -40 dBFS), para empezar sin hueco.
  var startS = 0;
  {
    var pk = 1e-9;
    for (var i = 0; i < end; i++) {
      pk = math.max(pk, busL[i].abs());
    }
    final w = (0.05 * sr).round();
    while (startS + w < end) {
      var e = 0.0;
      for (var i = startS; i < startS + w; i++) {
        e += busL[i] * busL[i] + busR[i] * busR[i];
      }
      if (dbOf(math.sqrt(e / (2 * w)) / pk) > -36) break;
      startS += w;
    }
  }
  return RenderedBus(
    Float32List.fromList(Float32List.sublistView(busL, startS, end)),
    Float32List.fromList(Float32List.sublistView(busR, startS, end)),
    startSample: startS,
    offset: off,
    targetBar: targetBar,
  );
}

/// Pesos de un tramo en la muestra i del clip: [w] para la banda alta y [wb]
/// para el grave (< 150 Hz).
class TransitionWeights {
  TransitionWeights({
    required this.first,
    required this.last,
    required this.vocal,
    required this.prevOther,
    required this.nextOther,
    required this.startB,
    required this.endB,
    required this.hp,
    required this.bassLead,
    required this.ramp,
  });

  /// Primer tramo (empieza en la muestra 0) o el que sigue hasta el final.
  final bool first, last;
  final bool vocal;

  /// El tramo anterior / siguiente (no de voz) es de la otra canción.
  final bool prevOther, nextOther;

  /// Índices del clip del downbeat de entrada y del de salida.
  final int startB, endB;

  /// Medio pulso (el corte dura un pulso), adelanto del grave saliente y rampa.
  final int hp, bassLead, ramp;
  double w = 1, wb = 1;

  void at(int i) {
    var w = 1.0, wb = 1.0;
    if (!first) {
      if (vocal) {
        // Entrada adelantada: de -12 dB al nivel pleno en el downbeat.
        if (i < startB) w = fromDb(-12 + 12 * i / startB) * math.min(1.0, i / ramp);
      } else {
        // Corte de ≤1 pulso centrado en el downbeat; el grave entra en él.
        // Entre stems de la misma canción (señales coherentes) el fundido es
        // lineal en ambas bandas, para no sumar +3 dB.
        if (prevOther) {
          if (i < 2 * hp) w = math.sin(math.pi / 2 * i / (2 * hp));
          wb = i < startB ? 0.0 : math.min(1.0, (i - startB) / ramp);
        } else if (i < 2 * hp) {
          w = i / (2 * hp);
          wb = w;
        }
      }
    }
    if (!last) {
      if (i >= endB - hp) {
        final t = math.min(1.0, (i - (endB - hp)) / (2 * hp));
        if (!vocal && !nextOther) {
          w *= 1 - t;
          wb *= 1 - t;
        } else {
          w *= math.cos(math.pi / 2 * t);
        }
      }
      // El grave saliente se va 1.5 pulsos antes del corte.
      if (!vocal && nextOther) {
        final cut = endB - bassLead;
        if (i >= cut) wb = 0;
        if (i < cut && i >= cut - ramp) wb *= (cut - i) / ramp;
      }
    }
    this.w = w;
    this.wb = wb;
  }
}

/// Huecos: ventanas de 50 ms por debajo de -40 dBFS antes de los últimos 5 s,
/// fusionadas en tramos (inicio, fin) en segundos.
List<(double, double)> findGaps(Float32List l, Float32List r, {double thresholdDb = -40, double tailSec = 5}) {
  const sr = kMixSampleRate;
  final w50 = (0.05 * sr).round();
  final end = l.length;
  final gaps = <(double, double)>[];
  for (var s0 = 0; s0 + w50 <= end - tailSec * sr; s0 += w50) {
    var e = 0.0;
    for (var i = s0; i < s0 + w50; i++) {
      e += 0.5 * (l[i] * l[i] + r[i] * r[i]);
    }
    if (dbOf(math.sqrt(e / w50)) < thresholdDb) {
      final t = s0 / sr;
      if (gaps.isNotEmpty && t - gaps.last.$2 < 0.06) {
        gaps[gaps.length - 1] = (gaps.last.$1, t + 0.05);
      } else {
        gaps.add((t, t + 0.05));
      }
    }
  }
  return gaps;
}
