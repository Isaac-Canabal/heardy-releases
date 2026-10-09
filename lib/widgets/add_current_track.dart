import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/music_provider.dart';
import '../services/explore_logic.dart';
import 'playlist_target_sheet.dart';
import 'remote_track_actions_mixin.dart';

/// "Añadir" de Reproduciendo: descarga la pista en streaming a una playlist o
/// copia la canción local a otra. Compartido por el teléfono y el escritorio.
Future<void> addCurrentTrackToPlaylist(
  BuildContext context,
  MediaItem item, {
  required bool Function() isMounted,
}) async {
  switch (nowPlayingAddAction(item)) {
    case NowPlayingAddAction.none:
      return;
    case NowPlayingAddAction.downloadStream:
      await enqueueRemoteTrackDownload(
        context,
        remoteTrackFromStreamItem(item)!,
        isMounted: isMounted,
      );
    case NowPlayingAddAction.addLocal:
      final choice = await pickTargetPlaylist(context);
      if (choice == null || !isMounted()) return;
      // ignore: use_build_context_synchronously
      final playlistId = await resolveTargetPlaylistId(context, choice);
      if (playlistId == null || !isMounted()) return;
      // ignore: use_build_context_synchronously
      final music = context.read<MusicProvider>();
      // ignore: use_build_context_synchronously
      final l10n = AppLocalizations.of(context)!;
      // ignore: use_build_context_synchronously
      final messenger = ScaffoldMessenger.of(context);
      await music.copySongToPlaylist(item.id, playlistId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.nowPlayingAddedToPlaylistSnack(item.title)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }
}

/// Botón de ícono "Añadir" para los widgets de escritorio; no se pinta si no
/// hay nada que añadir.
class AddToPlaylistIconButton extends StatelessWidget {
  final MediaItem item;
  const AddToPlaylistIconButton({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    if (nowPlayingAddAction(item) == NowPlayingAddAction.none) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('desktop_add_button'),
      tooltip: AppLocalizations.of(context)!.nowPlayingAddButton,
      icon: const Icon(Icons.playlist_add_rounded, color: Colors.white70),
      onPressed: () =>
          addCurrentTrackToPlaylist(context, item, isMounted: () => context.mounted),
    );
  }
}
