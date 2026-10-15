import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Carátula de una playlist: archivo local ([path]) o miniatura de red
/// ([url], playlists online) y, si no hay o falla, el degradado de siempre.
class PlaylistCover extends StatelessWidget {
  final String? path;
  final String? url;
  final double size;
  final double radius;
  final IconData placeholderIcon;

  const PlaylistCover({
    super.key,
    this.path,
    this.url,
    this.size = 58,
    this.radius = 12,
    this.placeholderIcon = Icons.queue_music_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final localPath = path;
    if (localPath != null && File(localPath).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.file(File(localPath), width: size, height: size, fit: BoxFit.cover),
      );
    }
    final remoteUrl = url;
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.network(
          remoteUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(placeholderIcon, color: Colors.white70),
      );
}
