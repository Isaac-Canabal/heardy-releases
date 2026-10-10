class LyricWord {
  final Duration start;
  final String text;
  const LyricWord(this.start, this.text);
}

class ParsedLyricText {
  final String text;
  final List<LyricWord> words;
  final Duration? end;
  const ParsedLyricText(this.text, this.words, this.end);
}

final _wordTag = RegExp(r'<(\d+):(\d+)(?:\.(\d+))?>');

Duration _tagTime(RegExpMatch m) {
  final msStr = m.group(3) ?? '0';
  final multiplier = msStr.length == 2 ? 10 : (msStr.length == 1 ? 100 : 1);
  return Duration(
    minutes: int.parse(m.group(1)!),
    seconds: int.parse(m.group(2)!),
    milliseconds: int.parse(msStr) * multiplier,
  );
}

/// Separa el texto de una línea LRC de sus etiquetas `<mm:ss.xx>` (LRC
/// enriquecido). Sin etiquetas devuelve el texto tal cual y `words` vacío; la
/// etiqueta final sin texto marca el fin de la última palabra.
ParsedLyricText parseLyricText(String raw, Duration lineStart) {
  final matches = _wordTag.allMatches(raw).toList();
  if (matches.isEmpty) return ParsedLyricText(raw.trim(), const [], null);

  final words = <LyricWord>[];
  Duration? end;

  final leading = raw.substring(0, matches.first.start);
  if (leading.trim().isNotEmpty) words.add(LyricWord(lineStart, leading));

  for (var i = 0; i < matches.length; i++) {
    final textEnd = i + 1 < matches.length ? matches[i + 1].start : raw.length;
    final segment = raw.substring(matches[i].end, textEnd);
    if (segment.isEmpty) {
      if (i == matches.length - 1) end = _tagTime(matches[i]);
      continue;
    }
    words.add(LyricWord(_tagTime(matches[i]), segment));
  }

  if (words.isEmpty) return const ParsedLyricText('', [], null);
  final text = words.map((w) => w.text).join().trim();
  return ParsedLyricText(text, words, end);
}

/// Palabra activa y fracción (0..1) recorrida de ella en [position]. La
/// última palabra termina en [lineEnd] (cierre explícito o inicio de la línea
/// siguiente). `index == -1` si aún no empezó ninguna.
({int index, double progress}) wordProgressAt(
  List<LyricWord> words,
  Duration lineEnd,
  Duration position,
) {
  var index = -1;
  for (var i = 0; i < words.length; i++) {
    if (words[i].start <= position) {
      index = i;
    } else {
      break;
    }
  }
  if (index == -1) return (index: -1, progress: 0.0);
  final from = words[index].start;
  final to = index + 1 < words.length ? words[index + 1].start : lineEnd;
  final span = (to - from).inMicroseconds;
  if (span <= 0) return (index: index, progress: 1.0);
  final p = (position - from).inMicroseconds / span;
  return (index: index, progress: p.clamp(0.0, 1.0));
}
