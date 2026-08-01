import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/screen_launcher.dart';

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
            _ => _screenList(state, vps, services),
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

  Future<void> _refreshScreens(AppState state, Vps vps) async {
    // The snapshot stream carries screen sessions, but after start/stop the
    // next tick can be seconds away — ask the agent to re-push immediately.
    try {
      await state.api.screenSessions(vps.id);
      await state.refreshAll();
    } catch (_) {}
  }

  Future<void> _startScreen(AppState state, Vps vps, {String? existingName}) async {
    final spec = await showScreenLauncher(context, state: state, vpsId: vps.id, fixedName: existingName);
    if (spec == null) return;
    try {
      state.onUserAction();
      await state.api.screenStart(vps.id, name: spec.name, dir: spec.dir, command: spec.command);
      if (mounted) showToast(context, 'Started ${spec.command} in ${spec.name}');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _refreshScreens(state, vps);
  }

  Future<void> _stopScreen(AppState state, Vps vps, ScreenSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop this process?'),
        content: Text(
          'Sends Ctrl+C to "${s.command}" in session ${s.name}.\n\n'
          'The session itself stays open, so you can start something else in it.',
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton('Cancel', onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton('Send Ctrl+C', icon: Icons.stop, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.screenStop(vps.id, s.name);
      if (mounted) showToast(context, 'Ctrl+C sent to ${s.name}');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _refreshScreens(state, vps);
  }

  Widget _screenList(AppState state, Vps vps, ServicesState services) {
    var sessions = services.screen;
    if (filter.isNotEmpty) {
      sessions = sessions.where((s) => s.name.toLowerCase().contains(filter)).toList();
    }
    final live = vps.online && !state.isReportStale(vps);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Long-running scripts kept alive in GNU screen.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                ),
              ),
              SmallButton(
                'New session',
                icon: Icons.add,
                onPressed: live ? () => _startScreen(state, vps) : null,
              ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const Center(child: Text('No screen sessions', style: TextStyle(color: BeacleColors.textDim)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    for (final s in sessions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: PanelCard(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(children: [
                            Icon(Icons.terminal, size: 18,
                                color: s.running ? BeacleColors.ok : BeacleColors.textDim),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Text(s.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 10),
                                  if (s.attached)
                                    const Text('attached',
                                        style: TextStyle(fontSize: 10, color: BeacleColors.textDim)),
                                ]),
                                const SizedBox(height: 2),
                                Text(
                                  s.running ? s.command : 'idle — nothing running',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: s.running ? 'Consolas' : null,
                                    color: s.running ? BeacleColors.text : BeacleColors.textDim,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'PID ${s.pid}${s.running ? ' · child ${s.childPid}' : ''} · created ${s.created}',
                                  style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                                ),
                              ]),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (s.running ? BeacleColors.ok : BeacleColors.textDim).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(s.running ? 'running' : 'idle',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: s.running ? BeacleColors.ok : BeacleColors.textDim)),
                            ),
                            const SizedBox(width: 10),
                            // Start only into an idle session, stop only a busy
                            // one — the agent enforces the same rule.
                            IconButton(
                              icon: const Icon(Icons.add, size: 16),
                              tooltip: s.running ? 'Already running — stop it first' : 'Run a script here',
                              color: BeacleColors.ok,
                              onPressed: (!live || s.running)
                                  ? null
                                  : () => _startScreen(state, vps, existingName: s.name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.stop, size: 16),
                              tooltip: s.running ? 'Send Ctrl+C' : 'Nothing to stop',
                              color: BeacleColors.err,
                              onPressed: (!live || !s.running) ? null : () => _stopScreen(state, vps, s),
                            ),
                            IconButton(
                              icon: const Icon(Icons.article_outlined, size: 16),
                              tooltip: 'Session output',
                              onPressed: !live
                                  ? null
                                  : () => showLogsDialog(
                                        context,
                                        'screen -S ${s.name} (hardcopy)',
                                        () => state.api.screenLogs(vps.id, s.name),
                                      ),
                            ),
                          ]),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Reattach on the server with screen -r <name>.',
                          style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
