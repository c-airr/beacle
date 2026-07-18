import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Live processes and open ports for a selected VPS.
class ProcessesScreen extends StatefulWidget {
  const ProcessesScreen({super.key});

  @override
  State<ProcessesScreen> createState() => _ProcessesScreenState();
}

class _ProcessesScreenState extends State<ProcessesScreen> {
  String? selectedId;
  List<ProcessInfo> processes = [];
  List<PortInfo> ports = [];
  bool loading = false;
  Timer? _timer;
  int _refreshSec = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetTimer();
      _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    final sec = context.read<AppState>().portsRefreshSeconds;
    if (sec == _refreshSec && _timer != null) return;
    _refreshSec = sec;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: sec), (_) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
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
    if (!silent) setState(() => loading = true);
    final snap = state.snapshots[id];
    if (snap != null && snap.ports.isNotEmpty && mounted && selectedId == id) {
      setState(() => ports = snap.ports);
    }
    try {
      final p = await state.api.processes(id);
      var pr = snap?.ports ?? <PortInfo>[];
      if (pr.isEmpty) {
        pr = await state.api.ports(id);
      }
      if (mounted && selectedId == id) {
        setState(() {
          processes = p;
          ports = pr;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          processes = [];
          ports = [];
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.portsRefreshSeconds != _refreshSec) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetTimer();
      });
    }
    if (state.vpsList.isEmpty) {
      return const Center(child: Text('No VPS registered', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= state.vpsList.first.id;
    final vps = state.vpsList.where((v) => v.id == selectedId).firstOrNull ?? state.vpsList.first;
    final online = vps.online && !state.isReportStale(vps);

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
                    _load();
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
        Expanded(
          child: !online
              ? Center(
                  child: Text(
                    state.isReportStale(vps) ? 'Data outdated — agent offline' : 'Waiting for agent…',
                    style: const TextStyle(color: BeacleColors.textDim),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        StatusDot(vps.status, size: 12),
                        const SizedBox(width: 10),
                        Text(vps.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 12),
                        const Text(
                          'Processes & open ports',
                          style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                        ),
                        const Spacer(),
                        if (loading)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          SmallButton('Refresh', icon: Icons.refresh, onPressed: _load),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: PanelCard(
                            title: 'PROCESSES (top CPU)',
                            child: _ProcessTable(processes: processes.take(40).toList()),
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
                ),
        ),
      ],
    );
  }
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
              Expanded(
                  child: Text(p.processName.isEmpty ? '-' : p.processName,
                      style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              SizedBox(
                  width: 60,
                  child: Text(p.pid > 0 ? '${p.pid}' : '-', style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
            ]),
          ),
        ),
    ]);
  }
}
