import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/cron_dialog.dart';
import '../widgets/firewall_dialog.dart';
import '../widgets/screen_launcher.dart';
import '../widgets/service_wizard.dart';

/// Everything running on a host: systemd units, screen sessions and raw
/// processes. Processes used to be their own tab, but "what is running here"
/// is one question — splitting it across two tabs only meant picking the host
/// twice.
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => ServicesScreenState();
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

class ServicesScreenState extends State<ServicesScreen> {
  String? selectedId;
  int tab = 0; // 0 all, 1 systemd, 2 processes, 3 screen
  String filter = '';
  final _filterCtl = TextEditingController();

  static const tabSystemd = 1;
  static const tabScreen = 3;

  /// Opens tab [t] on [vpsId] filtered to [query] (the search palette).
  void show({required String vpsId, required int t, String query = ''}) {
    _filterCtl.text = query;
    setState(() {
      selectedId = vpsId;
      filter = query.toLowerCase();
    });
    _selectTab(t);
  }

  /// htop opens sorted by CPU because that is the question being asked nine
  /// times out of ten.
  SortKey sortKey = SortKey.cpu;
  bool sortDesc = true;

  List<ProcessInfo> processes = [];
  bool loadingProcs = false;
  // A poll that has not come back yet. The timer fires on the clock, not on
  // the answer, and on a slow link the next tick used to start another ps
  // while the last one was still running.
  bool _procsInFlight = false;
  Timer? _procTimer;
  Timer? _nohupTimer;
  Timer? _logTimer;
  Timer? _logDebounce;
  int _refreshSec = 10;

  /// System logs tab state. The global filter field doubles as the grep query.
  List<SystemLogFile> logFiles = [];
  String? logFileId;
  String? _logHostId;
  String logText = '';
  bool loadingLogs = false;

  /// Keyed by VPS id: the nohup tab shows the whole fleet at once.
  Map<String, List<NohupJob>> nohupByVps = {};

  /// Cron tab state. Per-host like logs, but loaded once per host — crontabs
  /// do not change under their own power, so no polling.
  CronState? cron;
  String? _cronHostId;
  bool loadingCron = false;

