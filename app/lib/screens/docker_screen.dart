import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Docker tab — one place for containers, images, volumes, networks, compose.
class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key});

  @override
  State<DockerScreen> createState() => DockerScreenState();
}

class DockerScreenState extends State<DockerScreen> {
  int tab = 0; // containers, images, volumes, networks, compose
  String filter = '';
  final _filterCtl = TextEditingController();

  /// Shows the containers tab filtered to [query] (the search palette).
  void showContainers(String query) {
    _filterCtl.text = query;
    setState(() {
      tab = 0;
      filter = query.trim().toLowerCase();
    });
  }

  @override
  void dispose() {
    _filterCtl.dispose();
    super.dispose();
  }

  List<String> _tabLabels() => [
        context.l.t('dockerTabContainers'),
        context.l.t('dockerTabImages'),
        context.l.t('dockerTabVolumes'),
        context.l.t('dockerTabNetworks'),
        context.l.t('dockerTabCompose'),
      ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tabs = _tabLabels();
    final hosts = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (hosts.isEmpty) {
      return Center(child: Text(context.l.t('dockerNoVps'), style: TextStyle(color: BeacleColors.textDim)));
    }

    var running = 0, total = 0;
    for (final h in hosts) {
      final d = state.snapshots[h.id]!.docker;
      total += d.containers.length;
      running += d.containers.where((c) => c.running).length;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                context.l.f('dockerRunning', {'r': running, 't': total, 'h': hosts.length}),
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
              const Spacer(),
              if (tab == 0)
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _filterCtl,
                    decoration: InputDecoration(
                      hintText: context.l.t('dockerFilterHint'),
                      prefixIcon: const Icon(Icons.search, size: 16),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (v) => setState(() => filter = v.trim().toLowerCase()),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: SmoothSingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  TabChip(
                    label: tabs[i],
                    selected: tab == i,
                    onTap: () => setState(() => tab = i),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SmoothListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              for (var i = 0; i < hosts.length; i++) ...[
                if (i > 0) const SizedBox(height: 22),
                _VpsSectionHeader(vps: hosts[i], docker: state.snapshots[hosts[i].id]!.docker),
                const SizedBox(height: 10),
                // Container cards are spread into the list rather than wrapped
                // in a Column. A Column has to lay out every child it holds, so
                // one per host meant every card on every server was measured on
                // every rebuild — and this screen rebuilds on each agent frame,
                // several times a second. As direct children the list only lays
                // out what is on screen, which is why the stutter scaled with
                // how much was in the tab.
                //
                // The other tabs stay as blocks: they are single bordered
                // tables, and splitting their rows apart would break the frame
                // drawn around them. They also hold far fewer rows.
                if (tab == 0)
                  ..._containerRows(
                    vps: hosts[i],
                    docker: state.snapshots[hosts[i].id]!.docker,
                    filter: filter,
                    l: context.l,
                  )
                else
                  switch (tab) {
                    1 => _ImagesBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    2 => _VolumesBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    3 => _NetworksBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    _ => _ComposeBlock(vps: hosts[i], docker: state.snapshots[hosts[i].id]!.docker),
                  },
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VpsSectionHeader extends StatelessWidget {
  final Vps vps;
  final DockerState docker;
  const _VpsSectionHeader({required this.vps, required this.docker});

  @override
  Widget build(BuildContext context) {
    final run = docker.containers.where((c) => c.running).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: BeacleColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Row(
        children: [
          StatusDot(vps.status, size: 9),
          const SizedBox(width: 10),
          Text(vps.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Text(vps.host, style: TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
          const Spacer(),
          if (docker.available) ...[
            Text(context.l.f('dockerUp', {'r': run, 't': docker.containers.length}),
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const SizedBox(width: 12),
            Text(context.l.f('dockerVersion', {'v': docker.version}),
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              tooltip: context.l.t('pruneRun'),
              visualDensity: VisualDensity.compact,
              onPressed: () => showDialog(
                context: context,
                builder: (_) => _PruneDialog(vps: vps),
              ),
            ),
          ] else
            Flexible(
              child: Text(
                docker.error.isEmpty ? context.l.t('dockerUnavailable') : docker.error,
                style: TextStyle(fontSize: 11, color: BeacleColors.err),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

/// One host's container cards, as list items rather than a Column — see the
/// note at the call site.
List<Widget> _containerRows({
  required Vps vps,
  required DockerState docker,
  required String filter,
  required L l,
}) {
  if (!docker.available) {
    return [_EmptyNote(l.t('dockerUnavailable'))];
  }
  if (docker.containers.isEmpty) return [_EmptyNote(l.t('dockerNoContainers'))];

  final list = docker.containers.where((c) {
    if (filter.isEmpty) return true;
    return c.name.toLowerCase().contains(filter) ||
        c.image.toLowerCase().contains(filter) ||
        c.state.toLowerCase().contains(filter);
  }).toList();
  if (list.isEmpty) return [_EmptyNote(l.t('dockerNoMatch'))];

  // Stats were looked up by scanning the whole stats list per container, so a
  // host with fifty containers did twenty-five hundred comparisons on every
  // rebuild. Indexed once instead.
  final byID = <String, ContainerStats>{};
  for (final st in docker.stats) {
    byID[st.id] = st;
  }
  ContainerStats? statsFor(String id) {
    final exact = byID[id];
    if (exact != null) return exact;
    // Docker truncates ids in some outputs, so one side may be a prefix of the
    // other; that case is rare enough to pay for only when the map misses.
    for (final st in docker.stats) {
      if (st.id.startsWith(id) || id.startsWith(st.id)) return st;
    }
    return null;
  }

  return [
    for (final c in list)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ContainerCard(vps: vps, container: c, stats: statsFor(c.id)),
      ),
  ];
}

class _ContainerCard extends StatelessWidget {
  final Vps vps;
  final ContainerInfo container;
  final ContainerStats? stats;
  const _ContainerCard({required this.vps, required this.container, required this.stats});

  Color get _stateColor {
    switch (container.state) {
      case 'running':
        return BeacleColors.ok;
      case 'restarting':
      case 'paused':
        return BeacleColors.warn;
      case 'exited':
      case 'dead':
        return BeacleColors.err;
      default:
        return BeacleColors.textDim;
    }
  }

  String get _ports {
    if (container.ports.isEmpty) return '—';
    return container.ports
        .map((p) => p.publicPort > 0 ? '${p.publicPort}→${p.privatePort}/${p.protocol}' : '${p.privatePort}/${p.protocol}')
        .join('  ');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: BeacleColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.circle, size: 9, color: _stateColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: _CopyText(container.name,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ellipsis: true),
                        ),
                        if (container.composeProject.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _Pill(container.composeService.isNotEmpty
                              ? '${container.composeProject}/${container.composeService}'
                              : container.composeProject),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(container.image,
                        style: TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ActionBar(vps: vps, container: container, state: state),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Meta(label: context.l.t('dockerStatus'), value: container.status.isEmpty ? container.state : container.status),
              _Meta(label: context.l.t('dockerPorts'), value: _ports),
              _Meta(
                label: context.l.t('dockerCpu'),
                value: stats == null ? '—' : '${stats!.cpuPercent.toStringAsFixed(1)}%',
              ),
              _Meta(
                label: context.l.t('dockerRam'),
                value: stats == null ? '—' : '${fmtBytes(stats!.memUsage)} (${stats!.memPercent.toStringAsFixed(0)}%)',
              ),
              _Meta(label: context.l.t('dockerUptime'), value: _uptimeLabel(context.l, container)),
            ],
          ),
          if (stats != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: MetricBar(label: 'CPU', percent: stats!.cpuPercent)),
                const SizedBox(width: 14),
                Expanded(
                    child: MetricBar(
                        label: context.l.t('dkMem'), percent: stats!.memPercent, detail: fmtBytes(stats!.memUsage))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _uptimeLabel(L l, ContainerInfo c) {
    // Docker Status is already human, e.g. "Up 3 hours" / "Exited (0) 2 days ago"
    if (c.status.toLowerCase().startsWith('up ')) return c.status;
    if (c.running) return c.status.isEmpty ? l.t('svcRunning') : c.status;
    return c.status.isEmpty ? c.state : c.status;
  }
}

class _Meta extends StatelessWidget {
  final String label, value;
  const _Meta({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 9, letterSpacing: 0.6, color: BeacleColors.textDim)),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: BeacleColors.textDim)),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final Vps vps;
  final ContainerInfo container;
  final AppState state;
  const _ActionBar({required this.vps, required this.container, required this.state});

  String _actionLabel(BuildContext context, String action) => switch (action) {
        'restart' => context.l.t('actRestart'),
        'stop' => context.l.t('actStop'),
        'start' => context.l.t('actStart'),
        'remove' => context.l.t('actRemove'),
        _ => action,
      };

  Future<void> _act(BuildContext context, String action, {bool confirm = false}) async {
    final label = _actionLabel(context, action);
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.l.f('confirmTitle', {'action': label, 'name': container.name})),
          content: Text(context.l.f('confirmBody',
              {'verb': action, 'action': label, 'vps': vps.name, 'name': container.name})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(label)),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      state.onUserAction();
      await state.api.dockerAction(vps.id, container.id, action);
      if (context.mounted) {
        showToast(context, context.l.f('actionDone', {'name': container.name, 'action': label}));
      }
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  Future<void> _stats(BuildContext context) async {
    try {
      state.onUserAction();
      final s = await state.api.dockerStats(vps.id, container.id);
      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.l.f('statsTitle', {'name': container.name})),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statLine(context.l.t('statsCpu'), '${s.cpuPercent.toStringAsFixed(1)}%'),
                _statLine(context.l.t('statsMemory'),
                    '${fmtBytes(s.memUsage)} / ${fmtBytes(s.memLimit)} (${s.memPercent.toStringAsFixed(1)}%)'),
                _statLine(context.l.t('statsNetRx'), fmtBytes(s.netRx)),
                _statLine(context.l.t('statsNetTx'), fmtBytes(s.netTx)),
                _statLine(context.l.t('statsPids'), '${s.pids}'),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('close')))],
        ),
      );
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  Widget _statLine(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 100, child: Text(k, style: TextStyle(fontSize: 12, color: BeacleColors.textDim))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
        ]),
      );

  Future<void> _exec(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => _ExecDialog(vps: vps, container: container),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(Icons.article_outlined, context.l.t('actLogs'), () => showLogsDialog(
              context,
              '${vps.name} · ${container.name}',
              () => state.api.dockerLogs(vps.id, container.id, tail: 400),
            )),
        _iconBtn(Icons.terminal, context.l.t('actExec'), () => _exec(context)),
        _iconBtn(Icons.bar_chart, context.l.t('actStats'), () => _stats(context)),
        _iconBtn(Icons.refresh, context.l.t('actRestart'), () => _act(context, 'restart')),
        if (container.running)
          _iconBtn(Icons.stop, context.l.t('actStop'), () => _act(context, 'stop'), color: BeacleColors.err)
        else
          _iconBtn(Icons.play_arrow, context.l.t('actStart'), () => _act(context, 'start'), color: BeacleColors.ok),
        _iconBtn(Icons.delete_outline, context.l.t('actRemove'), () => _act(context, 'remove', confirm: true),
            color: BeacleColors.err),
      ],
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onPressed, {Color? color}) {
    return IconButton(
      icon: Icon(icon, size: 17, color: color),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}

/// One-shot command inside a container: type, run, read the answer.
/// No PTY — for an interactive shell, SSH to the VPS instead.
class _ExecDialog extends StatefulWidget {
  final Vps vps;
  final ContainerInfo container;
  const _ExecDialog({required this.vps, required this.container});

  @override
  State<_ExecDialog> createState() => _ExecDialogState();
}

class _ExecDialogState extends State<_ExecDialog> {
  final _cmd = TextEditingController();
  bool _running = false;
  DockerExecResult? _result;
  String? _error;

  /// Session history, most recent first. Per-app rather than per-container:
  /// the same three commands get typed everywhere.
  static final List<String> _history = [];

  @override
  void dispose() {
    _cmd.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final command = _cmd.text.trim();
    if (command.isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    final state = context.read<AppState>();
    try {
      state.onUserAction();
      final res = await state.api.dockerExec(widget.vps.id, widget.container.id, command);
      _history.remove(command);
      _history.insert(0, command);
      if (_history.length > 10) _history.removeLast();
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    return AlertDialog(
      title: Text(context.l.f('execTitle', {'name': widget.container.name})),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l.t('execBody'),
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cmd,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: context.l.t('execHint'),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    ),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                    onSubmitted: (_) => _run(),
                  ),
                ),
                const SizedBox(width: 8),
                SmallButton(
                  _running ? context.l.t('runningEllipsis') : context.l.t('execRun'),
                  icon: Icons.play_arrow,
                  onPressed: _running ? null : _run,
                ),
              ],
            ),
            if (_history.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${context.l.t('historyLabel')}:',
                        style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ),
                  for (final h in _history)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: _running
                          ? null
                          : () {
                              _cmd.text = h;
                              _run();
                            },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: BeacleColors.surfaceHi,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: BeacleColors.border),
                        ),
                        child: Text(h,
                            style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 120, maxHeight: 300),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: BeacleColors.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: BeacleColors.border),
              ),
              child: _running
                  ? const Center(
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : _error != null
                      ? SelectableText(_error!,
                          style: TextStyle(fontSize: 12, color: BeacleColors.err, height: 1.4))
                      : res == null
                          ? Text(context.l.t('execEmpty'),
                              style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
                          : SmoothSingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '${context.l.t('exitCode')}: ${res.exitCode}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: res.exitCode == 0 ? BeacleColors.ok : BeacleColors.err,
                                        ),
                                      ),
                                      if (res.truncated) ...[
                                        const SizedBox(width: 8),
                                        Text(context.l.t('truncatedNote'),
                                            style: TextStyle(
                                                fontSize: 11, color: BeacleColors.warn)),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    res.output.isEmpty ? context.l.t('emptyOutput') : res.output,
                                    style: const TextStyle(
                                        fontFamily: 'Consolas', fontSize: 11, height: 1.4),
                                  ),
                                ],
                              ),
                            ),
            ),
          ],
        ),
      ),
      actions: [
        if (res != null && res.output.isNotEmpty)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: res.output));
              showToast(context, context.l.t('copied'));
            },
            child: Text(context.l.t('execCopyOutput')),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('close'))),
      ],
    );
  }
}

