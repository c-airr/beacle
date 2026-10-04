import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../l10n/alert_text.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../update/app_updater.dart';
import '../tool_window.dart';
import '../user_config.dart';
import '../widgets/activity_scope.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/wg_switch.dart';
import '../widgets/alerts_panel.dart';
import '../window_control.dart';
import 'alerts_screen.dart';
import 'docker_screen.dart';
import 'files_screen.dart';
import 'terminal_screen.dart';
import 'map/map_screen.dart';
import 'overview_screen.dart';
import 'proxy_screen.dart';
import 'servers_screen.dart';
import 'services_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();

  static AppShellState of(BuildContext context) => context.findAncestorStateOfType<AppShellState>()!;
}

class AppShellState extends State<AppShell> {
  int index = 0;
  String? focusedVpsId;
  bool alertsOpen = false;
  final List<Alert> _toasts = [];
  StreamSubscription? _alertSub;
  final _serversKey = GlobalKey<ServersScreenState>();
  final _terminalKey = GlobalKey<TerminalScreenState>();
  final _filesKey = GlobalKey();

  /// The tool shown in the split panel on the right, if any.
  int? _splitTool;

  /// Width the window gained for the split panel, to give back on close.
  WindowGrowth _growth = WindowGrowth.none;

  /// The last main (non-tool) tab, to fall back to when a tool shown in the
  /// main area moves out of it.
  int _lastMain = 0;

  static const _splitWidth = 640.0;
  // Persisted in settings.json so closing the banner survives a restart.
  static const _wgBannerDismissKey = 'wg_migrate_banner_dismissed';
  late bool _wgMigrateBannerDismissed;

  late final List<Widget> _mainScreens;

  @visibleForTesting
  static const items = [
    (Icons.space_dashboard_outlined, 'navOverview'),
    (Icons.public_outlined, 'navMap'),
    (Icons.dns_outlined, 'navServers'),
    (Icons.view_in_ar_outlined, 'navDocker'),
    (Icons.miscellaneous_services_outlined, 'navServices'),
    (Icons.alt_route_outlined, 'navProxy'),
    (Icons.notifications_outlined, 'navAlerts'),
    (Icons.tune_outlined, 'navSettings'),
  ];

  /// Remote tools, kept apart in the bottom-left corner of the sidebar so they
  /// read as "work on a server" rather than another overview screen. Their
  /// screens follow the main ones in [_screens].
  @visibleForTesting
  static const toolItems = [
    (Icons.terminal, 'navSsh'),
    (Icons.folder_outlined, 'navFiles'),
  ];

  /// Localization key of tab [i]: the main list first, then the tools.
  @visibleForTesting
  static String labelKey(int i) => i < items.length ? items[i].$2 : toolItems[i - items.length].$2;

  String _label(BuildContext context, int i) => context.l.t(labelKey(i));

  int get _firstTool => items.length;

  @override
  void initState() {
    super.initState();
    _wgMigrateBannerDismissed = UserSettings.load().raw[_wgBannerDismissKey] == true;
    _mainScreens = [
      const OverviewScreen(),
      const MapScreen(),
      ServersScreen(key: _serversKey),
      const DockerScreen(),
      const ServicesScreen(),
      const ProxyScreen(),
      const AlertsScreen(),
      const SettingsScreen(),
    ];
    final state = context.read<AppState>();
    _alertSub = state.alertStream.stream.listen((a) {
      if (a.resolved) {
        // Condition cleared — yank the toast immediately so a recovering
        // agent does not leave a red "offline" strip for another six seconds.
        if (mounted) setState(() => _toasts.removeWhere((t) => t.id == a.id));
        return;
      }
      setState(() => _toasts.add(a));
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) setState(() => _toasts.remove(a));
      });
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  // Tab indices, kept next to _items so reordering the sidebar cannot silently
  // send a shortcut to the wrong screen.
  static const _tabServers = 2;
  static const _tabAlerts = 6;

  void goToServer(String vpsId) {
    context.read<AppState>().bumpActivity();
    setState(() {
      focusedVpsId = vpsId;
      index = _tabServers;
    });
    _serversKey.currentState?.selectVps(vpsId);
  }

  static final _sshTool = toolItems.indexWhere((t) => t.$2 == 'navSsh');

  /// The tool's widget. GlobalKeys let it move between the main area and the
  /// split panel without losing open shells or the current folder.
  Widget _toolWidget(int t) => t == _sshTool ? TerminalScreen(key: _terminalKey) : FilesScreen(key: _filesKey);

  SshDisplayMode _modeOf(int t) {
    final state = context.read<AppState>();
    return t == _sshTool ? state.sshMode : state.filesMode;
  }

