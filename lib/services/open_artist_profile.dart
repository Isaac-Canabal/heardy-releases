import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/explore_artist_screen.dart';
import '../widgets/artist_picker_sheet.dart';
import 'artist_resolver.dart';
import 'download_source.dart';
import 'explore_logic.dart';
import 'remote_track_actions.dart';

/// Abre el perfil de Explorar del artista de la canción que suena. Compartido
/// por Reproduciendo (teléfono) y el panel de escritorio para que el permiso
/// de servidor/sesión, el selector de créditos múltiples y los avisos sean los
/// mismos. [pushRoute] sustituye al `Navigator` raíz (el panel de escritorio
/// lo apunta al navegador de contenido del shell, para que el perfil no tape
/// la barra lateral). [setBusy] enciende y apaga el indicador de carga de quien llama;
/// [isMounted] evita usar el contexto si la pantalla ya se cerró.
Future<void> openArtistProfile(
  BuildContext context,
  String credits, {
  required bool Function() isMounted,
  required ValueChanged<bool> setBusy,
  ValueChanged<Route<void>>? pushRoute,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  void snack(String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  final gate = remoteAccessGate(
    hasServer: context.read<SettingsProvider>().hasDownloadServer,
    isSignedIn: context.read<HeardyAuthProvider>().isReady,
  );
  if (gate != RemoteAccessGate.ok) {
    snack(gate == RemoteAccessGate.noServer ? l10n.artistProfileNeedsServer : l10n.artistProfileNeedsLogin);
    return;
  }
  final source = context.read<DownloadSource>();
  final navigator = Navigator.of(context);
  var name = credits.trim();
  final names = splitArtistCredits(name);
  if (names.length > 1) {
    final chosen = await showArtistPickerSheet(context, names);
    if (chosen == null || !isMounted()) return;
    name = chosen;
  }
  setBusy(true);
  ExploreArtistHit? hit;
  var failed = false;
  try {
    hit = await resolveArtistHit(name, source.exploreArtistSearch);
  } catch (_) {
    failed = true;
  } finally {
    if (isMounted()) setBusy(false);
  }
  if (!isMounted()) return;
  if (hit == null) {
    snack(failed ? l10n.artistProfileUnavailable : l10n.artistProfileNotFound);
    return;
  }
  final found = hit;
  final route = ExploreArtistScreen.route(
    name: found.name,
    thumbnailUrl: found.thumbnailUrl,
    loader: () => source.exploreArtist(found.channelId),
  );
  if (pushRoute != null) {
    pushRoute(route);
  } else {
    navigator.push(route);
  }
}
