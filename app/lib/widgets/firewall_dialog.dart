import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// New firewall rule: form first, then the native commands as a dry-run with
/// an explicit confirm. The agent re-validates and re-guards at apply time.
Future<bool> showFirewallRuleDialog(
  BuildContext context, {
  required String vpsId,
  required String vpsName,
  String action = 'allow',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _FirewallRuleDialog(vpsId: vpsId, vpsName: vpsName, action: action),
    ) ??
    false;

/// Delete confirm showing the exact native command. Protected allows say so
/// out loud and are applied with force only from this dialog.
Future<bool> showFirewallDeleteDialog(
  BuildContext context, {
  required String vpsId,
  required String vpsName,
  required FirewallRule rule,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _FirewallDeleteDialog(vpsId: vpsId, vpsName: vpsName, rule: rule),
    ) ??
    false;

class _FirewallRuleDialog extends StatefulWidget {
  final String vpsId, vpsName, action;
  const _FirewallRuleDialog({required this.vpsId, required this.vpsName, required this.action});

  @override
  State<_FirewallRuleDialog> createState() => _FirewallRuleDialogState();
}

class _FirewallRuleDialogState extends State<_FirewallRuleDialog> {
  late String _action;
  String _proto = 'tcp';
  final _port = TextEditingController();
  final _source = TextEditingController();
  final _comment = TextEditingController();
  int _step = 0; // 0 form, 1 confirm
  FirewallDryRun? _dry;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _action = widget.action;
  }

  @override
  void dispose() {
    _port.dispose();
    _source.dispose();
    _comment.dispose();
    super.dispose();
  }

  FirewallRuleSpec get _spec => FirewallRuleSpec(
        action: _action,
        proto: _proto,
        port: _port.text.trim(),
        source: _source.text.trim(),
        comment: _comment.text.trim(),
      );

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dry =
          await context.read<AppState>().api.firewallDryRun(widget.vpsId, _action, _spec, '');
      if (!mounted) return;
      setState(() {
        _dry = dry;
        _step = 1;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      context.read<AppState>().onUserAction();
      final res = _action == 'allow'
          ? await api.firewallAllow(widget.vpsId, _spec)
          : await api.firewallDeny(widget.vpsId, _spec);
      if (!mounted) return;
      if (res.warning.isNotEmpty) showToast(context, res.warning);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
        _step = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${context.l.t(_action == 'allow' ? 'fwAllowTitle' : 'fwDenyTitle')} · ${widget.vpsName}'),
      content: SizedBox(
        width: 520,
        child: _step == 0 ? _form() : _confirm(),
      ),
      actions: _step == 0
          ? [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l.t('cancel'))),
              SmallButton(context.l.t('fwPreview'),
                  icon: Icons.visibility_outlined,
                  onPressed: _busy ? null : _preview),
            ]
          : [
              TextButton(onPressed: _busy ? null : () => setState(() => _step = 0), child: Text(context.l.t('back'))),
              SmallButton(
                _busy ? context.l.t('runningEllipsis') : context.l.t('fwApply'),
                icon: Icons.check,
                onPressed: _busy ? null : _apply,
              ),
            ],
    );
  }

  Widget _form() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                    value: 'allow',
                    label: Text(context.l.t('fwAllow'),
                        style: const TextStyle(fontSize: 12))),
                ButtonSegment(
                    value: 'deny',
                    label: Text(context.l.t('fwDeny'), style: const TextStyle(fontSize: 12))),
              ],
              selected: {_action},
              onSelectionChanged: (s) => setState(() => _action = s.first),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                  value: 'tcp', label: Text('TCP', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: 'udp', label: Text('UDP', style: TextStyle(fontSize: 12))),
            ],
            selected: {_proto},
            onSelectionChanged: (s) => setState(() => _proto = s.first),
          ),
        ]),
        const SizedBox(height: 10),
        _label(context.l.t('fwPort')),
        const SizedBox(height: 4),
        TextField(
          controller: _port,
          decoration: InputDecoration(
            hintText: context.l.t('fwPortHint'),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
        ),
        const SizedBox(height: 10),
        _label(context.l.t('fwSource')),
        const SizedBox(height: 4),
        TextField(
          controller: _source,
          decoration: InputDecoration(
            hintText: context.l.t('fwSourceHint'),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
        ),
        const SizedBox(height: 10),
        _label(context.l.t('fwComment')),
        const SizedBox(height: 4),
        TextField(
          controller: _comment,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
          ),
      ],
    );
  }

  Widget _confirm() {
    final dry = _dry;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l.t('fwWillRun'),
            style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: BeacleColors.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: BeacleColors.border),
          ),
          child: SelectableText((dry?.commands ?? []).join('\n'),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
        ),
        if (dry != null && dry.warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(dry.warning,
                style: const TextStyle(fontSize: 12, color: BeacleColors.warn)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
          ),
      ],
    );
  }

  Widget _label(String s) =>
      Text(s, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim));
}

class _FirewallDeleteDialog extends StatefulWidget {
  final String vpsId, vpsName;
  final FirewallRule rule;
  const _FirewallDeleteDialog({required this.vpsId, required this.vpsName, required this.rule});

  @override
  State<_FirewallDeleteDialog> createState() => _FirewallDeleteDialogState();
}

class _FirewallDeleteDialogState extends State<_FirewallDeleteDialog> {
  FirewallDryRun? _dry;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _preview();
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dry = await context
          .read<AppState>()
          .api
          .firewallDryRun(widget.vpsId, 'delete', null, widget.rule.id);
      if (!mounted) return;
      setState(() {
        _dry = dry;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      state.onUserAction();
      await state.api.firewallDelete(widget.vpsId, widget.rule.id,
          force: widget.rule.protected);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dry = _dry;
    return AlertDialog(
      title: Text('${context.l.t('fwDeleteTitle')} · ${widget.vpsName}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(widget.rule.raw,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
            const SizedBox(height: 10),
            if (_busy && dry == null)
              const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else if (dry != null) ...[
              Text(context.l.t('fwWillRun'),
                  style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: BeacleColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BeacleColors.border),
                ),
                child: SelectableText(dry.commands.join('\n'),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
              ),
              if (dry.warning.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(dry.warning,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: widget.rule.protected
                              ? BeacleColors.err
                              : BeacleColors.warn)),
                ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(context.l.t('cancel'))),
        SmallButton(context.l.t('delete'),
            icon: Icons.delete_outline,
            color: BeacleColors.err,
            onPressed: (_busy || dry == null) ? null : _apply),
      ],
    );
  }
}
