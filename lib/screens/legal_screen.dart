import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/legal_texts.dart';
import '../theme/app_theme.dart';

/// Términos de uso y política de privacidad.
///
/// Con [gate] en true es la pantalla del primer arranque: no hay forma de
/// salir sin marcar la casilla y aceptar, y la aceptación se registra con la
/// versión de los textos. Desde Ajustes se abre sin puerta, solo para leer.
class LegalScreen extends StatefulWidget {
  final bool gate;
  const LegalScreen({super.key, this.gate = false});

  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  bool _accepted = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !widget.gate,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.gate,
            title: Text(l10n.legalTitle),
            bottom: TabBar(
              tabs: [
                Tab(text: l10n.legalTermsTab),
                Tab(text: l10n.legalPrivacyTab),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: TabBarView(
                  children: [
                    _SectionsList(sections: termsSections, footer: l10n.legalVersionLine(legalVersion)),
                    _SectionsList(sections: privacySections, footer: l10n.legalVersionLine(legalVersion)),
                  ],
                ),
              ),
              if (widget.gate) _buildGateFooter(context, l10n),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGateFooter(BuildContext context, AppLocalizations l10n) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppTheme.primaryLight,
              value: _accepted,
              onChanged: (v) => setState(() => _accepted = v ?? false),
              title: Text(l10n.legalAcceptCheckbox, style: const TextStyle(fontSize: 13)),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _accepted
                    ? () => context.read<SettingsProvider>().acceptLegal(legalVersion)
                    : null,
                child: Text(l10n.legalAcceptButton),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionsList extends StatelessWidget {
  final List<LegalSection> sections;
  final String footer;
  const _SectionsList({required this.sections, required this.footer});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: sections.length + 1,
      itemBuilder: (context, i) {
        if (i == sections.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(footer, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
          );
        }
        final s = sections[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 6),
              Text(
                s.body,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13.5, height: 1.45),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Puerta del primer arranque: mientras la versión vigente de los textos no
/// esté aceptada, la app entera es la pantalla de términos. Espera a que las
/// preferencias carguen para no mostrarla un instante a quien ya aceptó.
class LegalGate extends StatelessWidget {
  final Widget child;
  const LegalGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    if (!settings.isLoaded) return const SizedBox.shrink();
    if (needsLegalAcceptance(settings.legalAcceptedVersion)) {
      return const LegalScreen(gate: true);
    }
    return child;
  }
}
