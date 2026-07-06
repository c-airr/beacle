import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = state.alerts.where((a) => !a.resolved).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (active.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 80),
              child: Text('All clear', style: TextStyle(color: BeacleColors.textDim, fontSize: 14)),
            ),
          )
        else
          for (final a in active)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: a.severity == 'critical' ? BeacleColors.err : BeacleColors.warn,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.vpsName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(a.message, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                        ],
                      ),
                    ),
                    SmallButton('Resolve', onPressed: () => state.resolveAlert(a.id)),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
