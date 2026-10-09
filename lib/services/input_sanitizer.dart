const int maxSearchInputLength = 200;
const int maxUsernameInputLength = 64;
const int maxUrlInputLength = 2048;

bool _isInvisibleOrControl(int r) {
  if (r < 0x20 || (r >= 0x7F && r <= 0x9F)) return true;
  return r == 0x061C ||
      r == 0x200B ||
      r == 0x200C ||
      r == 0x200E ||
      r == 0x200F ||
      (r >= 0x202A && r <= 0x202E) ||
      r == 0x2060 ||
      (r >= 0x2066 && r <= 0x2069) ||
      r == 0xFEFF;
}

bool _isWhitespace(int r) => r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D || r == 0xA0 || r == 0x2028 || r == 0x2029;

/// Limpia texto escrito por el usuario antes de enviarlo al servidor: quita
/// caracteres de control, de dirección y de ancho cero (salvo el unidor de
/// emojis entre símbolos), colapsa espacios y recorta a [maxLength] puntos de
/// código. Conserva acentos, ñ, emojis y comillas.
String sanitizeSearchInput(String input, {int maxLength = maxSearchInputLength}) {
  final runes = input.runes.toList();
  final out = <int>[];
  var pendingSpace = false;
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (_isWhitespace(r)) {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (r == 0x200D) {
      final joinsEmoji = out.isNotEmpty && out.last >= 0x2190 && i + 1 < runes.length && runes[i + 1] >= 0x2190;
      if (!joinsEmoji) continue;
    } else if (_isInvisibleOrControl(r)) {
      continue;
    }
    if (pendingSpace) {
      out.add(0x20);
      pendingSpace = false;
    }
    out.add(r);
  }
  if (out.length > maxLength) out.length = maxLength;
  while (out.isNotEmpty && out.last == 0x20) {
    out.removeLast();
  }
  return String.fromCharCodes(out);
}

String sanitizeUsernameInput(String input) =>
    sanitizeSearchInput(input, maxLength: maxUsernameInputLength);

String sanitizeUrlInput(String input) => sanitizeSearchInput(input, maxLength: maxUrlInputLength);

const int minUserSearchLength = 3;
const Duration userSearchCooldown = Duration(milliseconds: 400);

/// Evita lanzar una búsqueda de usuarios con un texto demasiado corto o justo
/// después de otra (doble toque, Enter repetido).
bool canRunUserSearch(String sanitized, DateTime? lastRun, DateTime now) {
  if (sanitized.runes.length < minUserSearchLength) return false;
  return lastRun == null || now.difference(lastRun) >= userSearchCooldown;
}
