import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';

/// Per-VPS host statistics: CPU (incl. cores), RAM, disk, network, system info.
/// Processes and ports live in the Processes tab.
class ServersScreen extends StatefulWidget {
  final String? initialVpsId;
  const ServersScreen({super.key, this.initialVpsId});

  @override
  State<ServersScreen> createState() => ServersScreenState();
}

class ServersScreenState extends State<ServersScreen> {
  String? selectedId;

  void selectVps(String id) {
    context.read<AppState>().bumpActivity();
    setState(() => selectedId = id);
  }

  @override
  void initState() {
    super.initState();
    selectedId = widget.initialVpsId;
  }

  @override
  void didUpdateWidget(covariant ServersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialVpsId != null && widget.initialVpsId != selectedId) {
      selectedId = widget.initialVpsId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.vpsList.isEmpty) {
      return const Center(child: Text('No VPS registered', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= state.vpsList.first.id;
    final vps = state.vpsList.where((v) => v.id == selectedId).firstOrNull ?? state.vpsList.first;
    final snap = state.snapshots[vps.id];
    final showDetail = snap != null && vps.online && !state.isReportStale(vps);

    return Row(
      children: [
        Container(
          width: 230,
          color: BeacleColors.surface,
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              for (final v in state.vpsList)
                HoverRow(
                  selected: v.id == selectedId,
                  onTap: () {
                    context.read<AppState>().bumpActivity();
                    setState(() => selectedId = v.id);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        StatusDot(v.status),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(v.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              Text(v.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                            ],
                          ),
                        ),
                        if (state.snapshots[v.id]?.metrics != null && v.online)
                          Text(
                            '${state.snapshots[v.id]!.metrics.cpuPercent.toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: showDetail
              ? _ServerStats(vps: vps, snap: snap)
              : _PendingView(vps: vps, state: state, stale: state.isReportStale(vps)),
        ),
      ],
    );
  }
}

class _PendingView extends StatelessWidget {
  final Vps vps;
  final AppState state;
  final bool stale;
  const _PendingView({required this.vps, required this.state, this.stale = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(vps.status, size: 10),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      stale ? '${vps.name} — data outdated' : '${vps.name} — waiting for agent',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                vps.tailscaleName.isNotEmpty ? 'Tailscale: ${vps.tailscaleName} · ${vps.host}' : vps.host,
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, fontFamily: 'Consolas'),
              ),
              if (stale) ...[
                const SizedBox(height: 12),
                Text(
                  'Last update ${fmtAgo(vps.lastSeen)}. Agent is not sending live metrics.',
                  style: const TextStyle(fontSize: 12, color: BeacleColors.warn, height: 1.45),
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text(
                  'Run the install command on the VPS as root. Stats appear within seconds after the agent connects.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
                ),
                const SizedBox(height: 10),
                const AddVpsCommand(),
              ],
              const SizedBox(height: 16),
              SmallButton('Delete VPS', icon: Icons.delete_outline, color: BeacleColors.err, onPressed: () async {
                if (!await confirmDeleteVps(context, vps)) return;
                await state.api.deleteVps(vps.id);
                await state.refreshAll();
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerStats extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot snap;
  const _ServerStats({required this.vps, required this.snap});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final m = snap.metrics;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            StatusDot(vps.status, size: 12),
            const SizedBox(width: 10),
            Text(vps.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            Text(vps.host, style: const TextStyle(color: BeacleColors.textDim)),
            const SizedBox(width: 12),
            Text('updated ${fmtAgo(vps.lastSeen)}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const Spacer(),
            SmallButton('Update agent', icon: Icons.system_update_alt, onPressed: () async {
              try {
                final r = await state.api.agentUpdate(vps.id);
                if (context.mounted) showToast(context, r);
              } catch (e) {
                if (context.mounted) showToast(context, '$e', error: true);
              }
            }),
            const SizedBox(width: 8),
            SmallButton('Rollback', icon: Icons.history, onPressed: () async {
              try {
                final r = await state.api.agentRollback(vps.id);
                if (context.mounted) showToast(context, r);
              } catch (e) {
                if (context.mounted) showToast(context, '$e', error: true);
              }
            }),
            const SizedBox(width: 8),
            SmallButton('Delete', icon: Icons.delete_outline, color: BeacleColors.err, onPressed: () async {
              if (!await confirmDeleteVps(context, vps)) return;
              await state.api.deleteVps(vps.id);
              await state.refreshAll();
            }),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Exact host statistics — CPU cores, memory, disks, network.',
          style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
        ),
        const SizedBox(height: 16),
        // Equal-height summary tiles
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _CpuSummary(m: m)),
              const SizedBox(width: 12),
              Expanded(child: _RamPanel(m: m)),
              const SizedBox(width: 12),
              Expanded(child: _UptimePanel(vps: vps, m: m)),
            ],
          ),
        ),
        if (m.cpuPerCore.isNotEmpty) ...[
          const SizedBox(height: 12),
          _CoresPanel(cores: m.cpuPerCore),
        ],
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: PanelCard(
                  expand: true,
                  title: 'DISKS',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.disks.isEmpty)
                        const Text('No disk data', style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
                      else
                        for (final d in m.disks)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: MetricBar(
                              label: '${d.mount} (${d.filesystem})',
                              percent: d.usedPercent,
                              detail: '${fmtBytes(d.usedBytes)} / ${fmtBytes(d.totalBytes)}',
                            ),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PanelCard(
                  expand: true,
                  title: 'NETWORK',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.network.isEmpty)
                        const Text('No network data', style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
                      else
                        for (final n in m.network)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Text(n.iface, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Icon(Icons.arrow_downward, size: 12, color: BeacleColors.ok),
                              Text(' ${fmtBytes(n.rxPerSec)}/s   ', style: const TextStyle(fontSize: 12)),
                              Icon(Icons.arrow_upward, size: 12, color: BeacleColors.textDim),
                              Text(' ${fmtBytes(n.txPerSec)}/s', style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PanelCard(
                  expand: true,
                  title: 'SYSTEM INFO',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _info('Hostname', m.hostname),
                    _info('OS', m.os),
                    _info('Kernel', m.kernel),
                    _info('Arch', m.arch),
                    _info('CPU', m.cpuModel),
                    _info('Cores', '${m.cpuCores}'),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text(k, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))),
          Expanded(child: Text(v.isEmpty ? '-' : v, style: const TextStyle(fontSize: 12))),
        ]),
      );
}

class _CpuSummary extends StatelessWidget {
  final SystemMetrics m;
  const _CpuSummary({required this.m});

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      expand: true,
      title: 'CPU',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${m.cpuPercent.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            '${m.cpuCores} cores · load ${m.load1.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(height: 12),
          MetricBar(label: 'Overall', percent: m.cpuPercent),
        ],
      ),
    );
  }
}

class _UptimePanel extends StatelessWidget {
  final Vps vps;
  final SystemMetrics m;
  const _UptimePanel({required this.vps, required this.m});

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      expand: true,
      title: 'UPTIME',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fmtUptime(m.uptimeSeconds), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('agent v${vps.agentVersion}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          const SizedBox(height: 4),
          Text(
            'load ${m.load1.toStringAsFixed(2)} / ${m.load5.toStringAsFixed(2)} / ${m.load15.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
        ],
      ),
    );
  }
}

