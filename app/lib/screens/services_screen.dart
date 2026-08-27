import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/screen_launcher.dart';
import '../widgets/service_wizard.dart';

/// Everything running on a host: systemd units, screen sessions and raw
/// processes. Processes used to be their own tab, but "what is running here"
/// is one question — splitting it across two tabs only meant picking the host
/// twice.
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

/// What a row in the unified list came from.
enum RunKind { systemd, process, screen }

/// One running thing, whatever kind it is. The "all" tab exists because that
/// is how the question actually gets asked — "what is eating this box" does
/// not come with a note saying whether the answer is a unit or a bare process.
class RunRow {
  final RunKind kind;
  final String name;
  final String detail;
  final String state;
  final int pid;
  final double cpu;
  final int mem;

  /// False when nothing can report usage for this row (a stopped unit), so the
  /// table can show a dash instead of a zero that looks like a measurement.
  final bool hasUsage;

  final SystemdUnit? unit;
  final ProcessInfo? proc;
  final ScreenSession? session;

  RunRow({
    required this.kind,
    required this.name,
    required this.detail,
    required this.state,
    required this.pid,
    required this.cpu,
    required this.mem,
    required this.hasUsage,
    this.unit,
    this.proc,
    this.session,
  });
}

enum SortKey { cpu, mem, name, pid }

class _ServicesScreenState extends State<ServicesScreen> {
  String? selectedId;
  int tab = 0; // 0 all, 1 systemd, 2 processes, 3 screen
  String filter = '';

  /// htop opens sorted by CPU because that is the question being asked nine
  /// times out of ten.
  SortKey sortKey = SortKey.cpu;
  bool sortDesc = true;

  List<ProcessInfo> processes = [];
  bool loadingProcs = false;
  Timer? _procTimer;
  Timer? _nohupTimer;
  int _refreshSec = 10;

  /// Keyed by VPS id: the nohup tab shows the whole fleet at once.
  Map<String, List<NohupJob>> nohupByVps = {};

  /// Tabs that need the process list: the processes tab and the merged view.
  bool get _needsProcesses => tab == 0 || tab == 2;

  /// screen and nohup span every server. Both answer "what did I leave running
  /// out there", and with four or more boxes, clicking through a dropdown to
  /// find out is the wrong shape for the question. The other tabs stay per-host
  /// because 250 units times a fleet is a list nobody reads.
  bool get _isFleetTab => tab == 3 || tab == 4;

  int get _fleetScreenCount {
    final state = context.read<AppState>();
    var n = 0;
    for (final v in state.vpsList) {
      n += state.snapshots[v.id]?.services.screen.length ?? 0;
    }
    return n;
  }

  int get _fleetNohupCount =>
      nohupByVps.values.fold<int>(0, (sum, jobs) => sum + jobs.length);

  /// Loads nohup jobs from every reachable server.
  ///
  /// A server that cannot be reached keeps whatever was last seen from it,
  /// marked stale, instead of going blank. Losing the network for five seconds
  /// should not erase the list of what you left running — and an empty list
  /// reads as "nothing is running there", which is a different and much worse
  /// claim than "we cannot ask right now".
  Future<void> _loadNohup() async {
    final state = context.read<AppState>();
    final hosts = state.vpsList.where((v) => v.online && !state.isReportStale(v)).toList();

    final results = await Future.wait(hosts.map((v) async {
      try {
        return MapEntry(v.id, await state.api.nohupJobs(v.id));
      } catch (_) {
        return MapEntry(v.id, null);
      }
    }));

    if (!mounted) return;
    setState(() {
      for (final r in results) {
        if (r.value != null) nohupByVps[r.key] = r.value!;
      }
    });
  }

  void _sortBy(SortKey key) {
    setState(() {
      if (sortKey == key) {
        sortDesc = !sortDesc;
      } else {
        sortKey = key;
        // Usage sorts big-first, names sort A-first: both are what you want on
        // the first click.
        sortDesc = key == SortKey.cpu || key == SortKey.mem;
      }
    });
  }

