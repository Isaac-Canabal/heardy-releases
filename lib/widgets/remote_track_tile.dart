import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/download_source.dart';
import '../services/remote_track_actions.dart';
import '../theme/app_theme.dart';

/// Fila de una pista remota: tocar la fila descarga; el botón de play escucha
/// (sólo si [onListen] no es null). Con [onPlay] tocar la fila REPRODUCE y el
/// icono de descarga pasa a ser un botón.
class RemoteTrackTile extends StatelessWidget {
  final RemoteTrack track;
  final VoidCallback onDownload;
  final VoidCallback? onListen;
  final VoidCallback? onPlay;
  final bool isLoadingStream;

  /// Ya está en la biblioteca: se cambia el icono de descarga por una marca.
  final bool downloaded;

  const RemoteTrackTile({
    super.key,
    required this.track,
    required this.onDownload,
    required this.onListen,
    required this.isLoadingStream,
    this.onPlay,
    this.downloaded = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: AppTheme.glassCard(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: isLoadingStream && onPlay != null ? null : (onPlay ?? onDownload),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: track.thumbnailUrl.isEmpty
                      ? _placeholder()
                      : Image.network(
                          track.thumbnailUrl,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (track.durationSeconds > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      formatTrackDuration(track.durationSeconds),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
                    ),
                  ),
                if (onPlay != null && isLoadingStream)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (onPlay != null || onListen == null)
                  const SizedBox.shrink()
                else if (isLoadingStream)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    key: Key('stream_track_button_${track.id}'),
                    tooltip: AppLocalizations.of(context)!.searchListenTooltip,
                    icon: Icon(Icons.play_arrow_rounded, color: AppTheme.primaryLight, size: 24),
                    onPressed: onListen,
                  ),
                if (downloaded)
                  Tooltip(
                    message: AppLocalizations.of(context)!.exploreAlreadyDownloaded,
                    child: Icon(
                      Icons.check_circle_rounded,
                      key: Key('downloaded_mark_${track.id}'),
                      color: Colors.white.withValues(alpha: 0.5),
                      size: 22,
                    ),
                  )
                else if (onPlay != null)
                  IconButton(
                    key: Key('download_track_button_${track.id}'),
                    tooltip: AppLocalizations.of(context)!.searchListenDownloadAction,
                    icon: Icon(Icons.download_rounded, color: AppTheme.primaryLight, size: 22),
                    onPressed: onDownload,
                  )
                else
                  Icon(Icons.download_rounded, color: AppTheme.primaryLight, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(track.title)),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
  }
}

/// Tarjeta compacta (portada cuadrada de 140 dp con título y artista debajo)
/// para estanterías horizontales. Tocar abre una hoja con Escuchar/Descargar;
/// sin [onListen] (escritorio) tocar descarga directamente.
class RemoteTrackCard extends StatelessWidget {
  static const double size = 140;

  final RemoteTrack track;
  final VoidCallback onDownload;
  final VoidCallback? onListen;
  final bool isLoadingStream;

  const RemoteTrackCard({
    super.key,
    required this.track,
    required this.onDownload,
    required this.onListen,
    required this.isLoadingStream,
  });

  void _onTap(BuildContext context) {
    final listen = onListen;
    if (listen == null) {
      onDownload();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: Key('card_listen_${track.id}'),
              leading: Icon(Icons.play_arrow_rounded, color: AppTheme.primaryLight),
              title: Text(l10n.searchListenTooltip),
              onTap: () {
                Navigator.of(sheetContext).pop();
                listen();
              },
            ),
            ListTile(
              key: Key('card_download_${track.id}'),
              leading: Icon(Icons.download_rounded, color: AppTheme.primaryLight),
              title: Text(l10n.searchListenDownloadAction),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onDownload();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isLoadingStream ? null : () => _onTap(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    track.thumbnailUrl.isEmpty
                        ? _placeholder()
                        : Image.network(
                            track.thumbnailUrl,
                            fit: BoxFit.cover,
                            cacheWidth: (size * 2).round(),
                            errorBuilder: (_, __, ___) => _placeholder(),
                          ),
                    if (isLoadingStream)
                      const ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(track.title)),
        child: const Icon(Icons.music_note_rounded, color: Colors.white70),
      );
}
