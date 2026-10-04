import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/alert_text.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';
import 'shell.dart';

/// First screen — answers: "Is everything working?"
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final online = state.vpsList.where((v) => v.online && !state.isReportStale(v)).toList();
    final offline = state.vpsList.where((v) => !v.online || state.isReportStale(v)).length;

    double cpuSum = 0, ramSum = 0, diskSum = 0, diskN = 0, netIn = 0, netOut = 0;
    for (final v in online) {
      final m = state.snapshots[v.id]?.metrics;
      if (m == null) continue;
      cpuSum += m.cpuPercent;
      ramSum += m.memPercent;
      for (final d in m.disks) {
        diskSum += d.usedPercent;
        diskN++;
      }
      for (final n in m.network) {
        netIn += n.rxPerSec.toDouble();
        netOut += n.txPerSec.toDouble();
      }
    }
    final nOnline = online.length;
    final avgCpu = nOnline == 0 ? 0.0 : cpuSum / nOnline;
    final avgRam = nOnline == 0 ? 0.0 : ramSum / nOnline;
    final avgDisk = diskN == 0 ? 0.0 : diskSum / diskN;
    final l = context.l;
    final attention = _attentionItems(state, l);

    return SmoothListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Text(
          l.t('ovTagline'),
          style: TextStyle(fontSize: 13, color: BeacleColors.textDim, letterSpacing: 0.2),
        ),
        const SizedBox(height: 14),

        // KPI strip
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 1100 ? 6 : (c.maxWidth > 780 ? 3 : 2);
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovOnline'),
                value: '$nOnline / ${state.vpsList.length}',
                hint: offline > 0 ? l.f('ovNOffline', {'n': offline}) : l.t('ovAllUp'),
                tone: offline > 0 ? BeacleColors.warn : BeacleColors.ok,
              ),
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovCpuAvg'),
                value: '${avgCpu.toStringAsFixed(0)}%',
                hint: nOnline == 0 ? '—' : l.t('ovFleet'),
                tone: avgCpu >= 90 ? BeacleColors.err : (avgCpu >= 75 ? BeacleColors.warn : BeacleColors.text),
              ),
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovRamAvg'),
                value: '${avgRam.toStringAsFixed(0)}%',
                hint: nOnline == 0 ? '—' : l.t('ovFleet'),
                tone: avgRam >= 90 ? BeacleColors.err : (avgRam >= 75 ? BeacleColors.warn : BeacleColors.text),
              ),
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovStorage'),
                value: '${avgDisk.toStringAsFixed(0)}%',
                hint: diskN == 0 ? '—' : l.t('ovAvgMount'),
                tone: avgDisk >= 90 ? BeacleColors.err : (avgDisk >= 80 ? BeacleColors.warn : BeacleColors.text),
              ),
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovNetwork'),
                value: '↓${fmtBytes(netIn)}/s',
                hint: '↑${fmtBytes(netOut)}/s',
              ),
              _KpiTile(
                width: (c.maxWidth - 10 * (cols - 1)) / cols,
                label: l.t('ovAlerts'),
                value: '${state.activeAlerts}',
                hint: state.activeAlerts == 0 ? l.t('ovAllClearLower') : l.t('ovActive'),
                tone: state.activeAlerts > 0 ? BeacleColors.err : BeacleColors.ok,
                onTap: () => AppShell.of(context).goToAlerts(),
              ),
            ],
          );
        }),

        const SizedBox(height: 22),
        _SectionHeader(
          title: l.t('ovAttention'),
          trailing: attention.isEmpty
              ? Text(l.t('ovAllClear'), style: TextStyle(fontSize: 11, color: BeacleColors.ok))
              : Text('${attention.length}', style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
        ),
        const SizedBox(height: 10),
        if (attention.isEmpty)
          _EmptyBand(l.t('ovNothingNeeds'))
        else
          ...attention.take(12).map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _AttentionRow(item: item),
              )),

        const SizedBox(height: 22),
        _SectionHeader(
          title: l.t('ovInfra'),
          trailing: SmallButton(l.t('addVps'), icon: Icons.add, onPressed: () => showAddVpsDialog(context)),
        ),
        const SizedBox(height: 10),
        if (state.vpsList.isEmpty)
          _EmptyBand(l.t('ovNoVps'))
        else
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            final cols = w > 1200 ? 4 : (w > 900 ? 3 : (w > 560 ? 2 : 1));
            final cardW = (w - 12 * (cols - 1)) / cols;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final v in state.vpsList)
                  SizedBox(
                    width: cardW,
                    child: _InfraCard(
                      vps: v,
                      snap: state.snapshots[v.id],
                      stale: state.isReportStale(v),
                      pingMs: _pingFor(state, v.id),
                    ),
                  ),
              ],
            );
          }),

        const SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(title: l.t('ovRecent')),
                  const SizedBox(height: 10),
                  PanelCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: state.actions.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(l.t('ovNoActions'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                          )
                        : Column(
                            children: [
                              for (final a in state.actions.take(12))
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 5),
                                  child: Row(
                                    children: [
                                      Icon(a.ok ? Icons.check_circle_outline : Icons.error_outline,
                                          size: 14, color: a.ok ? BeacleColors.ok : BeacleColors.err),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          a.vpsName.isEmpty ? a.action : '${a.vpsName} — ${a.action}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(l.ago(a.createdAt),
                                          style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(title: l.t('ovCharts'), trailing: Text('24h', style: TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                  const SizedBox(height: 10),
                  PanelCard(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(
                      children: [
                        _ChartBlock(
                          label: 'CPU',
                          unit: '%',
                          color: BeacleColors.text,
                          values: state.fleetHistory.map((s) => s.cpu).toList(),
                          current: avgCpu,
                        ),
                        const SizedBox(height: 14),
                        _ChartBlock(
                          label: 'RAM',
                          unit: '%',
                          color: BeacleColors.warn,
                          values: state.fleetHistory.map((s) => s.ram).toList(),
                          current: avgRam,
                        ),
                        const SizedBox(height: 14),
                        _ChartBlock(
                          label: l.t('ovNetwork'),
                          unit: '/s',
                          color: BeacleColors.ok,
                          values: state.fleetHistory.map((s) => s.netIn + s.netOut).toList(),
                          current: netIn + netOut,
                          format: fmtBytes,
                        ),
                        if (state.fleetHistory.length < 3)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              l.t('ovChartsFill'),
                              style: TextStyle(fontSize: 10, color: BeacleColors.textDim),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  static double? _pingFor(AppState state, String vpsId) {
    final related = state.links.where((l) => l.fromVpsId == vpsId || l.toVpsId == vpsId).toList();
    if (related.isEmpty) return null;
    var sum = 0.0;
    for (final l in related) {
      sum += l.latencyMs;
    }
    return sum / related.length;
  }
}

class _AttentionItem {
  final String severity; // critical | warning | info
  final String title;
  final String message;
  final String? vpsId;
  const _AttentionItem({
    required this.severity,
    required this.title,
    required this.message,
    this.vpsId,
  });
}

List<_AttentionItem> _attentionItems(AppState state, L l) {
  final out = <_AttentionItem>[];
  final seen = <String>{};

  void add(_AttentionItem item, String key) {
    if (seen.add(key)) out.add(item);
  }

  for (final a in state.alerts.where((a) => !a.resolved)) {
    add(
      _AttentionItem(
        severity: a.severity == 'critical' ? 'critical' : 'warning',
        title: a.vpsName,
        message: alertMessage(l, a),
        vpsId: a.vpsId.isEmpty ? null : a.vpsId,
      ),
      'alert:${a.id}',
    );
  }

  for (final v in state.vpsList) {
    if (!v.online || state.isReportStale(v)) {
      add(
        _AttentionItem(
          severity: 'critical',
          title: v.name,
          message: state.isReportStale(v) && v.online ? l.t('ovAgentOutdated') : l.t('offline'),
          vpsId: v.id,
        ),
        'offline:${v.id}',
      );
      continue;
    }
    final snap = state.snapshots[v.id];
    if (snap == null) continue;
    final m = snap.metrics;
    if (m.memPercent >= 90) {
      add(_AttentionItem(severity: 'critical', title: v.name, message: 'RAM ${m.memPercent.toStringAsFixed(0)}%', vpsId: v.id),
          'ram:${v.id}');
    } else if (m.memPercent >= 80) {
      add(_AttentionItem(severity: 'warning', title: v.name, message: 'RAM ${m.memPercent.toStringAsFixed(0)}%', vpsId: v.id),
          'ram:${v.id}');
    }
    if (m.cpuPercent >= 90) {
      add(_AttentionItem(severity: 'critical', title: v.name, message: 'CPU ${m.cpuPercent.toStringAsFixed(0)}%', vpsId: v.id),
          'cpu:${v.id}');
    }
    for (final d in m.disks) {
      if (d.usedPercent >= 95) {
        add(_AttentionItem(severity: 'critical', title: v.name, message: l.f('ovDisk', {'mount': d.mount, 'p': d.usedPercent.toStringAsFixed(0)}), vpsId: v.id),
            'disk:${v.id}:${d.mount}');
      } else if (d.usedPercent >= 85) {
        add(_AttentionItem(severity: 'warning', title: v.name, message: l.f('ovDisk', {'mount': d.mount, 'p': d.usedPercent.toStringAsFixed(0)}), vpsId: v.id),
            'disk:${v.id}:${d.mount}');
      }
    }
    for (final c in snap.docker.containers) {
      if (c.state == 'restarting') {
        add(_AttentionItem(severity: 'warning', title: v.name, message: l.f('ovDockerRestarting', {'name': c.name}), vpsId: v.id),
            'docker:${v.id}:${c.id}');
      }
    }
  }

  int rank(String s) => switch (s) {
        'critical' => 0,
        'warning' => 1,
        _ => 2,
      };
  out.sort((a, b) => rank(a.severity).compareTo(rank(b.severity)));
  return out;
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: BeacleColors.textDim)),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _EmptyBand extends StatelessWidget {
  final String text;
  const _EmptyBand(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: BeacleColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final double width;
  final String label, value;
  final String? hint;
  final Color? tone;
  final VoidCallback? onTap;
  const _KpiTile({
    required this.width,
    required this.label,
    required this.value,
    this.hint,
    this.tone,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: BeacleColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, letterSpacing: 0.8, color: BeacleColors.textDim)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: tone ?? BeacleColors.text)),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          ],
        ],
      ),
    );
    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  final _AttentionItem item;
  const _AttentionRow({required this.item});

  Color get _color => switch (item.severity) {
        'critical' => BeacleColors.err,
        'warning' => BeacleColors.warn,
        _ => BeacleColors.textDim,
      };

  String get _dot => switch (item.severity) {
        'critical' => '●',
        'warning' => '●',
        _ => '●',
      };

  @override
  Widget build(BuildContext context) {
    return HoverRow(
      onTap: item.vpsId == null ? null : () => AppShell.of(context).goToServer(item.vpsId!),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: BeacleColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _color.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Text(_dot, style: TextStyle(color: _color, fontSize: 12)),
            const SizedBox(width: 10),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 13, color: BeacleColors.text),
                  children: [
                    TextSpan(text: item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: '  —  ', style: TextStyle(color: BeacleColors.textDim)),
                    TextSpan(text: item.message, style: TextStyle(color: BeacleColors.textDim)),
                  ],
                ),
              ),
            ),
            if (item.vpsId != null)
              Icon(Icons.chevron_right, size: 16, color: BeacleColors.textDim),
          ],
        ),
      ),
    );
  }
}

