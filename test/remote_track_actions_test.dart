import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/remote_track_actions.dart';

void main() {
  test('remoteAccessGate: primero servidor, luego sesión', () {
    expect(remoteAccessGate(hasServer: false, isSignedIn: false), RemoteAccessGate.noServer);
    expect(remoteAccessGate(hasServer: false, isSignedIn: true), RemoteAccessGate.noServer);
    expect(remoteAccessGate(hasServer: true, isSignedIn: false), RemoteAccessGate.needsLogin);
    expect(remoteAccessGate(hasServer: true, isSignedIn: true), RemoteAccessGate.ok);
  });

  test('formatTrackDuration es mm:ss', () {
    expect(formatTrackDuration(5), '0:05');
    expect(formatTrackDuration(185), '3:05');
    expect(formatTrackDuration(3723), '62:03');
  });
}
