import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';

/// Detailed per-VPS view: CPU, RAM, disk, network, processes, open ports,
/// system info, plus agent update controls.
class ServersScreen extends StatefulWidget {
  final String? initialVpsId;
  const ServersScreen({super.key, this.initialVpsId});

  @override
  State<ServersScreen> createState() => ServersScreenState();
}

class ServersScreenState extends State<ServersScreen> {
  String? selectedId;
  List<ProcessInfo> processes = [];
  List<PortInfo> ports = [];
  bool loadingDetail = false;
  Timer? _detailTimer;
  int _detailRefreshSec = 10;

  void selectVps(String id) {
    context.read<AppState>().bumpActivity();
    setState(() => selectedId = id);
    _loadDetail();
  }

  @override
  void initState() {
    super.initState();
    selectedId = widget.initialVpsId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetDetailTimer());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetail());
  }

  @override
  void didUpdateWidget(covariant ServersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialVpsId != null && widget.initialVpsId != selectedId) {
      selectedId = widget.initialVpsId;
      _loadDetail();
    }
  }

  @override
  void dispose() {
    _detailTimer?.cancel();
    super.dispose();
  }

  void _resetDetailTimer() {
    final sec = context.read<AppState>().portsRefreshSeconds;
    if (sec == _detailRefreshSec && _detailTimer != null) return;
    _detailRefreshSec = sec;
    _detailTimer?.cancel();
    _detailTimer = Timer.periodic(Duration(seconds: sec), (_) => _loadDetail(silent: true));
  }

  Future<void> _loadDetail({bool silent = false}) async {
    final state = context.read<AppState>();
    final id = selectedId ?? (state.vpsList.isNotEmpty ? state.vpsList.first.id : null);
    if (id == null) return;
    selectedId ??= id;
    final vps = state.vpsList.where((v) => v.id == id).firstOrNull;
    if (vps == null || !vps.online || state.isReportStale(vps)) {
      setState(() {
        processes = [];
        ports = [];
      });
      return;
    }
    if (!silent) setState(() => loadingDetail = true);
    final snap = state.snapshots[id];
    if (snap != null && snap.ports.isNotEmpty) {
      if (mounted && selectedId == id) {
        setState(() => ports = snap.ports);
      }
    }
    try {
      final p = await state.api.processes(id);
      List<PortInfo> pr = snap?.ports ?? [];
      if (pr.isEmpty) {
        pr = await state.api.ports(id);
      }
      if (mounted && selectedId == id) {
        setState(() {
          processes = p;
          ports = pr;
          loadingDetail = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          processes = [];
          ports = [];
          loadingDetail = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.portsRefreshSeconds != _detailRefreshSec) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetDetailTimer();
      });
    }
    if (state.vpsList.isEmpty) {
      return const Center(child: Text('No VPS registered', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= state.vpsList.first.id;
    final vps = state.vpsList.where((v) => v.id == selectedId).firstOrNull ?? state.vpsList.first;
    final snap = state.snapshots[vps.id];
    final showDetail = snap != null && vps.online && !state.isReportStale(vps);

    return Row(
      children: [
        // server list
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
                    _loadDetail();
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
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        // detail
        Expanded(
          child: showDetail
              ? _ServerDetail(
                  vps: vps,
                  snap: snap,
                  processes: processes,
                  ports: ports,
                  onRefresh: _loadDetail,
                )
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
                  'Last update ${fmtAgo(vps.lastSeen)}. Agent is not sending live metrics — showing no stale processes or disk data.',
                  style: const TextStyle(fontSize: 12, color: BeacleColors.warn, height: 1.45),
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text(
                  'Run the install command on the VPS as root. Data appears within seconds after the agent connects.',
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

class _ServerDetail extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot snap;
  final List<ProcessInfo> processes;
  final List<PortInfo> ports;
  final VoidCallback onRefresh;
  const _ServerDetail({
    required this.vps,
    required this.snap,
    required this.processes,
    required this.ports,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final m = snap.metrics;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // header
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
        const SizedBox(height: 16),
        // metric cards
        Row(
          children: [
            Expanded(
              child: PanelCard(
                title: 'CPU',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${m.cpuPercent.toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('${m.cpuCores} cores · load ${m.load1.toStringAsFixed(2)} / ${m.load5.toStringAsFixed(2)} / ${m.load15.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PanelCard(
                title: 'MEMORY',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${m.memPercent.toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('${fmtBytes(m.memUsedBytes)} / ${fmtBytes(m.memTotalBytes)}  ·  swap ${fmtBytes(m.swapUsed)}',
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PanelCard(
                title: 'UPTIME',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(fmtUptime(m.uptimeSeconds), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('agent v${vps.agentVersion}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PanelCard(
                title: 'DISKS',
                child: Column(children: [
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
                ]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PanelCard(
                title: 'NETWORK',
                child: Column(children: [
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
                ]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PanelCard(
                title: 'SYSTEM INFO',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _info('Hostname', m.hostname),
                  _info('OS', m.os),
                  _info('Kernel', m.kernel),
                  _info('Arch', m.arch),
                  _info('CPU', m.cpuModel),
                ]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: PanelCard(
                title: 'PROCESSES (top CPU)',
                trailing: SmallButton('Refresh', icon: Icons.refresh, onPressed: onRefresh),
                child: _ProcessTable(processes: processes.take(25).toList()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: PanelCard(
                title: 'OPEN PORTS',
                child: _PortsTable(ports: ports),
              ),
            ),
          ],
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

class _ProcessTable extends StatelessWidget {
  final List<ProcessInfo> processes;
  const _ProcessTable({required this.processes});

  @override
  Widget build(BuildContext context) {
    if (processes.isEmpty) {
      return const Text('No process data', style: TextStyle(color: BeacleColors.textDim, fontSize: 12));
    }
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(children: [
      const Row(children: [
        SizedBox(width: 60, child: Text('PID', style: hdr)),
        Expanded(flex: 2, child: Text('NAME', style: hdr)),
        SizedBox(width: 70, child: Text('USER', style: hdr)),
        SizedBox(width: 60, child: Text('CPU %', style: hdr, textAlign: TextAlign.right)),
        SizedBox(width: 70, child: Text('MEM', style: hdr, textAlign: TextAlign.right)),
      ]),
      const Divider(height: 12),
      for (final p in processes)
        Tooltip(
          message: p.command,
          waitDuration: const Duration(milliseconds: 500),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 60, child: Text('${p.pid}', style: const TextStyle(fontSize: 12))),
              Expanded(flex: 2, child: Text(p.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              SizedBox(width: 70, child: Text(p.user, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))),
              SizedBox(
                  width: 60,
                  child: Text(p.cpuPercent.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
              SizedBox(
                  width: 70,
                  child: Text(fmtBytes(p.memBytes), style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
            ]),
          ),
        ),
    ]);
  }
}

class _PortsTable extends StatelessWidget {
  final List<PortInfo> ports;
  const _PortsTable({required this.ports});

  @override
  Widget build(BuildContext context) {
    if (ports.isEmpty) {
      return const Text('No port data', style: TextStyle(color: BeacleColors.textDim, fontSize: 12));
    }
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(children: [
      const Row(children: [
        SizedBox(width: 60, child: Text('PORT', style: hdr)),
        SizedBox(width: 40, child: Text('PROTO', style: hdr)),
        Expanded(child: Text('PROCESS', style: hdr)),
        SizedBox(width: 60, child: Text('PID', style: hdr, textAlign: TextAlign.right)),
      ]),
      const Divider(height: 12),
      for (final p in ports)
        Tooltip(
          message: p.commandLine.isEmpty ? '(unknown command)' : p.commandLine,
          waitDuration: const Duration(milliseconds: 500),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 60, child: Text('${p.port}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              SizedBox(width: 40, child: Text(p.protocol, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim))),
              Expanded(child: Text(p.processName.isEmpty ? '-' : p.processName, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              SizedBox(width: 60, child: Text(p.pid > 0 ? '${p.pid}' : '-', style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
            ]),
          ),
        ),
    ]);
  }
}