/// Docker cleanup with a preview: the dialog shows what dockerd reports as
/// reclaimable before anything is removed.
class _PruneDialog extends StatefulWidget {
  final Vps vps;
  const _PruneDialog({required this.vps});

  @override
  State<_PruneDialog> createState() => _PruneDialogState();
}

class _PruneDialogState extends State<_PruneDialog> {
  PrunePreview? _preview;
  String? _error;
  bool _images = true;
  bool _volumes = false;
  bool _builder = false;
  bool _working = false;
  PruneResult? _done;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await context.read<AppState>().api.prunePreview(widget.vps.id);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _run() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    final state = context.read<AppState>();
    try {
      state.onUserAction();
      final res = await state.api.dockerPrune(widget.vps.id,
          images: _images, volumes: _volumes, builder: _builder);
      if (mounted) setState(() => _done = res);
      await state.refreshAll();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    final done = _done;
    return AlertDialog(
      title: Text(context.l.f('pruneTitle', {'vps': widget.vps.name})),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l.t('pruneBody'),
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: TextStyle(fontSize: 12, color: BeacleColors.err, height: 1.4))
            else if (p == null)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
            else if (p.totalBytes == 0 && done == null)
              Text(context.l.t('pruneNone'),
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4))
            else ...[
              CheckboxListTile(
                value: _images,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  context.l.f('pruneImages', {'n': p.danglingImages, 'size': fmtBytes(p.danglingBytes)}),
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: _working || done != null ? null : (v) => setState(() => _images = v ?? false),
              ),
              CheckboxListTile(
                value: _volumes,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  context.l.f('pruneVolumes', {'n': p.unusedVolumes, 'size': fmtBytes(p.unusedVolumesBytes)}),
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: _working || done != null ? null : (v) => setState(() => _volumes = v ?? false),
              ),
              CheckboxListTile(
                value: _builder,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(context.l.t('pruneBuilder'), style: const TextStyle(fontSize: 12)),
                onChanged: _working || done != null ? null : (v) => setState(() => _builder = v ?? false),
              ),
            ],
            if (done != null) ...[
              const SizedBox(height: 8),
              Text(
                context.l.f('pruneDone', {
                  'size': fmtBytes(done.spaceReclaimed),
                  'images': done.imagesDeleted,
                  'volumes': done.volumesDeleted,
                }),
                style: TextStyle(fontSize: 12, color: BeacleColors.ok, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('close'))),
        if (done == null && p != null && p.totalBytes > 0)
          SmallButton(
            _working ? context.l.t('runningEllipsis') : context.l.t('pruneRun'),
            icon: Icons.cleaning_services_outlined,
            onPressed: (!_images && !_volumes && !_builder) || _working ? null : _run,
          ),
      ],
    );
  }
}

