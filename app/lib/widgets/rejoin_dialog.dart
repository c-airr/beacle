import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Servers the panel lost track of (state.json reset, restored backup),
/// asking to be let back in with the ID and token they still hold. The
/// address and its Tailscale name are what the panel checked itself; the
/// hostname is only the agent's word, so it is shown as such.
Future<void> showRejoinDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Consumer<AppState>(
      builder: (ctx, state, _) {
        if (state.rejoin.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
          });
        }
        return AlertDialog(
          title: Text(context.l.t('rejoinTitle')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l.t('rejoinIntro'), style: TextStyle(fontSize: 12.5, color: BeacleColors.textDim)),
                const SizedBox(height: 12),
                for (final r in state.rejoin) _RejoinRow(r: r),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('close'))),
          ],
        );
      },
    ),
  );
}

class _RejoinRow extends StatelessWidget {
  final Map<String, dynamic> r;
  const _RejoinRow({required this.r});

  Future<void> _answer(BuildContext context, bool letIn) async {
    try {
      await context.read<AppState>().answerRejoin('${r['ip']}', letIn);
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tailnet = '${r['tailnet_name'] ?? ''}';
    final host = '${r['hostname'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tailnet.isNotEmpty ? '$tailnet · ${r['ip']}' : '${r['ip']}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (host.isNotEmpty)
                  Text(context.l.f('rejoinSays', {'name': host}),
                      style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              ],
            ),
          ),
          TextButton(onPressed: () => _answer(context, false), child: Text(context.l.t('rejoinRefuse'))),
          const SizedBox(width: 4),
          SmallButton(context.l.t('rejoinLetIn'), icon: Icons.check, onPressed: () => _answer(context, true)),
        ],
      ),
    );
  }
}
