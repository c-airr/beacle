import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_client.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../user_config.dart';
import '../../config.dart';
import '../../widgets/add_vps_dialog.dart';
import '../../widgets/common.dart';
import '../shell.dart';

/// First-run wizard: welcome → SSH display mode → add VPS (Tailscale).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int step = 0;
  SshDisplayMode sshMode = SshDisplayMode.separateWindow;
  final List<SavedServer> _servers = [];
  bool _finishing = false;
  String? _error;

  void _finish() async {
    if (_servers.isEmpty) return;
    setState(() {
      _finishing = true;
      _error = null;
    });
    final cfg = UserConfig(onboardingComplete: true, sshDisplayMode: sshMode);
    UserConfigStore.save(cfg);
    final store = ServersStore(_servers.toList());
    store.save();
    if (mounted) {
      await context.read<AppState>().start();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AppShell()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BeacleColors.bg,
      body: Center(
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: BeacleColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BeacleColors.border),
          ),
          child: switch (step) {
            0 => _stepWelcome(),
            1 => _stepSshMode(),
            _ => _stepVps(),
          },
        ),
      ),
    );
  }

  Widget _stepWelcome() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('BEACLE', style: TextStyle(fontSize: 12, letterSpacing: 4, color: BeacleColors.textDim)),
        const SizedBox(height: 12),
        const Text('Welcome', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        const Text(
          'Beacle is a local panel for managing your VPS infrastructure — monitoring, Docker, systemd, and reverse proxy — over your Tailscale network.',
          style: TextStyle(fontSize: 13, color: BeacleColors.textDim, height: 1.5),
        ),
        const SizedBox(height: 28),
        Align(
          alignment: Alignment.centerRight,
          child: SmallButton('Continue', icon: Icons.arrow_forward, onPressed: () => setState(() => step = 1)),
        ),
      ],
    );
  }

  Widget _stepSshMode() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SSH display', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        const Text(
          'Choose how SSH sessions will open in a future release. SSH is not available yet.',
          style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
        ),
        const SizedBox(height: 16),
        _modeTile('Separate window', SshDisplayMode.separateWindow),
        _modeTile('Split view', SshDisplayMode.splitView),
        _modeTile('Fullscreen', SshDisplayMode.fullscreen),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: () => setState(() => step = 0), child: const Text('Back')),
            SmallButton('Continue', icon: Icons.arrow_forward, onPressed: () => setState(() => step = 2)),
          ],
        ),
      ],
    );
  }

  Widget _modeTile(String label, SshDisplayMode mode) {
    final selected = sshMode == mode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => sshMode = mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? BeacleColors.borderGlow : BeacleColors.border),
            color: selected ? BeacleColors.surfaceHi : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: selected ? BeacleColors.text : BeacleColors.textDim),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 13, color: selected ? BeacleColors.text : BeacleColors.textDim)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepVps() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add VPS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        tailscaleRequirementBanner(),
        const SizedBox(height: 16),
        if (_servers.isEmpty)
          const Text('No servers yet', style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
        else ...[
          for (final s in _servers) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.dns_outlined, size: 14, color: BeacleColors.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: const TextStyle(fontSize: 13)),
                        Text(s.tailscaleIp, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 16, color: BeacleColors.textDim),
                    onPressed: _finishing
                        ? null
                        : () async {
                            try {
                              await context.read<AppState>().api.deleteVps(s.id);
                            } catch (_) {}
                            if (mounted) setState(() => _servers.remove(s));
                          },
                  ),
                ],
              ),
            ),
            _InstallBlock(),
            const SizedBox(height: 10),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(fontSize: 11, color: BeacleColors.err)),
        ],
        const SizedBox(height: 12),
        SmallButton('Add VPS', icon: Icons.add, onPressed: _finishing ? null : () => _showAddVps()),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: _finishing ? null : () => setState(() => step = 1), child: const Text('Back')),
            SmallButton(
              'Finish',
              icon: Icons.check,
              onPressed: _servers.isEmpty || _finishing ? null : _finish,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showAddVps() async {
    final state = context.read<AppState>();
    List<TailscaleDevice> devices;
    try {
      devices = await state.api.tailscaleDevices();
    } catch (e) {
      setState(() => _error = e is ApiException && e.status == 503 ? tailscaleNotOnPc : '$e');
      return;
    }
    final available = devices.where((d) => !d.self).toList();
    if (!mounted) return;
    if (available.isEmpty) {
      setState(() => _error = tailscaleNoPeers);
      return;
    }
    final picked = await showDialog<TailscaleDevice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Tailscale device'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tailscaleRequirementBanner(),
              const SizedBox(height: 12),
              ListView(
                shrinkWrap: true,
                children: [
                  for (final d in available)
                    ListTile(
                      title: Text(d.name),
                      subtitle: Text(
                        [
                          if (d.ips.isNotEmpty) d.ips.first,
                          if (!d.online) 'offline',
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                      ),
                      onTap: () => Navigator.pop(ctx, d),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    final ip = picked.ips.isNotEmpty ? picked.ips.first : '';
    try {
      final vps = await state.api.createVps(name: picked.name, tailscaleName: picked.name, tailscaleIp: ip);
      setState(() {
        _servers.add(SavedServer(id: vps.id, name: vps.name, tailscaleName: picked.name, tailscaleIp: ip));
        _error = null;
      });
      if (!mounted) return;
      final cmd = await state.api.installCommand();
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: BeacleColors.glassHi,
          title: Text('Install agent on ${picked.name}'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Run on the VPS as root. Downloads from GitHub only.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim),
                ),
                const SizedBox(height: 8),
                CopyField(cmd),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    } catch (e) {
      setState(() => _error = '$e');
    }
  }
}

class _InstallBlock extends StatelessWidget {
  const _InstallBlock();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Install command', style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          SizedBox(height: 6),
          AddVpsCommand(),
        ],
      ),
    );
  }
}
