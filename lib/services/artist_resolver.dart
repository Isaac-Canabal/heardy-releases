import '../models/explore.dart';
import 'explore_logic.dart';

/// Busca el canal de un artista conocido sólo por nombre. Si el texto lista
/// varios créditos y ninguno de los resultados coincide con él, se reintenta
/// con el primer artista. Los errores de [search] se propagan.
Future<ExploreArtistHit?> resolveArtistHit(
  String name,
  Future<List<ExploreArtistHit>> Function(String query) search,
) async {
  final hits = await search(name);
  final target = normalizeArtistName(name);
  for (final h in hits) {
    if (h.channelId.isNotEmpty && normalizeArtistName(h.name) == target) return h;
  }
  final credits = splitArtistCredits(name);
  if (credits.length > 1) {
    final first = await search(credits.first);
    final hit = pickArtistHitForName(credits.first, first);
    if (hit != null) return hit;
  }
  return pickArtistHit(hits);
}
