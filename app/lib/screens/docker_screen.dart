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
  String? selectedId;
  int tab = 0; // 0 containers, 1 images, 2 compose

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final withAgent = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (withAgent.isEmpty) {
      return const Center(child: Text('No VPS with agent data', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= withAgent.first.id;
    final vps = withAgent.where((v) => v.id == selectedId).firstOrNull ?? withAgent.first;
    final docker = state.snapshots[vps.id]?.docker ?? DockerState.empty();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _vpsPicker(withAgent, vps),
              const SizedBox(width: 16),
              if (docker.available)
                Text('Docker ${docker.version}', style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))
              else
                Text('Docker unavailable: ${docker.error}',
                    style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
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
          child: switch (tab) {
            0 => _ContainersTab(vps: vps, docker: docker),
            1 => _ImagesTab(docker: docker),
            _ => _ComposeTab(docker: docker),
          },
        ),
      ],
    );
  }

  Widget _vpsPicker(List<Vps> list, Vps current) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: current.id,
        dropdownColor: BeacleColors.surfaceHi,
        style: const TextStyle(fontSize: 13, color: BeacleColors.text),
        items: [
          for (final v in list)
            DropdownMenuItem(
              value: v.id,
              child: Row(children: [StatusDot(v.status, size: 7), const SizedBox(width: 8), Text(v.name)]),
            )
        ],
        onChanged: (v) => setState(() => selectedId = v),
      ),
    );
  }
}

class _ContainersTab extends StatelessWidget {
  final Vps vps;
  final DockerState docker;
  const _ContainersTab({required this.vps, required this.docker});

  ContainerStats? _stats(String id) => docker.stats.where((s) => s.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    if (docker.containers.isEmpty) {
      return const Center(child: Text('No containers', style: TextStyle(color: BeacleColors.textDim)));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
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
                    width: 220,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(c.image,
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                          overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                  SizedBox(
                    width: 150,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.status, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                      if (c.restartCount > 0)
                        Text('restarts: ${c.restartCount}', style: const TextStyle(fontSize: 11, color: BeacleColors.warn)),
                    ]),
                  ),
                  Expanded(child: _statsCells(c)),
                  SizedBox(
                    width: 140,
                    child: Text(
                      c.ports.map((p) => p.publicPort > 0 ? '${p.publicPort}→${p.privatePort}' : '${p.privatePort}').join(', '),
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
      Expanded(
          child: MetricBar(
              label: 'MEM', percent: s.memPercent, detail: fmtBytes(s.memUsage))),
      const SizedBox(width: 12),
    ]);
  }

  Widget _actions(BuildContext context, AppState state, ContainerInfo c) {
    Future<void> act(String action) async {
      try {
        await state.api.dockerAction(vps.id, c.id, action);
        if (context.mounted) showToast(context, '${c.name}: $action ok');
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
        onPressed: () => showLogsDialog(context, 'Logs - ${c.name}',
            () => state.api.dockerLogs(vps.id, c.id, tail: 300)),
      ),
    ]);
  }
}

class _ImagesTab extends StatelessWidget {
  final DockerState docker;
  const _ImagesTab({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (docker.images.isEmpty) {
      return const Center(child: Text('No images', style: TextStyle(color: BeacleColors.textDim)));
    }
    const hdr = TextStyle(fontSize: 11, color: BeacleColors.textDim, fontWeight: FontWeight.w600);
    return ListView(
      padding: const EdgeInsets.all(16),
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
                    child: Text(im.id.replaceFirst('sha256:', '').substring(0, im.id.length > 20 ? 12 : im.id.length),
                        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas', color: BeacleColors.textDim))),
                SizedBox(
                    width: 100,
                    child: Text(fmtBytes(im.sizeBytes),
                        style: const TextStyle(fontSize: 12), textAlign: TextAlign.right)),
              ]),
            ),
          ),
      ],
    );
  }
}

class _ComposeTab extends StatelessWidget {
  final DockerState docker;
  const _ComposeTab({required this.docker});

  @override
  Widget build(BuildContext context) {
    if (docker.compose.isEmpty) {
      return const Center(child: Text('No compose projects detected', style: TextStyle(color: BeacleColors.textDim)));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final p in docker.compose)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PanelCard(
              title: p.name.toUpperCase(),
              trailing: Text('${p.running}/${p.total} running',
                  style: TextStyle(
                      fontSize: 12,
                      color: p.running == p.total ? BeacleColors.ok : BeacleColors.warn)),
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
