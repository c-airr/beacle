import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  String? selectedId;
  int tab = 0; // 0 systemd, 1 screen
  String filter = '';

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
                  decoration: const InputDecoration(hintText: 'Filter services...', prefixIcon: Icon(Icons.search, size: 16)),
                  onChanged: (v) => setState(() => filter = v.toLowerCase()),
                ),
              ),
              const Spacer(),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                    side: const BorderSide(color: BeacleColors.border), visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: 0, label: Text('systemd (${services.systemd.length})', style: const TextStyle(fontSize: 12))),
                  ButtonSegment(value: 1, label: Text('screen (${services.screen.length})', style: const TextStyle(fontSize: 12))),
                ],
                selected: {tab},
                onSelectionChanged: (s) => setState(() => tab = s.first),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tab == 0 ? _systemdList(state, vps, services) : _screenList(services),
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
