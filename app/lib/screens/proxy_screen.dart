import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Reverse proxy GUI - shared UI for Caddy and Nginx Proxy Manager.
/// Site management is a form, never a file editor.
class ProxyScreen extends StatefulWidget {
  const ProxyScreen({super.key});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  String? selectedId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final withAgent = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (withAgent.isEmpty) {
      return const Center(child: Text('No VPS with agent data', style: TextStyle(color: BeacleColors.textDim)));
    }
    selectedId ??= withAgent.first.id;
    final vps = withAgent.where((v) => v.id == selectedId).firstOrNull ?? withAgent.first;
    final proxy = state.snapshots[vps.id]?.proxy ?? ProxyState.empty();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: vps.id,
                  dropdownColor: BeacleColors.surfaceHi,
                  style: const TextStyle(fontSize: 13, color: BeacleColors.text),
                  items: [
                    for (final v in withAgent)
                      DropdownMenuItem(
                          value: v.id,
                          child: Row(children: [StatusDot(v.status, size: 7), const SizedBox(width: 8), Text(v.name)]))
                  ],
                  onChanged: (v) => setState(() => selectedId = v),
                ),
              ),
              const SizedBox(width: 16),
              _providerBadge(proxy),
              const Spacer(),
              SmallButton('Validate config', icon: Icons.rule, onPressed: () async {
                try {
                  state.onUserAction();
                  final r = await state.api.proxyValidate(vps.id);
                  if (!context.mounted) return;
                  showToast(context, r['valid'] == true ? 'Config valid: ${r['output']}' : 'Invalid: ${r['output']}',
                      error: r['valid'] != true);
                } catch (e) {
                  if (context.mounted) showToast(context, '$e', error: true);
                }
              }),
              const SizedBox(width: 8),
              SmallButton('Reload', icon: Icons.refresh, onPressed: () async {
                try {
                  state.onUserAction();
                  await state.api.proxyReload(vps.id);
                  if (context.mounted) showToast(context, 'Proxy reloaded');
                } catch (e) {
                  if (context.mounted) showToast(context, '$e', error: true);
                }
              }),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: proxy.provider == 'none' ? null : () => _siteForm(context, state, vps),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add site', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _sitesList(state, vps, proxy)),
              const VerticalDivider(width: 1),
              SizedBox(width: 380, child: _PortChecker(vps: vps)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _providerBadge(ProxyState proxy) {
    final label = switch (proxy.provider) {
      'caddy' => 'Caddy ${proxy.version}',
      'npm' => 'Nginx Proxy Manager',
      _ => 'No provider detected',
    };
    final color = proxy.provider == 'none'
        ? BeacleColors.textDim
        : proxy.running
            ? BeacleColors.ok
            : BeacleColors.err;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
        if (proxy.provider != 'none' && !proxy.running)
          const Text('  (not running)', style: TextStyle(fontSize: 12, color: BeacleColors.err)),
      ]),
    );
  }

  Widget _sitesList(AppState state, Vps vps, ProxyState proxy) {
    if (proxy.provider == 'none') {
      return const Center(
        child: Text('Install Caddy or Nginx Proxy Manager on this VPS\nto manage reverse proxy sites.',
            textAlign: TextAlign.center, style: TextStyle(color: BeacleColors.textDim)),
      );
    }
    if (proxy.sites.isEmpty) {
      return const Center(child: Text('No sites configured yet', style: TextStyle(color: BeacleColors.textDim)));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (proxy.lastError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('Provider error: ${proxy.lastError}',
                style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
          ),
        for (final s in proxy.sites)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PanelCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.language, size: 18, color: s.enabled ? BeacleColors.text : BeacleColors.textDim),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.domain, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text('→ ${s.upstream}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                    ]),
                  ),
                  _sslBadge(s.ssl),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    tooltip: 'Edit',
                    onPressed: () => _siteForm(context, state, vps, existing: s),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: BeacleColors.err),
                    tooltip: 'Delete',
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete site?'),
                          content: Text('Remove ${s.domain} from the proxy config?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        try {
                          state.onUserAction();
                          await state.api.proxyDeleteSite(vps.id, s.id);
                          if (mounted) showToast(context, 'Site deleted');
                          state.refreshAll();
                        } catch (e) {
                          if (mounted) showToast(context, '$e', error: true);
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _sslBadge(String ssl) {
    final (color, label) = switch (ssl) {
      'active' => (BeacleColors.ok, 'SSL active'),
      'pending' => (BeacleColors.warn, 'SSL pending'),
      'error' => (BeacleColors.err, 'SSL error'),
      _ => (BeacleColors.textDim, 'HTTP only'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ssl == 'active' ? Icons.lock : Icons.lock_open, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ]),
    );
  }

  Future<void> _siteForm(BuildContext context, AppState state, Vps vps, {ProxySite? existing}) async {
    final domain = TextEditingController(text: existing?.domain ?? '');
    final upstream = TextEditingController(text: existing?.upstream ?? '');
    bool ssl = existing == null ? true : existing.ssl != 'disabled';
    bool websockets = existing?.extra['websockets'] == 'true';
    String? error;
    bool busy = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Dialog(
          child: Container(
            width: 480,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'Add site' : 'Edit site',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 18),
                TextField(controller: domain, decoration: const InputDecoration(labelText: 'Domain', hintText: 'app.example.com')),
                const SizedBox(height: 10),
                TextField(
                    controller: upstream,
                    decoration: const InputDecoration(labelText: 'Upstream', hintText: 'localhost:3000')),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: ssl,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Enable SSL (automatic certificate)', style: TextStyle(fontSize: 13)),
                  onChanged: (v) => setState(() => ssl = v ?? true),
                ),
                CheckboxListTile(
                  value: websockets,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('WebSocket support', style: TextStyle(fontSize: 13)),
                  onChanged: (v) => setState(() => websockets = v ?? false),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (domain.text.trim().isEmpty || upstream.text.trim().isEmpty) {
                              setState(() => error = 'Domain and upstream are required');
                              return;
                            }
                            setState(() => busy = true);
                            final req = {
                              'domain': domain.text.trim(),
                              'upstream': upstream.text.trim(),
                              'enable_ssl': ssl,
                              'extra': {'websockets': websockets.toString()},
                            };
                            try {
                              state.onUserAction();
                              if (existing == null) {
                                await state.api.proxyAddSite(vps.id, req);
                              } else {
                                await state.api.proxyUpdateSite(vps.id, existing.id, req);
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                              state.refreshAll();
                            } catch (e) {
                              setState(() {
                                busy = false;
                                error = '$e';
                              });
                            }
                          },
                    child: Text(existing == null ? 'Add site' : 'Save'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Port checker sidebar: who is using a port, PID, command, health.
class _PortChecker extends StatefulWidget {
  final Vps vps;
  const _PortChecker({required this.vps});

  @override
  State<_PortChecker> createState() => _PortCheckerState();
}

class _PortCheckerState extends State<_PortChecker> {
  final ctl = TextEditingController();
  PortInfo? result;
  String? error;
  bool busy = false;

  Future<void> _check() async {
    final port = int.tryParse(ctl.text.trim());
    if (port == null) {
      setState(() => error = 'Enter a port number');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final r = await context.read<AppState>().api.portDetail(widget.vps.id, port);
      setState(() {
        result = r;
        busy = false;
      });
    } catch (e) {
      setState(() {
        error = '$e';
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PORT CHECKER',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: BeacleColors.textDim)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: ctl,
                decoration: const InputDecoration(hintText: 'Port, e.g. 3000'),
                onSubmitted: (_) => _check(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: busy ? null : _check,
                child: busy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Check')),
          ]),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(result!.pid > 0 ? Icons.settings_ethernet : Icons.block,
                      size: 16, color: result!.pid > 0 ? BeacleColors.text : BeacleColors.textDim),
                  const SizedBox(width: 8),
                  Text('Port ${result!.port}/${result!.protocol}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const Divider(height: 20),
                _kv('Process', result!.processName.isEmpty ? '(none)' : result!.processName),
                _kv('PID', result!.pid > 0 ? '${result!.pid}' : '-'),
                _kv('Listen', result!.listenAddr),
                _kv('Command', result!.commandLine.isEmpty ? '-' : result!.commandLine),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(result!.healthy ? Icons.check_circle : Icons.error,
                      size: 15, color: result!.healthy ? BeacleColors.ok : BeacleColors.err),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(result!.healthDetail,
                          style: TextStyle(
                              fontSize: 12, color: result!.healthy ? BeacleColors.ok : BeacleColors.err))),
                ]),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 76, child: Text(k, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))),
          Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 12))),
        ]),
      );
}
