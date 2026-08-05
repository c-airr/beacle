import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../update/app_updater.dart';
import '../widgets/activity_scope.dart';
import '../widgets/add_vps_dialog.dart';
import '../widgets/alerts_panel.dart';
import 'alerts_screen.dart';
import 'docker_screen.dart';
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

  static AppShellState of(BuildContext context) =>
      context.findAncestorStateOfType<AppShellState>()!;
}

class AppShellState extends State<AppShell> {
  int index = 0;
  String? focusedVpsId;
  bool alertsOpen = false;
  final List<Alert> _toasts = [];
  StreamSubscription? _alertSub;
  final _serversKey = GlobalKey<ServersScreenState>();

  late final List<Widget> _screens;

  @visibleForTesting
  static const items = [
    (Icons.space_dashboard_outlined, 'Overview'),
    (Icons.public_outlined, 'Map'),
    (Icons.dns_outlined, 'Servers'),
    (Icons.view_in_ar_outlined, 'Docker'),
    (Icons.miscellaneous_services_outlined, 'Services'),
    (Icons.alt_route_outlined, 'Proxy'),
    (Icons.notifications_outlined, 'Alerts'),
    (Icons.tune_outlined, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _screens = [
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

  void goToAlerts() {
    context.read<AppState>().bumpActivity();
    setState(() => index = _tabAlerts);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return ActivityScope(
      child: Scaffold(
      backgroundColor: BeacleColors.bg,
      body: Stack(
        children: [
          Row(
            children: [
              _buildSidebar(state),
              Expanded(
                child: Column(
                  children: [
                    _buildTopBar(state),
                    if (state.availableUpdate != null) _buildUpdateBanner(state),
                    Expanded(child: IndexedStack(index: index, children: _screens)),
                  ],
                ),
              ),
            ],
          ),
          if (alertsOpen)
            Positioned(
              top: 52,
              right: 16,
              child: AlertsPanel(onClose: () => setState(() => alertsOpen = false)),
            ),
          Positioned(
            top: 58,
            right: 16,
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
                label: items[i].$2,
                selected: index == i,
                badge: i == _tabAlerts ? state.activeAlerts : 0,
                onTap: () {
                  context.read<AppState>().bumpActivity();
                  setState(() {
                    if (i != _tabServers) focusedVpsId = null;
                    index = i;
                  });
                },
              ),
            ),
          const Spacer(),
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
                    state.connected ? 'Connected' : 'Offline',
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

  Widget _buildUpdateBanner(AppState state) {
    final info = state.availableUpdate!;
    return Material(
      color: BeacleColors.surface.withValues(alpha: 0.95),
      child: InkWell(
        onTap: () {
          context.read<AppState>().bumpActivity();
          setState(() => index = items.length - 1); // Settings
        },
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: BeacleColors.ok.withValues(alpha: 0.08),
            border: Border(bottom: BorderSide(color: BeacleColors.border.withValues(alpha: 0.5))),
          ),
          child: Row(
            children: [
              Icon(Icons.system_update, size: 14, color: BeacleColors.ok),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Beacle ${info.version} is available — you are on $appVersion. Open Settings → Updates to install.',
                  style: TextStyle(fontSize: 11, color: BeacleColors.text, height: 1.2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text('Settings', style: TextStyle(fontSize: 11, color: BeacleColors.ok, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(AppState state) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: BeacleColors.border.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Text(items[index].$2, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.2)),
          const Spacer(),
          Text(
            '${state.vpsList.where((v) => v.online).length}/${state.vpsList.length} online',
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 18),
            tooltip: 'Add VPS',
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
                    child: Text('${state.activeAlerts}', style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w700)),
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
  const _NavItem({required this.icon, required this.label, required this.selected, this.badge = 0, required this.onTap});

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
            boxShadow: widget.selected
                ? [BoxShadow(color: BeacleColors.glow.withValues(alpha: 0.06), blurRadius: 12)]
                : null,
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
      width: 300,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BeacleColors.glass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(alert.message, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
    );
  }
}