  List<RunRow> _sorted(List<RunRow> rows) {
    final out = [...rows];
    out.sort((a, b) {
      int cmp;
      switch (sortKey) {
        case SortKey.cpu:
          cmp = a.cpu.compareTo(b.cpu);
        case SortKey.mem:
          cmp = a.mem.compareTo(b.mem);
        case SortKey.pid:
          cmp = a.pid.compareTo(b.pid);
        case SortKey.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      // Ties on usage fall back to the name, so the list stops jittering
      // between refreshes when half the rows sit at 0.0%.
      if (cmp == 0) cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return sortDesc ? -cmp : cmp;
    });
    return out;
  }

  /// Joins everything running on the host into one list. systemd units and
  /// screen sessions carry a PID, so their CPU and memory come from the
  /// process table — otherwise a service could never be compared against the
  /// process that is actually starving it.
  List<RunRow> _allRows(ServicesState services) {
    final byPid = {for (final p in processes) p.pid: p};

    final rows = <RunRow>[
      for (final u in services.systemd)
        () {
          final p = byPid[u.mainPid];
          return RunRow(
            kind: RunKind.systemd,
            name: u.name,
            detail: u.description,
            state: u.activeState,
            pid: u.mainPid,
            cpu: p?.cpuPercent ?? 0,
            mem: p?.memBytes ?? 0,
            hasUsage: p != null,
            unit: u,
          );
        }(),
      for (final s in services.screen)
        () {
          // The interesting process is the command inside the session, not the
          // screen wrapper itself.
          final p = byPid[s.childPid] ?? byPid[s.pid];
          return RunRow(
            kind: RunKind.screen,
            name: s.name,
            detail: s.command,
            state: s.running ? (s.attached ? 'attached' : 'detached') : 'idle',
            pid: s.childPid != 0 ? s.childPid : s.pid,
            cpu: p?.cpuPercent ?? 0,
            mem: p?.memBytes ?? 0,
            hasUsage: p != null,
            session: s,
          );
        }(),
      for (final p in processes)
        RunRow(
          kind: RunKind.process,
          name: p.name,
          detail: p.command.isEmpty ? p.user : '${p.user}  ${p.command}',
          state: p.state,
          pid: p.pid,
          cpu: p.cpuPercent,
          mem: p.memBytes,
          hasUsage: true,
          proc: p,
        ),
    ];

    if (filter.isEmpty) return rows;
    return rows
        .where((r) =>
            r.name.toLowerCase().contains(filter) || r.detail.toLowerCase().contains(filter))
        .toList();
  }

  @override
  void dispose() {
    _procTimer?.cancel();
    _nohupTimer?.cancel();
    super.dispose();
  }

  /// Processes and nohup jobs are pulled on demand (neither rides the snapshot
  /// stream), so both only poll while a tab that shows them is open. screen
  /// needs no polling of its own — it arrives with the snapshots.
  void _syncProcessPolling() {
    final sec = context.read<AppState>().portsRefreshSeconds;
    if (!_needsProcesses) {
      _procTimer?.cancel();
      _procTimer = null;
    } else if (_procTimer == null || sec != _refreshSec) {
      _refreshSec = sec;
      _procTimer?.cancel();
      _procTimer = Timer.periodic(Duration(seconds: sec), (_) => _loadProcesses(silent: true));
    }

    if (tab != 4) {
      _nohupTimer?.cancel();
      _nohupTimer = null;
      return;
    }
    if (_nohupTimer != null) return;
    // Slower than processes: a detached job either runs or it does not, and
    // this is one round trip per server in the fleet.
    _nohupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _loadNohup());
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
              // Picking a server would mean nothing on the fleet tabs, so the
              // dropdown is replaced by what is actually being shown.
              if (_isFleetTab)
                Row(children: [
                  const Icon(Icons.dns_outlined, size: 15, color: BeacleColors.textDim),
                  const SizedBox(width: 8),
                  Text('All servers (${withAgent.length})',
                      style: const TextStyle(fontSize: 13, color: BeacleColors.text)),
                ])
              else
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
                    hintText: switch (tab) {
                      0 => 'Filter everything...',
                      2 => 'Filter processes...',
                      3 => 'Filter sessions...',
                      4 => 'Filter jobs...',
                      _ => 'Filter services...',
                    },
                    prefixIcon: const Icon(Icons.search, size: 16),
                  ),
                  onChanged: (v) => setState(() => filter = v.toLowerCase()),
                ),
              ),
              if (_needsProcesses) ...[
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
                  ButtonSegment(
                      value: 0,
                      label: Text('all (${services.systemd.length + services.screen.length + processes.length})',
                          style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 1, label: Text('systemd (${services.systemd.length})', style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 2, label: Text('processes (${processes.length})', style: const TextStyle(fontSize: 12))),
                  // Fleet-wide counts, because these two tabs are fleet-wide.
                  ButtonSegment(value: 3, label: Text('screen ($_fleetScreenCount)', style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 4, label: Text('nohup ($_fleetNohupCount)', style: const TextStyle(fontSize: 12))),
                ],
                selected: {tab},
                onSelectionChanged: (s) {
                  setState(() => tab = s.first);
                  if ((s.first == 0 || s.first == 2) && processes.isEmpty) _loadProcesses();
                  if (s.first == 4) _loadNohup();
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (tab) {
            0 => _allList(state, vps, services),
            1 => _systemdList(state, vps, services),
            2 => _processList(state, vps),
            3 => _fleetScreenList(state, withAgent),
            _ => _fleetNohupList(state, withAgent),
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

    final live = vps.online && !state.isReportStale(vps);

    Future<void> act(SystemdUnit u, String action) async {
      try {
        state.onUserAction();
        await state.api.systemdAction(vps.id, u.name, action);
        if (mounted) showToast(context, '${u.name}: $action ok');
      } catch (e) {
        if (mounted) showToast(context, '$e', error: true);
      }
    }

    Future<void> newService() async {
      final created = await showServiceWizard(context, state: state, vps: vps);
      if (!created) return;
      // The unit list rides the snapshot stream, so ask for a fresh one rather
      // than waiting out the interval — a service you just created should be
      // in the list when the dialog closes.
      state.onUserAction();
      await state.refreshAll();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(children: [
            const Expanded(
              child: Text(
                'Services that start on boot and come back if they die. Unlike a screen '
                'session or a nohup job, these survive a reboot.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
            ),
            SmallButton('New service', icon: Icons.add, onPressed: live ? newService : null),
          ]),
        ),
        if (units.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No services', style: TextStyle(color: BeacleColors.textDim)),
            ),
          )
        else
          Expanded(child: _systemdRows(state, vps, units, act)),
      ],
    );
  }

  Widget _systemdRows(
    AppState state,
    Vps vps,
    List<SystemdUnit> units,
    Future<void> Function(SystemdUnit, String) act,
  ) {
    return SmoothListView.builder(
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

  /// A column header that sorts. The arrow only appears on the active column,
  /// so the table says how it is ordered without a legend.
  Widget _sortHeader(String label, SortKey key, {TextAlign align = TextAlign.left}) {
    final active = sortKey == key;
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return InkWell(
      onTap: () => _sortBy(key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Text(label, style: active ? hdr.copyWith(color: BeacleColors.text) : hdr),
            if (active)
              Icon(sortDesc ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                  size: 14, color: BeacleColors.text),
          ],
        ),
      ),
    );
  }

  /// The merged view. Read-only on purpose: start/stop/restart live in the tab
  /// for that kind, where the confirmation can say what it is about to do to a
  /// unit rather than to "a row".
  Widget _allList(AppState state, Vps vps, ServicesState services) {
    if (!vps.online || state.isReportStale(vps)) {
      return Center(
        child: Text(
          state.isReportStale(vps) ? 'Data outdated — agent offline' : 'Waiting for agent…',
          style: const TextStyle(color: BeacleColors.textDim),
        ),
      );
    }
    final rows = _sorted(_allRows(services));
    if (rows.isEmpty) {
      return Center(
        child: Text(
          loadingProcs ? 'Loading…' : (filter.isEmpty ? 'Nothing running' : 'Nothing matches the filter'),
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
            children: [
              const SizedBox(width: 74, child: Text('KIND', style: hdr)),
              Expanded(flex: 2, child: _sortHeader('NAME', SortKey.name)),
              const Expanded(flex: 3, child: Text('DETAIL', style: hdr)),
              const SizedBox(width: 76, child: Text('STATE', style: hdr)),
              SizedBox(width: 62, child: _sortHeader('PID', SortKey.pid, align: TextAlign.right)),
              SizedBox(width: 66, child: _sortHeader('CPU %', SortKey.cpu, align: TextAlign.right)),
              SizedBox(width: 86, child: _sortHeader('MEMORY', SortKey.mem, align: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SmoothListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final r = rows[i];
              final hot = r.cpu >= 50;
              final (kindLabel, kindColor) = switch (r.kind) {
                RunKind.systemd => ('systemd', BeacleColors.accent),
                RunKind.screen => ('screen', BeacleColors.ok),
                RunKind.process => ('process', BeacleColors.textDim),
              };
              return Tooltip(
                message: r.detail.isEmpty ? r.name : r.detail,
                waitDuration: const Duration(milliseconds: 500),
                child: HoverRow(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 74,
                          child: Text(kindLabel,
                              style: TextStyle(fontSize: 10, color: kindColor, letterSpacing: 0.3)),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(r.name,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(r.detail,
                              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                          width: 76,
                          child: Text(r.state,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: r.state == 'failed' ? BeacleColors.err : BeacleColors.textDim),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                          width: 62,
                          child: Text(r.pid == 0 ? '—' : '${r.pid}',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                        ),
                        SizedBox(
                          width: 66,
                          child: Text(
                            r.hasUsage ? r.cpu.toStringAsFixed(1) : '—',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: hot ? BeacleColors.warn : BeacleColors.text,
                              fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 86,
                          child: Text(r.hasUsage ? fmtBytes(r.mem) : '—',
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

  /// Same ordering as the merged tab, applied to bare processes.
  List<ProcessInfo> _sortedProcs(List<ProcessInfo> rows) {
    final out = [...rows];
    out.sort((a, b) {
      int cmp;
      switch (sortKey) {
        case SortKey.cpu:
          cmp = a.cpuPercent.compareTo(b.cpuPercent);
        case SortKey.mem:
          cmp = a.memBytes.compareTo(b.memBytes);
        case SortKey.pid:
          cmp = a.pid.compareTo(b.pid);
        case SortKey.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      if (cmp == 0) cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return sortDesc ? -cmp : cmp;
    });
    return out;
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
    rows = _sortedProcs(rows);

    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
          child: Row(
            children: [
              SizedBox(width: 60, child: _sortHeader('PID', SortKey.pid)),
              Expanded(flex: 2, child: _sortHeader('NAME', SortKey.name)),
              const SizedBox(width: 90, child: Text('USER', style: hdr)),
              const SizedBox(width: 60, child: Text('STATE', style: hdr)),
              SizedBox(width: 70, child: _sortHeader('CPU %', SortKey.cpu, align: TextAlign.right)),
              SizedBox(width: 90, child: _sortHeader('MEMORY', SortKey.mem, align: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SmoothListView.builder(
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

  /// Deleting a session takes whatever is running in it with it, so the
  /// confirmation says which of the two cases this is rather than asking the
  /// same question either way.
  Future<void> _killScreen(AppState state, Vps vps, ScreenSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete session ${s.name}?'),
        content: Text(
          s.running
              ? 'The session and "${s.command}" running inside it are both killed. '
                  'Nothing is asked to shut down cleanly first — use the stop button for that.'
              : 'The session is empty, so only the session itself goes away.',
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton('Cancel', onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton('Delete', icon: Icons.delete_outline, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.screenKill(vps.id, s.name);
      if (mounted) showToast(context, 'Session ${s.name} deleted');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _refreshScreens(state, vps);
  }

  Future<void> _startNohup(AppState state, Vps vps) async {
    final spec = await showScreenLauncher(context, state: state, vpsId: vps.id, forNohup: true);
    if (spec == null) return;
    try {
      state.onUserAction();
      await state.api.nohupStart(vps.id, name: spec.name, dir: spec.dir, command: spec.command);
      if (mounted) showToast(context, 'Started ${spec.command}');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadNohup();
  }

  Future<void> _stopNohup(AppState state, Vps vps, NohupJob j) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stop ${j.name}?'),
        content: Text(
          j.running
              ? 'Sends SIGTERM to "${j.command}" (PID ${j.pid}) and its children, then SIGKILL '
                  'to anything still up after two seconds.\n\nThe log file stays.'
              : 'This job is no longer running — only its record is removed.',
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton('Cancel', onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton(j.running ? 'Stop' : 'Remove', icon: Icons.stop, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.nohupStop(vps.id, j.name);
      if (mounted) showToast(context, '${j.name} stopped');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadNohup();
  }

  /// nohup is the other way to leave something running: no terminal to
  /// reattach to, output goes to a file. Kept apart from screen because the
  /// two answer different questions — "let me watch this later" versus "just
  /// keep it up".
  /// A host's heading inside a fleet list. The actions belong to that host,
  /// not to the fleet: starting a session is always somewhere specific.
  ///
  /// When [offline] is set the rows below are the last thing seen rather than
  /// the current state, and the badge says so — the difference between "nothing
  /// is running there" and "we cannot ask right now" matters.
  Widget _hostHeader(Vps vps, String detail,
      {List<Widget> actions = const [], bool offline = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: BeacleColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: offline ? BeacleColors.err.withValues(alpha: 0.4) : BeacleColors.border),
      ),
      child: Row(
        children: [
          StatusDot(vps.status, size: 9),
          const SizedBox(width: 10),
          Text(vps.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          if (offline) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: BeacleColors.err.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(vps.status == 'agent_down' ? Icons.sensors_off : Icons.cloud_off,
                    size: 11, color: BeacleColors.err),
                const SizedBox(width: 5),
                Text(vps.status == 'agent_down' ? 'agent down' : 'offline',
                    style: const TextStyle(fontSize: 10, color: BeacleColors.err)),
              ]),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(detail,
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                overflow: TextOverflow.ellipsis),
          ),
          ...actions,
        ],
      ),
    );
  }

  /// Hosts worth drawing. Without a filter every server is listed, empty ones
  /// included, because an empty host is still somewhere you might want to start
  /// something. With a filter, servers with no match are dropped — three empty
  /// sections between two hits is just noise.
  List<Vps> _hostsWithMatches(List<Vps> hosts, int Function(Vps) matchCount) {
    if (filter.isEmpty) return hosts;
    return hosts.where((v) => matchCount(v) > 0).toList();
  }

  Widget _fleetScreenList(AppState state, List<Vps> hosts) {
    List<ScreenSession> sessionsOf(Vps v) {
      final all = state.snapshots[v.id]?.services.screen ?? const <ScreenSession>[];
      if (filter.isEmpty) return all;
      return all
          .where((s) =>
              s.name.toLowerCase().contains(filter) || s.command.toLowerCase().contains(filter))
          .toList();
    }

    final shown = _hostsWithMatches(hosts, (v) => sessionsOf(v).length);

    return SmoothListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Long-running scripts kept alive in GNU screen, across every server.',
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
          ),
        ),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text('Nothing matches the filter', style: TextStyle(color: BeacleColors.textDim)),
            ),
          ),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 22),
          Builder(builder: (_) {
            final vps = shown[i];
            final live = vps.online && !state.isReportStale(vps);
            final sessions = sessionsOf(vps);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _hostHeader(
                  vps,
                  live
                      ? '${sessions.length} session(s)'
                      : '${sessions.length} session(s) — last seen',
                  offline: !live,
                  actions: [
                    SmallButton('New session', icon: Icons.add,
                        onPressed: live ? () => _startScreen(state, vps) : null),
                  ],
                ),
                const SizedBox(height: 10),
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(live ? 'No screen sessions' : 'Nothing was running here when last seen',
                        style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                  )
                else
                  for (final s in sessions) _screenSessionCard(state, vps, s, live),
              ],
            );
          }),
        ],
        const Padding(
          padding: EdgeInsets.only(top: 14),
          child: Text('Reattach on the server with screen -r <name>.',
              style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
        ),
      ],
    );
  }

  Widget _screenSessionCard(AppState state, Vps vps, ScreenSession s, bool live) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Icon(Icons.terminal, size: 18, color: s.running ? BeacleColors.ok : BeacleColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(s.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                if (s.attached)
                  const Text('attached', style: TextStyle(fontSize: 10, color: BeacleColors.textDim)),
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
                    fontSize: 11, color: s.running ? BeacleColors.ok : BeacleColors.textDim)),
          ),
          const SizedBox(width: 10),
          // Start only into an idle session, stop only a busy one — the agent
          // enforces the same rule.
          IconButton(
            icon: const Icon(Icons.add, size: 16),
            tooltip: s.running ? 'Already running — stop it first' : 'Run a script here',
            color: BeacleColors.ok,
            onPressed: (!live || s.running) ? null : () => _startScreen(state, vps, existingName: s.name),
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
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            tooltip: 'Delete this session',
            color: BeacleColors.err,
            onPressed: !live ? null : () => _killScreen(state, vps, s),
          ),
        ]),
      ),
    );
  }

  Widget _fleetNohupList(AppState state, List<Vps> hosts) {
    List<NohupJob> jobsOf(Vps v) {
      final all = nohupByVps[v.id] ?? const <NohupJob>[];
      if (filter.isEmpty) return all;
      return all
          .where((j) =>
              j.name.toLowerCase().contains(filter) || j.command.toLowerCase().contains(filter))
          .toList();
    }

    final shown = _hostsWithMatches(hosts, (v) => jobsOf(v).length);

    return SmoothListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(children: [
            const Expanded(
              child: Text(
                'Detached commands across every server. Output goes to /var/log/beacle/<name>.log.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
            ),
            SmallButton('Refresh', icon: Icons.refresh, onPressed: _loadNohup),
          ]),
        ),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text('Nothing matches the filter', style: TextStyle(color: BeacleColors.textDim)),
            ),
          ),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 22),
          Builder(builder: (_) {
            final vps = shown[i];
            final live = vps.online && !state.isReportStale(vps);
            final jobs = jobsOf(vps);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _hostHeader(
                  vps,
                  live
                      ? '${jobs.where((j) => j.running).length}/${jobs.length} running'
                      : '${jobs.length} job(s) — last seen',
                  offline: !live,
                  actions: [
                    SmallButton('Run detached', icon: Icons.add,
                        onPressed: live ? () => _startNohup(state, vps) : null),
                  ],
                ),
                const SizedBox(height: 10),
                if (jobs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(live ? 'No nohup jobs' : 'Nothing was running here when last seen',
                        style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                  )
                else
                  for (final j in jobs) _nohupJobCard(state, vps, j, live),
              ],
            );
          }),
        ],
      ],
    );
  }

  Widget _nohupJobCard(AppState state, Vps vps, NohupJob j, bool live) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Icon(Icons.play_circle_outline, size: 18,
              color: j.running ? BeacleColors.ok : BeacleColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(j.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(j.command,
                  style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                'PID ${j.pid}${j.dir.isEmpty ? '' : ' · ${j.dir}'} · started ${j.started}',
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (j.running ? BeacleColors.ok : BeacleColors.textDim).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(j.running ? 'running' : 'exited',
                style: TextStyle(
                    fontSize: 11, color: j.running ? BeacleColors.ok : BeacleColors.textDim)),
          ),
          const SizedBox(width: 10),
          IconButton(
            icon: const Icon(Icons.article_outlined, size: 16),
            tooltip: 'Job output',
            onPressed: !live
                ? null
                : () => showLogsDialog(context, j.logFile, () => state.api.nohupLogs(vps.id, j.name)),
          ),
          IconButton(
            icon: Icon(j.running ? Icons.stop : Icons.delete_outline, size: 16),
            tooltip: j.running ? 'Stop this job' : 'Remove this record',
            color: BeacleColors.err,
            onPressed: !live ? null : () => _stopNohup(state, vps, j),
          ),
        ]),
      ),
    );
  }
}
