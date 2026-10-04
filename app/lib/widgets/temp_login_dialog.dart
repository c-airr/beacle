import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// A throwaway SSH account on [vps] for the user's own SSH client, so root's
/// credentials never leave the panel. The agent deletes it when it expires.
Future<void> showTempLoginDialog(BuildContext context, Vps vps) =>
    showDialog<void>(context: context, builder: (_) => _TempLoginDialog(vps));

class _TempLoginDialog extends StatefulWidget {
  final Vps vps;
  const _TempLoginDialog(this.vps);

  @override
  State<_TempLoginDialog> createState() => _TempLoginDialogState();
}

class _TempLoginDialogState extends State<_TempLoginDialog> {
  static const _durations = [15, 60, 240, 1440];

  int _minutes = 60;
  bool _sudo = true;
  bool _busy = false;
  String? _error;
  TempLogin? _created;
  List<TempLogin> _active = [];
  late String _address = _addresses.first;

  ApiClient get _api => context.read<AppState>().api;

  /// Where the server can be reached, public address first: through the
  /// Tailscale one, Tailscale SSH (when on) answers instead of the server's
  /// own sshd.
  List<String> get _addresses {
    final v = widget.vps;
    final out = <String>[];
    for (final a in [v.publicIp, v.host, v.tailscaleName]) {
      if (a.isNotEmpty && !out.contains(a)) out.add(a);
    }
    return out.isEmpty ? [v.name] : out;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.tempLogins(widget.vps.id);
      if (mounted) setState(() => _active = list);
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  String _errorText(Object e) =>
      e is ApiException && e.status == 404 && e.body is! Map ? L.read(context).t('tlNeedsAgent') : '$e';

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final l = await _api.createTempLogin(widget.vps.id, minutes: _minutes, sudo: _sudo);
      if (!mounted) return;
      setState(() {
        _created = l;
        _busy = false;
      });
      _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _errorText(e);
        });
      }
    }
  }

  Future<void> _delete(String user) async {
    try {
      await _api.deleteTempLogin(widget.vps.id, user);
      if (!mounted) return;
      showToast(context, context.l.f('tlDeleted', {'user': user}));
      setState(() {
        if (_created?.user == user) _created = null;
      });
      _load();
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
  }

  String _command(TempLogin l) => 'ssh ${l.port != 22 && l.port > 0 ? '-p ${l.port} ' : ''}${l.user}@$_address';

  /// A new console running ssh, with the password on the clipboard.
  Future<void> _openTerminal(TempLogin l) async {
    await Clipboard.setData(ClipboardData(text: l.password));
    try {
      await Process.start('cmd', [
        '/c',
        'start',
        'Beacle SSH',
        'ssh',
        if (l.port != 22 && l.port > 0) ...['-p', '${l.port}'],
        '${l.user}@$_address',
      ]);
      if (mounted) showToast(context, context.l.t('tlPasswordCopied'));
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
  }

  String _at(DateTime t) {
    final l = t.toLocal();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(l.hour)}:${two(l.minute)}';
    return l.year == now.year && l.month == now.month && l.day == now.day ? time : '${two(l.day)}.${two(l.month)} $time';
  }

  String _dur(int m) => m < 60 ? context.l.f('tlMin', {'n': m}) : context.l.f('tlHours', {'n': m ~/ 60});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = _created;
    return AlertDialog(
      title: Text(l.f('tlTitle', {'vps': widget.vps.name})),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('tlIntro'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
              const SizedBox(height: 16),
              if (c == null) ...[
                Row(children: [
                  Text(l.t('tlValid'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 12),
                  for (final m in _durations)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_dur(m), style: const TextStyle(fontSize: 12)),
                        selected: _minutes == m,
                        onSelected: (_) => setState(() => _minutes = m),
                      ),
                    ),
                ]),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _sudo,
                  onChanged: (v) => setState(() => _sudo = v ?? false),
                  title: Text(l.t('tlSudo'), style: const TextStyle(fontSize: 13)),
                ),
              ] else ...[
                if (_addresses.length > 1) ...[
                  Row(children: [
                    Text(l.t('tlAddress'), style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final a in _addresses)
                          ChoiceChip(
                            label: Text(a, style: const TextStyle(fontSize: 12)),
                            selected: _address == a,
                            onSelected: (_) => setState(() => _address = a),
                          ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 12),
                ],
                _field(l.t('tlCommand'), _command(c)),
                _field(l.t('tlUser'), c.user),
                _field(l.t('tlPassword'), c.password),
                Text('${l.f('tlExpires', {'at': _at(c.expiresAt)})}${c.sudo ? ' · sudo' : ''}',
                    style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const SizedBox(height: 4),
                Text(l.t('tlOnce'), style: TextStyle(fontSize: 12, color: BeacleColors.warn)),
                if (c.warning.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(c.warning, style: TextStyle(fontSize: 12, color: BeacleColors.warn, height: 1.4)),
                ],
                if (Platform.isWindows) ...[
                  const SizedBox(height: 12),
                  SmallButton(l.t('tlOpenTerminal'), icon: Icons.open_in_new, onPressed: () => _openTerminal(c)),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(fontSize: 12, color: BeacleColors.err)),
              ],
              const SizedBox(height: 18),
              Text(l.t('tlActive').toUpperCase(),
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.9, color: BeacleColors.textDim)),
              const SizedBox(height: 6),
              if (_active.isEmpty)
                Text(l.t('tlNone'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
              else
                for (final a in _active)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Icon(Icons.person_outline, size: 15, color: BeacleColors.textDim),
                      const SizedBox(width: 8),
                      Text(a.user, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('${l.f('tlExpires', {'at': _at(a.expiresAt)})}${a.sudo ? ' · sudo' : ''}',
                            style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                      ),
                      SmallButton(l.t('tlDelete'), color: BeacleColors.err, onPressed: () => _delete(a.user)),
                    ]),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('close'))),
        if (c == null)
          FilledButton.icon(
            onPressed: _busy || !widget.vps.online ? null : _create,
            icon: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.key_outlined, size: 16),
            label: Text(l.t('tlCreate')),
          ),
      ],
    );
  }

  Widget _field(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
          const SizedBox(height: 4),
          CopyField(value),
        ]),
      );
}
