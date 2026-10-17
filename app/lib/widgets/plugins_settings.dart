import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../native_dialogs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'plugin_blocks.dart';

/// Settings → Plugins: install, link, switch on and off, remove, read logs.
class PluginsSettings extends StatelessWidget {
  const PluginsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l = context.l;
    return SmoothListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(l.t('plgIntro'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.5)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          SmallButton(l.t('plgInstallZip'), icon: Icons.add, onPressed: () => _installZip(context)),
          SmallButton(l.t('plgLinkFolder'), icon: Icons.folder_open_outlined, onPressed: () => _linkFolder(context)),
        ]),
        const SizedBox(height: 16),
        if (state.plugins.isEmpty)
          Text(l.t('plgNone'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
        else
          // settings.section: what each plugin adds to its own card here.
          PluginSlot(
            slot: 'settings.section',
            builder: (context, renders, reload) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in state.plugins)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PluginCard(
                        p: p,
                        sections: [
                          for (final r in renders)
                            if (r.plugin == p['id']) r
                        ],
                        reload: reload),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _installZip(BuildContext context) async {
    final files = await NativeDialogs.openFiles();
    if (files.isEmpty || !context.mounted) return;
    final bytes = await File(files.first).readAsBytes();
    if (!context.mounted) return;
    await _install(context, {'zip': base64Encode(bytes)});
  }

  Future<void> _linkFolder(BuildContext context) async {
    final c = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l.t('plgLinkFolder')),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: c,
            autofocus: true,
            decoration: InputDecoration(hintText: ctx.l.t('plgFolderPath'), isDense: true),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ctx.l.t('plgInstall'))),
        ],
      ),
    );
    c.dispose();
    if (path == null || path.isEmpty || !context.mounted) return;
    await _install(context, {'path': path});
  }

  /// Shows what the package may do, then installs it on a yes.
  Future<void> _install(BuildContext context, Map<String, dynamic> src) async {
    final state = context.read<AppState>();
    state.onUserAction();
    try {
      final info = await state.api.post('/api/plugins/inspect', body: src) as Map<String, dynamic>;
      if (!context.mounted) return;
      final m = info['manifest'] as Map<String, dynamic>;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l.f('plgConfirmTitle', {'name': m['name'], 'v': m['version']})),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info['installed_version'] != null)
                  Text(ctx.l.f('plgUpgrade', {'v': info['installed_version']}), style: const TextStyle(fontSize: 12)),
                if (info['new_permissions'] == true) ...[
                  const SizedBox(height: 6),
                  Text(ctx.l.t('plgNewPerms'), style: TextStyle(fontSize: 12, color: BeacleColors.warn)),
                ],
                const SizedBox(height: 10),
                _Permissions(perms: (m['permissions'] as Map<String, dynamic>?) ?? const {}),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l.t('plgInstall'))),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      await state.api.post('/api/plugins', body: src);
      await state.refreshPlugins();
      if (context.mounted) showToast(context, context.l.f('plgInstalled', {'name': m['name']}));
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }
}

class _Permissions extends StatelessWidget {
  final Map<String, dynamic> perms;
  const _Permissions({required this.perms});

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final (key, label) in [
        ('read', 'plgPermRead'),
        ('write', 'plgPermWrite'),
        ('exec', 'plgPermExec'),
        ('http', 'plgPermHttp'),
        ('api', 'plgPermApi'),
      ])
        if ((perms[key] as List?)?.isNotEmpty ?? false) (context.l.t(label), (perms[key] as List).join(', ')),
    ];
    if (rows.isEmpty) {
      return Text(context.l.t('plgPermNone'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$label: ', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
              TextSpan(text: value, style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
            ])),
          ),
      ],
    );
  }
}

class _PluginCard extends StatelessWidget {
  final Map<String, dynamic> p;
  final List<SlotRender> sections;
  final VoidCallback reload;
  const _PluginCard({required this.p, required this.sections, required this.reload});

