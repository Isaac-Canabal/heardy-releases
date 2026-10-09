import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/statistics_data.dart';
import '../services/cloud_source.dart';
import '../theme/app_theme.dart';
import '../widgets/statistics_view.dart';
import '../l10n/app_localizations.dart';
import '../services/friendly_error.dart';

/// Estadísticas de un amigo. La línea que de verdad paga el refactor de F1:
/// `StatisticsView(data: StatisticsData.fromMap(...), headerLabel: '@usuario')`
/// pinta EXACTAMENTE lo mismo que la sección propia de Ajustes, sin duplicar
/// maquetación.
class FriendProfileScreen extends StatefulWidget {
  final String username;
  const FriendProfileScreen({super.key, required this.username});

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  bool _isWeek = true;
  StatisticsData? _data;
  String? _nowPlaying;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final json = await context
          .read<CloudSource>()
          .getStatsFriend(widget.username, period: _isWeek ? 'week' : 'month');
      if (!mounted) return;
      setState(() {
        _data = StatisticsData.fromMap(json);
        _nowPlaying = json['nowPlaying'] as String?;
      });
    } on CloudSourceException catch (e) {
      if (!mounted) return;
      setState(() => _error = localizedErrorReport(AppLocalizations.of(context)!, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text('@${widget.username}'), backgroundColor: Colors.transparent),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      decoration: AppTheme.glassCard(),
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            _nowPlaying != null ? Icons.graphic_eq_rounded : Icons.music_off_rounded,
                            color: _nowPlaying != null ? AppTheme.primaryLight : Colors.white38,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _nowPlaying ?? l10n.friendsNoActivity,
                              style: TextStyle(color: _nowPlaying != null ? Colors.white : Colors.white38),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    StatisticsView(
                      data: _data,
                      isWeek: _isWeek,
                      headerLabel: '@${widget.username}',
                      onPeriodChanged: (isWeek) {
                        setState(() {
                          _isWeek = isWeek;
                          _data = null;
                        });
                        _load();
                      },
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
