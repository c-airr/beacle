import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key});

  @override
  State<DockerScreen> createState() => _DockerScreenState();
}

class _DockerScreenState extends State<DockerScreen> {
  int tab = 0; // 0 containers, 1 images, 2 compose

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hosts = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (hosts.isEmpty) {
      return const Center(child: Text('No VPS with agent data', style: TextStyle(color: BeacleColors.textDim)));
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Text(
                '${hosts.length} VPS',
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
              const Spacer(),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  side: const BorderSide(color: BeacleColors.border),
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: 0, label: Text('Containers', style: TextStyle(fontSize: 12))),
                  ButtonSegment(value: 1, label: Text('Images', style: TextStyle(fontSize: 12))),
                  ButtonSegment(value: 2, label: Text('Compose', style: TextStyle(fontSize: 12))),
                ],
                selected: {tab},
                onSelectionChanged: (s) => setState(() => tab = s.first),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              for (var i = 0; i < hosts.length; i++) ...[
                if (i > 0) const SizedBox(height: 22),
                _VpsSectionHeader(vps: hosts[i], docker: state.snapshots[hosts[i].id]!.docker),
                const SizedBox(height: 10),
                switch (tab) {
                  0 => _ContainersBlock(vps: hosts[i], docker: state.snapshots[hosts[i].id]!.docker),
                  1 => _ImagesBlock(docker: state.snapshots[hosts[i].id]!.docker),
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

class _VpsSectionHeader extends StatelessWidget {
  final Vps vps;
  final DockerState docker;
  const _VpsSectionHeader({required this.vps, required this.docker});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          if (docker.available)
            Text('Docker ${docker.version}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim))
          else
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

class _ContainersBlock extends StatelessWidget {
  final Vps vps;
  final DockerState docker;
  const _ContainersBlock({required this.vps, required this.docker});

  ContainerStats? _stats(String id) => docker.stats.where((s) => s.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    if (!docker.available) {
      return const _EmptyNote('Docker not available on this VPS');
    }
    if (docker.containers.isEmpty) {
      return const _EmptyNote('No containers');
    }
    return Column(
      children: [
        for (final c in docker.containers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PanelCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 10, color: c.running ? BeacleColors.ok : BeacleColors.textDim),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 200,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(c.image,
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                          overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                  SizedBox(
                    width: 140,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.status, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                      if (c.restartCount > 0)
                        Text('restarts: ${c.restartCount}', style: const TextStyle(fontSize: 11, color: BeacleColors.warn)),
                    ]),
                  ),
                  Expanded(child: _statsCells(c)),
                  SizedBox(
                    width: 120,
                    child: Text(
                      c.ports
                          .map((p) => p.publicPort > 0 ? '${p.publicPort}→${p.privatePort}' : '${p.privatePort}')
                          .join(', '),
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _actions(context, state, c),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _statsCells(ContainerInfo c) {
    final s = _stats(c.id);
    if (s == null) return const SizedBox.shrink();
    return Row(children: [
      Expanded(child: MetricBar(label: 'CPU', percent: s.cpuPercent)),
      const SizedBox(width: 12),
      Expanded(child: MetricBar(label: 'MEM', percent: s.memPercent, detail: fmtBytes(s.memUsage))),
      const SizedBox(width: 12),
    ]);
  }

  Widget _actions(BuildContext context, AppState state, ContainerInfo c) {
    Future<void> act(String action) async {
      try {
        state.onUserAction();
        await state.api.dockerAction(vps.id, c.id, action);
        if (context.mounted) showToast(context, '${vps.name}/${c.name}: $action ok');
      } catch (e) {
        if (context.mounted) showToast(context, '$e', error: true);
      }
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        icon: const Icon(Icons.play_arrow, size: 17),
        tooltip: 'Start',
        color: c.running ? BeacleColors.textDim : BeacleColors.ok,
        onPressed: c.running ? null : () => act('start'),
      ),
      IconButton(
        icon: const Icon(Icons.stop, size: 17),
        tooltip: 'Stop',
        color: c.running ? BeacleColors.err : BeacleColors.textDim,
        onPressed: c.running ? () => act('stop') : null,
      ),
      IconButton(
        icon: const Icon(Icons.refresh, size: 17),
        tooltip: 'Restart',
        onPressed: () => act('restart'),
      ),
      IconButton(
        icon: const Icon(Icons.article_outlined, size: 17),
        tooltip: 'Logs',
        onPressed: () => showLogsDialog(context, '${vps.name} · ${c.name}',
            () => state.api.dockerLogs(vps.id, c.id, tail: 300)),
      ),
    ]);
  }
}

class _ImagesBlock extends StatelessWidget {
  final DockerState docker;
  const _ImagesBlock({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (!docker.available) {
      return const _EmptyNote('Docker not available on this VPS');
    }
    if (docker.images.isEmpty) {
      return const _EmptyNote('No images');
    }
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
                      child: Text(im.tags.isEmpty ? '<none>' : im.tags.join(', '),
                          style: const TextStyle(fontSize: 12))),
                  Expanded(
                      flex: 2,
                      child: Text(
                          im.id.replaceFirst('sha256:', '').substring(0, im.id.length > 20 ? 12 : im.id.length),
                          style: const TextStyle(fontSize: 12, fontFamily: 'Consolas', color: BeacleColors.textDim))),
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

class _ComposeBlock extends StatelessWidget {
  final DockerState docker;
  const _ComposeBlock({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (!docker.available) {
      return const _EmptyNote('Docker not available on this VPS');
    }
    if (docker.compose.isEmpty) {
      return const _EmptyNote('No compose projects');
    }
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
