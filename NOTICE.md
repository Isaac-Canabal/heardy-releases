# Third-party notices

Heardy is distributed under the GNU General Public License v3.0 (see `LICENSE`). It includes or links the following
third-party components. This list is not exhaustive for transitive dependencies.

## GPL-3.0 components (Android)

- **NewPipeExtractor** (https://github.com/TeamNewPipe/NewPipeExtractor), by TeamNewPipe and the NewPipe contributors,
  licensed under GPL-3.0-or-later. Linked unmodified (release v0.26.5, via JitPack) by the `heardy_yt_stream` plugin
  (`packages/heardy_yt_stream`) to resolve audio stream URLs on the device. The corresponding source of this Heardy
  version is this repository.
- **NewPipe** (https://github.com/TeamNewPipe/NewPipe), by TeamNewPipe and the NewPipe contributors, licensed under
  GPL-3.0-or-later. The following files are derived from NewPipe and were modified by Heardy in 2026 (each carries a
  notice at the top). Upstream paths are relative to
  `https://github.com/TeamNewPipe/NewPipe/blob/dev/app/src/main/`:
  - `packages/heardy_yt_stream/android/src/main/kotlin/com/heardy/ytstream/potoken/PoTokenWebView.kt`, from
    `java/org/schabi/newpipe/util/potoken/PoTokenWebView.kt` (package renamed; debug flag and log tag replaced).
  - `.../potoken/PoTokenGenerator.kt`, from `java/org/schabi/newpipe/util/potoken/PoTokenGenerator.kt` (package renamed).
  - `.../potoken/PoTokenException.kt`, from `java/org/schabi/newpipe/util/potoken/PoTokenException.kt` (package
    renamed; a log-tag debug flag added).
  - `.../potoken/JavaScriptUtil.kt`, from `java/org/schabi/newpipe/util/potoken/JavaScriptUtil.kt` (package renamed).
  - `.../potoken/PoTokenProviderImpl.kt`, from `java/org/schabi/newpipe/util/potoken/PoTokenProviderImpl.kt`
    (app-specific dependencies replaced by an injected context; extra client methods stubbed).
  - `.../ytstream/DownloaderImpl.kt`, from `java/org/schabi/newpipe/DownloaderImpl.java` (rewritten in Kotlin on
    OkHttp, without cookies, restricted mode or the ReCaptcha flow).
  - `packages/heardy_yt_stream/android/src/main/assets/po_token.html`, from `assets/po_token.html` (only the notice
    was added).
  Heardy is not affiliated with or endorsed by the NewPipe project.

## Bundled binaries (Windows)

- **yt-dlp** (https://github.com/yt-dlp/yt-dlp), Unlicense. The executable is downloaded at build time and updated by the
  app; it embeds third-party components under their own licenses (see the yt-dlp project).
- **FFmpeg** (LGPL build by BtbN/FFmpeg-Builds, https://github.com/BtbN/FFmpeg-Builds), LGPL-2.1-or-later, run as a
  separate process; shipped with its `LICENSE.txt` in the `ffmpeg` folder.

## Other Android libraries (via `packages/heardy_yt_stream`)

- **nanojson** (TeamNewPipe fork of grack/nanojson), Apache-2.0.
- **OkHttp** (Square), Apache-2.0.
- **RxJava / RxAndroid** (ReactiveX), Apache-2.0.
- **AndroidX WebKit / Annotation**, Apache-2.0.

## Dart / Flutter dependencies

All other Dart and Flutter packages are used under their own licenses (BSD-3-Clause, MIT, Apache-2.0, ...). The exact
set and versions are pinned in `pubspec.lock`; each package carries its license in its pub.dev page and source.
`packages/just_audio_media_kit_patch` is a patched copy of `just_audio_media_kit` and keeps its own `LICENSE`. On
Windows, audio playback uses `media_kit` with libmpv (see `media_kit_libs_windows_audio` for its licensing).

Lyrics are fetched from LRCLIB (https://lrclib.net/).

## Name and branding

The name "Heardy" and the logo/icon artwork (`Heardy_icon.png` and the branding files under `assets/`) are NOT licensed
for use under the GPL. Forks should use their own name and icon.
