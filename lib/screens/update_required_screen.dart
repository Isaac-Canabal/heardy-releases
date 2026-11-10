import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../providers/update_gate_provider.dart';
import '../services/app_update_source.dart';
import '../services/desktop_mini_mode_service.dart';
import '../theme/app_theme.dart';

typedef ExternalLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// Va por encima del `Navigator` (en `MaterialApp.builder`) para cubrir
/// también diálogos, hojas y rutas empujadas. Mientras está bloqueada, la app
/// de debajo sigue viva (la reproducción en curso no se toca) pero sin foco,
/// punteros ni semántica.
class UpdateGate extends StatelessWidget {
  final Widget child;
  final ExternalLauncher? launcher;

  const UpdateGate({super.key, required this.child, this.launcher});

  @override
  Widget build(BuildContext context) {
    final gate = context.watch<UpdateGateProvider>();
    final blocked = gate.blocked;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ExcludeFocus(
          excluding: blocked,
          child: ExcludeSemantics(
            excluding: blocked,
            child: IgnorePointer(ignoring: blocked, child: child),
          ),
        ),
        if (blocked)
          Positioned.fill(
            child: UpdateRequiredScreen(
              installedVersion: gate.installedVersion ?? '',
              requiredTag: gate.requiredTag ?? '',
              launcher: launcher ?? _launchExternal,
            ),
          ),
      ],
    );
  }
}

/// Página completa sin salida: sin cerrar, sin omitir, sin "más tarde". Su
/// única acción abre la sección de descargas del sitio.
class UpdateRequiredScreen extends StatefulWidget {
  final String installedVersion;
  final String requiredTag;
  final ExternalLauncher launcher;

  const UpdateRequiredScreen({
    super.key,
    required this.installedVersion,
    required this.requiredTag,
    required this.launcher,
  });

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _showAddress = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    DesktopMiniModeService.instance.isMini.addListener(_leaveMini);
    _leaveMini();
  }

  @override
  void dispose() {
    DesktopMiniModeService.instance.isMini.removeListener(_leaveMini);
    super.dispose();
  }

  // La ventana mini de escritorio no tiene sitio para esta página.
  void _leaveMini() {
    final mini = DesktopMiniModeService.instance;
    if (mini.isMini.value) unawaited(mini.exit().catchError((_) {}));
  }

  Future<void> _open() async {
    final uri = safeExternalUri(heardyDownloadsUrl);
    var ok = false;
    if (uri != null) {
      try {
        ok = await widget.launcher(uri);
      } catch (_) {}
    }
    if (!ok && mounted) setState(() => _showAddress = true);
  }

  Future<void> _copy() async {
    await Clipboard.setData(const ClipboardData(text: heardyDownloadsUrl));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final newVersion =
        widget.requiredTag.startsWith('v') ? widget.requiredTag.substring(1) : widget.requiredTag;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: AppTheme.gradientScaffold(),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.system_update_rounded, size: 64, color: AppTheme.primaryLight),
                      const SizedBox(height: 20),
                      Text(
                        l10n.updateRequiredTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.updateRequiredBody,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.updateRequiredVersions(widget.installedVersion, newVersion),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(onPressed: _open, child: Text(l10n.updateRequiredAction)),
                      if (_showAddress) ...[
                        const SizedBox(height: 16),
                        Text(
                          l10n.updateRequiredCouldNotOpen,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          heardyDownloadsUrl,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextButton(
                          onPressed: _copy,
                          child: Text(_copied ? l10n.updateRequiredCopied : l10n.updateRequiredCopyLink),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
