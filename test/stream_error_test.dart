import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/stream_resolver.dart';

void main() {
  group('streamErrorVideoIdToEmit', () {
    test('returns the videoId for a stream item not yet reported', () {
      expect(
        streamErrorVideoIdToEmit({'isStream': true, 'videoId': 'abc'}, null),
        'abc',
      );
    });

    test('does not report the same videoId twice', () {
      expect(
        streamErrorVideoIdToEmit({'isStream': true, 'videoId': 'abc'}, 'abc'),
        isNull,
      );
    });

    test('reports a different videoId after a previous one', () {
      expect(
        streamErrorVideoIdToEmit({'isStream': true, 'videoId': 'def'}, 'abc'),
        'def',
      );
    });

    test('ignores local items and missing extras', () {
      expect(streamErrorVideoIdToEmit({'filePath': 'x'}, null), isNull);
      expect(streamErrorVideoIdToEmit(null, null), isNull);
    });

    test('ignores stream items without a usable videoId', () {
      expect(streamErrorVideoIdToEmit({'isStream': true}, null), isNull);
      expect(streamErrorVideoIdToEmit({'isStream': true, 'videoId': ''}, null), isNull);
    });
  });

  group('findStreamErrorTrack', () {
    test('finds the remembered track by id', () {
      final tracks = [_track('a'), _track('b')];
      expect(findStreamErrorTrack(tracks, 'b')?.id, 'b');
    });

    test('returns null when it is no longer available', () {
      expect(findStreamErrorTrack([_track('a')], 'z'), isNull);
    });
  });
}

RemoteTrack _track(String id) => RemoteTrack(
      id: id,
      title: 't',
      artist: 'a',
      album: null,
      durationSeconds: 1,
      thumbnailUrl: '',
      sourceUrl: '',
    );
