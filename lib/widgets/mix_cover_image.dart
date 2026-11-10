import 'dart:io';

import 'package:flutter/material.dart';

import '../models/mix_record.dart';
import '../theme/app_theme.dart';

/// La carátula fundida de un mix, o el degradado del tema si no la tiene.
class MixCoverImage extends StatelessWidget {
  const MixCoverImage({super.key, required this.record, this.size = 56, this.radius = 10});

  final MixRecord record;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final art = record.artPath;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(record.name)),
      child: Icon(Icons.multitrack_audio_rounded, color: Colors.white70, size: size * 0.45),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: art.isEmpty
            ? fallback
            : Image.file(
                File(art),
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
