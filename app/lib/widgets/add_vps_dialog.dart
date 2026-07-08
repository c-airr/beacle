import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../config.dart';
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
  final state = context.read<AppState>();
  List<TailscaleDevice> devices;
  try {
    devices = await state.api.tailscaleDevices();
  } catch (e) {
    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Tailscale required'),
          content: Text(
            e is ApiException && e.status == 503 ? tailscaleNotOnPc : '$e',
            style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
    return;
  }
  if (!context.mounted) return;
  final picked = await showDialog<TailscaleDevice>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: BeacleColors.glassHi,
      title: const Text('Add VPS'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            tailscaleRequirementBanner(),
            const SizedBox(height: 14),
            if (devices.where((d) => !d.self).isEmpty)
              const Text(
                tailscaleNoPeers,
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
              )
            else
              ListView(
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
    ),
  );
  if (picked == null) return;
  final ip = picked.ips.isNotEmpty ? picked.ips.first : '';
  try {
    await state.api.createVps(name: picked.name, tailscaleName: picked.name, tailscaleIp: ip);
    await state.refreshAll();
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: BeacleColors.glassHi,
          title: Text('Install agent on ${picked.name}'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Run on the VPS as root. The script downloads from GitHub; your desktop Tailscale IP is only used as the agent backend URL.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
                ),
                const SizedBox(height: 10),
                const AddVpsCommand(),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showToast(context, '$e', error: true);
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