  /// Opens tool [t] the way the user chose for it in setup/Settings; for SSH,
  /// [vpsId] also opens a shell on that server.
  Future<void> openTool(int t, {String? vpsId}) async {
    context.read<AppState>().bumpActivity();
    switch (_modeOf(t)) {
      case SshDisplayMode.separateWindow:
        await ToolWindows.open(t == _sshTool ? 'ssh' : 'files', vpsId: vpsId);
        return;
      case SshDisplayMode.splitView:
        if (_splitTool == t && vpsId == null) {
          await _closeSplit();
          return;
        }
        await _openSplit(t);
      case SshDisplayMode.fullscreen:
        if (_splitTool == t) await _closeSplit();
        setState(() {
          focusedVpsId = null;
          index = _firstTool + t;
        });
    }
    if (vpsId != null && t == _sshTool) {
      // The terminal may have just been mounted; give it a frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _terminalKey.currentState?.open(vpsId));
    }
  }

  /// Opens a shell on [vpsId] (the "Connect with SSH" button).
  void openTerminal(String vpsId) => openTool(_sshTool, vpsId: vpsId);

  Future<void> _openSplit(int t) async {
    final wasOpen = _splitTool != null;
    setState(() {
      _splitTool = t;
      // A tool cannot be in the main area and the panel at once.
      if (index == _firstTool + t) index = _lastMain;
    });
    // Telegram-style: the window grows to make room instead of squeezing the
    // screen you were on. Swapping tools in an open panel keeps the size.
    if (!wasOpen) {
      _growth = await WindowControl.grow(_splitWidth, View.of(context).devicePixelRatio);
    }
  }

  Future<void> _closeSplit() async {
    final growth = _growth;
    _growth = WindowGrowth.none;
    setState(() => _splitTool = null);
    await WindowControl.shrink(growth, View.of(context).devicePixelRatio);
  }

