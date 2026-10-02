import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

Future<void> showWireGuardMigrateDialog(BuildContext context, Vps vps) async {
  await showDialog(
    context: context,
    builder: (_) => _WgMigrateDialog(vps: vps),
  );
}

class _WgMigrateDialog extends StatefulWidget {
  final Vps vps;
  const _WgMigrateDialog({required this.vps});

  @override
  State<_WgMigrateDialog> createState() => _WgMigrateDialogState();
}

class _WgMigrateDialogState extends State<_WgMigrateDialog> {
  late final TextEditingController _host =
      TextEditingController(text: widget.vps.publicIp.isNotEmpty ? widget.vps.publicIp : widget.vps.host);
  bool _busy = false;
  String? _error;
  String? _installCmd;
  bool _waiting = false;
  bool _done = false;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _installCmd = null;
      _waiting = false;
      _done = false;
    });
    final api = context.read<AppState>().api;
    try {
      final probe = await api.probeConnectivity(host);
      if (!probe.wireguardOk) {
        throw Exception(context.l.f('methodUnavailable', {
          'reason': probe.reason.isNotEmpty ? probe.reason : probe.ipClass,
        }));
      }
      final r = await api.migrateWireGuard(widget.vps.id, publicIp: host);
      final cmd = (r['install_command'] as String? ?? '').trim();
      final pushed = r['pushed'] as bool? ?? false;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _installCmd = pushed ? null : cmd;
        _waiting = true;
      });
      if (pushed) {
        _watchOnline();
      } else if (cmd.isNotEmpty) {
        setState(() => _waiting = true);
        _watchOnline();
      }
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _watchOnline() async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
      await context.read<AppState>().refreshAll();
      Vps? v;
      for (final x in context.read<AppState>().vpsList) {
        if (x.id == widget.vps.id) {
          v = x;
          break;
        }
      }
      if (v != null && v.isWireGuard && v.online) {
        if (mounted) {
          setState(() {
            _waiting = false;
            _done = true;
          });
        }
        return;
      }
    }
    if (mounted) {
      setState(() => _waiting = false);
      showToast(context, context.l.t('wgTimeout'), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l.t('wgMigrateTitle')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l.f('wgMigrateBody', {'name': widget.vps.name}),
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45)),
            const SizedBox(height: 12),
            Text(context.l.t('addServerHost'), style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
            const SizedBox(height: 4),
            TextField(
              controller: _host,
              decoration: InputDecoration(hintText: context.l.t('addServerHostHint'), isDense: true),
              style: const TextStyle(fontSize: 13),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(fontSize: 11, color: BeacleColors.err)),
            ],
            if (_installCmd != null && _installCmd!.isNotEmpty) ...[
              const SizedBox(height: 12),
              SecretCopyField(_installCmd!),
            ],
            if (_waiting)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(context.l.t('wgWaiting'), style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ]),
              ),
            if (_done)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(context.l.t('wgConnected'), style: const TextStyle(fontSize: 12, color: BeacleColors.ok)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('cancel'))),
        SmallButton(
          _busy ? context.l.t('runningEllipsis') : context.l.t('wgMigrateStart'),
          icon: Icons.swap_horiz,
          onPressed: _busy || _waiting ? null : _start,
        ),
      ],
    );
  }
}
