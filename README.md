# heardy-releases

Binarios de distribución de Heardy (APK de Android, instalador de Windows), publicados como GitHub Releases —
ver `releases/latest/download/Heardy.apk` y `releases/latest/download/Heardy-Setup.exe`.

## `just_audio_media_kit_patch/`

Un fork parchado de [`just_audio_media_kit`](https://github.com/Pato05/just_audio_media_kit) (paquete de
terceros), usado como dependencia git desde el `pubspec.yaml` de Heardy. El único cambio real sobre el
original: expone `JustAudioMediaKit.rawPlayerFor(id)` y `MediaKitPlayer.rawPlayer`, acceso público al `Player`
de `media_kit` que la API original mantiene privado — necesario para aplicarle filtros de audio (`af`,
ecualizador y normalización de volumen) en la versión de escritorio.
