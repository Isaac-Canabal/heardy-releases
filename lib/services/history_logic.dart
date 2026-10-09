import '../models/history_entry.dart';

/// Lógica pura del historial de escuchado.

/// Máximo de entradas que se conservan del historial de streaming.
const int maxStreamHistoryRows = 200;

/// Une local y streaming, más reciente primero. Una misma pista (mismo
/// [HistoryEntry.key]) sólo aparece una vez, con su reproducción más reciente.
/// Con [since], descarta lo anterior o igual a esa marca (historial "borrado").
List<HistoryEntry> mergeHistory(
  Iterable<HistoryEntry> local,
  Iterable<HistoryEntry> stream, {
  DateTime? since,
  int limit = maxStreamHistoryRows,
}) {
  final all = [...local, ...stream]..sort((a, b) => b.playedAt.compareTo(a.playedAt));
  final seen = <String>{};
  final out = <HistoryEntry>[];
  for (final e in all) {
    if (since != null && !e.playedAt.isAfter(since)) continue;
    if (!seen.add(e.key)) continue;
    out.add(e);
    if (out.length >= limit) break;
  }
  return out;
}

enum HistoryAgeKind { justNow, minutes, hours, yesterday, days, date }

class HistoryAge {
  final HistoryAgeKind kind;
  final int value;
  const HistoryAge(this.kind, [this.value = 0]);

  @override
  bool operator ==(Object other) => other is HistoryAge && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// Antigüedad relativa de [playedAt] respecto de [now]; la pantalla la traduce.
/// Hasta 6 días se cuentan días de calendario; después, fecha.
HistoryAge historyAge(DateTime playedAt, DateTime now) {
  final diff = now.difference(playedAt);
  if (diff.isNegative || diff.inMinutes < 1) return const HistoryAge(HistoryAgeKind.justNow);
  if (diff.inMinutes < 60) return HistoryAge(HistoryAgeKind.minutes, diff.inMinutes);
  final calendarDays = DateTime(now.year, now.month, now.day)
      .difference(DateTime(playedAt.year, playedAt.month, playedAt.day))
      .inDays;
  if (calendarDays == 0) return HistoryAge(HistoryAgeKind.hours, diff.inHours);
  if (calendarDays == 1) return const HistoryAge(HistoryAgeKind.yesterday);
  if (calendarDays < 7) return HistoryAge(HistoryAgeKind.days, calendarDays);
  return const HistoryAge(HistoryAgeKind.date);
}
