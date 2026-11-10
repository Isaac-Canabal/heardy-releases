// RAM total del dispositivo, para decidir qué modos de calidad del Mix caben
// (availableQualityModes). `null` si no se puede leer.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import 'mix_models.dart';

MixPlatform? currentMixPlatform() {
  if (Platform.isAndroid) return MixPlatform.android;
  if (Platform.isWindows) return MixPlatform.windows;
  return null;
}

Future<int?> totalDeviceMemoryBytes({MethodChannel channel = const MethodChannel('heardy/mix')}) async {
  try {
    if (Platform.isAndroid) {
      // ActivityManager.MemoryInfo.totalMem (MainActivity.kt).
      return await channel.invokeMethod<int>('totalMemory');
    }
    if (Platform.isWindows) return _windowsTotalMemory();
  } catch (e) {
    print('Mix: no se pudo leer la memoria total ($e)');
  }
  return null;
}

int? _windowsTotalMemory() {
  final p = calloc<MEMORYSTATUSEX>();
  try {
    p.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
    if (GlobalMemoryStatusEx(p) == 0) return null;
    return p.ref.ullTotalPhys;
  } finally {
    calloc.free(p);
  }
}
