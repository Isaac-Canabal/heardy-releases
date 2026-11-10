import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import '../l10n/app_localizations_es.dart';
import '../models/app_notification.dart';
import '../providers/settings_provider.dart';
import '../providers/update_gate_provider.dart';
import '../services/app_update_source.dart';
import '../services/cloud_source.dart';
import '../services/system_notifications.dart';
import '../services/version_compare.dart';
import 'package:heardy/services/app_log.dart';

/// Apartado de notificaciones (Etapa 17): un único lugar donde conviven
/// avisos de origen muy distinto — hoy las solicitudes de amistad entrantes,
/// mañana lo que haga falta — sin que cada uno necesite su propio
/// ícono/pantalla. La comprobación de versión también corre aquí, pero ya no
/// es una fila de la lista: alimenta la puerta obligatoria (`UpdateGate`) y
/// la notificación del sistema.
///
/// **Nada de esto se persiste en una tabla propia.** Las solicitudes de
/// amistad ya viven en el servidor (`CloudSource.getFriends`) y desaparecen
/// solas al aceptarlas/rechazarlas — igual que hace `FriendsScreen` hoy, acá
/// sólo se refleja el mismo estado. Lo único que sí hay que recordar entre
/// arranques es "qué versión ya vio el usuario", y para un único string
/// `SharedPreferences` alcanza — el mismo patrón que `accountPromptSeen` en
/// `SettingsProvider`, no una tabla nueva para una sola fila.
///
/// **Disparadores: arranque en frío y `resumed`, igual que `SyncProvider`**
/// (ver `main.dart`/`main_shell_screen.dart`) — nunca un timer propio. El
/// límite horario de `resumed` no aplica a la primera pasada ni mientras la
/// última comprobación de versión haya fallado.
class NotificationsProvider with ChangeNotifier {
  final CloudSource _cloudSource;
  final AppUpdateSource _updateSource;
  final Future<PackageInfo> Function() _packageInfo;
  final SystemNotifications _systemNotifications;
  final AppLanguage Function() _language;
  final UpdateGateProvider? _updateGate;

  static const _prefsKeyNotifiedVersion = 'notifications_system_notified_update_version';
  static const _prefsKeyNotifiedFriendUsernames = 'notifications_system_notified_friend_usernames';
  static const _resumeThrottle = Duration(hours: 1);

  List<FriendEntry> _incomingRequests = [];
  // Lo que ya se mostró como notificación real del sistema — independiente
  // de qué solicitudes siguen pendientes, para no repetir el aviso en cada
  // chequeo horario mientras el usuario no actúa.
  String? _notifiedVersion;
  Set<String> _notifiedFriendUsernames = {};
  bool _systemNotifiedStateLoaded = false;
  DateTime? _lastRefresh;
  bool _refreshing = false;
  bool _lastUpdateCheckOk = false;

  NotificationsProvider({
    required CloudSource cloudSource,
    AppUpdateSource? updateSource,
    Future<PackageInfo> Function()? packageInfo,
    SystemNotifications? systemNotifications,
    AppLanguage Function()? language,
    UpdateGateProvider? updateGate,
  })  : _cloudSource = cloudSource,
        _updateSource = updateSource ?? GithubAppUpdateSource(),
        _packageInfo = packageInfo ?? PackageInfo.fromPlatform,
        _systemNotifications = systemNotifications ?? LocalSystemNotifications(),
        _language = language ?? (() => AppLanguage.es),
        _updateGate = updateGate;

  AppLocalizations get _l10n =>
      _language() == AppLanguage.en ? AppLocalizationsEn() : AppLocalizationsEs();

  List<AppNotification> get items => [
        for (final entry in _incomingRequests) AppNotification.friendRequest(entry),
      ];

  int get unreadCount => items.length;

  /// `false` mientras no llegó ninguna pasada — evita el parpadeo de
  /// "sin notificaciones" en el primer frame, antes de que `refresh()`
  /// termine.
  bool get hasLoadedOnce => _lastRefresh != null;

