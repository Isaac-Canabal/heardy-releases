import 'dart:math';

/// Lógica pura del aleatorio de escritorio. En Windows el player (mpv) no
/// aplica `shuffleIndices` de just_audio, así que el handler reordena la cola
/// real y deja que siguiente/anterior/auto-avance sigan siendo lineales.

/// Copia de [items] con el elemento de [currentIndex] primero y el resto
/// barajado. Con un índice fuera de rango se baraja todo.
List<T> shuffleKeepingCurrent<T>(List<T> items, int currentIndex, Random random) {
  final hasCurrent = currentIndex >= 0 && currentIndex < items.length;
  final rest = <T>[
    for (var i = 0; i < items.length; i++)
      if (!hasCurrent || i != currentIndex) items[i],
  ]..shuffle(random);
  return hasCurrent ? [items[currentIndex], ...rest] : rest;
}

/// Orden original de [original] restringido a lo que sigue en [current], y al
/// final lo añadido mientras estaba barajado (en el orden de [current]).
List<T> restoreOriginalOrder<T>(
  List<T> current,
  List<T> original,
  String Function(T) key,
) {
  final present = {for (final item in current) key(item)};
  final seen = <String>{};
  final out = <T>[];
  for (final item in original) {
    final k = key(item);
    if (present.contains(k) && seen.add(k)) out.add(item);
  }
  for (final item in current) {
    if (seen.add(key(item))) out.add(item);
  }
  return out;
}

/// Mismos ids y en el mismo orden.
bool sameQueueIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
