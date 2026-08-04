import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../backend/autostart.dart';
import '../backend/config_maintenance.dart';
import '../config.dart';
import '../models/models.dart';
import '../paths.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../tray.dart';
import '../update/app_updater.dart';
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
  bool? autostartOn;

  // Status tab
  List<TailscaleDevice> tsDevices = [];
  bool tsLoading = false;
  String? tsError;
  List<String> netChecks = [];
  bool netChecking = false;
  String? maintenanceStatus;

  @override
  void initState() {
    super.initState();
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => autostartOn = v);
    });
  }

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
              Tab(text: 'General'),
              Tab(text: 'Updates'),
              Tab(text: 'Status'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _generalTab(state),
              _updatesTab(state),
              _statusTab(state),
            ],
          ),
        ),
      ],
    );
  }

  Widget _generalTab(AppState state) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PanelCard(
          title: 'APPEARANCE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // One option each for now, but presented as choices: the point of
              // a picker is that it says what the alternatives will be.
              _choice(
                label: 'Theme',
                detail: 'The palette is compiled in as constants, so a light theme is a rework '
                    'of every screen rather than a flag.',
                value: 'dark',
                options: const {'dark': 'Dark'},
                onChanged: (_) {},
              ),
              const Divider(height: 24),
              _choice(
                label: 'Language',
                detail: 'Translations need the interface strings extracted first.',
                value: 'en',
                options: const {'en': 'English'},
                onChanged: (_) {},
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: 'STARTUP',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!Autostart.supported)
                const Text(
                  'Launch at login is only wired up for Windows.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                )
              else ...[
                _toggle(
                  label: 'Start Beacle when I sign in',
                  detail: 'Registers this executable under the current user — no admin rights needed.',
                  value: autostartOn ?? false,
                  enabled: autostartOn != null,
                  onChanged: (v) async {
                    final ok = await Autostart.setEnabled(v, minimised: state.startMinimised);
                    final now = await Autostart.isEnabled();
                    if (!mounted) return;
                    setState(() => autostartOn = now);
                    if (!ok && now != v) {
                      showToast(context, 'Could not change the autostart entry', error: true);
                    }
                  },
                ),
                // Only meaningful once something starts on its own, so it stays
                // out of the way until then.
                if (autostartOn == true) ...[
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(left: 18),
                    child: _toggle(
                      label: 'Start minimised to the tray',
                      detail: 'Beacle comes up in the tray instead of on screen. Alerts and sounds '
                          'still arrive; it just does not take the foreground.',
                      value: state.startMinimised,
                      enabled: Tray.supported,
                      // The flag lives in the autostart command, so the entry is
                      // rewritten rather than a setting merely stored.
                      onChanged: (v) async {
                        state.setStartMinimised(v);
                        await Autostart.setEnabled(true, minimised: v);
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: 'TRAY',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _choice(
                label: 'When I close the window',
                detail: 'Closing to the tray leaves the backend running, so agents stay connected '
                    'and alerts keep arriving.',
                value: state.closeBehaviour,
                options: const {'tray': 'Minimise to tray', 'quit': 'Close the app'},
                onChanged: state.setCloseBehaviour,
                enabled: Tray.supported,
              ),
              if (!Tray.supported) ...[
                const SizedBox(height: 12),
                const Text(
                  'The tray is only built for Windows so far. On macOS and Linux the window '
                  'closes the app.',
                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.45),
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text(
                  'Right-click the tray icon for Show and Quit; double-click brings the window back.',
                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.45),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// A setting with a fixed set of answers. Disabled options still show what
  /// the choice is, which is the honest version of "coming soon".
  Widget _choice({
    required String label,
    required String detail,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
    bool enabled = true,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text(detail, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: options.containsKey(value) ? value : options.keys.first,
            dropdownColor: BeacleColors.surfaceHi,
            style: const TextStyle(fontSize: 13, color: BeacleColors.text),
            items: [
              for (final e in options.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: enabled && options.length > 1 ? (v) => onChanged(v ?? value) : null,
          ),
        ),
      ],
    );
  }

  Widget _toggle({
    required String label,
    required String detail,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text(detail, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Switch(value: value, onChanged: enabled ? onChanged : null),
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

            // ================================================================
            // PLANNED UPDATE UI — commented until the flow in app_updater.dart
            // is switched over. Uncomment together with the PLANNED block
            // there, and delete the Wrap above: these buttons replace it.
            //
            // Needs two extra fields on this State:
            //   UpdateInfo? available;   // set by Check, null keeps Update grey
            //   bool autoUpdate = AppUpdater.autoUpdateEnabled;
            //
            // The split matters: Check never downloads, so Update can be grey
            // until GitHub actually has something newer than appVersion.
            // ================================================================
            //
            // Wrap(
            //   spacing: 8,
            //   runSpacing: 8,
            //   children: [
            //     // Always available — you can ask the question at any time.
            //     SmallButton('Check for updates', icon: Icons.search,
            //         onPressed: checking ? null : () async {
            //       setState(() {
            //         checking = true;
            //         updateStatus = null;
            //       });
            //       try {
            //         final info = await AppUpdater.availableUpdate();
            //         setState(() {
            //           available = info;
            //           updateStatus = info == null
            //               ? 'You are on the latest version.'
            //               : 'Version ${info.version} is available.';
            //         });
            //       } catch (e) {
            //         setState(() => updateStatus = 'Update check failed: $e');
            //       } finally {
            //         setState(() => checking = false);
            //       }
            //     }),
            //
            //     // Grey until a check found something. Nothing was downloaded
            //     // before this point, so this button is the only thing that
            //     // touches the network for the payload.
            //     SmallButton('Update', icon: Icons.system_update,
            //         color: available == null ? null : BeacleColors.ok,
            //         onPressed: available == null || checking ? null : () async {
            //       setState(() => checking = true);
            //       try {
            //         final msg = await AppUpdater.downloadAndStage(available!);
            //         setState(() {
            //           staged = available;
            //           updateStatus = msg;
            //         });
            //       } catch (e) {
            //         setState(() => updateStatus = '$e');
            //       } finally {
            //         setState(() => checking = false);
            //       }
            //     }),
            //
            //     if (staged != null)
            //       SmallButton('Apply and restart', icon: Icons.restart_alt,
            //           color: BeacleColors.ok, onPressed: () async {
            //         try {
            //           await AppUpdater.applyAndRestart();
            //         } catch (e) {
            //           setState(() => updateStatus = '$e');
            //         }
            //       }),
            //
            //     const Spacer(),
            //
            //     // Deliberately at the far end from Update: this is the "I
            //     // know which build I want" path, not part of the normal
            //     // forward flow. Empty on a rolling tag — the beta overwrites
            //     // one release, so there is nothing to pick between yet.
            //     SmallButton('Choose version', icon: Icons.list, onPressed: () async {
            //       final versions = await AppUpdater.selectableVersions();
            //       if (!context.mounted) return;
            //       if (versions.isEmpty) {
            //         setState(() => updateStatus =
            //             'No tagged releases to choose from yet — the beta is a rolling tag.');
            //         return;
            //       }
            //       final picked = await showDialog<UpdateInfo>(
            //         context: context,
            //         builder: (ctx) => SimpleDialog(
            //           title: const Text('Install a specific version'),
            //           children: [
            //             for (final v in versions)
            //               SimpleDialogOption(
            //                 onPressed: () => Navigator.pop(ctx, v),
            //                 child: Row(children: [
            //                   Text('v${v.version}', style: const TextStyle(fontSize: 13)),
            //                   if (v.version == appVersion) ...[
            //                     const SizedBox(width: 8),
            //                     const Text('current',
            //                         style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            //                   ],
            //                 ]),
            //               ),
            //           ],
            //         ),
            //       );
            //       if (picked == null || picked.version == appVersion) return;
            //       setState(() => checking = true);
            //       try {
            //         final msg = await AppUpdater.installVersion(picked);
            //         setState(() {
            //           staged = picked;
            //           updateStatus = 'Version ${picked.version} staged. $msg';
            //         });
            //       } catch (e) {
            //         setState(() => updateStatus = '$e');
            //       } finally {
            //         setState(() => checking = false);
            //       }
            //     }),
            //
            //     // Goes to the release below the one running — normally the
            //     // second-to-last. It is fetched from GitHub, so this works on
            //     // a fresh install that has no versions/previous folder.
            //     SmallButton('Rollback', icon: Icons.history, color: BeacleColors.warn,
            //         onPressed: checking ? null : () async {
            //       setState(() {
            //         checking = true;
            //         updateStatus = null;
            //       });
            //       try {
            //         final target = await AppUpdater.rollbackTarget();
            //         if (target == null) {
            //           setState(() => updateStatus = 'No earlier release to roll back to.');
            //           return;
            //         }
            //         final msg = await AppUpdater.rollbackToRelease(target);
            //         setState(() {
            //           staged = target;
            //           updateStatus = 'Rolling back to ${target.version}. $msg';
            //         });
            //       } catch (e) {
            //         setState(() => updateStatus = '$e');
            //       } finally {
            //         setState(() => checking = false);
            //       }
            //     }),
            //   ],
            // ),
            //
            // const SizedBox(height: 14),
            // // Off by default. Nothing installs itself unless this is on.
            // Row(children: [
            //   Expanded(
            //     child: Column(
            //       crossAxisAlignment: CrossAxisAlignment.start,
            //       children: [
            //         const Text('Automatic updates', style: TextStyle(fontSize: 13)),
            //         const SizedBox(height: 2),
            //         Text(
            //           autoUpdate
            //               ? 'Checks GitHub every 6 hours and installs new releases on its own.'
            //               : 'Off — updates only happen when you press Update.',
            //           style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.35),
            //         ),
            //       ],
            //     ),
            //   ),
            //   Switch(
            //     value: autoUpdate,
            //     onChanged: (v) => setState(() {
            //       autoUpdate = v;
            //       AppUpdater.setAutoUpdate(v);
            //     }),
            //   ),
            // ]),
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
            // PLANNED — swap for this when auto-update becomes opt-in. The
            // sentence above stops being true the moment the setting exists,
            // and agent/updater.go AutoUpdateLoop has to read the same flag:
            // right now it ticks every 6 h no matter what the panel says.
            //
            // Text(
            //   AppUpdater.autoUpdateEnabled
            //       ? 'Agents follow the automatic updates setting above: they check every 6 hours. '
            //         'Update and rollback per VPS still work here. Agent config files are never overwritten.'
            //       : 'Automatic updates are off, so agents only update when you press Update here. '
            //         'Agent config files are never overwritten.',
            //   style: const TextStyle(fontSize: 12, color: BeacleColors.textDim),
            // ),
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

  /// One label/value line. Values are selectable because half of what this tab
  /// shows exists to be pasted somewhere else.
  Widget _field(String label, String value, {Color? tone, bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(label, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: tone ?? BeacleColors.text,
                fontFamily: mono ? 'Consolas' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runMaintenance(String label, Future<String> Function() action) async {
    setState(() => maintenanceStatus = null);
    try {
      final msg = await action();
      if (mounted) setState(() => maintenanceStatus = msg);
    } catch (e) {
      if (mounted) setState(() => maintenanceStatus = '$label failed: $e');
    }
  }

  Future<void> _loadTailscale() async {
    setState(() {
      tsLoading = true;
      tsError = null;
    });
    try {
      final devs = await context.read<AppState>().api.tailscaleDevices();
      if (mounted) {
        setState(() {
          tsDevices = devs;
          tsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          tsError = '$e';
          tsDevices = [];
          tsLoading = false;
        });
      }
    }
  }

  /// Walks the path a VPS actually depends on, in order, and reports each hop.
  /// One line saying "something is wrong" would send you looking in the wrong
  /// place half the time.
  Future<void> _validateNetwork(AppState state) async {
    setState(() {
      netChecking = true;
      netChecks = [];
    });
    final out = <String>[];

    out.add(state.connected
        ? '✓ Backend reachable on $localBackendUrl'
        : '✗ Backend unreachable: ${state.lastError ?? 'unknown error'}');

    try {
      final devs = await state.api.tailscaleDevices();
      final self = devs.where((d) => d.self).firstOrNull;
      out.add('✓ Tailscale responding — ${devs.length} device(s) in the tailnet');
      if (self == null) {
        out.add('✗ This machine is not in the device list — is Tailscale logged in?');
      } else {
        out.add(self.ips.isEmpty
            ? '✗ This machine has no Tailscale IP yet'
            : '✓ This machine: ${self.name} (${self.ips.first})');
      }
      final offline = devs.where((d) => !d.self && !d.online).length;
      if (offline > 0) out.add('· $offline device(s) in the tailnet are offline');
    } catch (e) {
      out.add('✗ Tailscale not available: $e');
    }

    if (state.vpsList.isEmpty) {
      out.add('· No VPS registered yet');
    } else {
      final online = state.vpsList.where((v) => v.online).length;
      final agentDown = state.vpsList.where((v) => v.status == 'agent_down').length;
      out.add('${online == state.vpsList.length ? '✓' : '·'} '
          'Agents connected: $online of ${state.vpsList.length}');
      if (agentDown > 0) {
        out.add('✗ $agentDown VPS answer on Tailscale but their agent is not reporting');
      }
    }

    if (mounted) {
      setState(() {
        netChecks = out;
        netChecking = false;
      });
    }
  }

  Widget _statusTab(AppState state) {
    final self = tsDevices.where((d) => d.self).firstOrNull;
    final peers = tsDevices.where((d) => !d.self).toList();
    final selfIp = self?.ips.firstOrNull ?? '';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        PanelCard(
          title: 'BACKEND',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                'Backend status',
                state.connected ? 'Running' : 'Stopped — ${state.lastError ?? 'no connection'}',
                tone: state.connected ? BeacleColors.ok : BeacleColors.err,
              ),
              _field('Backend port', localBackendUrl.split(':').last),
              _field('Data directory', BeaclePaths.configDir, mono: true),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SmallButton('Open data directory', icon: Icons.folder_open, onPressed: () {
                    _runMaintenance('Opening the folder', () async {
                      await ConfigMaintenance.openDataDirectory();
                      return 'Opened ${BeaclePaths.configDir}';
                    });
                  }),
                  SmallButton('Backup configuration', icon: Icons.save_alt, onPressed: () {
                    _runMaintenance('Backup', () async {
                      final path = await ConfigMaintenance.backup();
                      return 'Backed up to $path';
                    });
                  }),
                  SmallButton('Restore configuration', icon: Icons.restore, onPressed: () => _restoreDialog(state)),
                  SmallButton('Clear cached data', icon: Icons.cleaning_services, onPressed: () {
                    _runMaintenance('Clearing the cache', () async {
                      final freed = await ConfigMaintenance.clearCache();
                      return freed == 0 ? 'Cache was already empty' : 'Cleared ${fmtBytes(freed)} of cache';
                    });
                  }),
                ],
              ),
              if (maintenanceStatus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(maintenanceStatus!,
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        PanelCard(
          title: 'TAILSCALE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                'Tailscale status',
                tsLoading
                    ? 'Checking…'
                    : tsError != null
                        ? 'Unavailable — $tsError'
                        : tsDevices.isEmpty
                            ? 'Not checked yet'
                            : 'Connected',
                tone: tsError != null
                    ? BeacleColors.err
                    : tsDevices.isEmpty
                        ? BeacleColors.textDim
                        : BeacleColors.ok,
              ),
              _field('Current device',
                  self == null ? '—' : '${self.name}${selfIp.isEmpty ? '' : '  ·  $selfIp'}'),
              _field('Connected devices',
                  tsDevices.isEmpty ? '—' : '${peers.where((d) => d.online).length} online of ${peers.length}'),
              if (peers.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final d in peers.take(12))
                  Padding(
                    padding: const EdgeInsets.only(left: 170, bottom: 3),
                    child: Row(children: [
                      StatusDot(d.online ? 'online' : 'offline', size: 7),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${d.name}${d.ips.isEmpty ? '' : '  ${d.ips.first}'}',
                            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ),
                if (peers.length > 12)
                  Padding(
                    padding: const EdgeInsets.only(left: 170, top: 2),
                    child: Text('+ ${peers.length - 12} more',
                        style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (tsLoading)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    SmallButton('Refresh devices', icon: Icons.refresh, onPressed: _loadTailscale),
                  SmallButton('Validate network', icon: Icons.checklist,
                      onPressed: netChecking ? null : () => _validateNetwork(state)),
                  SmallButton(
                    'Copy local Tailscale IP',
                    icon: Icons.copy,
                    onPressed: selfIp.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: selfIp));
                            if (!mounted) return;
                            showToast(context, 'Copied $selfIp');
                          },
                  ),
                ],
              ),
              if (netChecking)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 3),
                ),
              if (netChecks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in netChecks)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            line,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: line.startsWith('✗')
                                  ? BeacleColors.err
                                  : line.startsWith('✓')
                                      ? BeacleColors.ok
                                      : BeacleColors.textDim,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _restoreDialog(AppState state) async {
    final backups = ConfigMaintenance.backups();
    if (backups.isEmpty) {
      setState(() => maintenanceStatus = 'No backups yet — use "Backup configuration" first.');
      return;
    }
    final picked = await showDialog<Directory>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Restore which backup?'),
        children: [
          for (final b in backups.take(20))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: Text(b.path.split(Platform.pathSeparator).last,
                  style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await _runMaintenance('Restore', () async {
      final n = await ConfigMaintenance.restore(picked);
      return 'Restored $n file(s). Restart Beacle for them to take effect — the current '
          'files were copied aside first.';
    });
  }
}
