import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/explore.dart';
import '../models/song.dart';
import '../providers/explore_provider.dart';
import '../services/download_source.dart';
import '../theme/app_theme.dart';
import 'desktop_horizontal_scroller.dart';
import 'skeleton_box.dart';

const double kExploreGutter = 16;

/// Alto de una lista horizontal de tarjetas cuadradas de [size] dp con título
/// y subtítulo debajo, escalado con el tamaño de letra del sistema.
double exploreCardListHeight(BuildContext context, double size) =>
    size + 12 + MediaQuery.textScalerOf(context).scale(36);

class ExploreShelfHeader extends StatelessWidget {
  final String title;

  /// Menú de la sección (ocultar, cambiar país), alineado a la derecha.
  final Widget? trailing;
  const ExploreShelfHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
      ),
    );
    final menu = trailing;
    return Padding(
      padding: EdgeInsets.fromLTRB(kExploreGutter, menu == null ? 24 : 16, menu == null ? kExploreGutter : 4, 12),
      child: menu == null ? text : Row(children: [Expanded(child: text), menu]),
    );
  }
}

/// Marco común de una estantería: cabecera + esqueleto / error con
/// "Reintentar" / contenido. Aislado por estantería: un fallo aquí no toca a
/// las demás.
class ExploreShelfFrame<T> extends StatelessWidget {
  /// null: sin cabecera (Inicio pinta una por cada estantería del servidor).
  final String? title;

  /// Menú de la cabecera; ignorado si [title] es null.
  final Widget? trailing;
  final ShelfState<T> state;
  final VoidCallback onRetry;
  final Widget skeleton;
  final Widget Function(T data) builder;
  final bool Function(T data) isEmpty;

  /// Qué mostrar con datos vacíos; null oculta la estantería entera.
  final Widget? emptyState;

  const ExploreShelfFrame({
    super.key,
    required this.title,
    this.trailing,
    required this.state,
    required this.onRetry,
    required this.skeleton,
    required this.builder,
    required this.isEmpty,
    this.emptyState,
  });

  @override
  Widget build(BuildContext context) {
    final data = state.data;
    if (data == null) {
      if (state.hasError) return _withHeader(_ErrorRow(onRetry: onRetry));
      return _withHeader(skeleton);
    }
    if (isEmpty(data)) {
      final empty = emptyState;
      return empty == null ? const SizedBox.shrink() : _withHeader(empty);
    }
    return _withHeader(builder(data));
  }

  Widget _withHeader(Widget body) {
    final t = title;
    if (t == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [ExploreShelfHeader(t, trailing: trailing), body],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorRow({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kExploreGutter),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.exploreShelfError,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
            ),
          ),
          TextButton(
            key: const Key('explore_shelf_retry'),
            onPressed: onRetry,
            child: Text(l10n.exploreShelfRetry),
          ),
        ],
      ),
    );
  }
}

/// Lista horizontal con las mismas guardas laterales en todas las estanterías.
class ExploreHorizontalList extends StatelessWidget {
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;

  const ExploreHorizontalList({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    return DesktopHorizontalScroller(
      height: height,
      builder: (context, controller, extra) => ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kExploreGutter).add(extra),
        itemCount: itemCount,
        separatorBuilder: (_, __) => SizedBox(width: spacing),
        itemBuilder: itemBuilder,
      ),
    );
  }
}

/// Portada cuadrada con título y subtítulo: listas de reproducción, álbumes.
class ExploreSquareCard extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String subtitle;
  final double size;
  final VoidCallback onTap;

  const ExploreSquareCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.onTap,
    this.subtitle = '',
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: size,
                height: size,
                child: imageUrl.isEmpty
                    ? _placeholder()
                    : Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        cacheWidth: (size * 2).round(),
                        errorBuilder: (_, __, ___) => _placeholder(),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(title)),
        child: const Icon(Icons.queue_music_rounded, color: Colors.white70, size: 36),
      );
}

String albumSubtitle(ExploreAlbum album) =>
    [album.artist, album.year].where((s) => s.isNotEmpty).join(' · ');

class ExplorePlaylistsRow extends StatelessWidget {
  final List<ExplorePlaylist> playlists;
  final void Function(ExplorePlaylist) onTap;
  final double size;

  const ExplorePlaylistsRow({super.key, required this.playlists, required this.onTap, this.size = 160});

  @override
  Widget build(BuildContext context) {
    return ExploreHorizontalList(
      height: exploreCardListHeight(context, size),
      itemCount: playlists.length,
      itemBuilder: (_, i) => ExploreSquareCard(
        imageUrl: playlists[i].thumbnailUrl,
        title: playlists[i].title,
        subtitle: playlists[i].subtitle,
        size: size,
        onTap: () => onTap(playlists[i]),
      ),
    );
  }
}

