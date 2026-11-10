import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_log.dart';
import '../services/app_update_source.dart';
import '../services/update_gate.dart';
import '../services/version_compare.dart';

/// Estado de la puerta de actualización obligatoria. No consulta la red: la
/// comprobación vive en `NotificationsProvider`, que le pasa cada release
/// publicado que ve ([recordRelease]). Aquí sólo se recuerda, en
/// `SharedPreferences`, el tag más alto visto que supera a la versión
/// instalada, para seguir bloqueando aun sin red. Sin ninguna comprobación
/// exitosa previa no hay tag y la puerta queda abierta (fail-open).
class UpdateGateProvider with ChangeNotifier, WidgetsBindingObserver {
  static const prefsKeyKnownTag = 'update_gate_latest_known_tag';

  final Future<PackageInfo> Function() _packageInfo;

  String? _installedVersion;
  String? _knownTag;
  bool _loaded = false;

  UpdateGateProvider({Future<PackageInfo> Function()? packageInfo})
      : _packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  String? get installedVersion => _installedVersion;

  /// Tag del release que hay que instalar, o `null` si no se bloquea.
  String? get requiredTag => blocked ? _knownTag : null;

  bool get blocked =>
      _loaded && updateGateDecision(installedVersion: _installedVersion, latestKnownTag: _knownTag);

  /// Carga la versión instalada y el tag guardado; si el usuario ya
  /// actualizó, el tag deja de ser más nuevo y se borra.
  Future<void> load() async {
    try {
      _installedVersion = (await _packageInfo()).version;
      final prefs = await SharedPreferences.getInstance();
      _knownTag = prefs.getString(prefsKeyKnownTag);
      if (_knownTag != null &&
          !updateGateDecision(installedVersion: _installedVersion, latestKnownTag: _knownTag)) {
        _knownTag = null;
        await prefs.remove(prefsKeyKnownTag);
      }
    } catch (e) {
      appLog('UpdateGateProvider: no se pudo cargar el estado: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Un release publicado que acaba de comprobarse con éxito. Sólo sube el
  /// tag recordado; una comprobación fallida nunca llega aquí, así que
  /// tampoco puede levantar un bloqueo conocido.
  Future<void> recordRelease(AppUpdateInfo release) async {
    final installed = _installedVersion;
    if (!_loaded || installed == null) return;
    if (!updateGateDecision(installedVersion: installed, latestKnownTag: release.tag)) return;
    final known = _knownTag;
    if (known != null && !isNewerVersion(release.tag, known)) return;
    _knownTag = release.tag;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKeyKnownTag, release.tag);
    } catch (e) {
      appLog('UpdateGateProvider: no se pudo guardar el tag: $e');
    }
  }

  /// En Android el botón atrás llega a los observadores en orden de registro:
  /// registrarlo antes de `runApp` lo pone por delante del `Navigator` y
  /// permite tragarlo mientras la app está bloqueada.
  void attachBackGuard() => WidgetsBinding.instance.addObserver(this);

  @override
  Future<bool> didPopRoute() async => blocked;
}
