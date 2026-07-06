import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

class AlertsPanel extends StatelessWidget {
  final VoidCallback onClose;
  const AlertsPanel({super.key, required this.onClose});

  IconData _icon(String type) {
    switch (type) {
      case 'cpu_high':
      case 'mem_high':
        return Icons.speed;
      case 'disk_high':
        return Icons.storage;
      case 'service_down':
        return Icons.miscellaneous_services;
      case 'docker_crash':
        return Icons.view_in_ar;
      case 'proxy_error':
        return Icons.alt_route;
      case 'agent_offline':
        return Icons.cloud_off;
      default:
        return Icons.warning_amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = state.alerts.where((a) => !a.resolved).toList();
    final resolved = state.alerts.where((a) => a.resolved).take(20).toList();

    return Container(
      width: 380,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BeacleColors.border),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Text('Alerts', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                if (active.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: BeacleColors.err.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                    child: Text('${active.length} active', style: const TextStyle(fontSize: 11, color: BeacleColors.err)),
                  ),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, size: 16), onPressed: onClose),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: state.alerts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No alerts', style: TextStyle(color: BeacleColors.textDim)),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final a in active) _AlertRow(alert: a, icon: _icon(a.type)),
                      if (resolved.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(8, 12, 8, 4),
                          child: Text('RESOLVED', style: TextStyle(fontSize: 10, color: BeacleColors.textDim, letterSpacing: 1)),
                        ),
                        for (final a in resolved) _AlertRow(alert: a, icon: _icon(a.type)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  final Alert alert;
  final IconData icon;
  const _AlertRow({required this.alert, required this.icon});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final color = alert.resolved
        ? BeacleColors.textDim
        : alert.severity == 'critical'
            ? BeacleColors.err
            : BeacleColors.warn;
    final t = alert.createdAt.toLocal();
    final time =
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return HoverRow(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('${alert.vpsName} - ${alert.type}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              decoration: alert.resolved ? TextDecoration.lineThrough : null)),
                    ),
                    Text(time, style: const TextStyle(fontSize: 10, color: BeacleColors.textDim)),
                  ]),
                  const SizedBox(height: 2),
                  Text(alert.message, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                ],
              ),
            ),
            if (!alert.resolved)
              IconButton(
                icon: const Icon(Icons.check, size: 14, color: BeacleColors.textDim),
                tooltip: 'Resolve',
                onPressed: () => state.resolveAlert(alert.id),
              ),
          ],
        ),
      ),
    );
  }
}