class ExploreAlbumsRow extends StatelessWidget {
  final List<ExploreAlbum> albums;
  final void Function(ExploreAlbum) onTap;
  final double size;

  const ExploreAlbumsRow({super.key, required this.albums, required this.onTap, this.size = 150});

  @override
  Widget build(BuildContext context) {
    return ExploreHorizontalList(
      height: exploreCardListHeight(context, size),
      itemCount: albums.length,
      itemBuilder: (_, i) => ExploreSquareCard(
        imageUrl: albums[i].thumbnailUrl,
        title: albums[i].title,
        subtitle: albumSubtitle(albums[i]),
        size: size,
        onTap: () => onTap(albums[i]),
      ),
    );
  }
}

/// Tarjeta de una pista remota en una estantería: tocar REPRODUCE ([onPlay]);
/// descargar queda en el menú (mantener pulsado o el botón de más opciones).
/// Sin [onPlay] (escritorio, no hay streaming) tocar descarga.
class ExploreTrackCard extends StatelessWidget {
  static const double size = 140;

  final RemoteTrack track;
  final VoidCallback onDownload;
  final VoidCallback? onPlay;
  final bool isLoadingStream;

  const ExploreTrackCard({
    super.key,
    required this.track,
    required this.onDownload,
    required this.onPlay,
    required this.isLoadingStream,
  });

  void _openMenu(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onPlay != null)
              ListTile(
                key: Key('card_listen_${track.id}'),
                leading: Icon(Icons.play_arrow_rounded, color: AppTheme.primaryLight),
                title: Text(l10n.searchListenTooltip),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onPlay!();
                },
              ),
            ListTile(
              key: Key('card_download_${track.id}'),
              leading: Icon(Icons.download_rounded, color: AppTheme.primaryLight),
              title: Text(l10n.searchListenDownloadAction),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onDownload();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final play = onPlay;
    return SizedBox(
      width: size,
      child: InkWell(
        key: Key('explore_track_${track.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: isLoadingStream ? null : (play ?? onDownload),
        onLongPress: isLoadingStream ? null : () => _openMenu(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    track.thumbnailUrl.isEmpty
                        ? _placeholder()
                        : Image.network(
                            track.thumbnailUrl,
                            fit: BoxFit.cover,
                            cacheWidth: (size * 2).round(),
                            errorBuilder: (_, __, ___) => _placeholder(),
                          ),
                    if (isLoadingStream)
                      const ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      )
                    else
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: IconButton(
                          key: Key('explore_track_more_${track.id}'),
                          tooltip: AppLocalizations.of(context)!.exploreTrackMoreTooltip,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 20),
                          style: IconButton.styleFrom(backgroundColor: Colors.black45),
                          onPressed: () => _openMenu(context),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(track.title)),
        child: const Icon(Icons.music_note_rounded, color: Colors.white70),
      );
}

/// Esqueleto de una fila de tarjetas cuadradas (o circulares).
class ExploreCardsSkeleton extends StatelessWidget {
  final double size;
  final bool circle;
  const ExploreCardsSkeleton({super.key, this.size = 150, this.circle = false});

  @override
  Widget build(BuildContext context) {
    return ExploreHorizontalList(
      height: exploreCardListHeight(context, size),
      itemCount: 4,
      itemBuilder: (_, __) => SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: size, height: size, radius: 12, circle: circle),
            const SizedBox(height: 8),
            SkeletonBox(width: size * 0.8, height: 12),
            const SizedBox(height: 6),
            SkeletonBox(width: size * 0.5, height: 10),
          ],
        ),
      ),
    );
  }
}

/// "Escuchar de nuevo": cuadrícula compacta de 2 filas que se desplaza en
/// horizontal. Tocar una canción la reproduce igual que en Inicio.
class QuickPicksGrid extends StatelessWidget {
  static const double cellHeight = 56;
  static const double rowGap = 8;

  final List<List<Song>> columns;
  final void Function(Song) onTap;

  const QuickPicksGrid({super.key, required this.columns, required this.onTap});

