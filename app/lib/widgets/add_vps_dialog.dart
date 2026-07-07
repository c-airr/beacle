import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

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
          title: const Text('Tailscale'),
          content: Text('$e', style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
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
        child: devices.where((d) => !d.self).isEmpty
            ? const Text('No Tailscale devices found. Install Tailscale on your VPS first.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final d in devices.where((x) => !x.self))
                    ListTile(
                      title: Text(d.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        d.ips.isNotEmpty ? d.ips.first : d.dns,
                        style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim),
                      ),
                      onTap: () => Navigator.pop(ctx, d),
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
          title: const Text('Install agent'),
          content: FutureBuilder<String>(
            future: state.api.installCommand(),
            builder: (c, snap) {
              if (!snap.hasData) return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Run on the VPS as root:', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                  const SizedBox(height: 8),
                  CopyField(snap.data!),
                ],
              );
            },
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showToast(context, '$e', error: true);
  }
}

class AddVpsCommand extends StatelessWidget {
  const AddVpsCommand({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.connected) {
      return const Text('Backend offline', style: TextStyle(fontSize: 12, color: BeacleColors.textDim));
    }
    return FutureBuilder<String>(
      future: state.api.installCommand(),
      builder: (ctx, snap) {
        if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: BeacleColors.err, fontSize: 12));
        if (!snap.hasData) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
        return CopyField(snap.data!);
      },
    );
  }
}
