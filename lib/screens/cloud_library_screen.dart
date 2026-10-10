import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/cloud_library_provider.dart';
import '../providers/download_provider.dart';
import '../services/friendly_error.dart';
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';

/// "En tus otros dispositivos": lo que la nube tiene y este equipo no, con
/// descarga de un toque a la Bandeja. Sólo lee la nube al abrirse o al pulsar
/// actualizar, nunca por su cuenta.
class CloudLibraryScreen extends StatefulWidget {
  const CloudLibraryScreen({super.key});

  @override
  State<CloudLibraryScreen> createState() => _CloudLibraryScreenState();
}

class _CloudLibraryScreenState extends State<CloudLibraryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<CloudLibraryProvider>().refresh();
    });
  }

  Future<void> _downloadOne(CloudLibraryEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<CloudLibraryProvider>().downloadOne(entry);
    final text = switch (result) {
      CloudDownloadResult.noMatch => l10n.cloudLibNoMatch,
      CloudDownloadResult.failed => l10n.cloudLibFailed,
      _ => null,
    };
    if (text != null) messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _downloadAll() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<CloudLibraryProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final total = provider.downloadableCount;
    final count = total < maxPlaylistBatch ? total : maxPlaylistBatch;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cloudLibConfirmTitle(count)),
        content: Text([
          l10n.cloudLibConfirmBody,
          if (exceedsPlaylistBatch(total)) l10n.cloudLibConfirmCap(maxPlaylistBatch),
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.cloudLibDownload)),
        ],
      ),
    );
    if (ok != true) return;
    final queued = await provider.downloadAll();
    messenger.showSnackBar(SnackBar(content: Text(l10n.cloudLibQueuedSnack(queued))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<CloudLibraryProvider>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.cloudLibTitle),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: l10n.cloudLibRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: provider.status == CloudLibraryStatus.loading ? null : provider.refresh,
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(child: MaxWidthCenter(child: _buildBody(l10n, provider))),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n, CloudLibraryProvider provider) {
    switch (provider.status) {
      case CloudLibraryStatus.idle:
      case CloudLibraryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case CloudLibraryStatus.noLibrary:
        return _message(l10n.cloudLibNoLibrary);
      case CloudLibraryStatus.error:
        return _message(l10n.cloudLibError(localizedErrorReport(l10n, provider.error!)));
      case CloudLibraryStatus.ready:
        final entries = provider.entries;
        if (entries.isEmpty) return _message(l10n.cloudLibEmpty);
        final downloadable = provider.downloadableCount;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 4),
              child: Text(
                l10n.cloudLibHint,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: kScreenGutter),
                    title: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      entry.hasLink ? entry.artist : l10n.cloudLibNoLink(entry.artist),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: entry.queued
                        ? Text(l10n.cloudLibQueued, style: const TextStyle(color: Colors.white54, fontSize: 12))
                        : IconButton(
                            tooltip: l10n.cloudLibDownload,
                            icon: const Icon(Icons.download_rounded, color: Colors.white70),
                            onPressed: () => _downloadOne(entry),
                          ),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(kScreenGutter),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: downloadable == 0 ? null : _downloadAll,
                    child: Text(l10n.cloudLibDownloadAll(downloadable)),
                  ),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _message(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
      ),
    );
  }
}
