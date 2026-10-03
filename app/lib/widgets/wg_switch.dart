import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../update/app_updater.dart';
import 'common.dart';

/// Opens the Tailscale → WireGuard switch as a dialog, with [preselect]
/// ticked if it can be switched.
Future<void> showWireGuardSwitchDialog(BuildContext context, {String? preselect}) async {
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.l.t('wgMigrateTitle'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Flexible(child: WireGuardSwitchPanel(preselect: preselect, scrollable: true)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.t('close'))),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _Step { idle, switching, waiting, done, failed }

class _Row {
  _Step step = _Step.idle;
  bool selected = false;
  ConnectivityProbe? probe;
  bool probing = false;
  String? error;
  String? command;
}

/// Servers still on Tailscale, each with whether it can move to WireGuard,
/// and one button that switches the ticked ones. Used by the "move to
/// WireGuard" banner and by Settings → WireGuard.
class WireGuardSwitchPanel extends StatefulWidget {
  final String? preselect;
  final bool scrollable;
  const WireGuardSwitchPanel({super.key, this.preselect, this.scrollable = false});

  @override
  State<WireGuardSwitchPanel> createState() => _WireGuardSwitchPanelState();
}

class _WireGuardSwitchPanelState extends State<WireGuardSwitchPanel> {
  final Map<String, _Row> _rows = {};
  bool _running = false;

  /// Servers that went through this panel stay listed with their result
  /// after they leave Tailscale.
  final Set<String> _touched = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeAll());
  }

  _Row _row(String id) => _rows.putIfAbsent(id, _Row.new);

  List<Vps> _servers(AppState state) => [
        for (final v in state.vpsList)
          if ((v.isTailscale && v.status != 'pending') || _touched.contains(v.id)) v,
      ];

  /// Why [v] cannot be switched right now, or null when it can.
  String? _blocker(BuildContext context, Vps v) {
    final l = L.read(context);
    if (!v.online) return l.t('wgRowOffline');
    if (v.agentVersion.isNotEmpty &&
        RegExp(r'^\d').hasMatch(v.agentVersion) &&
        AppUpdater.compareVersions(v.agentVersion, '2.0.0') < 0) {
      return l.f('wgRowOldAgent', {'v': v.agentVersion});
    }
    if (v.publicIp.isEmpty) return l.t('wgRowNoIp');
    final p = _row(v.id).probe;
    if (p != null && !p.wireguardOk) {
      return switch (p.reason) {
        'same_nat' => l.t('wgRowSameNat'),
        'cgnat' => l.t('wgRowCgnat'),
        'private_unreachable' => l.t('wgRowPrivate'),
        _ => l.f('methodUnavailable', {'reason': p.reason.isNotEmpty ? p.reason : p.ipClass}),
      };
    }
    return null;
  }

  Future<void> _probeAll() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    final servers = _servers(state);
    for (final v in servers) {
      if (widget.preselect == v.id) _row(v.id).selected = true;
    }
    await Future.wait([
      for (final v in servers)
        if (v.publicIp.isNotEmpty) _probe(state.api, v),
    ]);
    if (!mounted) return;
    // A preselected server that turned out not to be switchable is unticked.
    setState(() {
      for (final v in _servers(state)) {
        if (_blocker(context, v) != null) _row(v.id).selected = false;
      }
    });
  }

  Future<void> _probe(ApiClient api, Vps v) async {
    final r = _row(v.id);
    setState(() => r.probing = true);
    try {
      r.probe = await api.probeConnectivity(v.publicIp);
    } catch (_) {
      // No verdict is not a refusal; the switch itself checks again.
    }
    if (mounted) setState(() => r.probing = false);
  }

  Future<void> _switchSelected() async {
    final state = context.read<AppState>();
    final ids = [
      for (final v in _servers(state))
        if (_row(v.id).selected && _row(v.id).step != _Step.done) v.id,
    ];
    if (ids.isEmpty) return;
    setState(() => _running = true);
    // One at a time: each switch rekeys the panel's tunnel device.
    for (final id in ids) {
      if (!mounted) return;
      await _switchOne(state, id);
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _switchOne(AppState state, String id) async {
    final r = _row(id);
    final v = state.vpsList.where((x) => x.id == id).firstOrNull;
    if (v == null) return;
    _touched.add(id);
    setState(() {
      r.step = _Step.switching;
      r.error = null;
      r.command = null;
    });
    try {
      final res = await state.api.migrateWireGuard(id, publicIp: v.publicIp);
      if (!mounted) return;
      if (res['pushed'] != true) {
        // The agent did not take the switch over its connection; the
        // install command does it by hand on the server.
        setState(() {
          r.step = _Step.failed;
          r.error = L.read(context).t('wgRowNotPushed');
          r.command = (res['install_command'] as String? ?? '').trim();
        });
        return;
      }
      setState(() => r.step = _Step.waiting);
      final confirmed = await _waitConfirmed(state.api, id);
      // Closed mid-wait: leave the switch to the agent, which confirms over
      // the tunnel or reverts by itself when its trial runs out.
      if (!mounted) return;
      if (!confirmed) {
        // Put it back on Tailscale now rather than leave it on trial for
        // ten minutes; the agent is still reachable over its fallback.
        try {
          await state.api.switchBackTailscale(id);
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          r.step = _Step.failed;
          r.error = L.read(context).t('wgRowTimeout');
        });
        await state.refreshAll();
        return;
      }
      setState(() => r.step = _Step.done);
      await state.refreshAll();
    } catch (e) {
      if (mounted) {
        setState(() {
          r.step = _Step.failed;
          r.error = e is ApiException ? e.message : '$e';
        });
      }
    }
  }

  /// True once the agent itself says it runs on WireGuard with nothing to
  /// fall back to: it only drops the fallback after a register through the
  /// tunnel, so a connection over the old Tailscale route does not count.
  Future<bool> _waitConfirmed(ApiClient api, String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final st = await api.transportStatus(id);
        if (st['transport'] == 'wireguard' && (st['pending'] ?? '') == '') return true;
      } catch (_) {
        // Mid-reconnect; ask again.
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final servers = _servers(state);
    final l = context.l;
    final selected = servers.where((v) => _row(v.id).selected && _row(v.id).step != _Step.done).length;

    final intro = Text(l.t('wgSwitchIntro'),
        style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45));
    if (servers.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        intro,
        const SizedBox(height: 14),
        Text(l.t('wgSwitchNone'), style: const TextStyle(fontSize: 12)),
      ]);
    }

    final list = Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final v in servers) _serverRow(context, v)],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        intro,
        const SizedBox(height: 12),
        if (widget.scrollable) Flexible(child: SingleChildScrollView(child: list)) else list,
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(l.t('wgSwitchFootnote'),
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _running || selected == 0 ? null : _switchSelected,
            icon: _running
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.swap_horiz, size: 16),
            label: Text(selected > 0 ? l.f('wgSwitchN', {'n': selected}) : l.t('wgMigrateStart')),
          ),
        ]),
      ],
    );
  }

  Widget _serverRow(BuildContext context, Vps v) {
    final l = context.l;
    final r = _row(v.id);
    final blocker = r.step == _Step.idle ? _blocker(context, v) : null;
    final canTick = blocker == null && !_running && r.step != _Step.done;

    Widget status;
    switch (r.step) {
      case _Step.idle:
        status = blocker != null
            ? Text(blocker, style: const TextStyle(fontSize: 11, color: BeacleColors.warn))
            : Text(
                r.probing
                    ? l.t('wgRowChecking')
                    : r.probe?.reason == 'ping_blocked'
                        ? l.t('wgRowReadyNoPing')
                        : l.t('wgRowReady'),
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim));
      case _Step.switching:
      case _Step.waiting:
        status = Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6)),
          const SizedBox(width: 6),
          Text(
            l.t(r.step == _Step.switching ? 'wgRowSwitching' : 'wgRowWaiting'),
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
        ]);
      case _Step.done:
        status = Text(l.t('wgRowDone'), style: const TextStyle(fontSize: 11, color: BeacleColors.ok));
      case _Step.failed:
        status = Text(r.error ?? '', style: const TextStyle(fontSize: 11, color: BeacleColors.err));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi.withValues(alpha: r.selected ? 0.9 : 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: r.selected ? BeacleColors.accent.withValues(alpha: 0.5) : BeacleColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Checkbox(
            value: r.selected || r.step == _Step.done,
            onChanged: canTick ? (x) => setState(() => r.selected = x ?? false) : null,
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(v.name,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(v.publicIp.isNotEmpty ? v.publicIp : v.host,
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'monospace')),
              ]),
              const SizedBox(height: 2),
              status,
            ]),
          ),
        ]),
        if (r.command != null && r.command!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            child: SecretCopyField(r.command!),
          ),
      ]),
    );
  }
}
