import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

Widget tailscaleRequirementBanner() => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      child: const Text(
        tailscaleRequirement,
        style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.45),
      ),
    );

Future<void> showAddVpsDialog(BuildContext context) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _AddServerDialog(),
  );
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog();

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  ConnectivityProbe? _probe;
  String? _method; // wireguard | tailscale
  bool _pickingMethod = false;
  bool _busy = false;
  String? _error;
  Vps? _created;
  String? _installCmd;
  bool _waiting = false;
  bool _timedOut = false;
  bool _online = false;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _probe = null;
      _method = null;
      _pickingMethod = false;
    });
    try {
      final p = await context.read<AppState>().api.probeConnectivity(_host.text.trim());
      if (!mounted) return;
      setState(() {
        _probe = p;
        _method = p.recommended;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  bool get _wgOk => _probe?.wireguardOk == true;

  Future<void> _createWireGuard() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = context.read<AppState>();
    try {
      state.onUserAction();
      final name = _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim();
      final vps = await state.api.createVps(
        name: name,
        transport: 'wireguard',
        publicIp: _probe?.ip.isNotEmpty == true ? _probe!.ip : _host.text.trim(),
      );
      final cmd = await state.api.wireGuardInstallCommand(vps.id);
      if (!mounted) return;
      setState(() {
        _created = vps;
        _installCmd = cmd;
        _busy = false;
        _waiting = true;
      });
      _waitOnline(vps.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _waitOnline(String id) async {
    final state = context.read<AppState>();
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (mounted && DateTime.now().isBefore(end)) {
      await state.refreshAll();
      final v = state.vpsList.where((x) => x.id == id).firstOrNull;
      if (v != null && v.online) {
        if (mounted) setState(() { _waiting = false; _online = true; });
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    if (mounted) setState(() { _waiting = false; _timedOut = true; });
  }

  Future<void> _pickTailscale() async {
    final state = context.read<AppState>();
    List<TailscaleDevice> devices;
    try {
      devices = await state.api.tailscaleDevices();
    } catch (e) {
      setState(() => _error = e is ApiException && e.status == 503 ? tailscaleNotOnPc : '$e');
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<TailscaleDevice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.glassHi,
        title: Text(context.l.t('methodTs')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tailscaleRequirementBanner(),
              const SizedBox(height: 14),
              if (devices.where((d) => !d.self).isEmpty)
                const Text(tailscaleNoPeers,
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45))
              else
                SmoothListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in devices.where((x) => !x.self))
                      ListTile(
                        title: Text(d.name, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                          [
                            if (d.ips.isNotEmpty) d.ips.first,
                            if (!d.online) 'offline',
                            d.os,
                          ].where((s) => s.isNotEmpty).join(' · '),
                          style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim),
                        ),
                        onTap: () => Navigator.pop(ctx, d),
                      ),
                  ],
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('cancel')))],
      ),
    );
    if (picked == null || !mounted) return;
    final ip = picked.ips.isNotEmpty ? picked.ips.first : '';
    try {
      state.onUserAction();
      await state.api.createVps(name: picked.name, tailscaleName: picked.name, tailscaleIp: ip);
      await state.refreshAll();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: BeacleColors.glassHi,
          title: Text(context.l.f('wgInstallTitle', {'name': picked.name})),
          content: const SizedBox(width: 520, child: AddVpsCommand()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('close')))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Widget _methodTile(String id, String title, String detail, {String? blocked}) {
    final selected = _method == id;
    final enabled = blocked == null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ListTile(
        enabled: enabled,
        selected: selected,
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          blocked != null ? context.l.f('methodUnavailable', {'reason': blocked}) : detail,
          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.35),
        ),
        onTap: !enabled || selected
            ? null
            : () => setState(() {
                  _method = id;
                  _pickingMethod = false;
                }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      backgroundColor: BeacleColors.glassHi,
      title: Text(l.t('addServerTitle')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_created == null) ...[
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: l.t('addServerName'), isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _host,
                decoration: InputDecoration(
                  labelText: l.t('addServerHost'),
                  hintText: l.t('addServerHostHint'),
                  isDense: true,
                ),
                onSubmitted: (_) => _busy ? null : _check(),
              ),
              const SizedBox(height: 12),
              SmallButton(_busy ? l.t('addChecking') : l.t('addCheck'),
                  icon: Icons.search, onPressed: _busy ? null : _check),
              if (_probe != null) ...[
                const SizedBox(height: 12),
                Text('${_probe!.ip} · ${_probe!.ipClass}${_probe!.reason.isNotEmpty ? ' · ${_probe!.reason}' : ''}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas', color: BeacleColors.textDim)),
                if (!_probe!.pingOk)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(l.t('pingWarn'),
                        style: const TextStyle(fontSize: 11, color: BeacleColors.warn, height: 1.35)),
                  ),
                const SizedBox(height: 10),
                if (_pickingMethod) ...[
                  Text(l.t('methodTitle'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  _methodTile('wireguard', l.t('methodWg'), l.t('methodWgDetail'),
                      blocked: _wgOk ? null : (_probe!.reason.isEmpty ? l.t('probeCgnat') : _probe!.reason)),
                  _methodTile('tailscale', l.t('methodTs'), l.t('methodTsDetail')),
                ] else ...[
                  Text(_method == 'tailscale' ? l.t('methodTs') : l.t('methodWg'),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  TextButton(
                    onPressed: () => setState(() => _pickingMethod = true),
                    child: Text(l.t('tryAnotherWay')),
                  ),
                ],
              ],
            ] else ...[
              Text(l.t('wgInstallBody'),
                  style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45)),
              const SizedBox(height: 10),
              if (_installCmd != null) SecretCopyField(_installCmd!),
              const SizedBox(height: 10),
              if (_waiting)
                Row(children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(l.t('wgWaiting'), style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                ]),
              if (_online) Text(l.t('wgConnected'), style: const TextStyle(fontSize: 12, color: BeacleColors.ok)),
              if (_timedOut) ...[
                Text(l.t('wgTimeout'), style: const TextStyle(fontSize: 12, color: BeacleColors.err, height: 1.4)),
                TextButton(
                  onPressed: () => setState(() {
                    _created = null;
                    _installCmd = null;
                    _timedOut = false;
                    _pickingMethod = true;
                  }),
                  child: Text(l.t('tryAnotherWay')),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(fontSize: 12, color: BeacleColors.err, height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('cancel'))),
        if (_created == null && _probe != null && !_pickingMethod)
          SmallButton(l.t('addVps'), icon: Icons.add, onPressed: _busy
              ? null
              : () {
                  if (_method == 'tailscale') {
                    _pickTailscale();
                  } else if (_wgOk) {
                    _createWireGuard();
                  }
                }),
        if (_online) TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('close'))),
      ],
    );
  }
}

class AddVpsCommand extends StatefulWidget {
  const AddVpsCommand({super.key});

  @override
  State<AddVpsCommand> createState() => _AddVpsCommandState();
}

class _AddVpsCommandState extends State<AddVpsCommand> {
  Future<String>? _cmd;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cmd ??= context.read<AppState>().api.installCommand();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.connected) {
      return const Text('Backend offline', style: TextStyle(fontSize: 12, color: BeacleColors.textDim));
    }
    return FutureBuilder<String>(
      future: _cmd,
      builder: (ctx, snap) {
        if (snap.hasError) {
          final msg = snap.error is ApiException ? (snap.error as ApiException).message : '${snap.error}';
          return Text(msg, style: const TextStyle(color: BeacleColors.err, fontSize: 12, height: 1.4));
        }
        if (!snap.hasData) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
        return CopyField(snap.data!);
      },
    );
  }
}

Future<bool> confirmDeleteVps(BuildContext context, Vps vps) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete VPS?'),
      content: Text(
        'Remove ${vps.name} from Beacle? The agent on the server is not uninstalled.',
        style: const TextStyle(fontSize: 13, color: BeacleColors.textDim, height: 1.45),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ),
  );
  return ok == true;
}
