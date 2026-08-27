import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'screen_launcher.dart';

/// Creates a systemd service from a form.
///
/// This is the thing screen and nohup cannot do: a unit survives a reboot. It
/// is also the most consequential write in the product — a unit that fails to
/// parse can stop a machine booting, and an enabled one runs on every start
/// forever. So the file is shown before it is written, systemd is asked whether
/// it would accept it, and the agent refuses to overwrite a unit it did not put
/// there unless told twice.
Future<bool> showServiceWizard(
  BuildContext context, {
  required AppState state,
  required Vps vps,
}) async {
  final created = await showDialog<bool>(
    context: context,
    builder: (_) => _ServiceWizard(state: state, vps: vps),
  );
  return created ?? false;
}

class _ServiceWizard extends StatefulWidget {
  final AppState state;
  final Vps vps;
  const _ServiceWizard({required this.state, required this.vps});

  @override
  State<_ServiceWizard> createState() => _ServiceWizardState();
}

class _ServiceWizardState extends State<_ServiceWizard> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _exec = TextEditingController();
  final _dir = TextEditingController();
  final _user = TextEditingController();

  String _restart = 'always';
  bool _enableAtBoot = true;
  bool _startNow = true;
  bool _overwrite = false;
  Map<String, String> _env = {};

  SystemdUnitPreview? _preview;
  bool _busy = false;
  String? _error;
  Timer? _debounce;

  bool get _valid => _name.text.trim().isNotEmpty && _exec.text.trim().isNotEmpty;

  SystemdUnitSpec get _spec => SystemdUnitSpec(
        name: _name.text.trim(),
        description: _description.text.trim(),
        execStart: _exec.text.trim(),
        workingDir: _dir.text.trim(),
        user: _user.text.trim(),
        restart: _restart,
        env: _env,
        enableAtBoot: _enableAtBoot,
        startNow: _startNow,
        overwrite: _overwrite,
      );

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_name, _description, _exec, _dir, _user]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The preview comes from the agent rather than being composed here, so what
  /// is on screen is the same rendering that will be written — there is no
  /// second implementation to drift.
  void _schedulePreview() {
    _debounce?.cancel();
    if (!_valid) {
      setState(() => _preview = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final p = await widget.state.api.systemdPreview(widget.vps.id, _spec);
        if (mounted) setState(() => _preview = p);
      } catch (e) {
        if (mounted) {
          setState(() {
            _preview = null;
            _error = '$e';
          });
        }
      }
    });
  }

  Future<void> _pickCommand() async {
    final spec = await showScreenLauncher(
      context,
      state: widget.state,
      vpsId: widget.vps.id,
      fixedName: _name.text.trim().isEmpty ? null : _name.text.trim(),
    );
    if (spec == null) return;
    setState(() {
      if (_name.text.trim().isEmpty) _name.text = spec.name;
      if (spec.dir.isNotEmpty) _dir.text = spec.dir;
      _exec.text = spec.command;
    });
    _schedulePreview();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.api.systemdCreate(widget.vps.id, _spec);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return Dialog(
      child: Container(
        width: 760,
        constraints: const BoxConstraints(maxHeight: 720),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                child: Text('New service on ${widget.vps.name}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.pop(context, false),
              ),
            ]),
            const SizedBox(height: 4),
            const Text(
              'A systemd service starts on boot and is restarted if it dies — unlike a '
              'screen session or a nohup job, which end with the machine.',
              style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.45),
            ),
            const SizedBox(height: 16),

            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _name,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Service name',
                            hintText: 'my-bot',
                            helperText: 'Becomes my-bot.service',
                          ),
                          onChanged: (_) => setState(_schedulePreview),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _description,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                            hintText: 'What this service is for',
                          ),
                          onChanged: (_) => _schedulePreview(),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 14),

                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _exec,
                          decoration: const InputDecoration(
                            labelText: 'Command',
                            hintText: '/usr/bin/python3 /srv/bot/main.py',
                            helperText: 'Use absolute paths — systemd does not read your shell PATH.',
                          ),
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                          onChanged: (_) => _schedulePreview(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: SmallButton('Browse', icon: Icons.folder_open, onPressed: _pickCommand),
                      ),
                    ]),
                    const SizedBox(height: 14),

                    Row(children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _dir,
                          decoration: const InputDecoration(
                            labelText: 'Working directory',
                            hintText: '/srv/bot',
                          ),
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                          onChanged: (_) => _schedulePreview(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _user,
                          decoration: const InputDecoration(
                            labelText: 'Run as user',
                            hintText: 'root',
                            helperText: 'Blank means root.',
                          ),
                          onChanged: (_) => _schedulePreview(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          initialValue: _restart,
                          decoration: const InputDecoration(labelText: 'If it exits'),
                          dropdownColor: BeacleColors.surfaceHi,
                          style: const TextStyle(fontSize: 13, color: BeacleColors.text),
                          items: const [
                            DropdownMenuItem(value: 'always', child: Text('Always restart')),
                            DropdownMenuItem(value: 'on-failure', child: Text('Only on failure')),
                            DropdownMenuItem(value: 'no', child: Text('Leave it stopped')),
                          ],
                          onChanged: (v) {
                            setState(() => _restart = v ?? 'always');
                            _schedulePreview();
                          },
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),

                    _EnvEditor(
                      env: _env,
                      onChanged: (e) {
                        setState(() => _env = e);
                        _schedulePreview();
                      },
                    ),
                    const SizedBox(height: 8),

                    _toggle('Start on boot', 'Enables the unit, so it comes back after a reboot.',
                        _enableAtBoot, (v) => setState(() => _enableAtBoot = v)),
                    _toggle('Start now', 'Also starts it immediately after saving.', _startNow,
                        (v) => setState(() => _startNow = v)),

                    if (p != null && p.exists)
                      _toggle(
                        'Replace the existing service',
                        '${p.path} already exists. Beacle will not overwrite a unit it did not '
                            'write unless you say so here.',
                        _overwrite,
                        (v) {
                          setState(() => _overwrite = v);
                          _schedulePreview();
                        },
                        danger: true,
                      ),

                    const SizedBox(height: 16),
                    Row(children: [
                      const Text('UNIT FILE',
                          style: TextStyle(
                              fontSize: 11,
                              color: BeacleColors.textDim,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4)),
                      const Spacer(),
                      if (p != null)
                        Text(
                          p.valid ? 'systemd accepts this' : 'systemd rejects this',
                          style: TextStyle(
                            fontSize: 11,
                            color: p.valid ? BeacleColors.ok : BeacleColors.err,
                          ),
                        ),
                    ]),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: BeacleColors.bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: p == null || p.valid ? BeacleColors.border : BeacleColors.err),
                      ),
                      child: SelectableText(
                        p?.unit ?? 'Fill in a name and a command to see the unit file.',
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          height: 1.5,
                          color: p == null ? BeacleColors.textDim : BeacleColors.text,
                        ),
                      ),
                    ),
                    if (p != null && p.output.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(p.output,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.45,
                            color: p.valid ? BeacleColors.textDim : BeacleColors.err,
                          )),
                    ],
                  ],
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SmallButton('Cancel', onPressed: _busy ? null : () => Navigator.pop(context, false)),
                const SizedBox(width: 10),
                if (_busy)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  SmallButton(
                    'Create service',
                    icon: Icons.check,
                    color: _valid ? BeacleColors.ok : null,
                    // Enabled on a valid form even before the preview lands, but
                    // never when systemd has already said it would refuse.
                    onPressed: _valid && (p == null || p.valid) ? _create : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggle(String label, String detail, bool value, ValueChanged<bool> onChanged,
      {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13, color: danger ? BeacleColors.warn : BeacleColors.text)),
                const SizedBox(height: 2),
                Text(detail,
                    style: const TextStyle(
                        fontSize: 11, color: BeacleColors.textDim, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Environment variables for the unit. Kept simple on purpose: a secret in here
/// ends up in a world-readable file under /etc/systemd/system, so this is for
/// configuration, not credentials.
class _EnvEditor extends StatefulWidget {
  final Map<String, String> env;
  final ValueChanged<Map<String, String>> onChanged;
  const _EnvEditor({required this.env, required this.onChanged});

  @override
  State<_EnvEditor> createState() => _EnvEditorState();
}

class _EnvEditorState extends State<_EnvEditor> {
  final _key = TextEditingController();
  final _value = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  void _add() {
    final k = _key.text.trim();
    if (k.isEmpty) return;
    widget.onChanged({...widget.env, k: _value.text.trim()});
    _key.clear();
    _value.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Environment variables',
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
        const SizedBox(height: 8),
        for (final e in widget.env.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(
                child: Text('${e.key}=${e.value}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14, color: BeacleColors.err),
                onPressed: () {
                  final next = {...widget.env}..remove(e.key);
                  widget.onChanged(next);
                },
              ),
            ]),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _key,
              decoration: const InputDecoration(hintText: 'NODE_ENV'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _value,
              decoration: const InputDecoration(hintText: 'production'),
              style: const TextStyle(fontSize: 12),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          SmallButton('Add', icon: Icons.add, onPressed: _add),
        ]),
      ],
    );
  }
}
