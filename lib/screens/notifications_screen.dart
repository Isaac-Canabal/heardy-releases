import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notification.dart';
import '../providers/notifications_provider.dart';
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
        // La versión nueva ya no es una fila: bloquea con `UpdateGate`.
        return const SizedBox.shrink();
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
}
