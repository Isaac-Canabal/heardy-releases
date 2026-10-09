import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../services/download_source.dart';
import '../services/friendly_error.dart';
import '../theme/app_theme.dart';
import '../widgets/explore_shelves.dart';
import '../widgets/mini_player.dart';
import '../widgets/skeleton_box.dart';
import 'explore_collection_screen.dart';

/// Listas de reproducción de un ánimo o género; tocar una abre su colección.
class ExploreMoodScreen extends StatefulWidget {
  final ExploreMood mood;

  const ExploreMoodScreen({super.key, required this.mood});

  @override
  State<ExploreMoodScreen> createState() => _ExploreMoodScreenState();
}

class _ExploreMoodScreenState extends State<ExploreMoodScreen> {
  static const double _maxCardWidth = 180;

  List<ExplorePlaylist>? _playlists;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final playlists = await context.read<DownloadSource>().exploreMood(
            widget.mood.params,
            country: deviceExploreCountry(),
          );
      if (!mounted) return;
      _playlists = playlists;
    } catch (e) {
      if (!mounted) return;
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(ExplorePlaylist p) {
    final source = context.read<DownloadSource>();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExploreCollectionScreen(
        title: p.title,
        thumbnailUrl: p.thumbnailUrl,
        loader: () => source.explorePlaylist(p.playlistId),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mainExtent = exploreCardListHeight(context, _maxCardWidth);
    final delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: _maxCardWidth,
      mainAxisExtent: mainExtent,
      crossAxisSpacing: 12,
      mainAxisSpacing: 16,
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.mood.title),
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            CustomScrollView(slivers: _buildSlivers(l10n, delegate)),
            const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(AppLocalizations l10n, SliverGridDelegate delegate) {
    const padding = EdgeInsets.fromLTRB(kExploreGutter, 8, kExploreGutter, 90);
    final playlists = _playlists;
    if (playlists == null) {
      if (_loading) {
        return [
          SliverPadding(
            padding: padding,
            sliver: SliverGrid(
              gridDelegate: delegate,
              delegate: SliverChildBuilderDelegate(
                (_, __) => const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: _maxCardWidth, height: _maxCardWidth, radius: 12),
                    SizedBox(height: 8),
                    SkeletonBox(width: 120, height: 12),
                  ],
                ),
                childCount: 8,
              ),
            ),
          ),
        ];
      }
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Text(
                  _error == null ? '' : localizedErrorReport(l10n, _error!),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('explore_mood_retry'),
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  onPressed: _load,
                  child: Text(l10n.exploreShelfRetry),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (playlists.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l10n.exploreMoodEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: padding,
        sliver: SliverGrid(
          gridDelegate: delegate,
          delegate: SliverChildBuilderDelegate(
            (_, i) => LayoutBuilder(
              builder: (_, c) => ExploreSquareCard(
                imageUrl: playlists[i].thumbnailUrl,
                title: playlists[i].title,
                size: c.maxWidth,
                onTap: () => _open(playlists[i]),
              ),
            ),
            childCount: playlists.length,
          ),
        ),
      ),
    ];
  }
}
