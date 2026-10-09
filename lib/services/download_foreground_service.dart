import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Foreground service dedicado a las descargas — ver CLAUDE.md, "Descargas en
/// segundo plano".
///
/// Sin esto, Android congela o mata el proceso apenas la app deja de estar en
/// primer plano (no hay wakelock ni foreground service propio para
/// descargas, a diferencia de la reproducción, que ya tiene el suyo vía
/// `audio_service`). Como `DownloadProvider.processQueue()` procesa la cola
/// de a un trabajo por vez, esperando cada respuesta HTTP, si eso pasa
/// congelado cada trabajo choca con la misma restricción en su turno — eso
/// es lo que un usuario reportó como "me fui a otra app y al volver todas las
/// canciones habían fallado por falta de conexión".
///
/// El [DownloadTaskHandler] en sí no hace nada: su único trabajo es existir
/// para que el plugin pueda levantar el foreground service (Android exige un
/// TaskHandler para arrancarlo). La lógica real de descarga sigue viviendo
/// en `DownloadProvider`, en el isolate principal, sin cambios — lo único
/// que cambia es que mientras el service está activo, Android no debería
/// restringir la red/CPU de ese proceso.
class DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// El callback debe ser una función de nivel superior (`vm:entry-point`) —
/// requisito del plugin, corre en el isolate del servicio.
@pragma('vm:entry-point')
void startDownloadForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(DownloadTaskHandler());
}

const int downloadForegroundServiceId = 1000;

/// Configura el canal de notificación. Idempotente — barato llamarlo antes
/// de cada intento de arrancar el servicio en vez de una sola vez al inicio.
void initDownloadForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'com.heardy.app.downloads',
      channelName: 'Heardy Descargas',
      channelDescription:
          'Aparece mientras hay descargas en curso, para que sigan aunque uses otra app.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // No hay nada periódico que hacer en el isolate del servicio — toda
      // la lógica sigue en el isolate principal.
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Arranca (o, si ya está corriendo, actualiza) la notificación persistente.
/// Nunca lanza: sin plugin nativo registrado (tests de escritorio, por
/// ejemplo) esto falla con MissingPluginException, que acá es
/// print-and-swallow igual que el resto de `services/` — no hay nada más
/// razonable que hacer con ese error en particular.
Future<void> startOrUpdateDownloadForegroundNotification({
  required String title,
  required String text,
}) async {
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      return;
    }
    initDownloadForegroundTask();
    await FlutterForegroundTask.startService(
      serviceId: downloadForegroundServiceId,
      notificationTitle: title,
      notificationText: text,
      callback: startDownloadForegroundCallback,
    );
  } catch (e) {
    debugPrint('DownloadForegroundService: no se pudo iniciar/actualizar: $e');
  }
}

Future<void> stopDownloadForegroundNotification() async {
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  } catch (e) {
    debugPrint('DownloadForegroundService: no se pudo detener: $e');
  }
}