class _ImagesBlock extends StatelessWidget {
  final DockerState docker;
  const _ImagesBlock({required this.docker});

  static String _shortId(String id) {
    final clean = id.replaceFirst('sha256:', '');
    if (clean.length <= 12) return clean;
    return clean.substring(0, 12);
  }

  @override
  Widget build(BuildContext context) {
    if (!docker.available) return _EmptyNote(context.l.t('dockerUnavailable'));
    if (docker.images.isEmpty) return _EmptyNote(context.l.t('dockerNoImages'));
    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 3, child: Text(context.l.t('dkTags'), style: hdr)),
              Expanded(flex: 2, child: Text('ID', style: hdr)),
              SizedBox(width: 100, child: Text(context.l.t('dkSize'), style: hdr, textAlign: TextAlign.right)),
            ]),
          ),
          for (final im in docker.images)
            HoverRow(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(children: [
                  Expanded(
                      flex: 3,
                      child: _CopyText(im.tags.isEmpty ? '<none>' : im.tags.join(', '),
                          style: const TextStyle(fontSize: 12), ellipsis: true)),
                  Expanded(
                      flex: 2,
                      // Shows the short id but copies the full one — the short
                      // form is for reading, the long one is what a command
                      // needs.
                      child: _CopyId(full: im.id, shown: _shortId(im.id))),
                  SizedBox(
                      width: 100,
                      child: Text(fmtBytes(im.sizeBytes),
                          style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _VolumesBlock extends StatelessWidget {
  final DockerState docker;
  const _VolumesBlock({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (!docker.available) return _EmptyNote(context.l.t('dockerUnavailable'));
    if (docker.volumes.isEmpty) return _EmptyNote(context.l.t('dockerNoVolumes'));
    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 2, child: Text(context.l.t('procName'), style: hdr)),
              SizedBox(width: 80, child: Text(context.l.t('dkDriver'), style: hdr)),
              Expanded(flex: 3, child: Text(context.l.t('dkMountpoint'), style: hdr)),
            ]),
          ),
          for (final v in docker.volumes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Expanded(flex: 2, child: _CopyText(v.name, style: const TextStyle(fontSize: 12))),
                SizedBox(width: 80, child: Text(v.driver, style: TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                Expanded(
                    flex: 3,
                    child: _CopyText(v.mountpoint,
                        style: TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim),
                        ellipsis: true)),
              ]),
            ),
        ],
      ),
    );
  }
}

