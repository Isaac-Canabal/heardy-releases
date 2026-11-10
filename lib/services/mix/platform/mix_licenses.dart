// Licencias de lo que usa el Mix DJ, en la pantalla de licencias de la app
// (como las fuentes en theme/app_fonts.dart). sherpa-onnx y ONNX Runtime van
// dentro de la app; los modelos se descargan solo si el usuario los pide.
import 'package:flutter/foundation.dart';

import 'mix_license_texts.dart';

void registerMixLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
        ['sherpa-onnx'], 'sherpa-onnx v2.0.1 (https://github.com/k2-fsa/sherpa-onnx).\n\n$kApacheLicense20');
    yield const LicenseEntryWithLineBreaks(['ONNX Runtime'], kOnnxRuntimeMitLicense);
    yield const LicenseEntryWithLineBreaks(['Spleeter'], kSpleeterMitLicense);
    yield const LicenseEntryWithLineBreaks(['Ultimate Vocal Remover (UVR)'], kUvrNotice);
  });
}