/// Per-core usage in 1–2 columns so the tile stays balanced with many cores.
class _CoresPanel extends StatelessWidget {
  final List<double> cores;
  const _CoresPanel({required this.cores});

  @override
  Widget build(BuildContext context) {
    final dual = cores.length > 6;
    final compact = cores.length > 8;
    final gap = compact ? 4.0 : 6.0;

    Widget bar(int i) => Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: MetricBar(label: 'cpu$i', percent: cores[i]),
        );

    return PanelCard(
      title: 'CPU CORES',
      trailing: Text('${cores.length}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
      child: dual
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      for (var i = 0; i < (cores.length + 1) ~/ 2; i++) bar(i),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      for (var i = (cores.length + 1) ~/ 2; i < cores.length; i++) bar(i),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (var i = 0; i < cores.length; i++) bar(i),
              ],
            ),
    );
  }
}

class _RamPanel extends StatelessWidget {
  final SystemMetrics m;
  const _RamPanel({required this.m});

  @override
  Widget build(BuildContext context) {
    final usedCached = m.memUsedCachedBytes > 0 ? m.memUsedCachedBytes : m.memUsedBytes + m.memCachedBytes;
    final pctCached = m.memPercentCached > 0
        ? m.memPercentCached
        : (m.memTotalBytes > 0 ? usedCached / m.memTotalBytes * 100 : 0.0);

    return PanelCard(
      expand: true,
      title: 'MEMORY',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${m.memPercent.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            '${fmtBytes(m.memUsedBytes)} / ${fmtBytes(m.memTotalBytes)} used',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(height: 12),
          MetricBar(
            label: 'Used (apps)',
            percent: m.memPercent,
            detail: '${fmtBytes(m.memUsedBytes)} · ${m.memPercent.toStringAsFixed(0)}%',
          ),
          const SizedBox(height: 8),
          MetricBar(
            label: 'Used + cache',
            percent: pctCached,
            detail: '${fmtBytes(usedCached)} · ${pctCached.toStringAsFixed(0)}%',
          ),
          if (m.memCachedBytes > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Cache / buffers', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const Spacer(),
                Text(fmtBytes(m.memCachedBytes), style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'swap ${fmtBytes(m.swapUsed)} / ${fmtBytes(m.swapTotal)}',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
        ],
      ),
    );
  }
}