  static double columnWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.78).clamp(240.0, 320.0);

  @override
  Widget build(BuildContext context) {
    final width = columnWidth(context);
    return ExploreHorizontalList(
      height: cellHeight * 2 + rowGap,
      itemCount: columns.length,
      itemBuilder: (_, i) => SizedBox(
        width: width,
        child: Column(
          children: [
            for (var r = 0; r < columns[i].length; r++) ...[
              if (r > 0) const SizedBox(height: rowGap),
              _QuickPickCell(song: columns[i][r], onTap: () => onTap(columns[i][r])),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuickPickCell extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  const _QuickPickCell({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('quick_pick_${song.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: QuickPicksGrid.cellHeight,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
                child: SizedBox(
                  width: QuickPicksGrid.cellHeight,
                  height: QuickPicksGrid.cellHeight,
                  child: _art(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _art() {
    if (song.artPath.isNotEmpty && File(song.artPath).existsSync()) {
      return Image.file(File(song.artPath), fit: BoxFit.cover, cacheWidth: 112);
    }
    return Container(
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(song.title)),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
  }
}

class QuickPicksSkeleton extends StatelessWidget {
  const QuickPicksSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final width = QuickPicksGrid.columnWidth(context);
    return ExploreHorizontalList(
      height: QuickPicksGrid.cellHeight * 2 + QuickPicksGrid.rowGap,
      itemCount: 3,
      itemBuilder: (_, __) => SizedBox(
        width: width,
        child: Column(
          children: const [
            SkeletonBox(height: QuickPicksGrid.cellHeight),
            SizedBox(height: QuickPicksGrid.rowGap),
            SkeletonBox(height: QuickPicksGrid.cellHeight),
          ],
        ),
      ),
    );
  }
}

/// Mensaje corto dentro de una estantería (p. ej. "Escucha algo para ver
/// recomendaciones").
class ExploreEmptyNote extends StatelessWidget {
  final String text;
  const ExploreEmptyNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kExploreGutter),
      child: Text(text, style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13)),
    );
  }
}

/// "Tus artistas": avatares circulares (degradado + inicial; no hay foto).
class ArtistAvatarsRow extends StatelessWidget {
  static const double size = 96;

  final List<String> artists;
  final void Function(String) onTap;

  /// Artista que se está resolviendo ahora: muestra un indicador sobre su avatar.
  final String? loadingArtist;

  const ArtistAvatarsRow({super.key, required this.artists, required this.onTap, this.loadingArtist});

  @override
  Widget build(BuildContext context) {
    return ExploreHorizontalList(
      height: size + 12 + MediaQuery.textScalerOf(context).scale(34),
      itemCount: artists.length,
      itemBuilder: (_, i) => SizedBox(
        width: size,
        child: InkWell(
          key: Key('explore_artist_${artists[i]}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(artists[i]),
          child: Column(
            children: [
              Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppTheme.gradientForTitle(artists[i]),
                ),
                child: loadingArtist == artists[i]
                    ? const SizedBox(
                        key: Key('explore_artist_loading'),
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                      )
                    : Text(
                        _initial(artists[i]),
                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                artists[i],
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _initial(String name) {
    final t = name.trim();
    return t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase();
  }
}

/// Artistas similares de un perfil: avatares circulares con foto.
class ExploreRelatedArtistsRow extends StatelessWidget {
  static const double size = 96;

  final List<ExploreRelatedArtist> artists;
  final void Function(ExploreRelatedArtist) onTap;

  const ExploreRelatedArtistsRow({super.key, required this.artists, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ExploreHorizontalList(
      height: size + 12 + MediaQuery.textScalerOf(context).scale(34),
      itemCount: artists.length,
      itemBuilder: (_, i) => SizedBox(
        width: size,
        child: InkWell(
          key: Key('explore_related_${artists[i].channelId}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(artists[i]),
          child: Column(
            children: [
              ClipOval(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: artists[i].thumbnailUrl.isEmpty
                      ? _placeholder(artists[i].name)
                      : Image.network(
                          artists[i].thumbnailUrl,
                          fit: BoxFit.cover,
                          cacheWidth: (size * 2).round(),
                          errorBuilder: (_, __, ___) => _placeholder(artists[i].name),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                artists[i].name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(String name) => Container(
        decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(name)),
        alignment: Alignment.center,
        child: const Icon(Icons.person_rounded, color: Colors.white70, size: 40),
      );
}

class MoodChipsRow extends StatelessWidget {
  final List<ExploreMood> moods;
  final void Function(ExploreMood) onTap;

  const MoodChipsRow({super.key, required this.moods, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DesktopHorizontalScroller(
      height: 40,
      builder: (context, controller, extra) => ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kExploreGutter).add(extra),
        itemCount: moods.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => ActionChip(
          key: Key('mood_chip_${moods[i].params}'),
          label: Text(moods[i].title),
          labelStyle: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          side: BorderSide.none,
          shape: const StadiumBorder(),
          onPressed: () => onTap(moods[i]),
        ),
      ),
    );
  }
}

/// Aviso único cuando las estanterías de red no están disponibles (sin servidor
/// o sin sesión). Las locales siguen mostrándose.
class ExploreHintCard extends StatelessWidget {
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key actionKey;

  const ExploreHintCard({
    super.key,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.actionKey = const Key('explore_hint_action'),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(kExploreGutter, 24, kExploreGutter, 0),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.explore_rounded, color: AppTheme.primaryLight, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              key: actionKey,
              style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
