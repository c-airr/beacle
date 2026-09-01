import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Docker tab — one place for containers, images, volumes, networks, compose.
class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key});

  @override
  State<DockerScreen> createState() => _DockerScreenState();
}

class _DockerScreenState extends State<DockerScreen> {
  int tab = 0; // containers, images, volumes, networks, compose
  String filter = '';

  static const _tabs = ['Containers', 'Images', 'Volumes', 'Networks', 'Compose'];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hosts = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (hosts.isEmpty) {
      return const Center(child: Text('No VPS with agent data', style: TextStyle(color: BeacleColors.textDim)));
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
                '$running/$total running · ${hosts.length} VPS',
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
              const Spacer(),
              if (tab == 0)
                SizedBox(
                  width: 220,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Filter containers…',
                      prefixIcon: Icon(Icons.search, size: 16),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                for (var i = 0; i < _tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _TabChip(
                    label: _tabs[i],
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
                  )
                else
                  switch (tab) {
                    1 => _ImagesBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    2 => _VolumesBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    3 => _NetworksBlock(docker: state.snapshots[hosts[i].id]!.docker),
                    _ => _ComposeBlock(docker: state.snapshots[hosts[i].id]!.docker),
                  },
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? BeacleColors.glassHi : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? BeacleColors.borderGlow : BeacleColors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? BeacleColors.text : BeacleColors.textDim,
            ),
          ),
        ),
      ),
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
        color: BeacleColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Row(
        children: [
          StatusDot(vps.status, size: 9),
          const SizedBox(width: 10),
          Text(vps.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Text(vps.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
          const Spacer(),
          if (docker.available) ...[
            Text('$run/${docker.containers.length} up',
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const SizedBox(width: 12),
            Text('Docker ${docker.version}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          ] else
            Text(
              docker.error.isEmpty ? 'Docker unavailable' : docker.error,
              style: const TextStyle(fontSize: 11, color: BeacleColors.err),
              overflow: TextOverflow.ellipsis,
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
}) {
  if (!docker.available) {
    return const [_EmptyNote('Docker not available on this VPS')];
  }
  if (docker.containers.isEmpty) return const [_EmptyNote('No containers')];

  final list = docker.containers.where((c) {
    if (filter.isEmpty) return true;
    return c.name.toLowerCase().contains(filter) ||
        c.image.toLowerCase().contains(filter) ||
        c.state.toLowerCase().contains(filter);
  }).toList();
  if (list.isEmpty) return const [_EmptyNote('No containers match filter')];

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
        color: BeacleColors.surface,
        borderRadius: BorderRadius.circular(8),
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
                        style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
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
              _Meta(label: 'STATUS', value: container.status.isEmpty ? container.state : container.status),
              _Meta(label: 'PORTS', value: _ports),
              _Meta(
                label: 'CPU',
                value: stats == null ? '—' : '${stats!.cpuPercent.toStringAsFixed(1)}%',
              ),
              _Meta(
                label: 'RAM',
                value: stats == null ? '—' : '${fmtBytes(stats!.memUsage)} (${stats!.memPercent.toStringAsFixed(0)}%)',
              ),
              _Meta(label: 'UPTIME', value: _uptimeLabel(container)),
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
                        label: 'MEM', percent: stats!.memPercent, detail: fmtBytes(stats!.memUsage))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _uptimeLabel(ContainerInfo c) {
    // Docker Status is already human, e.g. "Up 3 hours" / "Exited (0) 2 days ago"
    if (c.status.toLowerCase().startsWith('up ')) return c.status;
    if (c.running) return c.status.isEmpty ? 'running' : c.status;
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
          Text(label, style: const TextStyle(fontSize: 9, letterSpacing: 0.6, color: BeacleColors.textDim)),
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
      child: Text(text, style: const TextStyle(fontSize: 10, color: BeacleColors.textDim)),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final Vps vps;
  final ContainerInfo container;
  final AppState state;
  const _ActionBar({required this.vps, required this.container, required this.state});

  Future<void> _act(BuildContext context, String action, {bool confirm = false}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$action ${container.name}?'),
          content: Text('This will $action the container on ${vps.name}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      state.onUserAction();
      await state.api.dockerAction(vps.id, container.id, action);
      if (context.mounted) showToast(context, '${container.name}: $action ok');
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
          title: Text('Stats · ${container.name}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statLine('CPU', '${s.cpuPercent.toStringAsFixed(1)}%'),
                _statLine('Memory', '${fmtBytes(s.memUsage)} / ${fmtBytes(s.memLimit)} (${s.memPercent.toStringAsFixed(1)}%)'),
                _statLine('Network RX', fmtBytes(s.netRx)),
                _statLine('Network TX', fmtBytes(s.netTx)),
                _statLine('PIDs', '${s.pids}'),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  Widget _statLine(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 100, child: Text(k, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
        ]),
      );

  Future<void> _terminal(BuildContext context) async {
    final cmd = 'docker exec -it ${container.name} sh';
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Terminal · ${container.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Interactive shell from Beacle is not wired yet. Run this on the VPS:',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: BeacleColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BeacleColors.border),
                ),
                child: SelectableText(cmd, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: cmd));
              showToast(context, 'Copied');
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(Icons.article_outlined, 'Logs', () => showLogsDialog(
              context,
              '${vps.name} · ${container.name}',
              () => state.api.dockerLogs(vps.id, container.id, tail: 400),
            )),
        _iconBtn(Icons.terminal, 'Terminal', () => _terminal(context)),
        _iconBtn(Icons.bar_chart, 'Stats', () => _stats(context)),
        _iconBtn(Icons.refresh, 'Restart', () => _act(context, 'restart')),
        if (container.running)
          _iconBtn(Icons.stop, 'Stop', () => _act(context, 'stop'), color: BeacleColors.err)
        else
          _iconBtn(Icons.play_arrow, 'Start', () => _act(context, 'start'), color: BeacleColors.ok),
        _iconBtn(Icons.delete_outline, 'Remove', () => _act(context, 'remove', confirm: true), color: BeacleColors.err),
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
    if (!docker.available) return const _EmptyNote('Docker not available on this VPS');
    if (docker.images.isEmpty) return const _EmptyNote('No images');
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 3, child: Text('TAGS', style: hdr)),
              Expanded(flex: 2, child: Text('ID', style: hdr)),
              SizedBox(width: 100, child: Text('SIZE', style: hdr, textAlign: TextAlign.right)),
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
    if (!docker.available) return const _EmptyNote('Docker not available on this VPS');
    if (docker.volumes.isEmpty) return const _EmptyNote('No volumes');
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 2, child: Text('NAME', style: hdr)),
              SizedBox(width: 80, child: Text('DRIVER', style: hdr)),
              Expanded(flex: 3, child: Text('MOUNTPOINT', style: hdr)),
            ]),
          ),
          for (final v in docker.volumes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Expanded(flex: 2, child: _CopyText(v.name, style: const TextStyle(fontSize: 12))),
                SizedBox(width: 80, child: Text(v.driver, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                Expanded(
                    flex: 3,
                    child: _CopyText(v.mountpoint,
                        style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim),
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
    if (!docker.available) return const _EmptyNote('Docker not available on this VPS');
    if (docker.networks.isEmpty) return const _EmptyNote('No networks');
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              Expanded(flex: 2, child: Text('NAME', style: hdr)),
              SizedBox(width: 80, child: Text('DRIVER', style: hdr)),
              SizedBox(width: 70, child: Text('SCOPE', style: hdr)),
              SizedBox(width: 90, child: Text('CONTAINERS', style: hdr, textAlign: TextAlign.right)),
            ]),
          ),
          for (final n in docker.networks)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Expanded(flex: 2, child: _CopyText(n.name, style: const TextStyle(fontSize: 12))),
                SizedBox(width: 80, child: Text(n.driver, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim))),
                SizedBox(width: 70, child: Text(n.scope, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim))),
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
  final DockerState docker;
  const _ComposeBlock({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (!docker.available) return const _EmptyNote('Docker not available on this VPS');
    if (docker.compose.isEmpty) return const _EmptyNote('No compose projects');
    return Column(
      children: [
        for (final p in docker.compose)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PanelCard(
              title: p.name.toUpperCase(),
              trailing: Text('${p.running}/${p.total} running',
                  style: TextStyle(
                      fontSize: 12, color: p.running == p.total ? BeacleColors.ok : BeacleColors.warn)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('dir: ${p.workingDir.isEmpty ? '-' : p.workingDir}',
                    style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                Text('config: ${p.configFile.isEmpty ? '-' : p.configFile}',
                    style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
              ]),
            ),
          ),
      ],
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
      message: 'Click to copy · $text',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: text));
          showToast(context, 'Copied $text');
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
      message: 'Click to copy full id · $full',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: full));
          showToast(context, 'Copied id');
        },
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(shown,
              style: const TextStyle(
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
      child: Text(text, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
    );
  }
}
