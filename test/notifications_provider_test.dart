// Verifica NotificationsProvider contra un CloudSource y un AppUpdateSource
// falsos, sin red — mismo patrón que sync_provider_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/models/app_notification.dart';
import 'package:heardy/providers/notifications_provider.dart';
import 'package:heardy/services/app_update_source.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/system_notifications.dart';

class _FakeCloudSource implements CloudSource {
  FriendsList friends = const FriendsList(friends: [], incoming: [], outgoing: []);
  bool throwOnGetFriends = false;
  final List<String> accepted = [];
  final List<String> rejected = [];

  @override
  Future<FriendsList> getFriends() async {
    if (throwOnGetFriends) {
      throw const CloudSourceException(CloudSourceErrorKind.unauthorized, 'sin sesión');
    }
    return friends;
  }

  @override
  Future<void> acceptFriendRequest(String username) async => accepted.add(username);

  @override
  Future<void> rejectOrCancelFriendRequest(String username) async => rejected.add(username);

  @override
  Future<CloudAccount> getAccount() => throw UnimplementedError();
  @override
  Future<String> setUsername(String username) => throw UnimplementedError();
  @override
  Future<UserLookupResult> lookupUser(String username) => throw UnimplementedError();
  @override
  Future<String> sendFriendRequest(String username) => throw UnimplementedError();
  @override
  Future<void> removeFriend(String username) => throw UnimplementedError();
  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) =>
      throw UnimplementedError();
  @override
  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  }) =>
      throw UnimplementedError();
  @override
  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes}) =>
      throw UnimplementedError();
  @override
  Future<CloudHistoryPage> getHistory({String? cursor, int limit = 500}) => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period}) =>
      throw UnimplementedError();
  @override
  Future<void> putPresence({required String songId, required int expiresInSeconds}) =>
      throw UnimplementedError();
  @override
  Future<void> clearPresence() => throw UnimplementedError();
  @override
  Future<bool> setShareNowPlaying(bool enabled) => throw UnimplementedError();
  @override
  Future<void> deleteAccountData() => throw UnimplementedError();
}

class _FakeUpdateSource implements AppUpdateSource {
  AppUpdateInfo? release;

  @override
  Future<AppUpdateInfo?> getLatestRelease() async => release;
}

class _FakeSystemNotifications implements SystemNotifications {
  final List<String> shown = [];
  final List<String> updateDownloadUrls = [];
  final List<String> updateViewUrls = [];

  @override
  Future<void> show({required int id, required String title, required String body}) async {
    shown.add('$title|$body');
  }

  @override
  Future<void> showUpdateAvailable({
    required int id,
    required String title,
    required String body,
    required String downloadUrl,
    required String downloadLabel,
    required String viewUrl,
    required String viewLabel,
  }) async {
    shown.add('$title|$body');
    updateDownloadUrls.add(downloadUrl);
    updateViewUrls.add(viewUrl);
  }
}

