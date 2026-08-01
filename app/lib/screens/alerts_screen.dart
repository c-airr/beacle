import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart';

/// Problem centre: everything currently wrong, grouped by how much it matters.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  /// null = every severity.
  String? severityFilter;
  bool showResolved = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    final active = state.alerts.where((a) => !a.resolved && !state.isMuted(a)).toList();
    final muted = state.alerts.where((a) => !a.resolved && state.isMuted(a)).toList();
    final resolved = state.alerts.where((a) => a.resolved).toList();

    final counts = {
      'critical': active.where((a) => a.severity == 'critical').length,
      'warning': active.where((a) => a.severity == 'warning').length,
      'info': active.where((a) => a.severity == 'info').length,
    };

    final shown = severityFilter == null
        ? active
        : active.where((a) => a.severity == severityFilter).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Row(
          children: [
            const Text(
              'What needs attention?',
              style: TextStyle(fontSize: 13, color: BeacleColors.textDim, letterSpacing: 0.2),
            ),
            const Spacer(),
            if (active.isNotEmpty)
              SmallButton(
                'Mark all seen',
                icon: Icons.done_all,
                onPressed: state.markAlertsSeen,
              ),
          ],
        ),
        const SizedBox(height: 14),

        Row(
          children: [
            _SeverityChip(
              label: 'CRITICAL',
              count: counts['critical']!,
              tone: BeacleColors.err,
              selected: severityFilter == 'critical',
              onTap: () => setState(() => severityFilter = severityFilter == 'critical' ? null : 'critical'),
            ),
            const SizedBox(width: 10),
            _SeverityChip(
              label: 'WARNING',
              count: counts['warning']!,
              tone: BeacleColors.warn,
              selected: severityFilter == 'warning',
              onTap: () => setState(() => severityFilter = severityFilter == 'warning' ? null : 'warning'),
            ),
            const SizedBox(width: 10),
            _SeverityChip(
              label: 'INFO',
              count: counts['info']!,
              tone: BeacleColors.textDim,
              selected: severityFilter == 'info',
              onTap: () => setState(() => severityFilter = severityFilter == 'info' ? null : 'info'),
            ),
          ],
        ),
        const SizedBox(height: 18),

        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    active.isEmpty ? Icons.check_circle_outline : Icons.filter_alt_off_outlined,
                    size: 32,
                    color: active.isEmpty ? BeacleColors.ok : BeacleColors.textDim,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    active.isEmpty ? 'All clear' : 'Nothing matches this filter',
                    style: const TextStyle(color: BeacleColors.textDim, fontSize: 14),
                  ),
                ],
              ),
            ),
          )
        else
          for (final a in shown)
            _AlertRow(alert: a, state: state, onChanged: () => setState(() {})),

        if (muted.isNotEmpty) ...[
          const SizedBox(height: 22),
          _GroupHeader('MUTED', muted.length),
          const SizedBox(height: 10),
          for (final a in muted)
            _AlertRow(alert: a, state: state, muted: true, onChanged: () => setState(() {})),
        ],

        if (resolved.isNotEmpty) ...[
          const SizedBox(height: 22),
          HoverRow(
            onTap: () => setState(() => showResolved = !showResolved),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    showResolved ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: BeacleColors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'RESOLVED (${resolved.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: BeacleColors.textDim,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (showResolved) ...[
            const SizedBox(height: 8),
            for (final a in resolved.take(50))
              _AlertRow(alert: a, state: state, onChanged: () => setState(() {})),
          ],
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  const _GroupHeader(this.label, this.count);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '$label ($count)',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: BeacleColors.textDim,
            letterSpacing: 0.4,
          ),
        ),
      );
}

class _SeverityChip extends StatelessWidget {
  final String label;
  final int count;
  final Color tone;
  final bool selected;
  final VoidCallback onTap;
  const _SeverityChip({
    required this.label,
    required this.count,
    required this.tone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: HoverRow(
        onTap: onTap,
        selected: selected,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? tone.withValues(alpha: 0.6) : BeacleColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: count > 0 ? tone : BeacleColors.border),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, letterSpacing: 0.4),
              ),
              const Spacer(),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: count > 0 ? tone : BeacleColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  final Alert alert;
  final AppState state;
  final bool muted;
  final VoidCallback onChanged;
  const _AlertRow({
    required this.alert,
    required this.state,
    required this.onChanged,
    this.muted = false,
  });

  Color get _tone => switch (alert.severity) {
        'critical' => BeacleColors.err,
        'warning' => BeacleColors.warn,
        _ => BeacleColors.textDim,
      };

  IconData get _icon => switch (alert.type) {
        'cpu_high' => Icons.speed,
        'mem_high' => Icons.memory,
        'disk_high' => Icons.storage,
        'service_down' => Icons.miscellaneous_services,
        'docker_crash' => Icons.view_in_ar,
        'proxy_error' => Icons.alt_route,
        'agent_offline' => Icons.cloud_off,
        _ => Icons.warning_amber_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final dim = muted || alert.resolved;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon, size: 18, color: alert.resolved ? BeacleColors.ok : _tone),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          alert.vpsName.isEmpty ? 'unknown host' : alert.vpsName,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          alert.type.replaceAll('_', ' '),
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(alert.message, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                    const SizedBox(height: 6),
                    Text(
                      alert.resolved ? 'resolved · started ${fmtAgo(alert.createdAt)}' : 'since ${fmtAgo(alert.createdAt)}',
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      if (alert.vpsId.isNotEmpty)
                        SmallButton(
                          'Open VPS',
                          icon: Icons.open_in_new,
                          onPressed: () => AppShell.of(context).goToServer(alert.vpsId),
                        ),
                      if (!alert.resolved) ...[
                        const SizedBox(width: 8),
                        SmallButton(
                          muted ? 'Unmute' : 'Mute',
                          icon: muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                          onPressed: () {
                            state.toggleMute(alert);
                            onChanged();
                          },
                        ),
                        const SizedBox(width: 8),
                        SmallButton(
                          'Resolve',
                          icon: Icons.check,
                          onPressed: () => state.resolveAlert(alert.id),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
