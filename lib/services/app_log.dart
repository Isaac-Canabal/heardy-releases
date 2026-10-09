import 'package:flutter/foundation.dart';

void appLog(Object? message) {
  if (kDebugMode) debugPrint(message?.toString());
}
