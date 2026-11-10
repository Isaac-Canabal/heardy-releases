import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/heardy_mixer_provider.dart';
import '../services/download_source.dart';
import '../services/mix/mix_types.dart';
import '../services/mix/mixer_logic.dart';
import '../services/mix/platform/mix_models.dart';
import '../theme/app_theme.dart';
import '../widgets/heardy_mixer_pickers.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_target_sheet.dart';
import 'heardy_mixer_result_screen.dart';

String mixerQualityLabel(AppLocalizations l10n, MixQualityMode m) => switch (m) {
      MixQualityMode.fast => l10n.mixerQualityFast,
      MixQualityMode.high => l10n.mixerQualityHigh,
      MixQualityMode.max => l10n.mixerQualityMax,
    };

String mixerModeLabel(AppLocalizations l10n, MixMode m) => switch (m) {
      MixMode.automatic => l10n.mixerModeAuto,
      MixMode.vocalsAOverMusicB => l10n.mixerModeVocalsAOverB,
      MixMode.vocalsBOverMusicA => l10n.mixerModeVocalsBOverA,
    };

String mixerStageLabel(AppLocalizations l10n, MixerUiStage s) => switch (s) {
      MixerUiStage.preparing => l10n.mixerStagePreparing,
      MixerUiStage.separating => l10n.mixerStageSeparating,
      MixerUiStage.analyzing => l10n.mixerStageAnalyzing,
      MixerUiStage.mixing => l10n.mixerStageMixing,
      MixerUiStage.encoding => l10n.mixerStageEncoding,
    };

String mixerErrorText(AppLocalizations l10n, MixerErrorKind k) => switch (k) {
      MixerErrorKind.modelMissing => l10n.mixerErrorModelMissing,
      MixerErrorKind.notEnoughMemory => l10n.mixerErrorMemory,
      MixerErrorKind.decodeFailed => l10n.mixerErrorDecode,
      MixerErrorKind.encodeFailed => l10n.mixerErrorEncode,
      MixerErrorKind.separationFailed => l10n.mixerErrorSeparation,
      MixerErrorKind.incompatible => l10n.mixerErrorIncompatible,
      MixerErrorKind.tempoTooFar => l10n.mixerErrorTempo,
      MixerErrorKind.sourceUnavailable => l10n.mixerErrorSource,
      MixerErrorKind.cancelled => l10n.mixerErrorCancelled,
      MixerErrorKind.unknown => l10n.mixerErrorUnknown,
    };

String mixerEstimateText(AppLocalizations l10n, Duration d) {
  final time = d.inSeconds < 60 ? l10n.mixerEstimateUnderMinute : l10n.mixerEstimateMinutes((d.inSeconds / 60).ceil());
  return l10n.mixerEstimate(time);
}

String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// Heardy Mixer: elegir dos canciones, la combinación y la calidad, y hacer el
/// mix en el dispositivo. El estado vive en [HeardyMixerProvider], así que se
/// puede salir mientras trabaja y volver a ver el avance.
class HeardyMixerScreen extends StatefulWidget {
  const HeardyMixerScreen({
    super.key,
    this.preselectA,
    this.preselectRemoteA,
    this.loadLibrary,
    this.showMiniPlayer = true,
  });

  /// "Mezclar con…": la canción del menú entra como A.
  final Song? preselectA;

  /// "Mezclar con…" sobre una pista de Explorar: entra como A buscada (se
  /// vuelve a resolver antes de usarla).
  final RemoteTrack? preselectRemoteA;
  final Future<List<Song>> Function()? loadLibrary;
  final bool showMiniPlayer;

  static Route<void> route({Song? preselectA, RemoteTrack? preselectRemoteA}) => MaterialPageRoute<void>(
      builder: (_) => HeardyMixerScreen(preselectA: preselectA, preselectRemoteA: preselectRemoteA));

  @override
  State<HeardyMixerScreen> createState() => _HeardyMixerScreenState();
}

class _HeardyMixerScreenState extends State<HeardyMixerScreen> {
  late final HeardyMixerProvider _mixer;
  MixerPhase? _lastPhase;

