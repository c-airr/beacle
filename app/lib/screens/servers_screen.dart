import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';
import '../widgets/edit_vps_dialog.dart';
import '../widgets/history_panel.dart';
import '../widgets/os_updates.dart';
import '../widgets/reboot_dialog.dart';
import '../widgets/temp_login_dialog.dart';
import 'shell.dart';

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

  /// Lowercased tag filter for the sidebar list; null shows everything.
  String? tagFilter;

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
      return Center(child: Text(context.l.t('srvNoVps'), style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= state.vpsList.first.id;
    // All distinct tags across the fleet, first-seen casing kept for display.
    final tagNames = <String, String>{};
    for (final v in state.vpsList) {
      for (final t in v.tags) {
        tagNames.putIfAbsent(t.toLowerCase(), () => t);
      }
    }
    final tags = tagNames.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    var shown = state.vpsList;
    if (tagFilter != null) {
      shown = shown.where((v) => v.tags.any((t) => t.toLowerCase() == tagFilter)).toList();
      if (shown.isEmpty) shown = state.vpsList;
    }
    final vps = shown.where((v) => v.id == selectedId).firstOrNull ?? shown.first;
    final snap = state.snapshots[vps.id];
    final showDetail = snap != null && vps.online && !state.isReportStale(vps);

    return Row(
      children: [
        Container(
          width: 230,
          color: BeacleColors.surface,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
                child: Row(
                  children: [
                    Text(context.l.t('navServers'),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: BeacleColors.textDim)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.tune, size: 16),
                      tooltip: context.l.t('editServer'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showEditVpsDialog(context, vps),
                    ),
                  ],
                ),
              ),
              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _tagChip(
                          context, context.l.t('allTags'), tagFilter == null, () => setState(() => tagFilter = null)),
                      for (final t in tags)
                        _tagChip(context, '#$t', tagFilter == t.toLowerCase(),
                            () => setState(() => tagFilter = tagFilter == t.toLowerCase() ? null : t.toLowerCase())),
                    ],
                  ),
                ),
              Expanded(
                child: SmoothListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final v in shown)
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
                                    Text(v.host, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                                    if (v.tags.isNotEmpty)
                                      Text(v.tags.map((t) => '#$t').join('  '),
                                          style: TextStyle(fontSize: 10, color: BeacleColors.textDim),
                                          overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              ),
                              if (state.snapshots[v.id]?.metrics != null && v.online)
                                Text(
                                  '${state.snapshots[v.id]!.metrics.cpuPercent.toStringAsFixed(0)}%',
                                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
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

  Widget _tagChip(BuildContext context, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? BeacleColors.glassHi : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? BeacleColors.borderGlow : BeacleColors.border),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, color: selected ? BeacleColors.text : BeacleColors.textDim)),
      ),
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
                      context.l.f(stale ? 'srvDataOutdated' : 'srvWaitingAgent', {'name': vps.name}),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                vps.tailscaleName.isNotEmpty ? 'Tailscale: ${vps.tailscaleName} · ${vps.host}' : vps.host,
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim, fontFamily: 'Consolas'),
              ),
              if (stale) ...[
                const SizedBox(height: 12),
                Text(
                  context.l.f('srvLastUpdate', {'ago': context.l.ago(vps.lastSeen)}),
                  style: TextStyle(fontSize: 12, color: BeacleColors.warn, height: 1.45),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Text(
                  context.l.t('srvRunInstall'),
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
                ),
                const SizedBox(height: 10),
                const AddVpsCommand(),
              ],
              const SizedBox(height: 16),
              SmallButton(context.l.t('srvDeleteVps'), icon: Icons.delete_outline, color: BeacleColors.err, onPressed: () async {
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
    return SmoothListView(
      padding: const EdgeInsets.all(16),
      children: [
        // A Wrap, not a Row: six buttons do not fit next to the name in a
        // normal-sized window, and a Row just cut the last ones off.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 10,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              StatusDot(vps.status, size: 12),
              const SizedBox(width: 10),
              Text(vps.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text(vps.host, style: TextStyle(color: BeacleColors.textDim)),
              const SizedBox(width: 12),
              Text(context.l.f('srvUpdated', {'ago': context.l.ago(vps.lastSeen)}),
                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              SmallButton(context.l.t('sshConnectButton'),
                  icon: Icons.terminal, onPressed: vps.online ? () => AppShell.of(context).openTerminal(vps.id) : null),
              SmallButton(context.l.t('tlButton'),
                  icon: Icons.key_outlined, onPressed: vps.online ? () => showTempLoginDialog(context, vps) : null),
              SmallButton(context.l.t('srvUpdateAgent'), icon: Icons.system_update_alt, onPressed: () async {
                try {
                  final r = await state.api.agentUpdate(vps.id);
                  if (context.mounted) showToast(context, r);
                } catch (e) {
                  if (context.mounted) showToast(context, '$e', error: true);
                }
              }),
              SmallButton(context.l.t('srvRollback'), icon: Icons.history, onPressed: () async {
                try {
                  final r = await state.api.agentRollback(vps.id);
                  if (context.mounted) showToast(context, r);
                } catch (e) {
                  if (context.mounted) showToast(context, '$e', error: true);
                }
              }),
              SmallButton(context.l.t('reboot'),
                  icon: Icons.restart_alt, onPressed: vps.online ? () => showRebootDialog(context, vps, snap) : null),
              SmallButton(context.l.t('poweroff'),
                  icon: Icons.power_settings_new_outlined,
                  onPressed: vps.online ? () => showPoweroffDialog(context, vps) : null),
              SmallButton(context.l.t('delete'), icon: Icons.delete_outline, color: BeacleColors.err,
                  onPressed: () async {
                if (!await confirmDeleteVps(context, vps)) return;
                await state.api.deleteVps(vps.id);
                await state.refreshAll();
              }),
            ]),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          context.l.t('srvStatsHint'),
          style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
        ),
        const SizedBox(height: 12),
        OsUpdatesBanner(vps: vps),
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
                  title: context.l.t('srvDisks'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.disks.isEmpty)
                        Text(context.l.t('srvNoDisk'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
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
                  title: context.l.t('srvNetwork'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.network.isEmpty)
                        Text(context.l.t('srvNoNet'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
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
                  title: context.l.t('srvSysInfo'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _info(context.l.t('srvHostname'), m.hostname),
                    _info('OS', m.os),
                    _info(context.l.t('srvKernel'), m.kernel),
                    _info(context.l.t('srvArch'), m.arch),
                    _info('CPU', m.cpuModel),
                    _info(context.l.t('srvCores'), '${m.cpuCores}'),
                  ]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Last on the page on purpose. Everything above is "right now", which
        // is what you came for; this answers what happened while nobody was
        // watching, and that is a question you scroll down to ask.
        HistoryPanel(vps: vps),
      ],
    );
  }

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text(k, style: TextStyle(fontSize: 12, color: BeacleColors.textDim))),
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
          Text('${m.cpuPercent.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            context.l.f('srvCoresLoad', {'n': m.cpuCores, 'load': m.load1.toStringAsFixed(2)}),
            style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(height: 12),
          MetricBar(label: context.l.t('srvOverall'), percent: m.cpuPercent),
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
      title: context.l.t('srvUptime'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l.uptime(m.uptimeSeconds), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(context.l.f('srvAgentV', {'v': vps.agentVersion}), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          const SizedBox(height: 4),
          Text(
            context.l.f('srvLoad', {'v': '${m.load1.toStringAsFixed(2)} / ${m.load5.toStringAsFixed(2)} / ${m.load15.toStringAsFixed(2)}'}),
            style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
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
      title: context.l.t('srvCpuCores'),
      trailing: Text('${cores.length}', style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
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
    final pctCached =
        m.memPercentCached > 0 ? m.memPercentCached : (m.memTotalBytes > 0 ? usedCached / m.memTotalBytes * 100 : 0.0);

    return PanelCard(
      expand: true,
      title: context.l.t('srvMemory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${m.memPercent.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            context.l.f('srvMemUsed', {'v': '${fmtBytes(m.memUsedBytes)} / ${fmtBytes(m.memTotalBytes)}'}),
            style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(height: 12),
          MetricBar(
            label: context.l.t('srvUsedApps'),
            percent: m.memPercent,
            detail: '${fmtBytes(m.memUsedBytes)} · ${m.memPercent.toStringAsFixed(0)}%',
          ),
          const SizedBox(height: 8),
          MetricBar(
            label: context.l.t('srvUsedCache'),
            percent: pctCached,
            detail: '${fmtBytes(usedCached)} · ${pctCached.toStringAsFixed(0)}%',
          ),
          if (m.memCachedBytes > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(context.l.t('srvCacheBuffers'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const Spacer(),
                Text(fmtBytes(m.memCachedBytes), style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            context.l.f('srvSwap', {'v': '${fmtBytes(m.swapUsed)} / ${fmtBytes(m.swapTotal)}'}),
            style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
        ],
      ),
    );
  }
}
