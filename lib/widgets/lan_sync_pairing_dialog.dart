import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// "1234 5678": el código se lee mejor en dos grupos.
String formatSas(String sas) => sas.length == 8 ? '${sas.substring(0, 4)} ${sas.substring(4)}' : sas;

/// Comparación numérica del emparejado: el mismo código tiene que verse en los
/// dos dispositivos. Devuelve `true` solo si el usuario confirma.
class LanPairingDialog extends StatelessWidget {
  final String sas;
  final String peerName;
  final String fingerprint;
  final bool replacesTrustedKey;

  const LanPairingDialog({
    super.key,
    required this.sas,
    required this.peerName,
    required this.fingerprint,
    this.replacesTrustedKey = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.lanSyncSasTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.lanSyncSasBody(peerName), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(
            formatSas(sas),
            key: const Key('lanSyncSas'),
            style: TextStyle(
              color: AppTheme.primaryLight,
              fontSize: 44,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.lanSyncSasFingerprint(fingerprint),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
            textAlign: TextAlign.center,
          ),
          if (replacesTrustedKey) ...[
            const SizedBox(height: 12),
            Text(
              l10n.lanSyncKeyReplacedWarning,
              key: const Key('lanSyncKeyReplaced'),
              style: const TextStyle(color: Colors.orangeAccent),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          Text(l10n.lanSyncSasQuestion, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('lanSyncSasNo'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.lanSyncSasNo),
        ),
        FilledButton(
          key: const Key('lanSyncSasYes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.lanSyncSasYes),
        ),
      ],
    );
  }
}
