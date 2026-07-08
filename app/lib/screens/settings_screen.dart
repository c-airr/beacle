import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../paths.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../update/app_updater.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  String? updateStatus;
  UpdateInfo? staged;
  bool checking = false;
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: BeacleColors.border,
            indicatorColor: BeacleColors.text,
            labelColor: BeacleColors.text,
            unselectedLabelColor: BeacleColors.textDim,
            tabs: const [
              Tab(text: 'VPS'),
              Tab(text: 'Updates'),
              Tab(text: 'Status'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _vpsTab(state),
              _updatesTab(state),
              _statusTab(state),
            ],
          ),
        ),
      ],
    );
  }

  Widget _vpsTab(AppState state) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PanelCard(
          title: 'TAILSCALE',
          child: const Text(
            tailscaleRequirement,
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: 'ADD VPS',
          trailing: SmallButton('Add VPS', icon: Icons.add, onPressed: () => showAddVpsDialog(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pick a device from your tailnet, then run the install command on that VPS as root.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
              const SizedBox(height: 6),
              Text(
                'Download: $installScriptUrl',
                style: const TextStyle(fontSize: 10, color: BeacleColors.textDim, fontFamily: 'Consolas'),
              ),
              const SizedBox(height: 14),
              const AddVpsCommand(),
              const SizedBox(height: 16),
              Text(
                '${state.vpsList.length} VPS registered',
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
              ),
            ],
          ),
        ),
        if (state.vpsList.isNotEmpty) ...[
          const SizedBox(height: 16),
          PanelCard(
            title: 'REGISTERED VPS',
            child: Column(
              children: [
                for (final v in state.vpsList)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        StatusDot(v.status, size: 8),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(v.name, style: const TextStyle(fontSize: 13)),
                              Text(
                                [
                                  if (v.tailscaleName.isNotEmpty) v.tailscaleName,
                                  v.host,
                                  v.status,
                                ].where((s) => s.isNotEmpty).join(' · '),
                                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete VPS',
                          icon: const Icon(Icons.delete_outline, size: 18, color: BeacleColors.err),
                          onPressed: () async {
                            if (!await confirmDeleteVps(context, v)) return;
                            await state.api.deleteVps(v.id);
                            await state.refreshAll();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _updatesTab(AppState state) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PanelCard(
          title: 'DESKTOP APP UPDATES',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Current version: $appVersion', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            const Text(
              'Updates are fetched from GitHub Releases. Your settings are never overwritten.',
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SmallButton('Check for updates', icon: Icons.system_update, onPressed: checking ? null : () async {
                  setState(() {
                    checking = true;
                    updateStatus = null;
                  });
                  try {
                    final info = await AppUpdater.checkForUpdate();
                    if (info == null) {
                      setState(() => updateStatus = 'You are on the latest version.');
                    } else {
                      final msg = await AppUpdater.downloadAndStage(info);
                      setState(() {
                        staged = info;
                        updateStatus = msg;
                      });
                    }
                  } catch (e) {
                    setState(() => updateStatus = 'Update check failed: $e');
                  } finally {
                    setState(() => checking = false);
                  }
                }),
                if (staged != null)
                  SmallButton('Apply and restart', icon: Icons.restart_alt, color: BeacleColors.ok, onPressed: () async {
                    try {
                      await AppUpdater.applyAndRestart();
                    } catch (e) {
                      setState(() => updateStatus = '$e');
                    }
                  }),
                if (AppUpdater.hasPrevious)
                  SmallButton('Rollback', icon: Icons.history, color: BeacleColors.warn, onPressed: () async {
                    try {
                      await AppUpdater.rollbackAndRestart();
                    } catch (e) {
                      setState(() => updateStatus = '$e');
                    }
                  }),
              ],
            ),
            if (checking) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 3)),
            if (updateStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(updateStatus!, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: 'AGENT UPDATES',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'Agents auto-update from the backend every 6 hours. You can also trigger update/rollback per VPS. Agent config files are never overwritten.',
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
            ),
            const SizedBox(height: 12),
            if (state.vpsList.isEmpty)
              const Text('No VPS yet — add one in the VPS tab.', style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
            else
              for (final v in state.vpsList)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusDot(v.status, size: 8),
                      SizedBox(width: 140, child: Text(v.name, style: const TextStyle(fontSize: 13))),
                      Text('v${v.agentVersion.isEmpty ? '?' : v.agentVersion}',
                          style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                      SmallButton('Update', icon: Icons.system_update_alt, onPressed: !v.online ? null : () async {
                        try {
                          final r = await state.api.agentUpdate(v.id);
                          if (context.mounted) showToast(context, '${v.name}: $r');
                        } catch (e) {
                          if (context.mounted) showToast(context, '$e', error: true);
                        }
                      }),
                      SmallButton('Rollback', icon: Icons.history, onPressed: !v.online ? null : () async {
                        try {
                          final r = await state.api.agentRollback(v.id);
                          if (context.mounted) showToast(context, '${v.name}: $r');
                        } catch (e) {
                          if (context.mounted) showToast(context, '$e', error: true);
                        }
                      }),
                    ],
                  ),
                ),
          ]),
        ),
      ],
    );
  }

  Widget _statusTab(AppState state) {
    final statusText = state.connected
        ? 'Connected · ${state.vpsList.length} VPS registered'
        : 'Backend unreachable: ${state.lastError ?? 'unknown error'}';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PanelCard(
          title: 'LOCAL BACKEND',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Data: ${BeaclePaths.dataDir}',
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
              ),
              const SizedBox(height: 8),
              Text(
                statusText,
                style: TextStyle(fontSize: 12, color: state.connected ? BeacleColors.ok : BeacleColors.err),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
