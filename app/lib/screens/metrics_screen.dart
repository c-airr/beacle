import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Fleet-wide metrics view.
class MetricsScreen extends StatelessWidget {
  const MetricsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.vpsList.isEmpty) {
      return const Center(
        child: Text('No VPS yet — add one from the toolbar (+)', style: TextStyle(color: BeacleColors.textDim, fontSize: 13)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final v in state.vpsList) _VpsMetricsCard(vps: v, snapshot: state.snapshots[v.id]),
      ],
    );
  }
}

class _VpsMetricsCard extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot? snapshot;
  const _VpsMetricsCard({required this.vps, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final m = snapshot?.metrics;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(vps.status),
                const SizedBox(width: 10),
                Text(vps.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                if (vps.isHub) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: BeacleColors.borderGlow),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('HUB', style: TextStyle(fontSize: 9, letterSpacing: 1)),
                  ),
                ],
                const Spacer(),
                Text(vps.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              ],
            ),
            const SizedBox(height: 16),
            if (m != null) ...[
              MetricBar(label: 'CPU', percent: m.cpuPercent),
              const SizedBox(height: 10),
              MetricBar(label: 'RAM', percent: m.memPercent),
              const SizedBox(height: 10),
              MetricBar(
                label: 'Disk',
                percent: m.disks.isNotEmpty ? m.disks.first.usedPercent : 0,
              ),
              const SizedBox(height: 10),
              Text(
                'Load ${m.load1.toStringAsFixed(2)} · ${m.cpuCores} cores · up ${fmtUptime(m.uptimeSeconds)}',
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
              ),
            ] else
              const Text('Waiting for agent data…', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          ],
        ),
      ),
    );
  }
}
