import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/embedded_backend.dart';
import '../config.dart';
import '../local_settings.dart';
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
        const _HubStatusCard(),
        const SizedBox(height: 16),
        const _AgentUrlCard(),
        const SizedBox(height: 16),
        PanelCard(
          title: 'ADD VPS',
          trailing: SmallButton('Generate token', icon: Icons.add_link, onPressed: () => showAddVpsDialog(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Generate a pairing token, then run the install command on your Linux VPS as root. '
                'The agent registers itself and appears in Overview / Servers.',
                style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
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
                        Expanded(child: Text(v.name, style: const TextStyle(fontSize: 13))),
                        Text(v.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
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
                'Panel API: $localBackendUrl (embedded, starts with the app)',
                style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, fontFamily: 'Consolas'),
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

class _HubStatusCard extends StatelessWidget {
  const _HubStatusCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final color = state.hubActive ? BeacleColors.ok : BeacleColors.warn;
    return PanelCard(
      title: 'NETWORK HUB',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(state.hubActive ? Icons.hub : Icons.warning_amber_outlined, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.hubActive ? 'Hub active' : 'No hub node',
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ),
            ],
          ),
          if (state.hubUrl != null && state.hubUrl!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Hub URL: ${state.hubUrl}', style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim)),
          ],
          if (state.hubMessage != null) ...[
            const SizedBox(height: 8),
            Text(state.hubMessage!, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          ],
        ],
      ),
    );
  }
}

class _AgentUrlCard extends StatefulWidget {
  const _AgentUrlCard();

  @override
  State<_AgentUrlCard> createState() => _AgentUrlCardState();
}

class _AgentUrlCardState extends State<_AgentUrlCard> {
  late final TextEditingController _ctrl =
      TextEditingController(text: LocalSettings.agentPublicUrlOverride ?? '');
  String? _detected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshDetected();
  }

  Future<void> _refreshDetected() async {
    final url = await LocalSettings.resolveAgentPublicUrl();
    if (mounted) setState(() => _detected = url);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'AGENT CONNECTION URL',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Remote VPS agents connect outbound to this URL (your local Beacle backend). '
            'Auto-detected from your public IP. Override if you use port forwarding or a tunnel.',
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
          ),
          if (_detected != null) ...[
            const SizedBox(height: 10),
            Text('Active: $_detected', style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(
              labelText: 'Override URL (optional)',
              hintText: 'http://your-public-ip:8930',
            ),
            style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              SmallButton('Save & restart backend', icon: Icons.save, onPressed: _busy ? null : () async {
                setState(() => _busy = true);
                LocalSettings.agentPublicUrlOverride =
                    _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
                await EmbeddedBackend.instance.restart();
                await _refreshDetected();
                if (context.mounted) {
                  context.read<AppState>().refreshAll();
                  setState(() => _busy = false);
                  showToast(context, 'Backend restarted with new agent URL');
                }
              }),
              SmallButton('Auto-detect', icon: Icons.refresh, onPressed: _busy ? null : () async {
                setState(() => _busy = true);
                LocalSettings.agentPublicUrlOverride = null;
                _ctrl.clear();
                await EmbeddedBackend.instance.restart();
                await _refreshDetected();
                if (context.mounted) {
                  context.read<AppState>().refreshAll();
                  setState(() => _busy = false);
                }
              }),
            ],
          ),
        ],
      ),
    );
  }
}