  void goToAlerts() {
    context.read<AppState>().bumpActivity();
    setState(() => index = _tabAlerts);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final wgBanner = _buildWgMigrateBanner(state);

    return ActivityScope(
      child: Scaffold(
        backgroundColor: BeacleColors.bg,
        body: Stack(
          children: [
            Row(
              children: [
                _buildSidebar(state),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: BeacleColors.panel,
                        borderRadius: BorderRadius.circular(BeacleRadius.panel),
                        border: Border.all(color: BeacleColors.panelBorder),
                      ),
                      child: Column(
                        children: [
                          _buildTopBar(state),
                          if (state.availableUpdate != null) _buildUpdateBanner(state),
                          if (wgBanner != null) wgBanner,
                          Expanded(child: _content()),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (alertsOpen)
              Positioned(
                top: 66,
                right: 20,
                child: AlertsPanel(onClose: () => setState(() => alertsOpen = false)),
              ),
            Positioned(
              top: 72,
              right: 20,
              child: IgnorePointer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (!alertsOpen)
                      for (final a in _toasts.reversed.take(3)) _AlertToast(alert: a),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Main area plus, in split view, the tool panel on the right.
  Widget _content() {
    final stack = IndexedStack(
      index: index,
      children: [
        ..._mainScreens,
        // Tools shown in the main area; a placeholder keeps the indices when
        // a tool lives in the split panel or its own window instead.
        for (var t = 0; t < toolItems.length; t++)
          _splitTool == t || _modeOf(t) == SshDisplayMode.separateWindow ? const SizedBox.shrink() : _toolWidget(t),
      ],
    );
    final split = _splitTool;
    if (split == null) return stack;
    return Row(
      children: [
        Expanded(child: stack),
        Container(
          width: _splitWidth,
          decoration: const BoxDecoration(
            color: BeacleColors.bg,
            border: Border(left: BorderSide(color: BeacleColors.border)),
          ),
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.only(left: 14, right: 4),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: BeacleColors.border))),
                child: Row(children: [
                  Icon(toolItems[split].$1, size: 15, color: BeacleColors.textDim),
                  const SizedBox(width: 8),
                  Text(context.l.t(toolItems[split].$2),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                    tooltip: context.l.t('close'),
                    onPressed: _closeSplit,
                  ),
                ]),
              ),
              Expanded(child: _toolWidget(split)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar(AppState state) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: BeacleColors.surface.withValues(alpha: 0.72),
        border: Border(right: BorderSide(color: BeacleColors.border.withValues(alpha: 0.6))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 22, 20, 28),
            child: Text(
              'BEACLE',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 4, color: BeacleColors.text),
            ),
          ),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              child: _NavItem(
                icon: items[i].$1,
                label: _label(context, i),
                selected: index == i,
                badge: i == _tabAlerts ? state.activeAlerts : 0,
                onTap: () {
                  context.read<AppState>().bumpActivity();
                  setState(() {
                    if (i != _tabServers) focusedVpsId = null;
                    index = i;
                    _lastMain = i;
                  });
                },
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Divider(height: 1, color: BeacleColors.border.withValues(alpha: 0.8)),
          ),
          for (var t = 0; t < toolItems.length; t++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              child: _NavItem(
                icon: toolItems[t].$1,
                label: context.l.t(toolItems[t].$2),
                selected: index == _firstTool + t || _splitTool == t,
                onTap: () => openTool(t),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: state.connected ? BeacleColors.ok : BeacleColors.err,
                    boxShadow: state.connected
                        ? [BoxShadow(color: BeacleColors.ok.withValues(alpha: 0.45), blurRadius: 6)]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.connected ? context.l.t('connected') : context.l.t('offline'),
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Someone coming from 1.x has every server on Tailscale. The banner
  /// tells them 2.0 does not need it and opens the server picker; once
  /// closed it stays closed, and the same picker lives in Settings.
  Widget? _buildWgMigrateBanner(AppState state) {
    if (_wgMigrateBannerDismissed) return null;
    if (!state.vpsList.any((v) => v.isTailscale && v.status != 'pending')) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        height: 44,
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
          color: BeacleColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BeacleColors.cardBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.vpn_key_outlined, size: 16, color: BeacleColors.ok),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l.t('wgMigrateBanner'),
                style: const TextStyle(fontSize: 12.5, color: BeacleColors.text, height: 1.2),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => showWireGuardSwitchDialog(context),
              child: Text(context.l.t('wgBannerButton'),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () {
                setState(() => _wgMigrateBannerDismissed = true);
                final s = UserSettings.load();
                s.raw[_wgBannerDismissKey] = true;
                s.save();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateBanner(AppState state) {
    final info = state.availableUpdate!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: BeacleColors.ok.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: BeacleColors.ok.withValues(alpha: 0.25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            context.read<AppState>().bumpActivity();
            setState(() => index = items.length - 1); // Settings
          },
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.system_update, size: 14, color: BeacleColors.ok),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l.f('stUpdateBanner', {'v': info.label, 'cur': info.rebuild ? appLabel : appVersion}),
                    style: TextStyle(fontSize: 11, color: BeacleColors.text, height: 1.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(context.l.t('navSettings'),
                    style: TextStyle(fontSize: 11, color: BeacleColors.ok, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(AppState state) {
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 24, right: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: BeacleColors.border.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Text(_label(context, index),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2)),
          const Spacer(),
          Text(
            context.l.f('onlineOf', {
              'on': state.vpsList.where((v) => v.online).length,
              'total': state.vpsList.length,
            }),
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 18),
            tooltip: context.l.t('addVps'),
            onPressed: () => showAddVpsDialog(context),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_none, size: 18),
                onPressed: () {
                  setState(() => alertsOpen = !alertsOpen);
                  if (alertsOpen) state.markAlertsSeen();
                },
              ),
              if (state.activeAlerts > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: BeacleColors.err,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child:
                        Text('${state.activeAlerts}', style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;
  const _NavItem(
      {required this.icon, required this.label, required this.selected, this.badge = 0, required this.onTap});

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? BeacleColors.glassHi
                : _hover
                    ? BeacleColors.hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.selected ? Border.all(color: BeacleColors.borderGlow) : null,
            boxShadow:
                widget.selected ? [BoxShadow(color: BeacleColors.glow.withValues(alpha: 0.06), blurRadius: 12)] : null,
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: widget.selected ? BeacleColors.text : BeacleColors.textDim),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: widget.selected ? FontWeight.w500 : FontWeight.w400,
                    color: widget.selected ? BeacleColors.text : BeacleColors.textDim,
                  ),
                ),
              ),
              if (widget.badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: BeacleColors.err.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('${widget.badge}', style: const TextStyle(fontSize: 9, color: BeacleColors.err)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertToast extends StatelessWidget {
  final Alert alert;
  const _AlertToast({required this.alert});

  @override
  Widget build(BuildContext context) {
    final color = alert.severity == 'critical' ? BeacleColors.err : BeacleColors.warn;
    return Container(
      width: 320,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            alert.vpsName.isEmpty ? alertTypeLabel(context.l, alert.type) : '${alert.vpsName} · ${alertTypeLabel(context.l, alert.type)}',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(height: 4),
          Text(alertMessage(context.l, alert), style: const TextStyle(fontSize: 13, color: BeacleColors.text, height: 1.3)),
        ],
      ),
    );
  }
}