Future<PackageInfo> _fakePackageInfo(String version) async => PackageInfo(
      appName: 'Heardy',
      packageName: 'com.heardy.app',
      version: version,
      buildNumber: '1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCloudSource cloudSource;
  late _FakeUpdateSource updateSource;
  late _FakeSystemNotifications systemNotifications;

  setUp(() {
    // Por test, no una vez para todo el archivo — si no, lo que un test
    // persiste (p. ej. "ya se avisó de v1.1.0") se filtra al siguiente que
    // reutilice el mismo tag/usuario y su notificación nunca dispara.
    SharedPreferences.setMockInitialValues({});
    cloudSource = _FakeCloudSource();
    updateSource = _FakeUpdateSource();
    systemNotifications = _FakeSystemNotifications();
  });

  NotificationsProvider buildProvider({String localVersion = '1.0.0'}) => NotificationsProvider(
        cloudSource: cloudSource,
        updateSource: updateSource,
        packageInfo: () => _fakePackageInfo(localVersion),
        systemNotifications: systemNotifications,
      );

  group('refresh', () {
    test('sin solicitudes ni release nuevo, la lista queda vacía', () async {
      final provider = buildProvider();
      await provider.refresh();
      expect(provider.items, isEmpty);
      expect(provider.unreadCount, 0);
      expect(provider.hasLoadedOnce, isTrue);
    });

    test('una solicitud de amistad entrante se refleja como notificación', () async {
      cloudSource.friends = const FriendsList(
        friends: [],
        incoming: [FriendEntry(username: 'juan')],
        outgoing: [],
      );
      final provider = buildProvider();
      await provider.refresh();
      expect(provider.items, hasLength(1));
      expect(provider.items.single.type, AppNotificationType.friendRequest);
      expect(provider.items.single.friendUsername, 'juan');
    });

    test('sin cuenta vinculada (getFriends falla) no rompe el refresco', () async {
      cloudSource.throwOnGetFriends = true;
      final provider = buildProvider();
      await provider.refresh();
      expect(provider.items, isEmpty);
      expect(provider.hasLoadedOnce, isTrue);
    });

    test('un release más nuevo que la versión instalada avisa', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.1.0', name: 'Heardy 1.1.0', htmlUrl: 'https://x', body: 'novedades');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();
      expect(provider.items, hasLength(1));
      expect(provider.items.single.type, AppNotificationType.appUpdate);
    });

    test('un release igual o más viejo que la versión instalada no avisa', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.0.0', name: 'Heardy 1.0.0', htmlUrl: 'https://x', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();
      expect(provider.items, isEmpty);
    });
  });

  group('dismissUpdate', () {
    test('descartar una versión la quita de la lista y no vuelve a avisar tras otro refresh', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.1.0', name: 'Heardy 1.1.0', htmlUrl: 'https://x', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();
      expect(provider.items, hasLength(1));

      await provider.dismissUpdate('v1.1.0');
      expect(provider.items, isEmpty);

      await provider.refresh();
      expect(provider.items, isEmpty, reason: 'la misma versión descartada no debe volver a avisar');
    });

    test('una versión más nueva todavía SÍ avisa aunque se haya descartado otra antes', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.1.0', name: 'Heardy 1.1.0', htmlUrl: 'https://x', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();
      await provider.dismissUpdate('v1.1.0');

      updateSource.release =
          const AppUpdateInfo(tag: 'v1.2.0', name: 'Heardy 1.2.0', htmlUrl: 'https://x', body: '');
      await provider.refresh();
      expect(provider.items, hasLength(1));
      expect(provider.items.single.updateInfo!.tag, 'v1.2.0');
    });
  });

  group('notificación real del sistema', () {
    test('una solicitud de amistad nueva dispara una notificación del sistema', () async {
      cloudSource.friends = const FriendsList(
        friends: [],
        incoming: [FriendEntry(username: 'juan')],
        outgoing: [],
      );
      final provider = buildProvider();
      await provider.refresh();

      expect(systemNotifications.shown, hasLength(1));
      expect(systemNotifications.shown.single, contains('@juan'));
    });

    test('la misma solicitud pendiente no repite la notificación en otro refresh', () async {
      cloudSource.friends = const FriendsList(
        friends: [],
        incoming: [FriendEntry(username: 'juan')],
        outgoing: [],
      );
      final provider = buildProvider();
      await provider.refresh();
      await provider.refresh();

      expect(systemNotifications.shown, hasLength(1));
    });

    test('un release nuevo dispara una notificación del sistema una sola vez', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.1.0', name: 'Heardy 1.1.0', htmlUrl: 'https://x', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();
      await provider.refresh();

      expect(systemNotifications.shown, hasLength(1));
    });

    test('la notificación de versión nueva lleva la URL de descarga y la del release', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.1.0', name: 'Heardy 1.1.0', htmlUrl: 'https://x/releases/v1.1.0', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();

      expect(systemNotifications.updateDownloadUrls.single, contains('v1.1.0'));
      expect(systemNotifications.updateViewUrls.single, 'https://x/releases/v1.1.0');
    });

    test('un release igual o más viejo no dispara notificación del sistema', () async {
      updateSource.release =
          const AppUpdateInfo(tag: 'v1.0.0', name: 'Heardy 1.0.0', htmlUrl: 'https://x', body: '');
      final provider = buildProvider(localVersion: '1.0.0');
      await provider.refresh();

      expect(systemNotifications.shown, isEmpty);
    });
  });

  group('respondToFriendRequest', () {
    test('aceptar llama a CloudSource y refresca la lista', () async {
      cloudSource.friends = const FriendsList(
        friends: [],
        incoming: [FriendEntry(username: 'juan')],
        outgoing: [],
      );
      final provider = buildProvider();
      await provider.refresh();

      cloudSource.friends = const FriendsList(friends: [], incoming: [], outgoing: []);
      await provider.respondToFriendRequest('juan', accept: true);

      expect(cloudSource.accepted, ['juan']);
      expect(provider.items, isEmpty);
    });

    test('rechazar llama a rejectOrCancelFriendRequest', () async {
      final provider = buildProvider();
      await provider.respondToFriendRequest('juan', accept: false);
      expect(cloudSource.rejected, ['juan']);
    });
  });
}
