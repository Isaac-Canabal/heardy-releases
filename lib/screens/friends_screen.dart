import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/cloud_source.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';
import 'friend_profile_screen.dart';
import '../services/friendly_error.dart';
import '../services/input_sanitizer.dart';

/// Ruta empujada, no una sexta pestaña — misma decisión, y por la misma
/// razón, que la Etapa 11 tomó para la lista de espera de importaciones (ver
/// CLAUDE.md, "Cloud sync"): un sexto `NavigationDestination` deja muy poco
/// espacio por icono, y Amigos necesita buscador + bandeja + detalle, tres
/// niveles que un `ListView` de Ajustes tampoco resolvería bien.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  bool _showRequests = false;
  bool _loading = true;
  String? _error;
  FriendsList? _friends;
  final _searchController = TextEditingController();
  bool _searching = false;
  DateTime? _lastSearchAt;
  String? _searchError;
  UserLookupResult? _searchResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final friends = await context.read<CloudSource>().getFriends();
      if (!mounted) return;
      setState(() => _friends = friends);
    } on CloudSourceException catch (e) {
      if (!mounted) return;
      setState(() => _error = localizedErrorReport(AppLocalizations.of(context)!, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search() async {
    final username = sanitizeUsernameInput(_searchController.text);
    if (username.isEmpty || _searching) return;
    final now = DateTime.now();
    if (!canRunUserSearch(username, _lastSearchAt, now)) {
      if (now.difference(_lastSearchAt ?? DateTime.fromMillisecondsSinceEpoch(0)) >= userSearchCooldown) {
        setState(() {
          _searchResult = null;
          _searchError = AppLocalizations.of(context)!.errorCheckInput;
        });
      }
      return;
    }
    _lastSearchAt = now;
    setState(() {
      _searching = true;
      _searchError = null;
      _searchResult = null;
    });
    try {
      final result = await context.read<CloudSource>().lookupUser(username);
      if (!mounted) return;
      setState(() => _searchResult = result);
    } on CloudSourceException catch (e) {
      if (!mounted) return;
      setState(() => _searchError = localizedErrorReport(AppLocalizations.of(context)!, e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _sendRequest(String username) async {
    try {
      await context.read<CloudSource>().sendFriendRequest(username);
      if (!mounted) return;
      setState(() => _searchResult = null);
      _searchController.clear();
      await _load();
    } on CloudSourceException catch (e) {
      if (!mounted) return;
      setState(() => _searchError = localizedErrorReport(AppLocalizations.of(context)!, e));
    }
  }

  Future<void> _accept(String username) async {
    await context.read<CloudSource>().acceptFriendRequest(username);
    await _load();
  }

  Future<void> _rejectOrCancel(String username) async {
    await context.read<CloudSource>().rejectOrCancelFriendRequest(username);
    await _load();
  }

  Future<void> _remove(String username) async {
    await context.read<CloudSource>().removeFriend(username);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final friends = _friends;
    final requestCount = (friends?.incoming.length ?? 0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.friendsTitle),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(_error!, style: const TextStyle(color: Colors.white70)),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _buildSearchBox(l10n),
                          const SizedBox(height: 20),
                          SegmentedButton<bool>(
                            segments: [
                              ButtonSegment(value: false, label: Text(l10n.friendsTabFriends)),
                              ButtonSegment(value: true, label: Text(l10n.friendsTabRequests(requestCount))),
                            ],
                            selected: {_showRequests},
                            onSelectionChanged: (s) => setState(() => _showRequests = s.first),
                          ),
                          const SizedBox(height: 16),
                          if (_showRequests) ..._buildRequests(l10n, friends) else ..._buildFriendsList(l10n, friends),
                          const SizedBox(height: 24),
                          Text(
                            l10n.friendsNoPushNotice,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }

  Widget _buildSearchBox(AppLocalizations l10n) {
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(hintText: l10n.friendsSearchHint, prefixText: '@'),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: Text(l10n.friendsSearchButton),
              ),
            ],
          ),
          if (_searchError != null) ...[
            const SizedBox(height: 8),
            Text(_searchError!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          if (_searchResult != null) ...[
            const SizedBox(height: 12),
            _buildSearchResultRow(l10n, _searchResult!),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchResultRow(AppLocalizations l10n, UserLookupResult result) {
    Widget action;
    switch (result.relation) {
      case UserRelation.self:
        action = const SizedBox.shrink();
        break;
      case UserRelation.friend:
        action = const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 20);
        break;
      case UserRelation.pendingOutgoing:
        action = Text(l10n.friendsCancel, style: const TextStyle(color: Colors.white54));
        break;
      case UserRelation.pendingIncoming:
        action = Text(l10n.friendsAccept, style: TextStyle(color: AppTheme.primaryLight));
        break;
      case UserRelation.none:
        action = TextButton(
          onPressed: () => _sendRequest(result.username),
          child: Text(l10n.friendsSendRequest),
        );
        break;
    }
    return Row(
      children: [
        Expanded(child: Text('@${result.username}', style: const TextStyle(color: Colors.white))),
        action,
      ],
    );
  }

  List<Widget> _buildRequests(AppLocalizations l10n, FriendsList? friends) {
    final incoming = friends?.incoming ?? const [];
    final outgoing = friends?.outgoing ?? const [];
    if (incoming.isEmpty && outgoing.isEmpty) {
      return [Center(child: Text(l10n.friendsEmpty, style: const TextStyle(color: Colors.white54)))];
    }
    return [
      for (final entry in incoming)
        _requestTile(entry.username, trailing: [
          IconButton(
            icon: const Icon(Icons.check_rounded, color: Colors.greenAccent),
            onPressed: () => _accept(entry.username),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
            onPressed: () => _rejectOrCancel(entry.username),
          ),
        ]),
      for (final entry in outgoing)
        _requestTile(entry.username, trailing: [
          TextButton(onPressed: () => _rejectOrCancel(entry.username), child: Text(l10n.friendsCancel)),
        ]),
    ];
  }

  Widget _requestTile(String username, {required List<Widget> trailing}) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
      title: Text('@$username', style: const TextStyle(color: Colors.white)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }

  List<Widget> _buildFriendsList(AppLocalizations l10n, FriendsList? friends) {
    final list = friends?.friends ?? const [];
    if (list.isEmpty) {
      return [Center(child: Text(l10n.friendsEmpty, style: const TextStyle(color: Colors.white54)))];
    }
    return [
      for (final entry in list)
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
          title: Text('@${entry.username}', style: const TextStyle(color: Colors.white)),
          subtitle: Text(
            entry.nowPlaying ?? l10n.friendsNoActivity,
            style: TextStyle(color: entry.nowPlaying != null ? AppTheme.primaryLight : Colors.white38),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.person_remove_outlined, color: Colors.white38),
            onPressed: () => _remove(entry.username),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => FriendProfileScreen(username: entry.username)),
          ),
        ),
    ];
  }
}
