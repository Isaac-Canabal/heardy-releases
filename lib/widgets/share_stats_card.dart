import 'package:flutter/material.dart';

import '../models/statistics_data.dart';
import '../theme/app_theme.dart';
import '../widgets/statistics_view.dart';

/// Ancho lógico FIJO (360, × `pixelRatio: 3` da 1080px de ancho — ver
/// `share_image_service.dart`), alto determinado por el CONTENIDO.
///
/// **Antes tenía una altura fija de 640 también, y eso cortaba la tarjeta a
/// mitad de las estadísticas**: con el top 10 de artistas lleno, la sección
/// "Top canciones" que va después ya no entraba en lo que quedaba dentro de
/// un `Expanded` + `SingleChildScrollView(NeverScrollableScrollPhysics)` — se
/// laqueaba fuera del área capturada por `renderBoundaryPng` en vez de
/// aparecer cortada a la vista (nunca hubo scroll de verdad, sólo un tamaño
/// fijo que asumía que 10 artistas + 5 canciones siempre entraban en 640dp,
/// cosa que no es cierta). Dejar que la tarjeta crezca con su contenido
/// (`mainAxisSize.min`, sin `Expanded` ni scroll) es lo que garantiza que
/// TODO lo que `StatisticsView` decide mostrar llegue a la imagen exportada.
class ShareStatsCard extends StatelessWidget {
  final String username;
  final StatisticsData data;
  final bool isWeek;

  const ShareStatsCard({super.key, required this.username, required this.data, required this.isWeek});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Container(
        // Fondo OPACO a propósito: `AppTheme.glassCard()` es translúcido, así
        // que un `RepaintBoundary` a su alrededor se pintaría sobre
        // transparencia si esta tarjeta no pusiera su propio fondo.
        decoration: AppTheme.gradientScaffold(),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@$username',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            StatisticsView(
              data: data,
              isWeek: isWeek,
              decorated: false,
              onPeriodChanged: null,
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                'Heardy',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
