import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_notification.dart';
import '../providers/notifications_provider.dart';
import '../services/app_update_source.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';

/// Ruta empujada, igual que `FriendsScreen` — un mismo motivo: no hay hueco
/// para una sexta pestaña, y esto necesita bandeja + detalle, no un ícono
/// suelto en Ajustes.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<NotificationsProvider>();
    final items = provider.items;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.notificationsTitle),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: !provider.hasLoadedOnce
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: provider.refresh,
                  child: items.isEmpty
                      ? ListView(
                          children: [
                            SizedBox(
                              height: MediaQuery.sizeOf(context).height * 0.6,
                              child: Center(
                                child: Text(
                                  l10n.notificationsEmpty,
                                  style: const TextStyle(color: Colors.white54),
                                ),
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: items.length,
                          itemBuilder: (context, index) => _tile(context, l10n, provider, items[index]),
                        ),
                ),
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    AppLocalizations l10n,
    NotificationsProvider provider,
    AppNotification item,
  ) {
    switch (item.type) {
      case AppNotificationType.friendRequest:
        return _friendRequestTile(l10n, provider, item);
      case AppNotificationType.appUpdate:
        return _appUpdateTile(context, l10n, provider, item);
    }
  }

  Widget _friendRequestTile(
    AppLocalizations l10n,
    NotificationsProvider provider,
    AppNotification item,
  ) {
    final username = item.friendUsername!;
    return Card(
      color: Colors.white.withValues(alpha: 0.06),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
        title: Text(item.title, style: const TextStyle(color: Colors.white)),
        subtitle: Text(l10n.notificationsFriendRequestSubtitle, style: const TextStyle(color: Colors.white54)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.check_rounded, color: Colors.greenAccent),
              onPressed: () => provider.respondToFriendRequest(username, accept: true),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
              onPressed: () => provider.respondToFriendRequest(username, accept: false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appUpdateTile(
    BuildContext context,
    AppLocalizations l10n,
    NotificationsProvider provider,
    AppNotification item,
  ) {
    final info = item.updateInfo!;
    return Card(
      color: Colors.white.withValues(alpha: 0.06),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_rounded, color: AppTheme.primaryLight),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.notificationsUpdateTitle(item.title),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (item.body.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(item.body, style: const TextStyle(color: Colors.white54)),
            ],
            const SizedBox(height: 12),
            // `Wrap`, no `Row`: tres botones con etiquetas de texto no
            // entran en el ancho de un teléfono angosto — un `Row` sin
            // `Expanded`/`Flexible` simplemente pinta fuera de los márgenes
            // de la tarjeta en vez de acomodarse. `Wrap` los pasa a una
            // segunda línea en vez de desbordar.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => provider.dismissUpdate(info.tag),
                  child: Text(l10n.notificationsDismiss),
                ),
                OutlinedButton(
                  onPressed: info.htmlUrl.isEmpty ? null : () => _openRelease(info.htmlUrl),
                  child: Text(l10n.notificationsViewRelease),
                ),
                FilledButton(
                  onPressed: () => _openRelease(heardyDownloadsUrl),
                  child: Text(l10n.notificationsGoToDownloads),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRelease(String url) async {
    final uri = safeExternalUri(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}
