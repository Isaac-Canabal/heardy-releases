import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/lan_sync_provider.dart';
import '../services/lan_sync_crypto.dart' show lanKeyFingerprint;
import '../services/lan_sync_service.dart';
import '../services/lan_sync_trust_store.dart';
import '../theme/app_theme.dart';
import '../widgets/lan_sync_pairing_dialog.dart';
import '../widgets/max_width_center.dart';

/// Texto de estado para el último resultado. Pura para poder probarla.
String lanResultText(AppLocalizations l10n, LanSyncResult r) {
  final name = r.peer?.label.isNotEmpty == true ? r.peer!.label : '—';
  switch (r.outcome) {
    case LanSyncOutcome.ok:
      final a = r.applied;
      return l10n.lanSyncResultSynced(name, a?.playlistsAdded ?? 0, a?.membershipsAdded ?? 0, a?.historyAdded ?? 0);
    case LanSyncOutcome.paired:
      return l10n.lanSyncResultPaired(name);
    case LanSyncOutcome.unreachable:
      return l10n.lanSyncResultUnreachable;
    case LanSyncOutcome.timeout:
      return l10n.lanSyncResultTimeout;
    case LanSyncOutcome.peerClosed:
      return l10n.lanSyncResultPeerClosed;
    case LanSyncOutcome.untrustedPeer:
      return l10n.lanSyncResultUntrusted;
    case LanSyncOutcome.peerNotPairing:
      return l10n.lanSyncResultPeerNotPairing;
    case LanSyncOutcome.sasRejectedLocal:
      return l10n.lanSyncResultSasLocal;
    case LanSyncOutcome.sasRejectedPeer:
      return l10n.lanSyncResultSasPeer;
    case LanSyncOutcome.protocolError:
      return l10n.lanSyncResultProtocol;
    case LanSyncOutcome.tooLarge:
      return l10n.lanSyncResultTooLarge;
    case LanSyncOutcome.notLocalAddress:
      return l10n.lanSyncResultNotLocal;
    case LanSyncOutcome.noNetwork:
      return l10n.lanSyncNoNetwork;
    case LanSyncOutcome.busy:
      return l10n.lanSyncResultBusy;
    case LanSyncOutcome.rateLimited:
      return l10n.lanSyncResultRateLimited;
    case LanSyncOutcome.failed:
      return l10n.lanSyncResultFailed;
  }
}

String _phaseText(AppLocalizations l10n, LanPhase phase) {
  switch (phase) {
    case LanPhase.connecting:
      return l10n.lanSyncPhaseConnecting;
    case LanPhase.handshaking:
      return l10n.lanSyncPhaseHandshaking;
    case LanPhase.confirming:
      return l10n.lanSyncPhaseConfirming;
    case LanPhase.exchanging:
      return l10n.lanSyncPhaseExchanging;
    case LanPhase.applying:
      return l10n.lanSyncPhaseApplying;
    case LanPhase.idle:
      return l10n.lanSyncPhaseConnecting;
  }
}

/// Sección de Ajustes: explica y abre la pantalla.
class LanSyncSettingsSection extends StatelessWidget {
  const LanSyncSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.lanSyncSectionBody, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LanSyncScreen())),
              icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(l10n.lanSyncOpenButton),
            ),
          ),
        ],
      ),
    );
  }
}

class LanSyncScreen extends StatefulWidget {
  const LanSyncScreen({super.key});

  @override
  State<LanSyncScreen> createState() => _LanSyncScreenState();
}

