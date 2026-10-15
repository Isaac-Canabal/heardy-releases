import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/playlist.dart';
import '../theme/app_theme.dart';

/// Elección del tipo de una playlist al crearla: "Descargas" (archivos en el
/// dispositivo) u "Online" (referencias que suenan por streaming). El tipo no
/// se puede cambiar después. Sin streaming en la plataforma, "Online" queda
/// deshabilitada con su motivo.
class PlaylistKindPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool streamingAvailable;

  const PlaylistKindPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.streamingAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            l10n.playlistKindTitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _KindTile(
          key: const Key('playlist_kind_local'),
          icon: Icons.download_done_rounded,
          title: l10n.playlistKindDownloads,
          subtitle: l10n.playlistKindDownloadsHint,
          selected: value == Playlist.kindLocal,
          onTap: () => onChanged(Playlist.kindLocal),
        ),
        const SizedBox(height: 8),
        _KindTile(
          key: const Key('playlist_kind_online'),
          icon: Icons.cloud_queue_rounded,
          title: l10n.playlistKindOnline,
          subtitle: streamingAvailable
              ? l10n.playlistKindOnlineHint
              : l10n.playlistKindOnlineUnavailable,
          selected: value == Playlist.kindOnline && streamingAvailable,
          onTap: streamingAvailable ? () => onChanged(Playlist.kindOnline) : null,
        ),
      ],
    );
  }
}

class _KindTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  const _KindTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? AppTheme.primary : Colors.white.withValues(alpha: 0.08),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: selected ? AppTheme.primaryLight : Colors.white70, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, color: AppTheme.primaryLight, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Diálogo "Nueva playlist": nombre + tipo. Devuelve null si se cancela.
Future<({String name, String kind})?> showCreatePlaylistDialog(
  BuildContext context, {
  required bool streamingAvailable,
}) {
  return showDialog<({String name, String kind})>(
    context: context,
    builder: (_) => _CreatePlaylistDialog(streamingAvailable: streamingAvailable),
  );
}

class _CreatePlaylistDialog extends StatefulWidget {
  final bool streamingAvailable;
  const _CreatePlaylistDialog({required this.streamingAvailable});

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _controller = TextEditingController();
  String _kind = Playlist.kindLocal;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = _controller.text.trim();
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Text(l10n.homeNewPlaylistTitle, style: const TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('create_playlist_name_field'),
                controller: _controller,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(hintText: l10n.commonCreateNewPlaylistHint),
              ),
              const SizedBox(height: 16),
              PlaylistKindPicker(
                value: _kind,
                streamingAvailable: widget.streamingAvailable,
                onChanged: (k) => setState(() => _kind = k),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        TextButton(
          key: const Key('create_playlist_confirm'),
          onPressed: name.isEmpty ? null : () => Navigator.pop(context, (name: name, kind: _kind)),
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