class _InfraCard extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot? snap;
  final bool stale;
  final double? pingMs;
  const _InfraCard({required this.vps, required this.snap, required this.stale, this.pingMs});

  @override
  Widget build(BuildContext context) {
    final m = snap?.metrics;
    final docker = snap?.docker;
    final svc = snap?.services;
    final running = docker?.containers.where((c) => c.running).length ?? 0;
    final total = docker?.containers.length ?? 0;
    final failed = svc?.systemd.where((u) => u.activeState == 'failed').length ?? 0;
    final activeUnits = svc?.systemd.where((u) => u.activeState == 'active').length ?? 0;

    return HoverRow(
      onTap: () => AppShell.of(context).goToServer(vps.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: BeacleColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BeacleColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(stale && vps.online ? 'offline' : vps.status, size: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(vps.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              vps.location.isNotEmpty ? vps.location : (vps.host.isEmpty ? '—' : vps.host),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MiniStat(label: 'CPU', value: m == null ? '—' : '${m.cpuPercent.toStringAsFixed(0)}%'),
                _MiniStat(label: 'RAM', value: m == null ? '—' : '${m.memPercent.toStringAsFixed(0)}%'),
                _MiniStat(label: context.l.t('ovPing'), value: pingMs == null ? '—' : '${pingMs!.toStringAsFixed(0)} ms'),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    docker == null || !docker.available
                        ? 'Docker —'
                        : 'Docker $running/$total',
                    style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
                  ),
                ),
                Text(
                  svc == null
                      ? 'Systemd —'
                      : (failed > 0 ? context.l.f('ovSystemdFailed', {'n': failed}) : 'Systemd $activeUnits'),
                  style: TextStyle(
                    fontSize: 11,
                    color: failed > 0 ? BeacleColors.warn : BeacleColors.textDim,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: BeacleColors.textDim)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ChartBlock extends StatelessWidget {
  final String label, unit;
  final Color color;
  final List<double> values;
  final double current;
  final String Function(num)? format;
  const _ChartBlock({
    required this.label,
    required this.unit,
    required this.color,
    required this.values,
    required this.current,
    this.format,
  });

  @override
  Widget build(BuildContext context) {
    final shown = format != null ? '${format!(current)}$unit' : '${current.toStringAsFixed(0)}$unit';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const Spacer(),
            Text(shown, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparklinePainter(values: values, color: color),
          ),
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const _SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = BeacleColors.surfaceHi;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)), bg);
    if (values.length < 2) {
      final mid = size.height / 2;
      canvas.drawLine(
        Offset(8, mid),
        Offset(size.width - 8, mid),
        Paint()
          ..color = BeacleColors.border
          ..strokeWidth = 1,
      );
      return;
    }
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - ((values[i] - minV) / span) * (size.height - 6) - 3;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values.length != values.length || old.color != color;
}
