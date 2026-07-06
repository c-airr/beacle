import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';
import 'shell.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // left: VPS list
          Expanded(
            flex: 3,
            child: PanelCard(
              title: 'VPS FLEET',
              trailing: SmallButton('Add VPS', icon: Icons.add, onPressed: () => showAddVpsDialog(context)),
              padding: const EdgeInsets.all(12),
              child: Expanded(
                child: state.vpsList.isEmpty
                    ? const Center(
                        child: Text(
                          'No VPS yet. Click "Add VPS", run the install command on a server, and it will appear here automatically.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: BeacleColors.textDim, fontSize: 12),
                        ))
                    : ListView(
                        children: [
                          for (final v in state.vpsList)
                            _VpsRow(vps: v, snapshot: state.snapshots[v.id]),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // right column: alerts preview + recent actions
          SizedBox(
            width: 360,
            child: Column(
              children: [
                Expanded(
                  child: PanelCard(
                    title: 'ALERTS',
                    padding: const EdgeInsets.all(12),
                    child: Expanded(
                      child: state.alerts.where((a) => !a.resolved).isEmpty
                          ? const Center(child: Text('All clear', style: TextStyle(color: BeacleColors.textDim)))
                          : ListView(
                              children: [
                                for (final a in state.alerts.where((a) => !a.resolved).take(15))
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 5),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.circle,
                                            size: 8,
                                            color: a.severity == 'critical' ? BeacleColors.err : BeacleColors.warn),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(a.vpsName,
                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                                              Text(a.message,
                                                  style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: PanelCard(
                    title: 'RECENT ACTIONS',
                    padding: const EdgeInsets.all(12),
                    child: Expanded(
                      child: state.actions.isEmpty
                          ? const Center(child: Text('No actions yet', style: TextStyle(color: BeacleColors.textDim)))
                          : ListView(
                              children: [
                                for (final a in state.actions.take(30))
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Icon(a.ok ? Icons.check : Icons.close,
                                            size: 12, color: a.ok ? BeacleColors.ok : BeacleColors.err),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text('${a.vpsName}: ${a.action}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VpsRow extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot? snapshot;
  const _VpsRow({required this.vps, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final m = snapshot?.metrics;
    final disk = (m != null && m.disks.isNotEmpty) ? m.disks.first.usedPercent : 0.0;
    return HoverRow(
      onTap: () => AppShell.of(context).goToServer(vps.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            StatusDot(vps.status),
            const SizedBox(width: 12),
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vps.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    vps.location.isNotEmpty ? '${vps.location} · ${vps.host}' : vps.host,
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: MetricBar(label: 'CPU', percent: m?.cpuPercent ?? 0)),
            const SizedBox(width: 14),
            Expanded(child: MetricBar(label: 'RAM', percent: m?.memPercent ?? 0)),
            const SizedBox(width: 14),
            Expanded(child: MetricBar(label: 'Disk', percent: disk)),
            const SizedBox(width: 14),
            SizedBox(
              width: 80,
              child: Text(
                m != null ? 'up ${fmtUptime(m.uptimeSeconds)}' : vps.status,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
