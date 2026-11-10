// Nombre y artista automáticos de un mix de Heardy Mixer. Puro y determinista:
// el mismo par de títulos da siempre el mismo nombre, que el usuario puede
// editar antes de guardarlo.
const kMaxMixNameLength = 40;
const kMaxMixArtistLength = 80;
const kFallbackMixName = 'Heardy Mix';

final _bracketed = RegExp(r'\s*[\(\[\{][^\)\]\}]*[\)\]\}]');
final _featuring = RegExp(r'\s+(feat\.?|ft\.?|featuring|prod\.?)\s+.*$', caseSensitive: false);
final _trailingNoise = RegExp(
  r'\s*[-–—|:]\s*(official.*|video.*|audio.*|lyrics?.*|letra.*|visualizer.*|remaster.*|hd|4k|mv)\s*$',
  caseSensitive: false,
);
final _spaces = RegExp(r'\s+');

/// Título sin "(Official Video)", "[Audio]", "feat. …", "| Lyrics" ni el
/// prefijo "Artista - " típico de YouTube.
String cleanMixTitle(String title) {
  var t = title.replaceAll(_bracketed, ' ');
  final pipe = t.indexOf(' | ');
  if (pipe >= 0) t = t.substring(0, pipe);
  final dash = t.indexOf(' - ');
  if (dash >= 0 && dash + 3 < t.length) t = t.substring(dash + 3);
  t = t.replaceAll(_trailingNoise, '').replaceAll(_featuring, '');
  return t.replaceAll(_spaces, ' ').trim();
}

/// Mitad inicial de A y mitad final de B: por palabras si alguno tiene más de
/// una, por letras si los dos son una sola palabra ("Believer" + "Thunder" =
/// "Belinder").
String combinedMixName(String titleA, String titleB) {
  final a = cleanMixTitle(titleA), b = cleanMixTitle(titleB);
  if (a.isEmpty && b.isEmpty) return kFallbackMixName;
  if (a.isEmpty || b.isEmpty) return _bound(a.isEmpty ? b : a);
  final wa = a.split(' '), wb = b.split(' ');
  String name;
  if (wa.length == 1 && wb.length == 1) {
    final head = a.substring(0, (a.length + 1) ~/ 2);
    final tail = b.substring(b.length ~/ 2).toLowerCase();
    name = head + tail;
  } else {
    final head = wa.take((wa.length + 1) ~/ 2);
    final tail = wb.skip(wb.length ~/ 2);
    name = [...head, ...tail].join(' ');
  }
  final lower = name.toLowerCase();
  if (lower == a.toLowerCase() || lower == b.toLowerCase()) name = '$a × $b';
  return _bound(name);
}

/// Corta en el último espacio que quepa; una sola palabra larguísima se corta
/// a secas.
String _bound(String s, [int max = kMaxMixNameLength]) {
  if (s.length <= max) return s;
  final cut = s.substring(0, max);
  final space = cut.lastIndexOf(' ');
  final out = (space > 0 ? cut.substring(0, space) : cut).trim();
  return out.endsWith('×') ? out.substring(0, out.length - 1).trim() : out;
}

/// "Artista A × Artista B"; si uno falta, el otro solo.
String combinedMixArtist(String artistA, String artistB) {
  final a = artistA.trim(), b = artistB.trim();
  if (a.isEmpty || b.isEmpty) return _bound(a.isEmpty ? b : a, kMaxMixArtistLength);
  if (a.toLowerCase() == b.toLowerCase()) return _bound(a, kMaxMixArtistLength);
  return _bound('$a × $b', kMaxMixArtistLength);
}

const kMaxEditedMixNameLength = 80;

/// Un nombre editado a mano: espacios colapsados y como mucho 80 caracteres.
/// `null` si queda vacío (se conserva el anterior).
String? normalizeMixName(String name) {
  final clean = name.replaceAll(_spaces, ' ').trim();
  if (clean.isEmpty) return null;
  return clean.length > kMaxEditedMixNameLength ? clean.substring(0, kMaxEditedMixNameLength).trim() : clean;
}
