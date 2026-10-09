import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/sync_provider.dart';
import '../services/cloud_source.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/auth/login_screen.dart';
import '../services/friendly_error.dart';
import '../services/input_sanitizer.dart';

/// Se invoca desde EXACTAMENTE dos sitios (E-5 de la Etapa 16): al abrir
/// Amigos y al compartir estadísticas. Nunca en el registro — un usuario
/// migrado tiene que poder vincular su biblioteca sin elegir un handle.
///
/// Mismo molde que `pickTargetPlaylist`: sin sesión, empuja `LoginScreen`; si
/// ya hay nombre, lo devuelve directo; si no, abre la hoja. Cancelar
/// devuelve `null` y quien llamó aborta limpiamente.
Future<String?> ensureUsername(BuildContext context) async {
  final auth = context.read<HeardyAuthProvider>();
  if (!auth.isReady) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
    if (!context.mounted || !context.read<HeardyAuthProvider>().isReady) return null;
  }

  final source = context.read<CloudSource>();
  CloudAccount account;
  try {
    account = await source.getAccount();
  } on CloudSourceException catch (e) {
    // Antes esto devolvía null en silencio — el botón de compartir/el ícono
    // de Amigos parecían "no hacer nada". Un fallo real (servidor sin la
    // ruta todavía, sin cuenta, sin red) tiene que verse, no desaparecer.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(localizedErrorReport(AppLocalizations.of(context)!, e))));
    }
    return null;
  }
  if (account.username != null && account.username!.isNotEmpty) return account.username;
  if (!context.mounted) return null;

  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const UsernameClaimSheet(),
  );
}

class UsernameClaimSheet extends StatefulWidget {
  const UsernameClaimSheet({super.key});

  @override
  State<UsernameClaimSheet> createState() => _UsernameClaimSheetState();
}

class _UsernameClaimSheetState extends State<UsernameClaimSheet> {
  final _controller = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final username = sanitizeUsernameInput(_controller.text);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await context.read<CloudSource>().setUsername(username);
      if (!mounted) return;
      // Al instante, sin esperar la próxima sincronización completa — ver el
      // docstring de noteUsernameSaved: el nombre ya quedó guardado en el
      // servidor en este punto, esto sólo evita que la UI parezca no
      // haberse enterado si la siguiente sync falla por otra razón.
      context.read<SyncProvider>().noteUsernameSaved(saved);
      Navigator.of(context).pop(saved);
    } on CloudSourceException catch (e) {
      // Un 400/409 trae el motivo en español ("Sólo letras minúsculas…",
      // "Ese nombre ya está en uso"): `userMessage` lo muestra tal cual si es
      // una frase para personas y cae a un mensaje fijo si no.
      if (!mounted) return;
      setState(() => _error = localizedErrorReport(AppLocalizations.of(context)!, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.usernameClaimTitle,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: l10n.usernameClaimHint,
              errorText: _error,
              prefixText: '@',
            ),
            onSubmitted: (_) => _saving ? null : _save(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving || _controller.text.trim().isEmpty ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(l10n.usernameClaimSave),
            ),
          ),
        ],
      ),
    );
  }
}
