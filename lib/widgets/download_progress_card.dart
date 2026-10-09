import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../providers/download_provider.dart';
import '../l10n/app_localizations.dart';

/// The active-download panel for [ImportScreen].
///
/// Adapted from the pre-pivot download UI (see `youtube-downloader-final`)
/// for the new [DownloadProvider] shape — same ring/percentage/gradient-bar
/// look, but driven by [phase] and a [progress] that can be **negative
/// for "indeterminate"**: `/audio` blocks while the server downloads the
/// video server-side (DD1), so there are a few seconds with nothing to show
/// a byte count for. The elapsed-time readout from the original card was
/// dropped — [DownloadProvider] doesn't track it, and the phase label already
/// tells the user what's happening.
class DownloadProgressCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final DownloadPhase phase;

  /// 0..1 while downloading; negative means indeterminate.
  final double progress;

  /// How many more jobs are waiting behind this one.
  final int queueRemaining;

  final VoidCallback onCancel;
  final VoidCallback? onCancelAll;

  const DownloadProgressCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.phase,
    required this.progress,
    required this.queueRemaining,
    required this.onCancel,
    this.onCancelAll,
  });

  bool get _determinate => progress >= 0;
  int get _percent => _determinate ? (progress.clamp(0.0, 1.0) * 100).round() : 0;

  String _phaseLabel(AppLocalizations l10n) => switch (phase) {
        DownloadPhase.idle => '',
        DownloadPhase.resolving => l10n.downloadPhaseResolving,
        DownloadPhase.preparing => l10n.downloadPhasePreparing,
        DownloadPhase.downloading => l10n.downloadPhaseDownloading,
        DownloadPhase.saving => l10n.downloadPhaseSaving,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(highlighted: true),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProgressRing(percent: _percent, determinate: _determinate),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.cloud_download_rounded,
                          color: AppTheme.accent.withValues(alpha: 0.9),
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.downloadCardTitle,
                          style: TextStyle(
                            color: AppTheme.primaryLight,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          icon: Icon(Icons.close_rounded, color: Colors.redAccent.shade100, size: 22),
                          tooltip: l10n.downloadCardCancelThisTooltip,
                          onPressed: onCancel,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title.isEmpty ? l10n.downloadCardPreparing : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_determinate)
                Text(
                  '$_percent',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    letterSpacing: -1,
                  ),
                )
              else
                const SizedBox(
                  height: 36,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Icon(Icons.hourglass_top_rounded, color: Colors.white54, size: 28),
                  ),
                ),
              if (_determinate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5, left: 2),
                  child: Text(
                    '%',
                    style: TextStyle(
                      color: AppTheme.primaryLight.withValues(alpha: 0.9),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _phaseLabel(l10n),
                    style: TextStyle(
                      color: AppTheme.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (queueRemaining > 0)
                    Text(
                      l10n.downloadCardQueuedSuffix(queueRemaining),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _determinate
              ? _GradientProgressBar(value: progress)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 10,
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
                    ),
                  ),
                ),
          if (onCancelAll != null && queueRemaining > 0) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onCancelAll,
                icon: const Icon(Icons.playlist_remove_rounded, size: 16),
                label: Text(l10n.downloadCardCancelAllButton),
                style: TextButton.styleFrom(foregroundColor: Colors.white.withValues(alpha: 0.6)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  final int percent;
  final bool determinate;

  const _ProgressRing({required this.percent, required this.determinate});

  @override
  Widget build(BuildContext context) {
    final value = determinate ? (percent / 100).clamp(0.01, 1.0) : null;

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
          ),
          Icon(Icons.music_note_rounded, color: AppTheme.primaryLight, size: 20),
        ],
      ),
    );
  }
}

class _GradientProgressBar extends StatelessWidget {
  final double value;

  const _GradientProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.white.withValues(alpha: 0.08)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: clamped > 0 ? clamped : 0.02,
              child: Container(
                decoration: BoxDecoration(
                  gradient: AppTheme.progressGradient,
                  boxShadow: [
                    BoxShadow(color: AppTheme.primary.withValues(alpha: 0.38), blurRadius: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
