import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/server_pool.dart';

/// Pone sobre [child] un aviso con cuenta atrás mientras todos los servidores
/// estén sin capacidad. Sin aviso, devuelve [child] tal cual.
class ServerCapacityGate extends StatelessWidget {
  final Widget child;
  const ServerCapacityGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final pool = context.read<ServerPool>();
    return ValueListenableBuilder<DateTime?>(
      valueListenable: pool.allExhaustedUntil,
      builder: (context, resetAt, _) {
        if (resetAt == null) return child;
        return Column(
          children: [
            _CapacityBanner(resetAt: resetAt),
            // El aviso ya absorbió la zona de la barra de estado.
            Expanded(
              child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
            ),
          ],
        );
      },
    );
  }
}

class _CapacityBanner extends StatefulWidget {
  final DateTime resetAt;
  const _CapacityBanner({required this.resetAt});

  @override
  State<_CapacityBanner> createState() => _CapacityBannerState();
}

class _CapacityBannerState extends State<_CapacityBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.resetAt.difference(DateTime.now().toUtc());
    return Material(
      color: Colors.orange.shade900,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.hourglass_bottom_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.serverCapacityBanner(formatRemaining(remaining)),
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
