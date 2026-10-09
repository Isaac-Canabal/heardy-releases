import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/models/history_entry.dart';
import 'package:heardy/services/history_logic.dart';

HistoryEntry _e(String id, DateTime at, {bool stream = true, String? videoId}) => HistoryEntry(
      isStream: stream,
      songId: stream ? '' : id,
      videoId: stream ? id : videoId,
      title: 't$id',
      artist: 'a',
      playedAt: at,
    );

void main() {
  final t0 = DateTime(2026, 10, 9, 12);

  group('mergeHistory', () {
    test('une local y streaming, más reciente primero', () {
      final merged = mergeHistory(
        [_e('l1', t0.subtract(const Duration(hours: 2)), stream: false)],
        [_e('s1', t0), _e('s2', t0.subtract(const Duration(hours: 5)))],
      );
      expect([for (final e in merged) e.title], ['ts1', 'tl1', 'ts2']);
    });

    test('una misma pista (local descargada y stream) sólo sale con su reproducción más reciente', () {
      final merged = mergeHistory(
        [_e('l1', t0, stream: false, videoId: 'vid')],
        [_e('vid', t0.subtract(const Duration(days: 1)))],
      );
      expect(merged, hasLength(1));
      expect(merged.single.isStream, isFalse);
    });

    test('since descarta lo anterior o igual y limit corta', () {
      final merged = mergeHistory(
        const [],
        [_e('a', t0), _e('b', t0.subtract(const Duration(hours: 1))), _e('c', t0.subtract(const Duration(hours: 2)))],
        since: t0.subtract(const Duration(hours: 2)),
        limit: 1,
      );
      expect([for (final e in merged) e.videoId], ['a']);
    });
  });

  group('historyAge', () {
    test('rangos relativos', () {
      HistoryAge age(Duration d) => historyAge(t0.subtract(d), t0);
      expect(age(const Duration(seconds: 20)), const HistoryAge(HistoryAgeKind.justNow));
      expect(age(const Duration(minutes: 5)), const HistoryAge(HistoryAgeKind.minutes, 5));
      expect(age(const Duration(hours: 3)), const HistoryAge(HistoryAgeKind.hours, 3));
      expect(age(const Duration(hours: 20)), const HistoryAge(HistoryAgeKind.yesterday));
      expect(age(const Duration(days: 3)), const HistoryAge(HistoryAgeKind.days, 3));
      expect(age(const Duration(days: 12)), const HistoryAge(HistoryAgeKind.date));
      expect(historyAge(t0.add(const Duration(minutes: 1)), t0), const HistoryAge(HistoryAgeKind.justNow));
    });
  });

  test('toRemoteTrack arma la URL de YouTube', () {
    final track = _e('abc', t0).toRemoteTrack();
    expect(track.id, 'abc');
    expect(track.sourceUrl, 'https://www.youtube.com/watch?v=abc');
  });
}
