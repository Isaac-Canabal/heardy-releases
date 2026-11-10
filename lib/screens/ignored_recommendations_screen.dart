import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/folder_sync_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';

/// "Recomendaciones ignoradas": lo que el usuario descartó de "En tus otros
/// dispositivos" en este dispositivo. Restaurar una (o todas) la devuelve a esa
/// lista en la siguiente lectura. Es una preferencia local, nunca se sincroniza.
class IgnoredRecommendationsScreen extends StatefulWidget {
  const IgnoredRecommendationsScreen({super.key});

  @override
  State<IgnoredRecommendationsScreen> createState() => _IgnoredRecommendationsScreenState();
}

class _IgnoredRecommendationsScreenState extends State<IgnoredRecommendationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FolderSyncProvider>().loadIgnored();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<FolderSyncProvider>();
    final items = provider.ignoredRecommendations;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.ignoredRecsSectionTitle),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: items.isEmpty
                ? Center(
                    key: const Key('ignored_empty'),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        l10n.ignoredRecsEmpty,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 4),
                        child: Text(
                          l10n.ignoredRecsHint,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final item = items[i];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: kScreenGutter),
                              title: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                item.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              trailing: TextButton(
                                key: Key('ignored_restore_${item.fileHash}'),
                                onPressed: () => provider.restoreRecommendation(item.fileHash),
                                child: Text(l10n.ignoredRecsRestore),
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
                              key: const Key('ignored_restore_all'),
                              onPressed: provider.restoreAllRecommendations,
                              child: Text(l10n.ignoredRecsRestoreAll),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
