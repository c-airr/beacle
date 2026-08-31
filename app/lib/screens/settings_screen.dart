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
import '../update/agent_updater.dart';
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
  UpdateInfo? available;
  bool checking = false;
  bool downloading = false;

  // Agent updates: filled by "Check for updates" against GitHub, never
  // assumed — the Update buttons only exist once a newer release is seen.
  AgentReleaseInfo? agentLatest;
  bool agentChecking = false;
  String? agentUpdateStatus;
  final Set<String> agentUpdating = {};
  bool agentPickerBusy = false;

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
    // The Status tab used to show "Not checked yet" until the user pressed
    // Refresh. Loading once on init means the Tailscale section is already
    // populated by the time the user opens Settings.
    _loadTailscale();
    _tabs.addListener(_onTabChanged);
    // Seed the Updates tab with whatever the startup check already found, so
    // the Update button is not greyed out for a second check on first open.
    final state = context.read<AppState>();
    available = state.availableUpdate;
  }

  void _onTabChanged() {
    // Re-fetch when the user comes back to the Status tab, so a stale device
    // list does not sit there for the whole session.
    if (_tabs.index == 2 && !tsLoading) {
      _loadTailscale();
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
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
    return SmoothListView(
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
    final hasPrev = AppUpdater.hasPrevious;
    return SmoothListView(
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
            const SizedBox(height: 14),
            // The forward flow is Check → Update → Apply. Check only looks at
            // GitHub; Update downloads and stages; Apply swaps the install
            // and restarts. Rollback is the side exit, only present when an
            // in-place update left a previous build behind.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SmallButton('Check for updates', icon: Icons.search, onPressed: checking || downloading ? null : () async {
                  setState(() {
                    checking = true;
                    updateStatus = null;
                  });
                  try {
                    final info = await state.recheckForUpdate();
                    setState(() {
                      available = info;
                      updateStatus = info == null
                          ? 'You are on the latest version.'
                          : 'Version ${info.version} is available.';
                    });
                  } catch (e) {
                    setState(() => updateStatus = 'Update check failed: $e');
                  } finally {
                    setState(() => checking = false);
                  }
                }),
                if (available != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: BeacleColors.surfaceHi,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: BeacleColors.border),
                          ),
                          child: Text('v$appVersion', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.arrow_forward, size: 16, color: BeacleColors.ok),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: BeacleColors.ok.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: BeacleColors.ok.withValues(alpha: 0.4)),
                          ),
                          child: Text('v${available!.version}', style: const TextStyle(fontSize: 11, color: BeacleColors.ok, fontWeight: FontWeight.w500)),
                        ),
                      ],
                    ),
                  ),
                if (available != null)
                  SmallButton('Update', icon: Icons.system_update, color: BeacleColors.ok, onPressed: downloading ? null : () async {
                    setState(() {
                      downloading = true;
                      updateStatus = null;
                    });
                    try {
                      final msg = await AppUpdater.downloadAndStage(available!);
                      setState(() {
                        staged = available;
                        updateStatus = msg;
                      });
                    } catch (e) {
                      setState(() => updateStatus = '$e');
                    } finally {
                      setState(() => downloading = false);
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
                if (hasPrev)
                  SmallButton('Rollback', icon: Icons.history, color: BeacleColors.warn, onPressed: () async {
                    try {
                      await AppUpdater.rollbackAndRestart();
                    } catch (e) {
                      setState(() => updateStatus = '$e');
                    }
                  }),
                SmallButton('Choose version…', icon: Icons.list_alt, onPressed: downloading ? null : _pickDesktopVersion),
              ],
            ),
            if (checking || downloading)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 3, color: checking ? null : BeacleColors.ok),
              ),
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
              'Agent updates are pulled from the GitHub release on demand. Press "Check for updates" to compare your agents against the latest release — Update buttons appear only when a newer agent actually exists. Agent config files are never overwritten.',
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SmallButton('Check for updates', icon: Icons.search,
                    onPressed: agentChecking ? null : () => _checkAgentUpdates(state)),
                if (agentLatest != null) _latestAgentChip(agentLatest!),
                if (agentChecking)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (agentUpdateStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(agentUpdateStatus!, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
                      if (_agentUpdateAvailable(v))
                        SmallButton(
                          agentUpdating.contains(v.id) ? 'Updating…' : 'Update',
                          icon: Icons.system_update_alt,
                          color: BeacleColors.ok,
                          onPressed: !v.online || agentUpdating.contains(v.id)
                              ? null
                              : () => _updateAgent(state, v, null),
                        ),
                      SmallButton('Choose version…', icon: Icons.list_alt,
                          onPressed: !v.online || agentPickerBusy ? null : () => _pickAgentVersion(state, v)),
                    ],
                  ),
                ),
          ]),
        ),
      ],
    );
  }

  /// Chip next to "Check for updates" showing what GitHub currently offers.
  Widget _latestAgentChip(AgentReleaseInfo info) {
    final label = info.version != null
        ? 'latest: v${info.version}'
        : 'latest build: ${info.publishedAt?.toLocal().toString().substring(0, 16) ?? info.tag}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
    );
  }

  /// The Update button exists only after a successful check proved something
  /// newer is out there, and stays hidden for the release the user
  /// deliberately downgraded away from.
  bool _agentUpdateAvailable(Vps v) {
    if (!v.online || agentLatest == null) return false;

    // Digests first, because they answer the question being asked: are the
    // bytes on GitHub different from the bytes this agent is running. Version
    // numbers cannot — a rebuild republished under the same tag keeps its
    // number, which is how a fleet sat two months stale while the panel
    // reported it current.
    // Measured against the asset built for this machine — an arm64 server
    // compared with the amd64 binary differs by definition, and asked to
    // update again every time it had just updated.
    final remote = agentLatest!.digestFor(v.arch);
    if (remote != null && v.agentDigest.isNotEmpty) {
      return remote != v.agentDigest;
    }

    // No digest on one side or the other: an agent too old to report one, or a
    // release predating GitHub's digests. Fall back to comparing versions.
    final latest = agentLatest!.version;
    if (latest == null) {
      // Nothing orderable either — the user decides; the build date in the
      // chip says how fresh the release is.
      return true;
    }
    if (v.agentVersion.isEmpty) return true;
    return AgentUpdater.isActionable(latest, v.agentVersion);
  }

  Future<void> _checkAgentUpdates(AppState state) async {
    setState(() {
      agentChecking = true;
      agentUpdateStatus = null;
    });
    try {
      final info = await AgentUpdater.latestAgentRelease();
      if (!mounted) return;
      if (info == null) {
        setState(() => agentUpdateStatus = 'Could not read the agent release from GitHub.');
        return;
      }
      // A release newer than the one the user walked away from makes the
      // suppression obsolete.
      final suppressed = AgentUpdater.suppressedVersion;
      if (info.version != null &&
          suppressed != null &&
          AppUpdater.isNewer(info.version!, suppressed)) {
        AgentUpdater.clearSuppression();
      }
      setState(() {
        agentLatest = info;
        final outdated = state.vpsList.where(_agentUpdateAvailable).length;
        if (info.version == null) {
          agentUpdateStatus =
              'Latest build published ${info.publishedAt?.toLocal().toString().substring(0, 16) ?? 'unknown'} — '
              'no VERSION asset on the release, so agents cannot be compared by version.';
        } else if (outdated == 0) {
          agentUpdateStatus = 'All agents are up to date (v${info.version}).';
        } else {
          agentUpdateStatus = 'Agent v${info.version} is available for $outdated VPS.';
        }
        // Worth saying out loud which question was answered: a digest match is
        // certainty about the bytes, a version match is a claim about a label.
        if (info.digests.isEmpty) {
          agentUpdateStatus = '${agentUpdateStatus!} Compared by version — the '
              'release carries no asset digest.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => agentUpdateStatus = 'Agent update check failed: $e');
    } finally {
      if (mounted) setState(() => agentChecking = false);
    }
  }

  Future<void> _updateAgent(AppState state, Vps v, String? tag) async {
    setState(() => agentUpdating.add(v.id));
    try {
      final r = await state.api.agentUpdate(v.id, tag: tag);
      if (mounted) showToast(context, '${v.name}: $r');
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => agentUpdating.remove(v.id));
    }
  }

  /// Version picker for one VPS: every GitHub release that ships agent
  /// binaries. Downgrades ask twice so a misclick cannot roll an agent back.
  Future<void> _pickAgentVersion(AppState state, Vps v) async {
    setState(() => agentPickerBusy = true);
    List<AgentReleaseInfo> releases;
    try {
      releases = await AgentUpdater.agentReleases();
    } catch (e) {
      if (mounted) showToast(context, 'Could not load releases: $e', error: true);
      setState(() => agentPickerBusy = false);
      return;
    }
    if (!mounted) return;
    setState(() => agentPickerBusy = false);
    if (releases.isEmpty) {
      showToast(context, 'No releases with agent binaries found.', error: true);
      return;
    }
    final chosen = await showDialog<AgentReleaseInfo>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.surface,
        title: Text('Agent version for ${v.name}', style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 420,
          height: 320,
          child: SmoothListView(
            children: [
              for (final r in releases)
                ListTile(
                  dense: true,
                  title: Text(r.version != null ? 'v${r.version}' : r.tag,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '${r.tag}${r.prerelease ? ' · pre-release' : ''}'
                    '${r.publishedAt != null ? ' · ${r.publishedAt!.toLocal().toString().substring(0, 16)}' : ''}',
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                  ),
                  trailing: r.version != null && r.version == v.agentVersion
                      ? const Text('current', style: TextStyle(fontSize: 11, color: BeacleColors.ok))
                      : null,
                  onTap: () => Navigator.of(ctx).pop(r),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel'))],
      ),
    );
    if (chosen == null || !mounted) return;
    final downgrade = chosen.version != null &&
        v.agentVersion.isNotEmpty &&
        AppUpdater.compareVersions(chosen.version!, v.agentVersion) < 0;
    final label = chosen.version != null ? 'v${chosen.version}' : chosen.tag;
    final ok = await _confirmInstall(
      title: 'Install $label on ${v.name}?',
      message: 'The agent will download the binary from the "$label" release and restart.',
      downgrade: downgrade,
      downgradeMessage:
          '${v.name} is running v${v.agentVersion}. Installing $label is a DOWNGRADE.',
    );
    if (ok != true || !mounted) return;
    if (downgrade && agentLatest?.version != null) {
      AgentUpdater.suppressNotificationsFor(agentLatest!.version!);
    }
    await _updateAgent(state, v, chosen.tag);
  }

  /// Version picker for the desktop app: stable GitHub releases only (drafts
  /// and pre-releases are filtered out inside AppUpdater.releases).
  Future<void> _pickDesktopVersion() async {
    List<UpdateInfo> releases;
    try {
      releases = await AppUpdater.releases();
    } catch (e) {
      if (mounted) showToast(context, 'Could not load releases: $e', error: true);
      return;
    }
    if (!mounted) return;
    if (releases.isEmpty) {
      showToast(context, 'No stable releases found for this platform.', error: true);
      return;
    }
    final chosen = await showDialog<UpdateInfo>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.surface,
        title: const Text('Install a specific version', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 420,
          height: 320,
          child: SmoothListView(
            children: [
              for (final r in releases)
                ListTile(
                  dense: true,
                  title: Text('v${r.version}', style: const TextStyle(fontSize: 13)),
                  subtitle: r.notes.trim().isEmpty
                      ? null
                      : Text(r.notes.trim().split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  trailing: r.version == appVersion
                      ? const Text('current', style: TextStyle(fontSize: 11, color: BeacleColors.ok))
                      : null,
                  onTap: () => Navigator.of(ctx).pop(r),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel'))],
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen.version == appVersion) {
      showToast(context, 'v$appVersion is already installed.');
      return;
    }
    final downgrade = AppUpdater.compareVersions(chosen.version, appVersion) < 0;
    final ok = await _confirmInstall(
      title: 'Install v${chosen.version}?',
      message: 'The release will be downloaded and staged; apply it with "Apply and restart".',
      downgrade: downgrade,
      downgradeMessage: 'You are on v$appVersion. Installing v${chosen.version} is a DOWNGRADE.',
    );
    if (ok != true || !mounted) return;
    if (downgrade) {
      // After the restart the running build is older than GitHub's latest —
      // remember what we walked away from so the banner does not nag.
      AppUpdater.suppressNotificationsFor(available?.version ?? appVersion);
    }
    setState(() {
      downloading = true;
      updateStatus = null;
    });
    try {
      final msg = await AppUpdater.downloadAndStage(chosen);
      setState(() {
        staged = chosen;
        updateStatus = msg;
      });
    } catch (e) {
      setState(() => updateStatus = '$e');
    } finally {
      setState(() => downloading = false);
    }
  }

  /// One confirmation for updates, two for downgrades — going back a version
  /// must be impossible to trigger by accident.
  Future<bool?> _confirmInstall({
    required String title,
    required String message,
    required bool downgrade,
    String? downgradeMessage,
  }) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.surface,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: Text(message, style: const TextStyle(fontSize: 13, color: BeacleColors.textDim)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (first != true || !mounted || !downgrade) return first;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.surface,
        title: const Text('Confirm downgrade', style: TextStyle(fontSize: 15, color: BeacleColors.warn)),
        content: Text(
          '${downgradeMessage ?? 'This installs an older version.'}\n\nAre you absolutely sure?',
          style: const TextStyle(fontSize: 13, color: BeacleColors.textDim),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, downgrade', style: TextStyle(color: BeacleColors.warn)),
          ),
        ],
      ),
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

    return SmoothListView(
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