  String get _id => '${p['id']}';

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final l = context.l;
    final enabled = p['enabled'] == true;
    final servers = (p['servers'] as Map<String, dynamic>?) ?? const {};
    final disabledOn = [for (final s in (p['disabled_on'] as List? ?? const [])) '$s'];
    final error = '${p['error'] ?? ''}';
    return PanelCard(
      title: '${p['name']}  ${p['version']}',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if ((p['config'] as List?)?.isNotEmpty ?? false)
          IconButton(
            icon: const Icon(Icons.tune, size: 16),
            tooltip: l.t('plgSettings'),
            onPressed: () => _editSettings(context),
          ),
        IconButton(
          icon: const Icon(Icons.article_outlined, size: 16),
          tooltip: l.t('plgLog'),
          onPressed: () => _showLog(context),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline, size: 16, color: BeacleColors.err),
          tooltip: l.t('delete'),
          onPressed: () => _remove(context),
        ),
        Switch(value: enabled, onChanged: (on) => _patch(context, {'enabled': on})),
      ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ('${p['linked'] ?? ''}'.isNotEmpty)
            Text(l.f('plgLinked', {'path': p['linked']}),
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
          _Permissions(perms: (p['permissions'] as Map<String, dynamic>?) ?? const {}),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(error, style: TextStyle(fontSize: 12, color: BeacleColors.err)),
          ],
          for (final r in sections) ...[
            const SizedBox(height: 10),
            PluginBlocks(render: r, onAction: reload),
          ],
          if (enabled && servers.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(l.t('plgServerToggle'), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final v in state.vpsList)
                if (servers[v.id] is Map) _serverChip(context, v.id, v.name, servers[v.id] as Map, disabledOn),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _serverChip(BuildContext context, String id, String name, Map st, List<String> disabledOn) {
    final s = '${st['state']}';
    final color = switch (s) {
      'running' => BeacleColors.ok,
      'error' => BeacleColors.err,
      'off' => BeacleColors.textDim,
      _ => BeacleColors.warn,
    };
    return Tooltip(
      message: '${st['error'] ?? context.l.t('plgState_$s')}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _patch(context, {
          'disabled_on': disabledOn.contains(id) ? (disabledOn.toList()..remove(id)) : [...disabledOn, id],
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Text('$name · ${context.l.t('plgState_$s')}', style: TextStyle(fontSize: 11, color: color)),
        ),
      ),
    );
  }

  Future<void> _patch(BuildContext context, Map<String, dynamic> body) async {
    final state = context.read<AppState>();
    state.onUserAction();
    try {
      await state.api.patch('/api/plugins/$_id', body: body);
      await state.refreshPlugins();
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  Future<void> _editSettings(BuildContext context) async {
    final fields = [for (final f in (p['config'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
    final values = (p['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    final config = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _SettingsDialog(name: '${p['name']}', fields: fields, values: values),
    );
    if (config == null || !context.mounted) return;
    await _patch(context, {'config': config});
    if (context.mounted) showToast(context, context.l.t('plgSettingsSaved'));
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${ctx.l.t('delete')} — ${p['name']}'),
        content: Text(ctx.l.f('plgRemoveConfirm', {'name': p['name']})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l.t('delete'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final state = context.read<AppState>();
    try {
      await state.api.delete('/api/plugins/$_id');
      await state.refreshPlugins();
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
  }

  Future<void> _showLog(BuildContext context) async {
    final state = context.read<AppState>();
    List<String> lines;
    try {
      lines = [for (final e in (await state.api.get('/api/plugins/$_id/log') as List? ?? [])) '$e'];
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p['name']} · ${ctx.l.t('plgLog')}'),
        content: SizedBox(
          width: 640,
          height: 380,
          child: lines.isEmpty
              ? Text(ctx.l.t('plgLogEmpty'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
              : SelectableText(lines.join('\n'), style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l.t('close')))],
      ),
    );
  }
}

/// The form a manifest's "config" describes. Returns what to save; a secret
/// left empty is not sent, so the saved one stays.
class _SettingsDialog extends StatefulWidget {
  final String name;
  final List<Map<String, dynamic>> fields;
  final Map<String, dynamic> values;
  const _SettingsDialog({required this.name, required this.fields, required this.values});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final Map<String, TextEditingController> _text = {
    for (final f in widget.fields)
      if (!const ['bool', 'select'].contains(f['type']))
        '${f['key']}': TextEditingController(
            text: f['type'] == 'secret' ? '' : '${widget.values[f['key']] ?? f['default'] ?? ''}'),
  };
  late final Map<String, Object?> _picked = {
    for (final f in widget.fields)
      if (const ['bool', 'select'].contains(f['type'])) '${f['key']}': widget.values[f['key']] ?? f['default'],
  };

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _result() {
    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      final key = '${f['key']}';
      switch (f['type']) {
        case 'bool':
          out[key] = _picked[key] == true;
        case 'select':
          if (_picked[key] != null) out[key] = '${_picked[key]}';
        case 'number':
          final n = double.tryParse(_text[key]!.text.trim().replaceAll(',', '.'));
          if (n != null) out[key] = n;
        case 'secret':
          if (_text[key]!.text.isNotEmpty) out[key] = _text[key]!.text;
        default:
          out[key] = _text[key]!.text.trim();
      }
    }
    return out;
  }

  Widget _field(Map<String, dynamic> f) {
    final key = '${f['key']}';
    final label = '${f['label'] ?? key}';
    final help = '${f['help'] ?? ''}';
    switch (f['type']) {
      case 'bool':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label, style: const TextStyle(fontSize: 13)),
          subtitle: help.isEmpty ? null : Text(help, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
          value: _picked[key] == true,
          onChanged: (v) => setState(() => _picked[key] = v),
        );
      case 'select':
        final options = [for (final o in (f['options'] as List? ?? const [])) '$o'];
        return DropdownButtonFormField<String>(
          initialValue: options.contains('${_picked[key]}') ? '${_picked[key]}' : null,
          decoration: InputDecoration(labelText: label, helperText: help.isEmpty ? null : help, isDense: true),
          items: [
            for (final o in options) DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 13)))
          ],
          onChanged: (v) => setState(() => _picked[key] = v),
        );
    }
    final secret = f['type'] == 'secret';
    return TextField(
      controller: _text[key],
      obscureText: secret,
      keyboardType: f['type'] == 'number' ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        helperText: help.isEmpty ? null : help,
        hintText: secret && widget.values[key] == true ? context.l.t('plgSecretSet') : null,
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.name} · ${context.l.t('plgSettings')}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in widget.fields) Padding(padding: const EdgeInsets.only(bottom: 12), child: _field(f)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, _result()), child: Text(context.l.t('save'))),
      ],
    );
  }
}
