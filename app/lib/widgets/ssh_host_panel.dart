import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../native_dialogs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// The side panel of the SSH tab that adds or edits a saved SSH host: where
/// it is, who logs in, and with a password, a private key or both.
class SshHostPanel extends StatefulWidget {
  /// The host to edit; null adds a new one.
  final SshHost? host;
  final ValueChanged<SshHost> onSaved;
  final VoidCallback? onDelete;
  final VoidCallback onClose;
  const SshHostPanel({super.key, this.host, required this.onSaved, this.onDelete, required this.onClose});

  @override
  State<SshHostPanel> createState() => _SshHostPanelState();
}

class _SshHostPanelState extends State<SshHostPanel> {
  late final _label = TextEditingController(text: widget.host?.label ?? '');
  late final _address = TextEditingController(text: widget.host?.host ?? '');
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final _user = TextEditingController(text: widget.host?.user ?? '');
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();

  // A saved secret the user asked to remove.
  bool _clearPassword = false;
  bool _clearKey = false;
  bool _saving = false;
  String? _error;

  bool get _hasPassword => widget.host?.hasPassword == true && !_clearPassword;
  bool get _hasKey => widget.host?.hasKey == true && !_clearKey;

  @override
  void dispose() {
    for (final c in [_label, _address, _port, _user, _password, _key, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadKeyFile() async {
    try {
      final paths = await NativeDialogs.openFiles();
      if (paths.isEmpty) return;
      final f = File(paths.first);
      // A private key is a few kilobytes; anything big is the wrong file.
      if (await f.length() > 64 * 1024) throw const FormatException('too big');
      final text = await f.readAsString();
      if (mounted) setState(() => _key.text = text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final l = L.read(context);
    final address = _address.text.trim(), user = _user.text.trim();
    if (address.isEmpty || user.isEmpty) {
      setState(() => _error = l.t('sshHostNeedHostUser'));
      return;
    }
    if (_password.text.isEmpty && _key.text.trim().isEmpty && !_hasPassword && !_hasKey) {
      setState(() => _error = l.t('sshHostNeedSecret'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await context.read<AppState>().api.saveSshHost(widget.host?.id, {
        'label': _label.text.trim(),
        'host': address,
        'port': int.tryParse(_port.text.trim()) ?? 0,
        'user': user,
        'password': _password.text,
        'key': _key.text.trim(),
        'passphrase': _passphrase.text,
        'clear_password': _clearPassword,
        'clear_key': _clearKey,
      });
      if (mounted) widget.onSaved(saved);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final editing = widget.host != null;
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: BeacleColors.surface,
        border: Border(left: BorderSide(color: BeacleColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
            child: Row(children: [
              Expanded(
                child: Text(l.t(editing ? 'sshHostEditTitle' : 'sshNewHost'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: l.t('cancel'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(l.t('sshHostLabel'), _label, hint: l.t('sshHostLabelHint')),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field(l.t('sshHostAddress'), _address, hint: l.t('sshHostAddressHint'))),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 76,
                      child: _field(l.t('sshHostPort'), _port, keyboard: TextInputType.number),
                    ),
                  ]),
                  _field(l.t('sshHostUser'), _user, hint: 'root, ubuntu, ...'),
                  _field(
                    l.t('sshHostPassword'),
                    _password,
                    obscure: true,
                    hint: _secretHint(widget.host?.hasPassword == true, _clearPassword),
                    forget: widget.host?.hasPassword == true
                        ? () => setState(() => _clearPassword = !_clearPassword)
                        : null,
                    forgetting: _clearPassword,
                  ),
                  _field(
                    l.t('sshHostKey'),
                    _key,
                    lines: 5,
                    mono: true,
                    hint: _secretHint(widget.host?.hasKey == true, _clearKey) ?? l.t('sshHostKeyHint'),
                    forget: widget.host?.hasKey == true ? () => setState(() => _clearKey = !_clearKey) : null,
                    forgetting: _clearKey,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _loadKeyFile,
                      icon: const Icon(Icons.file_open_outlined, size: 15),
                      label: Text(l.t('sshHostKeyFile'), style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  _field(l.t('sshHostPassphrase'), _passphrase, obscure: true),
                  const SizedBox(height: 4),
                  Text(l.t('sshHostSecretsNote'),
                      style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: TextStyle(fontSize: 12, color: BeacleColors.err, height: 1.4)),
                  ],
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: BeacleColors.border))),
            child: Row(children: [
              if (widget.onDelete != null)
                TextButton(
                  onPressed: _saving ? null : widget.onDelete,
                  child: Text(l.t('delete'), style: TextStyle(color: BeacleColors.err)),
                ),
              const Spacer(),
              TextButton(onPressed: widget.onClose, child: Text(l.t('cancel'))),
              const SizedBox(width: 6),
              SmallButton(l.t('save'), icon: Icons.check, onPressed: _saving ? null : _save),
            ]),
          ),
        ],
      ),
    );
  }

  /// The hint of a secret field on an edit: kept as saved, or about to go.
  String? _secretHint(bool saved, bool clearing) {
    if (!saved) return null;
    return context.l.t(clearing ? 'sshHostSecretCleared' : 'sshHostSecretKept');
  }

  Widget _field(
    String label,
    TextEditingController c, {
    String? hint,
    bool obscure = false,
    int lines = 1,
    bool mono = false,
    TextInputType? keyboard,
    VoidCallback? forget,
    bool forgetting = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: BeacleColors.textDim)),
        const SizedBox(height: 5),
        TextField(
          controller: c,
          obscureText: obscure,
          minLines: lines,
          maxLines: lines,
          keyboardType: keyboard ?? (lines > 1 ? TextInputType.multiline : null),
          enabled: !forgetting,
          style: TextStyle(fontSize: 13, fontFamily: mono ? 'Consolas' : null),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 12, color: BeacleColors.textDim.withValues(alpha: 0.7)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
            suffixIcon: forget == null
                ? null
                : IconButton(
                    tooltip: context.l.t(forgetting ? 'sshHostKeep' : 'sshHostForget'),
                    icon: Icon(forgetting ? Icons.undo : Icons.delete_outline, size: 16),
                    onPressed: forget,
                  ),
          ),
        ),
      ]),
    );
  }
}