  @override
  void initState() {
    super.initState();
    _mixer = context.read<HeardyMixerProvider>();
    _lastPhase = _mixer.phase;
    final a = widget.preselectA;
    // Tras el primer frame: notificar durante el build de la ruta falla.
    if (a != null) WidgetsBinding.instance.addPostFrameCallback((_) => _mixer.setLibrarySong(MixerSlotId.a, a));
    final remote = widget.preselectRemoteA;
    if (a == null && remote != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _mixer.setSearchResult(MixerSlotId.a, remote));
    }
    _mixer.addListener(_onMixerChanged);
    _mixer.ensureReady();
  }

  @override
  void dispose() {
    _mixer.removeListener(_onMixerChanged);
    super.dispose();
  }

  void _onMixerChanged() {
    final phase = _mixer.phase;
    final finished = _lastPhase == MixerPhase.running && phase == MixerPhase.succeeded;
    _lastPhase = phase;
    if (finished && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _openResult();
  }

  void _openResult() {
    final r = _mixer.lastRecord;
    if (r == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HeardyMixerResultScreen(record: r)));
  }

  Future<void> _pickLibrary(MixerSlotId id) async {
    final song = await showMixerLibraryPicker(context, load: widget.loadLibrary);
    if (song != null) _mixer.setLibrarySong(id, song);
  }

  Future<void> _pickSearch(MixerSlotId id) async {
    final listed = await showMixerSearchPicker(context, source: context.read<DownloadSource>());
    if (listed == null || !mounted) return;
    final ok = await _mixer.setSearchResult(id, listed);
    if (!ok && mounted && _mixer.slot(id)?.track?.id != listed.id) {
      _snack(AppLocalizations.of(context)!.mixerResolveFailed);
    }
  }

  Future<void> _alsoDownload(RemoteTrack track) async {
    final choice = await pickTargetPlaylist(context, kind: Playlist.kindLocal);
    if (choice == null || !mounted) return;
    final playlistId = await resolveTargetPlaylistId(context, choice);
    if (playlistId == null || !mounted) return;
    // La pista ya viene de resolve: metadata completa, una fila normal en `songs`.
    await context.read<DownloadProvider>().enqueueTrack(track, playlistId: playlistId, metadataComplete: true);
    _mixer.markQueuedForLibrary(track.id);
  }

  /// Aviso de modo arriesgado, una vez por sesión. `true` si se puede seguir
  /// con ese modo; si el usuario prefiere el más ligero, lo deja elegido y
  /// devuelve `false`.
  Future<bool> _confirmRisk(MixQualityMode mode) async {
    if (!_mixer.isRisky(mode) || _mixer.riskAcknowledged) return true;
    final l10n = AppLocalizations.of(context)!;
    final lighter = _mixer.recommendedQuality;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.mixerRiskTitle, style: const TextStyle(color: Colors.white)),
        content: Text(l10n.mixerRiskBody, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(key: const Key('mixer_risk_cancel'), onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(l10n.mixerCancel)),
          if (lighter != mode)
            TextButton(
              key: const Key('mixer_risk_lighter'),
              onPressed: () => Navigator.pop(ctx, 'lighter'),
              child: Text(l10n.mixerRiskLighter(mixerQualityLabel(l10n, lighter))),
            ),
          TextButton(key: const Key('mixer_risk_continue'), onPressed: () => Navigator.pop(ctx, 'continue'), child: Text(l10n.mixerRiskContinue)),
        ],
      ),
    );
    if (!mounted) return false;
    if (choice == 'continue') {
      _mixer.acknowledgeRisk();
      return true;
    }
    if (choice == 'lighter') _mixer.quality = lighter;
    return false;
  }

  Future<void> _selectQuality(MixQualityMode mode) async {
    if (await _confirmRisk(mode) && mounted) _mixer.quality = mode;
  }

  Future<void> _start() async {
    if (!await _confirmRisk(_mixer.quality) || !mounted) return;
    if (!_mixer.isModelInstalled(_mixer.quality)) {
      final ok = await _confirmModelDownload();
      if (!ok || !mounted) return;
      if (!await _mixer.downloadModel() || !mounted) return;
    }
    await _mixer.start();
  }

  Future<bool> _confirmModelDownload() async {
    final l10n = AppLocalizations.of(context)!;
    final size = _megabytes(_mixer.modelDownloadBytes(_mixer.quality));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(l10n.mixerModelConfirmTitle, style: const TextStyle(color: Colors.white)),
        content: Text(l10n.mixerModelConfirmBody(size), style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(key: const Key('mixer_model_confirm_cancel'), onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.mixerCancel)),
          TextButton(key: const Key('mixer_model_confirm_ok'), onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.mixerDownload)),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m = context.watch<HeardyMixerProvider>();
    final Widget content;
    if (!m.ready) {
      content = const Center(child: CircularProgressIndicator());
    } else if (!m.supported) {
      content = _Message(l10n.mixerUnsupported);
    } else {
      content = ListView(
        padding: EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, widget.showMiniPlayer ? 120 : 24),
        children: [
          for (final id in MixerSlotId.values) ...[
            _SlotCard(
              id: id,
              mixer: m,
              onPickLibrary: () => _pickLibrary(id),
              onPickSearch: () => _pickSearch(id),
              onAlsoDownload: _alsoDownload,
            ),
            const SizedBox(height: 12),
          ],
          _SectionTitle(l10n.mixerModeTitle),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in MixMode.values)
                ChoiceChip(
                  key: Key('mixer_mode_${mode.name}'),
                  label: Text(mixerModeLabel(l10n, mode)),
                  selected: m.mode == mode,
                  onSelected: m.phase == MixerPhase.running ? null : (_) => m.mode = mode,
                ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionTitle(l10n.mixerQualityTitle),
          _QualityPicker(mixer: m, onSelect: _selectQuality),
          const SizedBox(height: 8),
          _ModelStatus(mixer: m, onDownload: () async {
            if (await _confirmModelDownload() && mounted) await _mixer.downloadModel();
          }),
          const SizedBox(height: 16),
          _RunPanel(mixer: m, onStart: _start, onOpenResult: _openResult),
        ],
      );
    }
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            SafeArea(
              child: MaxWidthCenter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, kScreenGutter, 4),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          Expanded(
                            child: Text(
                              l10n.mixerTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ),
            if (widget.showMiniPlayer) const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(kScreenGutter),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
        ),
      );
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.id,
    required this.mixer,
    required this.onPickLibrary,
    required this.onPickSearch,
    required this.onAlsoDownload,
  });
  final MixerSlotId id;
  final HeardyMixerProvider mixer;
  final VoidCallback onPickLibrary, onPickSearch;
  final void Function(RemoteTrack) onAlsoDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final slot = mixer.slot(id);
    final busy = mixer.phase == MixerPhase.running;
    final label = id == MixerSlotId.a ? l10n.mixerSongA : l10n.mixerSongB;
    final pickers = Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          key: Key('mixer_pick_library_${id.name}'),
          onPressed: busy ? null : onPickLibrary,
          icon: const Icon(Icons.library_music_rounded, size: 18),
          label: Text(l10n.mixerPickLibrary),
        ),
        OutlinedButton.icon(
          key: Key('mixer_pick_search_${id.name}'),
          onPressed: busy ? null : onPickSearch,
          icon: const Icon(Icons.search_rounded, size: 18),
          label: Text(l10n.mixerPickSearch),
        ),
      ],
    );
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: AppTheme.primaryLight, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (mixer.isResolving(id))
            Row(children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(l10n.mixerResolving, style: const TextStyle(color: Colors.white70)),
            ])
          else if (slot == null)
            pickers
          else ...[
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: MixerArt(path: slot.artPath, url: slot.thumbnailUrl, title: slot.title, size: 52),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(slot.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                      Text(slot.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
                    ],
                  ),
                ),
                if (!busy)
                  IconButton(
                    key: Key('mixer_clear_${id.name}'),
                    tooltip: l10n.mixerRemove,
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () => mixer.clearSlot(id),
                  ),
              ],
            ),
            if (slot.isRemote) ...[
              const SizedBox(height: 8),
              Text(l10n.mixerFromSearchNote, style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
              const SizedBox(height: 4),
              if (mixer.isQueuedForLibrary(slot.track!.id))
                Row(children: [
                  Icon(Icons.check_rounded, size: 18, color: AppTheme.primaryLight),
                  const SizedBox(width: 6),
                  Text(l10n.mixerAlsoDownloadQueued, style: const TextStyle(color: Colors.white70)),
                ])
              else
                TextButton.icon(
                  key: Key('mixer_also_download_${id.name}'),
                  onPressed: () => onAlsoDownload(slot.track!),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(l10n.mixerAlsoDownload),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _QualityPicker extends StatelessWidget {
  const _QualityPicker({required this.mixer, required this.onSelect});
  final HeardyMixerProvider mixer;
  final void Function(MixQualityMode) onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = mixer.qualityOptions;
    final busy = mixer.phase == MixerPhase.running;
    final selected = options.where((o) => o.mode == mixer.quality).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in options)
              ChoiceChip(
                key: Key('mixer_quality_${o.mode.name}'),
                label: Text(mixerQualityLabel(l10n, o.mode)),
                selected: mixer.quality == o.mode,
                onSelected: busy ? null : (_) => onSelect(o.mode),
              ),
          ],
        ),
        for (final o in options.where((o) => o.risky))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${mixerQualityLabel(l10n, o.mode)}: ${l10n.mixerQualityRisky}',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
            ),
          ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              mixerEstimateText(l10n, selected.estimate),
              key: const Key('mixer_estimate'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

class _ModelStatus extends StatelessWidget {
  const _ModelStatus({required this.mixer, required this.onDownload});
  final HeardyMixerProvider mixer;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final q = mixer.quality;
    final state = mixer.modelDownloadState;
    if (state == MixerModelDownloadState.downloading) {
      final p = mixer.modelProgress;
      final text = switch (p?.phase) {
        MixModelPhase.verifying => l10n.mixerModelVerifying,
        MixModelPhase.extracting => l10n.mixerModelExtracting,
        _ => l10n.mixerModelDownloading(((p?.fraction ?? 0) * 100).floor()),
      };
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: p?.phase == MixModelPhase.downloading ? p!.fraction : null,
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('mixer_model_cancel'),
            onPressed: mixer.cancelModelDownload,
            child: Text(l10n.mixerCancel),
          ),
        ],
      );
    }
    if (mixer.isModelInstalled(q)) return const SizedBox.shrink();
    final resumable = state == MixerModelDownloadState.cancelled || state == MixerModelDownloadState.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.mixerModelMissing(_megabytes(mixer.modelDownloadBytes(q))),
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        if (state == MixerModelDownloadState.failed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(mixer.modelChecksumFailed ? l10n.mixerModelChecksum : l10n.mixerModelFailed,
                style: TextStyle(color: Colors.orangeAccent.shade100, fontSize: 13)),
          ),
        TextButton.icon(
          key: const Key('mixer_model_download'),
          onPressed: mixer.phase == MixerPhase.running ? null : onDownload,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(resumable && !mixer.modelChecksumFailed ? l10n.mixerModelResume : l10n.mixerModelDownload),
        ),
      ],
    );
  }
}

