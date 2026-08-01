import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Everything running on a host: systemd units, screen sessions and raw
/// processes. Processes used to be their own tab, but "what is running here"
/// is one question — splitting it across two tabs only meant picking the host
/// twice.
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  String? selectedId;
  int tab = 0; // 0 systemd, 1 processes, 2 screen
  String filter = '';

  List<ProcessInfo> processes = [];
  bool loadingProcs = false;
  Timer? _procTimer;
  int _refreshSec = 10;

  @override
  void dispose() {
    _procTimer?.cancel();
    super.dispose();
  }

  /// Processes are pulled on demand (they are not part of the snapshot stream),
  /// so only poll while their tab is actually open.
  void _syncProcessPolling() {
    final sec = context.read<AppState>().portsRefreshSeconds;
    if (tab != 1) {
      _procTimer?.cancel();
      _procTimer = null;
      return;
    }
    if (_procTimer != null && sec == _refreshSec) return;
    _refreshSec = sec;
    _procTimer?.cancel();
    _procTimer = Timer.periodic(Duration(seconds: sec), (_) => _loadProcesses(silent: true));
  }

  Future<void> _loadProcesses({bool silent = false}) async {
    final state = context.read<AppState>();
    final id = selectedId;
    if (id == null) return;
    final vps = state.vpsList.where((v) => v.id == id).firstOrNull;
    if (vps == null || !vps.online || state.isReportStale(vps)) {
      if (mounted) setState(() => processes = []);
      return;
    }
    if (!silent && mounted) setState(() => loadingProcs = true);
    try {
      final p = await state.api.processes(id);
      if (mounted && selectedId == id) {
        setState(() {
          processes = p;
          loadingProcs = false;
        });
      }
    } catch (_) {
      if (mounted && selectedId == id) {
        setState(() {
          processes = [];
          loadingProcs = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final withAgent = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (withAgent.isEmpty) {
      return const Center(child: Text('No VPS with agent data', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= withAgent.first.id;
    final vps = withAgent.where((v) => v.id == selectedId).firstOrNull ?? withAgent.first;
    final services = state.snapshots[vps.id]?.services ?? ServicesState.empty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncProcessPolling();
    });

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: vps.id,
                  dropdownColor: BeacleColors.surfaceHi,
                  style: const TextStyle(fontSize: 13, color: BeacleColors.text),
                  items: [
                    for (final v in withAgent)
                      DropdownMenuItem(
                          value: v.id,
                          child: Row(children: [StatusDot(v.status, size: 7), const SizedBox(width: 8), Text(v.name)]))
                  ],
                  onChanged: (v) => setState(() => selectedId = v),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tab == 1 ? 'Filter processes...' : 'Filter services...',
                    prefixIcon: const Icon(Icons.search, size: 16),
                  ),
                  onChanged: (v) => setState(() => filter = v.toLowerCase()),
                ),
              ),
              if (tab == 1) ...[
                const SizedBox(width: 12),
                if (loadingProcs)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  SmallButton('Refresh', icon: Icons.refresh, onPressed: _loadProcesses),
              ],
              const Spacer(),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                    side: const BorderSide(color: BeacleColors.border), visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: 0, label: Text('systemd (${services.systemd.length})', style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 1, label: Text('processes (${processes.length})', style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 2, label: Text('screen (${services.screen.length})', style: const TextStyle(fontSize: 12))),
                ],
                selected: {tab},
                onSelectionChanged: (s) {
                  setState(() => tab = s.first);
                  if (s.first == 1 && processes.isEmpty) _loadProcesses();
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (tab) {
            0 => _systemdList(state, vps, services),
            1 => _processList(state, vps),
            _ => _screenList(services),
          },
        ),
      ],
    );
  }

  Widget _systemdList(AppState state, Vps vps, ServicesState services) {
    var units = services.systemd;
    if (filter.isNotEmpty) {
      units = units.where((u) => u.name.toLowerCase().contains(filter) || u.description.toLowerCase().contains(filter)).toList();
    }
    // failed first, then active, then rest
    units.sort((a, b) {
      int rank(SystemdUnit u) => u.activeState == 'failed' ? 0 : (u.activeState == 'active' ? 1 : 2);
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });

    if (units.isEmpty) {
      return const Center(child: Text('No services', style: TextStyle(color: BeacleColors.textDim)));
    }

    Future<void> act(SystemdUnit u, String action) async {
      try {
        state.onUserAction();
        await state.api.systemdAction(vps.id, u.name, action);
        if (mounted) showToast(context, '${u.name}: $action ok');
      } catch (e) {
        if (mounted) showToast(context, '$e', error: true);
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: units.length,
      itemBuilder: (ctx, i) {
        final u = units[i];
        final color = switch (u.activeState) {
          'active' => BeacleColors.ok,
          'failed' => BeacleColors.err,
          'activating' || 'deactivating' => BeacleColors.warn,
          _ => BeacleColors.textDim,
        };
        return HoverRow(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(Icons.circle, size: 9, color: color),
                const SizedBox(width: 12),
                SizedBox(
                  width: 260,
                  child: Text(u.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                ),
                SizedBox(
                  width: 130,
                  child: Text('${u.activeState} (${u.subState})', style: TextStyle(fontSize: 12, color: color)),
                ),
                SizedBox(
                  width: 70,
                  child: Text(u.enabled, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ),
                Expanded(
                  child: Text(u.description, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim), overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  tooltip: 'Start',
                  color: u.activeState == 'active' ? BeacleColors.textDim : BeacleColors.ok,
                  onPressed: u.activeState == 'active' ? null : () => act(u, 'start'),
                ),
                IconButton(
                  icon: const Icon(Icons.stop, size: 16),
                  tooltip: 'Stop',
                  color: u.activeState == 'active' ? BeacleColors.err : BeacleColors.textDim,
                  onPressed: u.activeState == 'active' ? () => act(u, 'stop') : null,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  tooltip: 'Restart',
                  onPressed: () => act(u, 'restart'),
                ),
                IconButton(
                  icon: const Icon(Icons.article_outlined, size: 16),
                  tooltip: 'Logs (journalctl)',
                  onPressed: () => showLogsDialog(
                      context, 'journalctl -u ${u.name}', () => state.api.systemdLogs(vps.id, u.name, lines: 300)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _processList(AppState state, Vps vps) {
    if (!vps.online || state.isReportStale(vps)) {
      return Center(
        child: Text(
          state.isReportStale(vps) ? 'Data outdated — agent offline' : 'Waiting for agent…',
          style: const TextStyle(color: BeacleColors.textDim),
        ),
      );
    }
    var rows = processes;
    if (filter.isNotEmpty) {
      rows = rows
          .where((p) =>
              p.name.toLowerCase().contains(filter) ||
              p.user.toLowerCase().contains(filter) ||
              p.command.toLowerCase().contains(filter))
          .toList();
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          loadingProcs ? 'Loading…' : (filter.isEmpty ? 'No process data' : 'Nothing matches the filter'),
          style: const TextStyle(color: BeacleColors.textDim),
        ),
      );
    }

    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
          child: Row(
            children: const [
              SizedBox(width: 60, child: Text('PID', style: hdr)),
              Expanded(flex: 2, child: Text('NAME', style: hdr)),
              SizedBox(width: 90, child: Text('USER', style: hdr)),
              SizedBox(width: 60, child: Text('STATE', style: hdr)),
              SizedBox(width: 70, child: Text('CPU %', style: hdr, textAlign: TextAlign.right)),
              SizedBox(width: 90, child: Text('MEMORY', style: hdr, textAlign: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final p = rows[i];
              final hot = p.cpuPercent >= 50;
              return Tooltip(
                message: p.command.isEmpty ? p.name : p.command,
                waitDuration: const Duration(milliseconds: 500),
                child: HoverRow(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 60,
                          child: Text('${p.pid}',
                              style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(p.name,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                          width: 90,
                          child: Text(p.user,
                              style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(p.state,
                              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                        ),
                        SizedBox(
                          width: 70,
                          child: Text(
                            p.cpuPercent.toStringAsFixed(1),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: hot ? BeacleColors.warn : BeacleColors.text,
                              fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 90,
                          child: Text(fmtBytes(p.memBytes),
                              textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _screenList(ServicesState services) {
    var sessions = services.screen;
    if (filter.isNotEmpty) {
      sessions = sessions.where((s) => s.name.toLowerCase().contains(filter)).toList();
    }
    if (sessions.isEmpty) {
      return const Center(child: Text('No screen sessions', style: TextStyle(color: BeacleColors.textDim)));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final s in sessions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PanelCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Icon(Icons.terminal, size: 18, color: s.attached ? BeacleColors.ok : BeacleColors.textDim),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Text('PID ${s.pid} · created ${s.created}',
                        style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (s.attached ? BeacleColors.ok : BeacleColors.textDim).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(s.attached ? 'attached' : 'detached',
                      style: TextStyle(fontSize: 11, color: s.attached ? BeacleColors.ok : BeacleColors.textDim)),
                ),
              ]),
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Detached sessions can be reattached with screen -r <name> on the server.',
              style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
        ),
      ],
    );
  }
}
