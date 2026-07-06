import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shows pairing token
Future<void> showAddVpsDialog(BuildContext context) async {
  final state = context.read<AppState>();
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: BeacleColors.glassHi,
      child: Container(
        width: 580,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add VPS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            const Text(
              'Generate a one-time token. On your Linux VPS run the install command (or download the agent and run beacle set).',
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
            ),
            const SizedBox(height: 16),
            FutureBuilder<PairingInfo>(
              future: state.api.createPairingToken(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return Text('Error: ${snap.error}', style: const TextStyle(color: BeacleColors.err, fontSize: 12));
                }
                if (!snap.hasData) {
                  return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
                }
                final p = snap.data!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Install (recommended)', style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                    const SizedBox(height: 6),
                    CopyField(p.installCommand),
                    const SizedBox(height: 14),
                    const Text('Manual', style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                    const SizedBox(height: 6),
                    CopyField(p.setCommand),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
            ),
          ],
        ),
      ),
    ),
  );
}

class AddVpsCommand extends StatelessWidget {
  const AddVpsCommand({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.connected) {
      return const Text('Backend offline', style: TextStyle(fontSize: 12, color: BeacleColors.textDim));
    }
    return FutureBuilder<PairingInfo>(
      future: state.api.createPairingToken(),
      builder: (ctx, snap) {
        if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: BeacleColors.err, fontSize: 12));
        if (!snap.hasData) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
        return CopyField(snap.data!.installCommand);
      },
    );
  }
}
