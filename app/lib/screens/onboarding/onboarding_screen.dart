import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/language.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../user_config.dart';
import '../../widgets/add_vps_dialog.dart';
import '../../widgets/common.dart';
import '../shell.dart';

/// First-run wizard: welcome → SSH display mode → add VPS.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int step = 0;
  AppLanguage lang = AppLanguage.en;
  SshDisplayMode sshMode = SshDisplayMode.separateWindow;
  SshDisplayMode filesMode = SshDisplayMode.separateWindow;
  final List<SavedServer> _servers = [];
  bool _finishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A reinstall keeps settings.json — respect a language chosen earlier.
    lang = AppLanguageWire.fromWire(UserSettings.load().raw['language'] as String?);
    // Same for the SSH/Files choice from an earlier setup.
    final prev = UserConfigStore.load();
    sshMode = prev.sshDisplayMode;
    filesMode = prev.filesDisplayMode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().setLanguage(lang);
    });
  }

  void _pickLanguage(AppLanguage v) {
    setState(() => lang = v);
    // Applied live so the rest of the wizard already shows the new language.
    context.read<AppState>().setLanguage(v);
  }

  void _finish() async {
    if (_servers.isEmpty) return;
    setState(() {
      _finishing = true;
      _error = null;
    });
    final cfg = UserConfig(onboardingComplete: true, sshDisplayMode: sshMode, filesDisplayMode: filesMode);
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
            color: BeacleColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BeacleColors.border),
          ),
          child: switch (step) {
            0 => _stepLanguage(),
            1 => _stepWelcome(),
            2 => _stepSshMode(),
            _ => _stepVps(),
          },
        ),
      ),
    );
  }

  Widget _stepLanguage() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l.t('obLanguageTitle'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text(
          context.l.t('obLanguageBody'),
          style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
        ),
        const SizedBox(height: 16),
        // Two columns: eight languages in one would push Continue off a
        // small screen.
        LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: 8,
            children: [
              for (final l in AppLanguage.values) SizedBox(width: (c.maxWidth - 8) / 2, child: _langTile(l)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: SmallButton(context.l.t('continueBtn'),
              icon: Icons.arrow_forward, onPressed: () => setState(() => step = 1)),
        ),
      ],
    );
  }

  Widget _langTile(AppLanguage mode) {
    final selected = lang == mode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _pickLanguage(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? BeacleColors.borderGlow : BeacleColors.border),
            color: selected ? BeacleColors.surfaceHi : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: selected ? BeacleColors.text : BeacleColors.textDim),
              const SizedBox(width: 10),
              Text(mode.label,
                  style:
                      TextStyle(fontSize: 13, color: selected ? BeacleColors.text : BeacleColors.textDim)),
            ],
          ),
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
        Text(context.l.t('obWelcomeTitle'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        Text(
          context.l.t('obWelcomeBody'),
          style: const TextStyle(fontSize: 13, color: BeacleColors.textDim, height: 1.5),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: () => setState(() => step = 0), child: Text(context.l.t('back'))),
            SmallButton(context.l.t('continueBtn'),
                icon: Icons.arrow_forward, onPressed: () => setState(() => step = 2)),
          ],
        ),
      ],
    );
  }

  Widget _stepSshMode() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l.t('obSshTitle'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text(
          context.l.t('obSshBody'),
          style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
        ),
        const SizedBox(height: 16),
        _modeGroup(context.l.t('navSsh'), Icons.terminal, sshMode, (m) => setState(() => sshMode = m)),
        const SizedBox(height: 14),
        _modeGroup(context.l.t('navFiles'), Icons.folder_outlined, filesMode, (m) => setState(() => filesMode = m)),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: () => setState(() => step = 1), child: Text(context.l.t('back'))),
            SmallButton(context.l.t('continueBtn'),
                icon: Icons.arrow_forward, onPressed: () => setState(() => step = 3)),
          ],
        ),
      ],
    );
  }

  Widget _modeGroup(String title, IconData icon, SshDisplayMode value, ValueChanged<SshDisplayMode> onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 14, color: BeacleColors.textDim),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: BeacleColors.textDim)),
        ]),
        const SizedBox(height: 4),
        _modeTile(context.l.t('obSshSeparate'), SshDisplayMode.separateWindow, value, onPick),
        _modeTile(context.l.t('obSshSplit'), SshDisplayMode.splitView, value, onPick),
        _modeTile(context.l.t('obSshFullscreen'), SshDisplayMode.fullscreen, value, onPick),
      ],
    );
  }

  Widget _modeTile(String label, SshDisplayMode mode, SshDisplayMode value, ValueChanged<SshDisplayMode> onPick) {
    final selected = value == mode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onPick(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
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
        Text(context.l.t('obVpsTitle'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        tailscaleRequirementBanner(),
        const SizedBox(height: 16),
        if (_servers.isEmpty)
          Text(context.l.t('obNoServers'),
              style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))
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
                    tooltip: context.l.t('obRemove'),
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
        SmallButton(context.l.t('addVps'), icon: Icons.add, onPressed: _finishing ? null : () => _showAddVps()),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: _finishing ? null : () => setState(() => step = 2), child: Text(context.l.t('back'))),
            SmallButton(
              context.l.t('finish'),
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
    await showAddVpsDialog(context);
    if (!mounted) return;
    try {
      final list = await state.api.listVps();
      setState(() {
        _servers
          ..clear()
          ..addAll(list.map((v) => SavedServer(
                id: v.id,
                name: v.name,
                tailscaleName: v.tailscaleName,
                tailscaleIp: v.host,
              )));
        _error = null;
      });
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeacleColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l.t('obInstallCmd'),
              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          const SizedBox(height: 6),
          const AddVpsCommand(),
        ],
      ),
    );
  }
}
