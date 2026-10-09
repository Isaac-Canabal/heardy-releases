# Reglas para R8/ProGuard cuando minifyEnabled/shrinkResources están
# activos (ver build.gradle, A5 de la Fase 1 de seguridad). Sin device real
# para probar en este entorno: estas reglas son defensivas, pensadas para no
# romper en silencio lo que estos plugins hacen vía reflexión o servicios
# declarados en el manifest — verificar igual con un APK de release real en
# un dispositivo antes de dar esto por cerrado.

# Los plugins de Flutter con embedding v2 se registran de forma estática
# (GeneratedPluginRegistrant), no por reflexión, así que R8 no necesita
# ayuda para eso. Lo que sí puede romper es la interacción con Android:
# servicios/receivers declarados en el manifest, y cualquier serialización
# que dependa de nombres de clase o de campos sobreviviendo la ofuscación.

# audio_service: el MediaBrowserService y el MediaButtonReceiver están
# declarados en AndroidManifest.xml: sin esto, Android intenta instanciar
# una clase que R8 pudo haber renombrado o eliminado por no ver referencias
# directas en el código Dart/Kotlin.
-keep class com.ryanheise.audioservice.** { *; }

# flutter_foreground_task: mismo motivo — su servicio también está declarado
# en el manifest (foregroundServiceType="dataSync").
-keep class com.pravera.flutter_foreground_task.** { *; }

# flutter_local_notifications: usado sólo con .show() inmediato en este
# proyecto (nunca zonedSchedule ni notificaciones que sobrevivan un reinicio,
# confirmado por grep), así que el caso de rotura más común del plugin — la
# serialización con Gson de una notificación programada — no debería
# aplicar. Se mantiene igual como red de seguridad barata.
-keep class com.dexterous.** { *; }

# just_audio/ExoPlayer trae sus propias consumer-rules dentro del AAR, que
# R8 aplica automáticamente — no hace falta duplicarlas acá.

# Elimina los stubs de Play Core que Flutter referencia condicionalmente
# para "deferred components" (módulos de instalación diferida). Esta app no
# los usa, y sin esta línea R8 puede fallar con "Missing class" en vez de
# simplemente ignorar la referencia.
-dontwarn com.google.android.play.core.**
