import '../models/song.dart';

enum SmartListKind { mostPlayed, recentlyAdded, neverPlayed, forgotten }

const Duration forgottenThreshold = Duration(days: 90);
const int smartListLimit = 100;

class SongPlayStat {
  final Song song;
  final int playCount;
  final DateTime? lastPlayed;

  const SongPlayStat({required this.song, required this.playCount, this.lastPlayed});
}

int _byNewestAdded(SongPlayStat a, SongPlayStat b) =>
    b.song.downloadDate.compareTo(a.song.downloadDate);

List<SongPlayStat> buildSmartList(
  SmartListKind kind,
  List<SongPlayStat> stats,
  DateTime now, {
  int limit = smartListLimit,
}) {
  final List<SongPlayStat> result;
  switch (kind) {
    case SmartListKind.mostPlayed:
      result = stats.where((s) => s.playCount > 0).toList()
        ..sort((a, b) {
          final byCount = b.playCount.compareTo(a.playCount);
          if (byCount != 0) return byCount;
          final la = a.lastPlayed, lb = b.lastPlayed;
          if (la == null || lb == null) return 0;
          return lb.compareTo(la);
        });
    case SmartListKind.recentlyAdded:
      result = [...stats]..sort(_byNewestAdded);
    case SmartListKind.neverPlayed:
      result = stats.where((s) => s.playCount == 0).toList()..sort(_byNewestAdded);
    case SmartListKind.forgotten:
      final cutoff = now.subtract(forgottenThreshold);
      result = stats.where((s) {
        final last = s.lastPlayed;
        return s.playCount > 0 && last != null && !last.isAfter(cutoff);
      }).toList()
        ..sort((a, b) {
          final byCount = b.playCount.compareTo(a.playCount);
          if (byCount != 0) return byCount;
          return a.lastPlayed!.compareTo(b.lastPlayed!);
        });
  }
  return result.length > limit ? result.sublist(0, limit) : result;
}