  Future<void> onAppResumed() async {
    final last = _lastRefresh;
    if (last != null && _lastUpdateCheckOk && DateTime.now().difference(last) < _resumeThrottle) return;
    await refresh();
  }

  /// Las solicitudes de amistad y la comprobación de versión son
  /// independientes a propósito, igual que los pasos de `SyncProvider`: sin
  /// cuenta vinculada, `_refreshFriendRequests` falla y no debe tapar la
  /// comprobación de versión, que no necesita sesión.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await Future.wait([_refreshFriendRequests(), _refreshAvailableUpdate()]);
      _lastRefresh = DateTime.now();
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> _loadSystemNotifiedState() async {
    if (_systemNotifiedStateLoaded) return;
    _systemNotifiedStateLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    _notifiedVersion = prefs.getString(_prefsKeyNotifiedVersion);
    _notifiedFriendUsernames = (prefs.getStringList(_prefsKeyNotifiedFriendUsernames) ?? []).toSet();
  }

  Future<void> _refreshFriendRequests() async {
    try {
      await _loadSystemNotifiedState();
      final friends = await _cloudSource.getFriends();
      _incomingRequests = friends.incoming;

      // Notificación real del sistema sólo para lo que no se avisó todavía
      // — si no, cada chequeo horario repetiría el aviso de una solicitud
      // que sigue pendiente sin que el usuario haya hecho nada con ella.
      final currentUsernames = _incomingRequests.map((e) => e.username).toSet();
      final newUsernames = currentUsernames.difference(_notifiedFriendUsernames);
      for (final username in newUsernames) {
        await _systemNotifications.show(
          id: 'friend:$username'.hashCode,
          title: '@$username',
          body: _l10n.notificationsFriendRequestSubtitle,
        );
      }
      // Se reconcilia con lo que sigue pendiente ahora mismo: una solicitud
      // ya resuelta (acá o desde `FriendsScreen`) sale del set, así que si
      // el mismo usuario manda una solicitud nueva más adelante, vuelve a
      // avisar.
      if (newUsernames.isNotEmpty || !setEquals(_notifiedFriendUsernames, currentUsernames)) {
        _notifiedFriendUsernames = currentUsernames;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_prefsKeyNotifiedFriendUsernames, _notifiedFriendUsernames.toList());
      }
    } catch (e) {
      // Sin cuenta vinculada, o sin red: no hay solicitudes que mostrar, no
      // un error que romper la campanita por algo que ni siquiera usa quien
      // no tiene cuenta.
      appLog('NotificationsProvider: no se pudieron traer las solicitudes de amistad: $e');
    }
  }

  Future<void> _refreshAvailableUpdate() async {
    await _loadSystemNotifiedState();

    // `null` = sin red, límite de la API o ningún release publicado: no es
    // una comprobación exitosa y nunca levanta un bloqueo ya conocido.
    final release = await _updateSource.getLatestRelease();
    _lastUpdateCheckOk = release != null;
    if (release == null) return;

    await _updateGate?.recordRelease(release);

    final info = await _packageInfo();
    final isNewer = isNewerVersion(release.tag, info.version);

    if (isNewer && release.tag != _notifiedVersion) {
      await _systemNotifications.showUpdateAvailable(
        id: 'update:${release.tag}'.hashCode,
        title: _l10n.notificationsUpdateTitle(release.name.isEmpty ? release.tag : release.name),
        body: release.body,
        downloadUrl: heardyDownloadsUrl,
        downloadLabel: _l10n.notificationsGoToDownloads,
        viewUrl: release.htmlUrl,
        viewLabel: _l10n.notificationsViewRelease,
      );
      _notifiedVersion = release.tag;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyNotifiedVersion, release.tag);
    }
  }

  Future<void> respondToFriendRequest(
    String username, {
    required bool accept,
  }) async {
    if (accept) {
      await _cloudSource.acceptFriendRequest(username);
    } else {
      await _cloudSource.rejectOrCancelFriendRequest(username);
    }
    await _refreshFriendRequests();
    notifyListeners();
  }
}