  /// Firewall tab state. Same shape as cron: load on open, reload after
  /// every mutation.
  FirewallStatus? fw;
  String? _fwHostId;
  bool loadingFw = false;

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
    _logTimer?.cancel();
    _logDebounce?.cancel();
    _filterCtl.dispose();
    super.dispose();
  }

  /// Processes, nohup jobs and system logs are pulled on demand (none rides
  /// the snapshot stream), so each only polls while its tab is open. screen
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
    } else if (_nohupTimer == null) {
      // Slower than processes: a detached job either runs or it does not, and
      // this is one round trip per server in the fleet.
      _nohupTimer = Timer.periodic(const Duration(seconds: 15), (_) => _loadNohup());
    }

    if (tab != 5) {
      _logTimer?.cancel();
      _logTimer = null;
    } else if (_logTimer == null) {
      _logTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadLogs(silent: true));
    }
  }

  Future<void> _loadLogFiles() async {
    final state = context.read<AppState>();
    final id = selectedId;
    if (id == null) return;
    final vps = state.vpsList.where((v) => v.id == id).firstOrNull;
    if (vps == null || !vps.online || state.isReportStale(vps)) {
      if (mounted) setState(() => logFiles = []);
      return;
    }
    if (mounted) setState(() => loadingLogs = true);
    try {
      final files = await state.api.systemLogFiles(id);
      if (!mounted || selectedId != id) return;
      setState(() {
        logFiles = files;
        loadingLogs = false;
        if (logFileId == null || !files.any((f) => f.id == logFileId)) {
          logFileId = files.isEmpty ? null : files.first.id;
        }
      });
      if (logFileId != null) _loadLogs();
    } catch (_) {
      if (mounted && selectedId == id) {
        setState(() {
          logFiles = [];
          loadingLogs = false;
        });
      }
    }
  }

  Future<void> _loadLogs({bool silent = false}) async {
    final state = context.read<AppState>();
    final id = selectedId;
    final fileId = logFileId;
    if (id == null || fileId == null || tab != 5) return;
    if (!silent && mounted) setState(() => loadingLogs = true);
    try {
      final text = await state.api.systemLogs(id, fileId, tail: 500, grep: filter);
      if (mounted && selectedId == id && logFileId == fileId) {
        setState(() {
          logText = text;
          loadingLogs = false;
        });
      }
    } catch (_) {
      if (mounted && selectedId == id) setState(() => loadingLogs = false);
    }
  }

  void _debouncedLogReload() {
    _logDebounce?.cancel();
    _logDebounce = Timer(const Duration(milliseconds: 600), () => _loadLogs(silent: true));
  }

  Future<void> _loadCron() async {
    final state = context.read<AppState>();
    final id = selectedId;
    if (id == null) return;
    final vps = state.vpsList.where((v) => v.id == id).firstOrNull;
    if (vps == null || !vps.online || state.isReportStale(vps)) {
      if (mounted) {
        setState(() {
          cron = null;
          _cronHostId = id;
          loadingCron = false;
        });
      }
      return;
    }
    if (mounted) setState(() => loadingCron = true);
    try {
      final c = await state.api.cronState(id);
      if (!mounted || selectedId != id) return;
      setState(() {
        cron = c;
        _cronHostId = id;
        loadingCron = false;
      });
    } catch (_) {
      if (mounted && selectedId == id) {
        setState(() {
          cron = null;
          _cronHostId = id;
          loadingCron = false;
        });
      }
    }
  }

  Future<void> _cronCreate(AppState state, Vps vps) async {
    final spec = await showCronEditor(context, vpsName: vps.name);
    if (spec == null) return;
    try {
      state.onUserAction();
      await state.api.cronCreate(vps.id, spec);
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadCron();
  }

  Future<void> _cronEdit(AppState state, Vps vps, CronEntry e) async {
    final spec = await showCronEditor(context, existing: e, vpsName: vps.name);
    if (spec == null) return;
    try {
      state.onUserAction();
      await state.api.cronUpdate(vps.id, e.id, spec);
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadCron();
  }

  Future<void> _cronDelete(AppState state, Vps vps, CronEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.t('cronDeleteTitle')),
        content: Text(context.l.f('cronDeleteBody', {'cmd': e.command, 'vps': vps.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
          SmallButton(context.l.t('delete'), icon: Icons.delete_outline, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.cronDelete(vps.id, e.id);
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadCron();
  }

  Future<void> _loadFw() async {
    final state = context.read<AppState>();
    final id = selectedId;
    if (id == null) return;
    final vps = state.vpsList.where((v) => v.id == id).firstOrNull;
    if (vps == null || !vps.online || state.isReportStale(vps)) {
      if (mounted) {
        setState(() {
          fw = null;
          _fwHostId = id;
          loadingFw = false;
        });
      }
      return;
    }
    if (mounted) setState(() => loadingFw = true);
    try {
      final f = await state.api.firewallStatus(id);
      if (!mounted || selectedId != id) return;
      setState(() {
        fw = f;
        _fwHostId = id;
        loadingFw = false;
      });
    } catch (_) {
      if (mounted && selectedId == id) {
        setState(() {
          fw = null;
          _fwHostId = id;
          loadingFw = false;
        });
      }
    }
  }

  Future<void> _fwRule(AppState state, Vps vps, String action) async {
    final applied =
        await showFirewallRuleDialog(context, vpsId: vps.id, vpsName: vps.name, action: action);
    if (applied) await _loadFw();
  }

  Future<void> _fwDelete(AppState state, Vps vps, FirewallRule r) async {
    final applied =
        await showFirewallDeleteDialog(context, vpsId: vps.id, vpsName: vps.name, rule: r);
    if (applied) await _loadFw();
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
    if (silent && _procsInFlight) return;
    if (!silent && mounted) setState(() => loadingProcs = true);
    _procsInFlight = true;
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
    } finally {
      _procsInFlight = false;
    }
  }

  bool get _loadingTab => switch (tab) {
        5 => loadingLogs,
        6 => loadingCron,
        7 => loadingFw,
        _ => loadingProcs,
      };

  void _selectTab(int t) {
    setState(() => tab = t);
    if ((t == 0 || t == 2) && processes.isEmpty) _loadProcesses();
    if (t == 4) _loadNohup();
    if (t == 5) _loadLogFiles();
    if (t == 6 && _cronHostId != selectedId) _loadCron();
    if (t == 7 && _fwHostId != selectedId) _loadFw();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final withAgent = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (withAgent.isEmpty) {
      return Center(child: Text(context.l.t('dockerNoVps'), style: TextStyle(color: BeacleColors.textDim)));
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
              SizedBox(
                width: 220,
                child: _isFleetTab
                    ? Row(children: [
                        Icon(Icons.dns_outlined, size: 15, color: BeacleColors.textDim),
                        const SizedBox(width: 8),
                        Text(context.l.f('svcAllServers', {'n': withAgent.length}),
                            style: TextStyle(fontSize: 13, color: BeacleColors.text)),
                      ])
                    : DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: vps.id,
                          dropdownColor: BeacleColors.surfaceHi,
                          style: TextStyle(fontSize: 13, color: BeacleColors.text),
                          items: [
                            for (final v in withAgent)
                              DropdownMenuItem(
                                  value: v.id,
                                  child: Row(children: [
                                    StatusDot(v.status, size: 7),
                                    const SizedBox(width: 8),
                                    Flexible(child: Text(v.name, overflow: TextOverflow.ellipsis)),
                                  ]))
                          ],
                          onChanged: (v) {
                            setState(() => selectedId = v);
                            if (tab == 5) _loadLogFiles();
                            if (tab == 6) _loadCron();
                            if (tab == 7) _loadFw();
                          },
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _filterCtl,
                  decoration: InputDecoration(
                    hintText: switch (tab) {
                      0 => context.l.t('svcFilterAll'),
                      2 => context.l.t('svcFilterProcs'),
                      3 => context.l.t('svcFilterSessions'),
                      4 => context.l.t('svcFilterJobs'),
                      5 => context.l.t('logsGrepHint'),
                      6 => context.l.t('cronFilterHint'),
                      7 => context.l.t('fwFilterHint'),
                      _ => context.l.t('svcFilterServices'),
                    },
                    prefixIcon: const Icon(Icons.search, size: 16),
                  ),
                  onChanged: (v) {
                    setState(() => filter = v.toLowerCase());
                    if (tab == 5) _debouncedLogReload();
                  },
                ),
              ),
              if (_needsProcesses || tab == 5 || tab == 6 || tab == 7) ...[
                const SizedBox(width: 12),
                // The spinner sits over the button rather than in its place,
                // so the row keeps its width while a list loads.
                Stack(alignment: Alignment.center, children: [
                  Visibility(
                    visible: !_loadingTab,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: SmallButton(context.l.t('refresh'), icon: Icons.refresh, onPressed: switch (tab) {
                      5 => _loadLogs,
                      6 => _loadCron,
                      7 => _loadFw,
                      _ => _loadProcesses,
                    }),
                  ),
                  if (_loadingTab) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: SmoothSingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, label, count) in [
                (0, 'all', services.systemd.length + services.screen.length + processes.length),
                (1, 'systemd', services.systemd.length),
                (2, 'processes', processes.length),
                // Fleet-wide counts, because these two tabs are fleet-wide.
                (3, 'screen', _fleetScreenCount),
                (4, 'nohup', _fleetNohupCount),
                (5, 'logs', logFiles.length),
                (6, 'cron', (cron?.entries.length ?? 0) + (cron?.timers.length ?? 0)),
                (7, 'firewall', fw?.rules.length ?? 0),
              ]) ...[
                if (i > 0) const SizedBox(width: 6),
                TabChip(label: context.l.t('svcTab_$label'), count: count, selected: tab == i, onTap: () => _selectTab(i)),
              ],
            ]),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (tab) {
            0 => _allList(state, vps, services),
            1 => _systemdList(state, vps, services),
            2 => _processList(state, vps),
            3 => _fleetScreenList(state, withAgent),
            4 => _fleetNohupList(state, withAgent),
            5 => _systemLogsList(state, vps),
            6 => _cronList(state, vps),
            _ => _fwList(state, vps),
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
        if (mounted) showToast(context, context.l.f('actionDone', {'name': u.name, 'action': action}));
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
            Expanded(
              child: Text(
                context.l.t('svcSystemdIntro'),
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
            ),
            SmallButton(context.l.t('svcNewService'), icon: Icons.add, onPressed: live ? newService : null),
          ]),
        ),
        if (units.isEmpty)
          Expanded(
            child: Center(
              child: Text(context.l.t('svcNoServices'), style: TextStyle(color: BeacleColors.textDim)),
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
                  child: Text(u.enabled, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ),
                Expanded(
                  child: Text(u.description, style: TextStyle(fontSize: 12, color: BeacleColors.textDim), overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  tooltip: context.l.t('actStart'),
                  color: u.activeState == 'active' ? BeacleColors.textDim : BeacleColors.ok,
                  onPressed: u.activeState == 'active' ? null : () => act(u, 'start'),
                ),
                IconButton(
                  icon: const Icon(Icons.stop, size: 16),
                  tooltip: context.l.t('actStop'),
                  color: u.activeState == 'active' ? BeacleColors.err : BeacleColors.textDim,
                  onPressed: u.activeState == 'active' ? () => act(u, 'stop') : null,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  tooltip: context.l.t('actRestart'),
                  onPressed: () => act(u, 'restart'),
                ),
                IconButton(
                  icon: const Icon(Icons.article_outlined, size: 16),
                  tooltip: context.l.t('svcLogsJournal'),
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
    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
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
          state.isReportStale(vps) ? context.l.t('svcStale') : context.l.t('svcWaiting'),
          style: TextStyle(color: BeacleColors.textDim),
        ),
      );
    }
    final rows = _sorted(_allRows(services));
    if (rows.isEmpty) {
      return Center(
        child: Text(
          loadingProcs ? context.l.t('svcLoading') : (filter.isEmpty ? context.l.t('svcNothingRunning') : context.l.t('svcNothingMatches')),
          style: TextStyle(color: BeacleColors.textDim),
        ),
      );
    }

    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
          child: Row(
            children: [
              SizedBox(width: 74, child: Text(context.l.t('svcKind'), style: hdr)),
              Expanded(flex: 2, child: _sortHeader(context.l.t('procName'), SortKey.name)),
              Expanded(flex: 3, child: Text(context.l.t('svcDetail'), style: hdr)),
              SizedBox(width: 76, child: Text(context.l.t('procState'), style: hdr)),
              SizedBox(width: 62, child: _sortHeader('PID', SortKey.pid, align: TextAlign.right)),
              SizedBox(width: 66, child: _sortHeader('CPU %', SortKey.cpu, align: TextAlign.right)),
              SizedBox(width: 86, child: _sortHeader(context.l.t('procMemory'), SortKey.mem, align: TextAlign.right)),
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
                RunKind.process => (context.l.t('svcKindProcess'), BeacleColors.textDim),
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
                              style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
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
                              style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
          state.isReportStale(vps) ? context.l.t('svcStale') : context.l.t('svcWaiting'),
          style: TextStyle(color: BeacleColors.textDim),
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
          loadingProcs
              ? context.l.t('svcLoading')
              : (filter.isEmpty ? context.l.t('svcNoProcData') : context.l.t('svcNothingMatches')),
          style: TextStyle(color: BeacleColors.textDim),
        ),
      );
    }
    rows = _sortedProcs(rows);

    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
          child: Row(
            children: [
              SizedBox(width: 60, child: _sortHeader(context.l.t('procPid'), SortKey.pid)),
              Expanded(flex: 2, child: _sortHeader(context.l.t('procName'), SortKey.name)),
              SizedBox(width: 90, child: Text(context.l.t('procUser'), style: hdr)),
              SizedBox(width: 60, child: Text(context.l.t('procState'), style: hdr)),
              SizedBox(width: 70, child: _sortHeader(context.l.t('procCpu'), SortKey.cpu, align: TextAlign.right)),
              SizedBox(width: 90, child: _sortHeader(context.l.t('procMemory'), SortKey.mem, align: TextAlign.right)),
              const SizedBox(width: 64),
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
                              style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
                              style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(p.state,
                              style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
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
                        SizedBox(
                          width: 64,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              _killBtn(
                                icon: Icons.close,
                                tip: context.l.t('killTerminate'),
                                color: BeacleColors.warn,
                                onPressed: () => _killProcess(state, vps, p, 'term'),
                              ),
                              _killBtn(
                                icon: Icons.delete_forever_outlined,
                                tip: context.l.t('killForce'),
                                color: BeacleColors.err,
                                onPressed: () => _killProcess(state, vps, p, 'kill'),
                              ),
                            ],
                          ),
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

  Widget _killBtn(
      {required IconData icon, required String tip, required Color color, required VoidCallback onPressed}) {
    return SizedBox(
      width: 30,
      height: 26,
      child: IconButton(
        icon: Icon(icon, size: 15, color: color),
        tooltip: tip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }

  /// Asks for confirmation, then signals the process. The list refreshes right
  /// away so a successful kill reads as the row disappearing.
  Future<void> _killProcess(AppState state, Vps vps, ProcessInfo p, String signal) async {
    final force = signal == 'kill';
    final cmd = p.command.isEmpty ? p.name : p.command;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(force
            ? context.l.f('killKillTitle', {'name': p.name})
            : context.l.f('killTermTitle', {'name': p.name})),
        content: Text(
          force
              ? context.l.f('killKillBody', {'pid': p.pid, 'command': cmd, 'vps': vps.name})
              : context.l.f('killTermBody', {'pid': p.pid, 'command': cmd, 'vps': vps.name}),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(force ? context.l.t('killForce') : context.l.t('killTerminate'),
                style: TextStyle(color: BeacleColors.err)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.killProcess(vps.id, p.pid, signal);
      if (mounted) showToast(context, context.l.f('killDone', {'pid': p.pid}));
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    _loadProcesses(silent: true);
  }

  /// System logs for one host: a file picker plus the filter field above
  /// doubling as a grep query. Polls while the tab is open.
  Widget _systemLogsList(AppState state, Vps vps) {
    if (!vps.online || state.isReportStale(vps)) {
      return Center(
        child: Text(
          state.isReportStale(vps) ? context.l.t('svcStale') : context.l.t('svcWaiting'),
          style: TextStyle(color: BeacleColors.textDim),
        ),
      );
    }
    // Switching hosts with the tab open must re-list: available files differ
    // per distro (syslog vs messages) and per installed proxy.
    if (_logHostId != vps.id && !loadingLogs) {
      _logHostId = vps.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLogFiles();
      });
    }
    if (loadingLogs && logFiles.isEmpty) {
      return Center(
        child: Text(context.l.t('svcLoading'), style: TextStyle(color: BeacleColors.textDim)),
      );
    }
    if (logFiles.isEmpty) {
      return Center(
        child: Text(context.l.t('logsNoFiles'), style: TextStyle(color: BeacleColors.textDim)),
      );
    }
    final current =
        logFiles.where((f) => f.id == logFileId).firstOrNull ?? logFiles.first;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
          child: Row(
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: current.id,
                  dropdownColor: BeacleColors.surfaceHi,
                  style: TextStyle(fontSize: 13, color: BeacleColors.text),
                  items: [
                    for (final f in logFiles) DropdownMenuItem(value: f.id, child: Text(f.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      logFileId = v;
                      logText = '';
                    });
                    _loadLogs();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(current.path,
                    style: TextStyle(
                        fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(22, 10, 22, 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BeacleColors.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: BeacleColors.border),
            ),
            child: SmoothSingleChildScrollView(
              child: SelectableText(
                logText.isEmpty ? context.l.t('logsEmpty') : logText,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.45,
                  color: logText.isEmpty ? BeacleColors.textDim : BeacleColors.text,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Cron for one host: root's crontab (editable) plus read-only system
  /// cron files and systemd timers. The global filter matches commands.
  Widget _cronList(AppState state, Vps vps) {
    final live = vps.online && !state.isReportStale(vps);
    final c = cron;
    if (c == null && loadingCron) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (c == null) {
      return Center(
        child: Text(!live ? context.l.t('svcStale') : context.l.t('cronLoadFailed'),
            style: TextStyle(color: BeacleColors.textDim)),
      );
    }
    bool matches(CronEntry e) {
      if (filter.isEmpty) return true;
      final hay = '${e.command} ${e.source} ${e.schedule} ${e.user}'.toLowerCase();
      return hay.contains(filter);
    }

    bool timerMatches(SystemdTimer t) {
      if (filter.isEmpty) return true;
      return t.unit.toLowerCase().contains(filter);
    }

    final mine = c.entries.where((e) => e.source == 'crontab' && matches(e)).toList();
    final system = c.entries.where((e) => e.source != 'crontab' && matches(e)).toList();
    final timers = c.timers.where(timerMatches).toList();

    return SmoothListView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      children: [
        Row(children: [
          Expanded(
            child: Text(context.l.t('cronMine'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          if (!c.cronAvailable)
            Text(context.l.t('cronNoCron'),
                style: TextStyle(fontSize: 12, color: BeacleColors.warn)),
          const SizedBox(width: 8),
          SmallButton(context.l.t('cronNew'),
              icon: Icons.add,
              onPressed: !live || !c.cronAvailable ? null : () => _cronCreate(state, vps)),
        ]),
        const SizedBox(height: 8),
        if (mine.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(context.l.t('cronEmpty'),
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          ),
        for (final e in mine) _cronEntryCard(state, vps, e, live),
        if (system.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(context.l.t('cronSystem'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final e in system) _cronEntryCard(state, vps, e, live),
        ],
        if (timers.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(context.l.t('cronTimers'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final t in timers)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: BeacleColors.card,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BeacleColors.border),
                ),
                child: Row(children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: t.active == 'active' ? BeacleColors.ok : BeacleColors.textDim,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.unit, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(
                          '${context.l.t('cronNext')}: ${t.next.isEmpty ? '—' : t.next}   ·   '
                          '${context.l.t('cronLast')}: ${t.last.isEmpty ? '—' : t.last}',
                          style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
        ],
      ],
    );
  }

  Widget _cronEntryCard(AppState state, Vps vps, CronEntry e, bool live) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: BeacleColors.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: BeacleColors.border),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(e.command,
                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
                const SizedBox(height: 3),
                Text(
                  '${e.schedule}${e.user.isNotEmpty ? '   ·   ${e.user}' : ''}   ·   ${e.source}',
                  style: TextStyle(
                      fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
                ),
              ],
            ),
          ),
          if (e.editable) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 17),
              tooltip: context.l.t('edit'),
              color: BeacleColors.textDim,
              onPressed: !live ? null : () => _cronEdit(state, vps, e),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 17),
              tooltip: context.l.t('delete'),
              color: BeacleColors.err,
              onPressed: !live ? null : () => _cronDelete(state, vps, e),
            ),
          ],
        ]),
      ),
    );
  }

  /// Firewall for one host: backend state, editable rules with the SSH
  /// guard, and the listener list so allows match open ports.
  Widget _fwList(AppState state, Vps vps) {
    final live = vps.online && !state.isReportStale(vps);
    final f = fw;
    if (f == null && loadingFw) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (f == null) {
      return Center(
        child: Text(!live ? context.l.t('svcStale') : context.l.t('fwLoadFailed'),
            style: TextStyle(color: BeacleColors.textDim)),
      );
    }
    bool matches(FirewallRule r) {
      if (filter.isEmpty) return true;
      return '${r.raw} ${r.summary} ${r.comment}'.toLowerCase().contains(filter);
    }

    bool portMatches(PortInfo p) {
      if (filter.isEmpty) return true;
      return '${p.port} ${p.protocol} ${p.processName}'.toLowerCase().contains(filter);
    }

    final rules = f.rules.where(matches).toList();
    final open = f.openPorts.where(portMatches).toList();
    final canEdit = live && f.editable;

    Widget chip(String text, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(text, style: TextStyle(fontSize: 11, color: color)),
        );

    return SmoothListView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            chip(f.backend, BeacleColors.text),
            if (f.backendDetail.isNotEmpty)
              Text(f.backendDetail,
                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            chip(
                f.enabled ? context.l.t('fwEnabled') : context.l.t('fwDisabled'),
                f.enabled ? BeacleColors.ok : BeacleColors.warn),
            if (f.defaultIncoming.isNotEmpty)
              chip('${context.l.t('fwDefaultIn')}: ${f.defaultIncoming}',
                  f.defaultIncoming == 'deny' ? BeacleColors.ok : BeacleColors.warn),
            if (f.protectedPorts.isNotEmpty)
              chip('${context.l.t('fwGuarded')}: ${f.protectedPorts.join(', ')}',
                  BeacleColors.accent),
          ],
        ),
        if (f.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(f.note,
                style: TextStyle(fontSize: 12, color: BeacleColors.warn)),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(context.l.t('fwRules'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          SmallButton(context.l.t('fwAllow'),
              icon: Icons.add, onPressed: canEdit ? () => _fwRule(state, vps, 'allow') : null),
          const SizedBox(width: 8),
          SmallButton(context.l.t('fwBlockIp'),
              icon: Icons.block_outlined,
              color: BeacleColors.err,
              onPressed: canEdit ? () => _fwRule(state, vps, 'deny') : null),
        ]),
        const SizedBox(height: 8),
        if (rules.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(context.l.t('fwEmpty'),
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          ),
        for (final r in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: BeacleColors.card,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: BeacleColors.border),
              ),
              child: Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: r.action == 'allow'
                        ? BeacleColors.ok
                        : r.action == 'deny'
                            ? BeacleColors.err
                            : BeacleColors.textDim,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(r.summary,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (r.protected) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.shield_outlined,
                              size: 13, color: BeacleColors.accent),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      SelectableText(r.raw,
                          style: TextStyle(
                              fontSize: 11,
                              color: BeacleColors.textDim,
                              fontFamily: 'Consolas')),
                      if (r.comment.isNotEmpty)
                        Text(r.comment,
                            style: TextStyle(
                                fontSize: 11, color: BeacleColors.textDim)),
                    ],
                  ),
                ),
                if (r.id.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 17),
                    tooltip: context.l.t('delete'),
                    color: BeacleColors.err,
                    onPressed: canEdit ? () => _fwDelete(state, vps, r) : null,
                  ),
              ]),
            ),
          ),
        if (open.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(context.l.t('fwOpenPorts'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final p in open)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(
                  width: 110,
                  child: Text('${p.port}/${p.protocol}',
                      style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
                ),
                Expanded(
                  child: Text(
                    p.processName.isEmpty ? '—' : p.processName,
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
        ],
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
      if (mounted) showToast(context, context.l.f('svcStartedIn', {'cmd': spec.command, 'name': spec.name}));
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _refreshScreens(state, vps);
  }

  Future<void> _stopScreen(AppState state, Vps vps, ScreenSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.t('svcStopProcTitle')),
        content: Text(
          context.l.f('svcStopProcBody', {'cmd': s.command, 'name': s.name}),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton(context.l.t('cancel'), onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton(context.l.t('svcSendCtrlC'), icon: Icons.stop, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.screenStop(vps.id, s.name);
      if (mounted) showToast(context, context.l.f('svcCtrlCSent', {'name': s.name}));
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
        title: Text(context.l.f('svcDeleteSessionTitle', {'name': s.name})),
        content: Text(
          s.running
              ? context.l.f('svcDeleteSessionBusy', {'cmd': s.command})
              : context.l.t('svcDeleteSessionEmpty'),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton(context.l.t('cancel'), onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton(context.l.t('delete'), icon: Icons.delete_outline, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.screenKill(vps.id, s.name);
      if (mounted) showToast(context, context.l.f('svcSessionDeleted', {'name': s.name}));
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
      if (mounted) showToast(context, context.l.f('svcStarted', {'cmd': spec.command}));
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _loadNohup();
  }

  Future<void> _stopNohup(AppState state, Vps vps, NohupJob j) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.f('svcStopJobTitle', {'name': j.name})),
        content: Text(
          j.running
              ? context.l.f('svcStopJobBody', {'cmd': j.command, 'pid': j.pid})
              : context.l.t('svcStopJobGone'),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          SmallButton(context.l.t('cancel'), onPressed: () => Navigator.pop(ctx, false)),
          const SizedBox(width: 8),
          SmallButton(context.l.t(j.running ? 'actStop' : 'remove'), icon: Icons.stop, color: BeacleColors.err,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.onUserAction();
      await state.api.nohupStop(vps.id, j.name);
      if (mounted) showToast(context, context.l.f('svcJobStopped', {'name': j.name}));
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
        color: BeacleColors.card,
        borderRadius: BorderRadius.circular(12),
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
                Text(context.l.t(vps.status == 'agent_down' ? 'svcAgentDown' : 'svcOfflineLower'),
                    style: TextStyle(fontSize: 10, color: BeacleColors.err)),
              ]),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(detail,
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
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
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            context.l.t('svcScreenIntro'),
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
          ),
        ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(
              child: Text(context.l.t('svcNothingMatches'), style: TextStyle(color: BeacleColors.textDim)),
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
                      ? context.l.f('svcNSessions', {'n': sessions.length})
                      : context.l.f('svcNSessionsLast', {'n': sessions.length}),
                  offline: !live,
                  actions: [
                    SmallButton(context.l.t('sshNewSession'), icon: Icons.add,
                        onPressed: live ? () => _startScreen(state, vps) : null),
                  ],
                ),
                const SizedBox(height: 10),
                if (sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(live ? context.l.t('svcNoScreens') : context.l.t('svcNothingLastSeen'),
                        style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                  )
                else
                  for (final s in sessions) _screenSessionCard(state, vps, s, live),
              ],
            );
          }),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(context.l.t('svcReattach'),
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
                  Text(context.l.t('svcAttached'), style: TextStyle(fontSize: 10, color: BeacleColors.textDim)),
              ]),
              const SizedBox(height: 2),
              Text(
                s.running ? s.command : context.l.t('svcIdleNothing'),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: s.running ? 'Consolas' : null,
                  color: s.running ? BeacleColors.text : BeacleColors.textDim,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'PID ${s.pid}${s.running ? ' · ${context.l.f('svcChild', {'pid': s.childPid})}' : ''} · ${context.l.f('svcCreated', {'t': s.created})}',
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
              ),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (s.running ? BeacleColors.ok : BeacleColors.textDim).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(context.l.t(s.running ? 'svcRunning' : 'svcIdle'),
                style: TextStyle(
                    fontSize: 11, color: s.running ? BeacleColors.ok : BeacleColors.textDim)),
          ),
          const SizedBox(width: 10),
          // Start only into an idle session, stop only a busy one — the agent
          // enforces the same rule.
          IconButton(
            icon: const Icon(Icons.add, size: 16),
            tooltip: context.l.t(s.running ? 'svcAlreadyRunning' : 'svcRunHere'),
            color: BeacleColors.ok,
            onPressed: (!live || s.running) ? null : () => _startScreen(state, vps, existingName: s.name),
          ),
          IconButton(
            icon: const Icon(Icons.stop, size: 16),
            tooltip: context.l.t(s.running ? 'svcSendCtrlC' : 'svcNothingToStop'),
            color: BeacleColors.err,
            onPressed: (!live || !s.running) ? null : () => _stopScreen(state, vps, s),
          ),
          IconButton(
            icon: const Icon(Icons.article_outlined, size: 16),
            tooltip: context.l.t('svcSessionOutput'),
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
            tooltip: context.l.t('svcDeleteSession'),
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
            Expanded(
              child: Text(
                context.l.t('svcNohupIntro'),
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
            ),
            SmallButton(context.l.t('refresh'), icon: Icons.refresh, onPressed: _loadNohup),
          ]),
        ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(
              child: Text(context.l.t('svcNothingMatches'), style: TextStyle(color: BeacleColors.textDim)),
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
                      ? context.l.f('svcNRunning', {'r': jobs.where((j) => j.running).length, 't': jobs.length})
                      : context.l.f('svcNJobsLast', {'n': jobs.length}),
                  offline: !live,
                  actions: [
                    SmallButton(context.l.t('svcRunDetached'), icon: Icons.add,
                        onPressed: live ? () => _startNohup(state, vps) : null),
                  ],
                ),
                const SizedBox(height: 10),
                if (jobs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(live ? context.l.t('svcNoNohup') : context.l.t('svcNothingLastSeen'),
                        style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
                'PID ${j.pid}${j.dir.isEmpty ? '' : ' · ${j.dir}'} · ${context.l.f('svcStartedAt', {'t': j.started})}',
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim),
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
            child: Text(context.l.t(j.running ? 'svcRunning' : 'svcExited'),
                style: TextStyle(
                    fontSize: 11, color: j.running ? BeacleColors.ok : BeacleColors.textDim)),
          ),
          const SizedBox(width: 10),
          IconButton(
            icon: const Icon(Icons.article_outlined, size: 16),
            tooltip: context.l.t('svcJobOutput'),
            onPressed: !live
                ? null
                : () => showLogsDialog(context, j.logFile, () => state.api.nohupLogs(vps.id, j.name)),
          ),
          IconButton(
            icon: Icon(j.running ? Icons.stop : Icons.delete_outline, size: 16),
            tooltip: context.l.t(j.running ? 'svcStopJob' : 'svcRemoveRecord'),
            color: BeacleColors.err,
            onPressed: !live ? null : () => _stopNohup(state, vps, j),
          ),
        ]),
      ),
    );
  }
}
