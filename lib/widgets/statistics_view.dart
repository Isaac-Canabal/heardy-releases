import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/statistics_data.dart';
import '../services/statistics_service.dart';
import '../theme/app_theme.dart';

/// La tarjeta de estadísticas, extraída de `settings_screen.dart` para que la
/// puedan reutilizar tal cual el perfil de un amigo y la imagen que se
/// comparte. Los cuerpos de los widgets son los mismos que estaban ahí: esto
/// es una extracción, no un rediseño.
///
/// Ninguno de estos widgets toca la base de datos ni un `Provider`: reciben un
/// [StatisticsData] ya cargado. Por eso se pueden probar en un `testWidgets`
/// normal, sin `runAsync`, sin ffi y sin árbol de providers.
class StatisticsView extends StatelessWidget {
  /// `null` mientras se carga: pinta el indicador de progreso conservando la
  /// cabecera y el contenedor, que es como se veía antes de la extracción.
  final StatisticsData? data;

  final bool isWeek;

  /// `null` oculta el selector semana/mes — el caso de la imagen compartida y
  /// de una vista de sólo lectura.
  final ValueChanged<bool>? onPeriodChanged;

  /// Si está desplegada la lista larga de canciones. Con [onToggleExpanded] en
  /// `null` no se dibuja el chevron y siempre se muestran 5.
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  /// `false` quita el contenedor de cristal. Es lo que necesita la imagen
  /// compartida: `AppTheme.glassCard()` es translúcido, así que un
  /// `RepaintBoundary` a su alrededor se renderiza sobre transparencia; quien
  /// exporta pone su propio fondo opaco.
  final bool decorated;

  /// Encabezado de la tarjeta. `null` usa "Tu actividad"; el perfil de un
  /// amigo y la imagen compartida pasan aquí su `@usuario`.
  final String? headerLabel;

  /// Se pinta a la derecha de la cabecera, después del selector de periodo.
  /// Lo usa el botón de compartir, para que los widgets hoja no tengan que
  /// enterarse de que compartir existe.
  final Widget? trailing;

  const StatisticsView({
    super.key,
    required this.data,
    required this.isWeek,
    this.onPeriodChanged,
    this.expanded = false,
    this.onToggleExpanded,
    this.decorated = true,
    this.headerLabel,
    this.trailing,
  });

  static const int _collapsedSongCount = 5;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.bar_chart_rounded, color: AppTheme.primaryLight, size: 20),
            const SizedBox(width: 8),
            // `Expanded`, no `Flexible` + `Spacer`: con el toggle de periodo Y
            // el botón de compartir compitiendo por la misma fila en una
            // pantalla de 360dp, el título se comía casi todo el ancho antes
            // de llegar a truncarse — el mismo desbordamiento que ya se
            // documentó una vez en este proyecto (Etapa 9), pero acá el ancho
            // sobrante era negativo, no sólo insuficiente para un hint.
            Expanded(
              child: Text(
                headerLabel ?? l10n.statsYourActivity,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        if (onPeriodChanged != null || trailing != null) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onPeriodChanged != null) PeriodToggle(isWeek: isWeek, onChanged: onPeriodChanged!),
              if (trailing != null) trailing!,
            ],
          ),
        ],
        const SizedBox(height: 16),
        _buildBody(context, l10n),
      ],
    );

    if (!decorated) return content;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: content,
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final stats = data;
    if (stats == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (stats.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          l10n.statsEmptyHint,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 13,
          ),
        ),
      );
    }

    final visibleSongs = expanded || stats.topSongs.length <= _collapsedSongCount
        ? stats.topSongs
        : stats.topSongs.sublist(0, _collapsedSongCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StatMiniCard(
                label: l10n.statsPlaysLabel,
                value: '${stats.totalPlays}',
                icon: Icons.play_circle_outline_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatMiniCard(
                label: l10n.statsListenTimeLabel,
                value: formatListenTime(stats.totalListenSeconds),
                icon: Icons.schedule_rounded,
              ),
            ),
          ],
        ),
        if (stats.topArtists.isNotEmpty) ...[
          const SizedBox(height: 16),
          _listLabel(l10n.statsTopArtists),
          const SizedBox(height: 8),
          for (var i = 0; i < stats.topArtists.length; i++)
            TopArtistRow(
              rank: i + 1,
              name: stats.topArtists[i].name.isEmpty
                  ? l10n.statsUnknownArtist
                  : stats.topArtists[i].name,
              playCount: stats.topArtists[i].playCount,
            ),
        ],
        if (stats.topSongs.isNotEmpty) ...[
          const SizedBox(height: 16),
          _listLabel(l10n.statsTopSongs),
          const SizedBox(height: 8),
          for (var i = 0; i < visibleSongs.length; i++)
            TopSongRow(
              rank: i + 1,
              title: visibleSongs[i].title.isEmpty
                  ? l10n.statsUntitledSong
                  : visibleSongs[i].title,
              artist: visibleSongs[i].artist.isEmpty
                  ? l10n.statsUnknownArtist
                  : visibleSongs[i].artist,
              artPath: visibleSongs[i].artPath,
              playCount: visibleSongs[i].playCount,
            ),
          if (onToggleExpanded != null && stats.topSongs.length > _collapsedSongCount)
            Center(
              child: IconButton(
                icon: Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                onPressed: onToggleExpanded,
              ),
            ),
        ],
      ],
    );
  }

  Widget _listLabel(String text) => Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
}

class PeriodToggle extends StatelessWidget {
  final bool isWeek;
  final ValueChanged<bool> onChanged;

  const PeriodToggle({super.key, required this.isWeek, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PeriodChip(
            label: l10n.statsWeek,
            selected: isWeek,
            onTap: () => onChanged(true),
          ),
          PeriodChip(
            label: l10n.statsMonth,
            selected: !isWeek,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const PeriodChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.primary.withValues(alpha: 0.35) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class StatMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const StatMiniCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.primaryLight, size: 18),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class TopArtistRow extends StatelessWidget {
  final int rank;
  final String name;
  final int playCount;

  const TopArtistRow({
    super.key,
    required this.rank,
    required this.name,
    required this.playCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _RankLabel(rank),
          const SizedBox(width: 8),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.person_rounded,
              color: Colors.white.withValues(alpha: 0.7),
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          _PlayCountBadge(playCount),
        ],
      ),
    );
  }
}

class TopSongRow extends StatelessWidget {
  final int rank;
  final String title;
  final String artist;
  final String artPath;
  final int playCount;

  const TopSongRow({
    super.key,
    required this.rank,
    required this.title,
    required this.artist,
    required this.artPath,
    required this.playCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _RankLabel(rank),
          const SizedBox(width: 8),
          ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildArt()),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          _PlayCountBadge(playCount),
        ],
      ),
    );
  }

  Widget _buildArt() {
    if (artPath.isNotEmpty) {
      final file = File(artPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderArt(),
        );
      }
    }
    return _placeholderArt();
  }

  Widget _placeholderArt() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.7),
        size: 20,
      ),
    );
  }
}

class _RankLabel extends StatelessWidget {
  final int rank;

  const _RankLabel(this.rank);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      child: Text(
        '$rank',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _PlayCountBadge extends StatelessWidget {
  final int playCount;

  const _PlayCountBadge(this.playCount);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${playCount}x',
        style: TextStyle(
          color: AppTheme.primaryLight,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
