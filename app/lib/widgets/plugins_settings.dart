import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../native_dialogs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

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
          for (final p in state.plugins)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: _PluginCard(p: p)),
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
      for (final (key, label) in [('read', 'plgPermRead'), ('exec', 'plgPermExec'), ('http', 'plgPermHttp')])
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
  const _PluginCard({required this.p});

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