class _NetworksBlock extends StatelessWidget {
  final DockerState docker;
  const _NetworksBlock({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (!docker.available) return _EmptyNote(context.l.t('dockerUnavailable'));
    if (docker.networks.isEmpty) return _EmptyNote(context.l.t('dockerNoNetworks'));
    final hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 2, child: Text(context.l.t('procName'), style: hdr)),
              SizedBox(width: 80, child: Text(context.l.t('dkDriver'), style: hdr)),
              SizedBox(width: 70, child: Text(context.l.t('dkScope'), style: hdr)),
              SizedBox(width: 90, child: Text(context.l.t('dkContainers'), style: hdr, textAlign: TextAlign.right)),
            ]),
          ),
          for (final n in docker.networks)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Expanded(flex: 2, child: _CopyText(n.name, style: const TextStyle(fontSize: 12))),
                SizedBox(width: 80, child: Text(n.driver, style: TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                SizedBox(width: 70, child: Text(n.scope, style: TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                SizedBox(
                    width: 90,
                    child: Text('${n.containers}',
                        style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
              ]),
            ),
        ],
      ),
    );
  }
}

class _ComposeBlock extends StatelessWidget {
  final Vps vps;
  final DockerState docker;
  const _ComposeBlock({required this.vps, required this.docker});