class _RunPanel extends StatelessWidget {
  const _RunPanel({required this.mixer, required this.onStart, required this.onOpenResult});
  final HeardyMixerProvider mixer;
  final VoidCallback onStart, onOpenResult;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (mixer.phase) {
      case MixerPhase.running:
        final stage = mixer.stage ?? MixerUiStage.preparing;
        return Container(
          key: const Key('mixer_progress'),
          decoration: AppTheme.glassCard(highlighted: true),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in MixerUiStage.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Icon(
                      s.index < stage.index
                          ? Icons.check_circle_rounded
                          : s == stage
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: s.index <= stage.index ? AppTheme.primaryLight : Colors.white38,
                    ),
                    const SizedBox(width: 8),
                    Text(mixerStageLabel(l10n, s),
                        style: TextStyle(color: s == stage ? Colors.white : Colors.white60)),
                  ]),
                ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: mixer.fraction),
              const SizedBox(height: 8),
              Text(l10n.mixerRunningHint, style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(key: const Key('mixer_cancel'), onPressed: mixer.cancel, child: Text(l10n.mixerCancel)),
              ),
            ],
          ),
        );
      case MixerPhase.succeeded:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTheme.gradientButton(
              onPressed: onOpenResult,
              child: Text(l10n.mixerViewResult, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            TextButton(onPressed: mixer.reset, child: Text(l10n.mixerNewMix)),
          ],
        );
      case MixerPhase.failed:
      case MixerPhase.idle:
        final error = mixer.error;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  mixerErrorText(l10n, error),
                  key: const Key('mixer_error'),
                  style: TextStyle(
                    color: error == MixerErrorKind.cancelled ? Colors.white70 : Colors.orangeAccent.shade100,
                  ),
                ),
              ),
            AppTheme.gradientButton(
              onPressed: mixer.canStart ? onStart : null,
              child: Text(
                error == null || error == MixerErrorKind.cancelled ? l10n.mixerStart : l10n.mixerRetry,
                key: const Key('mixer_start'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
    }
  }
}