class _LanSyncScreenState extends State<LanSyncScreen> {
  late final LanSyncProvider _provider;
  final _address = TextEditingController();
  String? _addressError;
  var _sasDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<LanSyncProvider>();
    _provider.addListener(_watchSas);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_provider.start());
    });
  }

  @override
  void dispose() {
    _provider.removeListener(_watchSas);
    unawaited(_provider.stop());
    _address.dispose();
    super.dispose();
  }

  void _watchSas() {
    final request = _provider.pendingSas;
    if (request != null && !_sasDialogOpen && mounted) {
      _sasDialogOpen = true;
      unawaited(_showSas(request));
    } else if (request == null && _sasDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
  }

  Future<void> _showSas(LanSasRequest request) async {
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LanPairingDialog(
        sas: request.sas,
        peerName: request.peer.label,
        fingerprint: lanKeyFingerprint(request.peer.publicKey),
        replacesTrustedKey: request.replacesTrustedKey,
      ),
    );
    _sasDialogOpen = false;
    _provider.answerSas(request, answer ?? false);
  }

  Future<void> _forget(LanTrustedPeer peer) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.lanSyncForgetTitle(peer.label)),
        content: Text(l10n.lanSyncForgetBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.lanSyncForget, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) await _provider.forget(peer.deviceId);
  }

  ParsedLanAddress? _parsedAddress() {
    final parsed = parseLanAddress(_address.text);
    setState(() => _addressError = parsed == null ? AppLocalizations.of(context)!.lanSyncInvalidAddress : null);
    return parsed;
  }

  Widget _card(Widget child) => Container(
        decoration: AppTheme.glassCard(),
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 8),
        child: child,
      );

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      );

  Widget _deviceRow({
    required String name,
    String? subtitle,
    required List<Widget> actions,
  }) =>
      _card(Row(
        children: [
          Icon(Icons.devices_rounded, color: AppTheme.primaryLight),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                if (subtitle != null)
                  Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
              ],
            ),
          ),
          ...actions,
        ],
      ));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = context.watch<LanSyncProvider>();
    final busy = p.isBusy;
    final muted = TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 13);
    final trustedIds = {for (final peer in p.peers) peer.deviceId};
    final open = p.pairingOpenUntil;

    String? status;
    if (busy) {
      status = _phaseText(l10n, p.phase);
    } else if (p.lastResult != null) {
      status = lanResultText(l10n, p.lastResult!);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(l10n.lanSyncScreenTitle), backgroundColor: Colors.transparent),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(l10n.lanSyncExplain, style: muted),
                if (p.noNetwork)
                  _card(Text(l10n.lanSyncNoNetwork, style: const TextStyle(color: Colors.orangeAccent))),
                if (p.storeUnavailable)
                  _card(Text(l10n.lanSyncStoreError, style: const TextStyle(color: Colors.orangeAccent))),
                if (status != null) ...[
                  const SizedBox(height: 10),
                  _card(Row(
                    children: [
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      Expanded(
                        child: Text(
                          status,
                          key: const Key('lanSyncStatus'),
                          style: TextStyle(
                            color: !busy && (p.lastResult?.isSuccess ?? false) ? Colors.greenAccent : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  )),
                ],
                _title(l10n.lanSyncNearby),
                if (p.nearby.isEmpty && p.isActive) Text(l10n.lanSyncNearbyEmpty, style: muted),
                for (final d in p.nearby)
                  _deviceRow(
                    name: d.label,
                    subtitle: d.address.address,
                    actions: [
                      trustedIds.contains(d.deviceId)
                          ? FilledButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      final peer = p.peers.firstWhere((x) => x.deviceId == d.deviceId);
                                      p.syncWithPeer(peer);
                                    },
                              child: Text(l10n.lanSyncSync),
                            )
                          : OutlinedButton(
                              onPressed: busy ? null : () => p.pairWithNearby(d),
                              child: Text(l10n.lanSyncPair),
                            ),
                    ],
                  ),
                _title(l10n.lanSyncPaired),
                if (p.peers.isEmpty) Text(l10n.lanSyncPairedEmpty, style: muted),
                for (final peer in p.peers)
                  _deviceRow(
                    name: peer.label,
                    subtitle: l10n.lanSyncFingerprint(lanKeyFingerprint(peer.publicKey)),
                    actions: [
                      FilledButton(
                        onPressed: busy || !p.isActive ? null : () => p.syncWithPeer(peer),
                        child: Text(l10n.lanSyncSync),
                      ),
                      IconButton(
                        tooltip: l10n.lanSyncForget,
                        onPressed: busy ? null : () => _forget(peer),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (p.pairingCoolingDown)
                  Text(l10n.lanSyncPairingCooldown, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13))
                else if (open != null) ...[
                  Row(children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l10n.lanSyncPairingWaiting, style: muted)),
                    TextButton(onPressed: p.closePairingWindow, child: Text(l10n.commonCancel)),
                  ]),
                ] else
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: p.isActive && !busy ? p.openPairingWindow : null,
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: Text(l10n.lanSyncAllowPairing),
                    ),
                  ),
                _title(l10n.lanSyncConnectByAddress),
                if (p.addressHint != null) Text(l10n.lanSyncAddressOwn(p.addressHint!), style: muted),
                const SizedBox(height: 8),
                TextField(
                  controller: _address,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  maxLength: 21,
                  decoration: InputDecoration(
                    hintText: l10n.lanSyncAddressHint,
                    errorText: _addressError,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: busy || !p.isActive
                            ? null
                            : () {
                                final t = _parsedAddress();
                                if (t != null) p.pairWithAddress(t);
                              },
                        child: Text(l10n.lanSyncPair),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: busy || !p.isActive
                            ? null
                            : () {
                                final t = _parsedAddress();
                                if (t != null) p.syncWithAddress(t);
                              },
                        child: Text(l10n.lanSyncSync),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