  Future<void> _act(BuildContext context, ComposeProject p, String action) async {
    final state = context.read<AppState>();
    if (action == 'down') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.l.f('composeOutputTitle', {'action': 'down', 'project': p.name})),
          content: Text(context.l.f('composeDownBody', {'project': p.name, 'vps': vps.name})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.l.t('composeDown'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    // Pulls can take minutes — a blocking dialog with an honest note beats a
    // dead-looking button.
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          content: Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                context.l.f('composeWorking', {'action': action, 'project': p.name}),
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ]),
        ),
      );
    }
    String output;
    try {
      state.onUserAction();
      output = await state.api.composeAction(vps.id, p.name, action);
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // progress
        showToast(context, '$e', error: true);
      }
      return;
    }
    if (!context.mounted) return;
    Navigator.pop(context); // progress
    await state.refreshAll();
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.f('composeOutputTitle', {'action': action, 'project': p.name})),
        content: SizedBox(
          width: 520,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: BeacleColors.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: BeacleColors.border),
            ),
            child: SmoothSingleChildScrollView(
              child: SelectableText(
                output.isEmpty ? context.l.t('emptyOutput') : output,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.4),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: output));
              showToast(context, context.l.t('copied'));
            },
            child: Text(context.l.t('copy')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('close'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!docker.available) return _EmptyNote(context.l.t('dockerUnavailable'));
    if (docker.compose.isEmpty) return _EmptyNote(context.l.t('dockerNoCompose'));
    return Column(
      children: [
        for (final p in docker.compose)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PanelCard(
              title: p.name.toUpperCase(),
              trailing: Text(context.l.f('dockerUp', {'r': p.running, 't': p.total}),
                  style: TextStyle(
                      fontSize: 12, color: p.running == p.total ? BeacleColors.ok : BeacleColors.warn)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.l.f('dkDir', {'v': p.workingDir.isEmpty ? '-' : p.workingDir}),
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                Text(context.l.f('dkConfig', {'v': p.configFile.isEmpty ? '-' : p.configFile}),
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in p.services)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: BeacleColors.surfaceHi,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: BeacleColors.border),
                      ),
                      child: Text(s, style: const TextStyle(fontSize: 11)),
                    ),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: [
                  _composeBtn(context, Icons.refresh, context.l.t('composeRestart'), () => _act(context, p, 'restart')),
                  _composeBtn(context, Icons.system_update, context.l.t('composeUpdate'), () => _act(context, p, 'up')),
                  _composeBtn(context, Icons.download_outlined, context.l.t('composePull'), () => _act(context, p, 'pull')),
                  _composeBtn(context, Icons.stop, context.l.t('composeDown'), () => _act(context, p, 'down'),
                      color: BeacleColors.err),
                ]),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _composeBtn(BuildContext context, IconData icon, String label, VoidCallback onPressed, {Color? color}) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 14, color: color),
      label: Text(label, style: TextStyle(fontSize: 12, color: color)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: BeacleColors.border),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onPressed,
    );
  }
}

/// A table cell whose text can be copied.
///
/// Docker names are frequently unusable by hand — a compose-created volume is
/// its project name, a hash and a suffix — and they are exactly what you need
/// in the terminal command you are about to type. Selecting text inside a
/// scrolling list fights the scroll, so a click copies the whole value
/// instead.
class _CopyText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final bool ellipsis;
  const _CopyText(this.text, {this.style, this.ellipsis = false});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return Text(text, style: style);
    return Tooltip(
      message: context.l.f('dkClickCopy', {'v': text}),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: text));
          showToast(context, context.l.f('dkCopied', {'v': text}));
        },
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            text,
            style: style,
            overflow: ellipsis ? TextOverflow.ellipsis : null,
          ),
        ),
      ),
    );
  }
}

/// Shows a shortened id, copies the full one.
class _CopyId extends StatelessWidget {
  final String full, shown;
  const _CopyId({required this.full, required this.shown});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l.f('dkClickCopyId', {'v': full}),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: full));
          showToast(context, context.l.t('dkCopiedId'));
        },
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(shown,
              style: TextStyle(
                  fontSize: 12, fontFamily: 'Consolas', color: BeacleColors.textDim)),
        ),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;
  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(text, style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
    );
  }
}
