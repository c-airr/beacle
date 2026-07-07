import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_client.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../user_config.dart';
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
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: BeacleColors.surfaceHi,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BeacleColors.border),
          ),
          child: const Text(
            'At least one VPS with a public IPv4 address or a computer with a public IPv4 address is required for Tailscale mesh connectivity. Each VPS must have Tailscale installed.',
            style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.45),
          ),
        ),
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
                  Expanded(child: Text(s.name, style: const TextStyle(fontSize: 13))),
                  Text(s.tailscaleIp, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                ],
              ),
            ),
            _InstallBlock(serverName: s.name),
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
      setState(() => _error = '$e');
      return;
    }
    final available = devices.where((d) => !d.self).toList();
    if (!mounted) return;
    final picked = await showDialog<TailscaleDevice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Tailscale device'),
        content: SizedBox(
          width: 400,
          child: available.isEmpty
              ? const Text('No remote devices found. Install Tailscale on your VPS first.',
                  style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in available)
                      ListTile(
                        title: Text(d.name),
                        subtitle: Text(d.ips.isNotEmpty ? d.ips.first : d.dns,
                            style: const TextStyle(fontSize: 11, fontFamily: 'Consolas')),
                        onTap: () => Navigator.pop(ctx, d),
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
                const Text('Run on the VPS as root:', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
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
  final String serverName;
  const _InstallBlock({required this.serverName});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: BeacleColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Install on $serverName', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          const SizedBox(height: 6),
          FutureBuilder<String>(
            future: state.api.installCommand(),
            builder: (ctx, snap) {
              if (snap.hasError) return Text('${snap.error}', style: const TextStyle(fontSize: 11, color: BeacleColors.err));
              if (!snap.hasData) return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
              return CopyField(snap.data!);
            },
          ),
        ],
      ),
    );
  }
}
