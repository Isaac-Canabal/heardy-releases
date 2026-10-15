import '../services/app_update_source.dart';
import '../services/cloud_source.dart';

/// Los tipos de aviso que hoy caben en el apartado de notificaciones. Añadir
/// uno nuevo es: un valor acá, un caso en `NotificationsProvider._refresh*`,
/// y un caso de UI en `notifications_screen.dart` — no hace falta tocar
/// esquema ni migración, porque nada de esto se persiste tal cual (ver
/// `NotificationsProvider`).
enum AppNotificationType { friendRequest, appUpdate }

/// Una fila del apartado de notificaciones. Se reconstruye entera en cada
/// [NotificationsProvider.refresh] a partir de datos que ya viven en otro
/// lado (la lista de amigos, el último release) — no es un modelo
/// persistido, así que no sigue la convención de `toMap`/`fromJson` del
/// resto de `models/`.
class AppNotification {
  final AppNotificationType type;
  final String id;
  final String title;
  final String body;

  /// Sólo para [AppNotificationType.friendRequest].
  final String? friendUsername;

  /// Sólo para [AppNotificationType.appUpdate].
  final AppUpdateInfo? updateInfo;

  const AppNotification._({
    required this.type,
    required this.id,
    required this.title,
    required this.body,
    this.friendUsername,
    this.updateInfo,
  });

  factory AppNotification.friendRequest(FriendEntry entry) => AppNotification._(
        type: AppNotificationType.friendRequest,
        id: 'friend:${entry.username}',
        title: '@${entry.username}',
        body: '',
        friendUsername: entry.username,
      );

  factory AppNotification.appUpdate(AppUpdateInfo info) => AppNotification._(
        type: AppNotificationType.appUpdate,
        id: 'update:${info.tag}',
        title: info.name.isEmpty ? info.tag : info.name,
        body: releaseNotesToPlainText(info.body),
        updateInfo: info,
      );
}
