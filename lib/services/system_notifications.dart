import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_log.dart';
import 'app_update_source.dart';

/// Seam para disparar una notificación real del sistema — sólo el plugin
/// tiene efecto de verdad (Android); en cualquier otra plataforma es un
/// no-op. Igual que `DownloadSource`/`CloudSource`, una interfaz por si un
/// test necesita sustituirla, porque `flutter_local_notifications` no tiene
/// doble de prueba.
abstract class SystemNotifications {
  Future<void> show({required int id, required String title, required String body});

  /// Como [show], pero con dos botones tocables desde la propia
  /// notificación: bajar el binario de esta plataforma directamente, o
  /// revisar la página del release. Sólo tiene efecto en Android.
  Future<void> showUpdateAvailable({
    required int id,
    required String title,
    required String body,
    required String downloadUrl,
    required String downloadLabel,
    required String viewUrl,
    required String viewLabel,
  });
}

/// Abre la URL detrás de un toque en la notificación o en uno de sus
/// botones — [target] es directamente esa URL, no un id a resolver, porque
/// [LocalSystemNotifications] guarda la URL de cada botón como su propio
/// `id` (ver `showUpdateAvailable`). Se llama tanto desde el toque en
/// primer plano (`onDidReceiveNotificationResponse`, en `main.dart`) como
/// desde un arranque en frío disparado por la notificación
/// (`getNotificationAppLaunchDetails`, también en `main.dart`) — ambos
/// puntos pasan por acá para no duplicar la lógica de abrir la URL.
Future<void> handleSystemNotificationTap(String? target) async {
  if (target == null) return;
  final uri = safeExternalUri(target);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    appLog('SystemNotifications: no se pudo abrir el enlace: $e');
  }
}

/// Reutiliza la misma instancia global que `main.dart` ya inicializa con el
/// ícono de la app y el canal de notificaciones antes de crear cualquier
/// provider — no hace falta un canal separado para esto, `flutter_local_
/// notifications` deja elegir importancia por notificación individual.
class LocalSystemNotifications implements SystemNotifications {
  static const _channelId = 'com.heardy.app.notifications';
  static const _channelName = 'Heardy';

  @override
  Future<void> show({required int id, required String title, required String body}) async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterLocalNotificationsPlugin().show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (e) {
      print('LocalSystemNotifications: no se pudo mostrar la notificación: $e');
    }
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
    if (!Platform.isAndroid) return;
    try {
      await FlutterLocalNotificationsPlugin().show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            // `id` es la URL misma, no una clave a resolver — el toque en
            // el botón la manda de vuelta tal cual en `actionId`
            // (`handleSystemNotificationTap`). `showsUserInterface: true`
            // hace que Android traiga la app a primer plano antes de
            // avisar del toque, así el handler siempre corre en el
            // isolate normal de la app — nunca hace falta un entry point
            // de isolate en segundo plano sólo para poder abrir una URL.
            actions: [
              AndroidNotificationAction(downloadUrl, downloadLabel, showsUserInterface: true),
              AndroidNotificationAction(viewUrl, viewLabel, showsUserInterface: true),
            ],
          ),
        ),
        // Tocar el cuerpo de la notificación (no un botón) lleva a la
        // página del release — mismo destino que el botón "ver", que es el
        // menos disruptivo de los dos por defecto.
        payload: viewUrl,
      );
    } catch (e) {
      print('LocalSystemNotifications: no se pudo mostrar la notificación de actualización: $e');
    }
  }
}
