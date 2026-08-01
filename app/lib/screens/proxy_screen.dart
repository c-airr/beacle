import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/proxy_site_form.dart';

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
                onPressed: proxy.provider == 'none' ? null : () => _openSiteForm(state, vps),
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
                      Row(children: [
                        Flexible(
                          child: Text(
                            s.domains.length > 1 ? s.domains.join(', ') : s.domain,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _sourceChip(s),
                      ]),
                      const SizedBox(height: 2),
                      Text(_targetLine(s),
                          style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                      if (_optionSummary(s).isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(_optionSummary(s),
                            style: const TextStyle(fontSize: 10, color: BeacleColors.textDim)),
                      ],
                    ]),
                  ),
                  _upstreamBadge(s),
                  const SizedBox(width: 8),
                  _sslBadge(s.ssl),
                  const SizedBox(width: 16),
                  if (s.rawConfig.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.code, size: 16),
                      tooltip: 'View config',
                      onPressed: () => _showRawConfig(s),
                    ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    tooltip: s.editable || s.managed
                        ? 'Edit'
                        : 'Read-only: ${s.readOnlyReason}',
                    color: (s.editable || s.managed) ? null : BeacleColors.textDim,
                    onPressed: (s.editable || s.managed)
                        ? () => _openSiteForm(state, vps, existing: s)
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: BeacleColors.err),
                    tooltip: s.managed ? 'Delete' : 'Only Beacle-managed sites can be deleted here',
                    onPressed: !s.managed
                        ? null
                        : () async {
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

  /// Shows the block exactly as it sits in the config. For sites the form
  /// cannot model this is the only honest view — and it is also how you check
  /// what Beacle generated for the ones it owns.
  void _showRawConfig(ProxySite s) {
    showLogsDialog(
      context,
      '${s.domain} — ${s.sourceFile.isEmpty ? 'Caddy config' : s.sourceFile}',
      () async => s.rawConfig,
    );
  }

  Future<void> _openSiteForm(AppState state, Vps vps, {ProxySite? existing}) async {
    final saved = await showProxySiteForm(context, state: state, vps: vps, existing: existing);
    if (!saved) return;
    if (mounted) showToast(context, existing == null ? 'Site created' : 'Site updated');
    // The snapshot carries proxy state, but the next tick can be seconds out —
    // pull now so the new row (and its port check) appears immediately.
    await state.refreshAll();
  }

  /// What the site actually does. A static site has no upstream, so printing
  /// "→ " with nothing after it would look like a broken config.
  String _targetLine(ProxySite s) {
    if (s.upstream.isNotEmpty && s.kind == 'mixed') {
      return 'static files + → ${s.upstream}';
    }
    if (s.upstream.isNotEmpty) return '→ ${s.upstream}';
    if (s.kind == 'static') return 'serves files from disk';
    return 'no reverse_proxy in this block';
  }

  /// Distinguishes sites Beacle owns from ones parsed out of the hand-written
  /// Caddyfile, because only the former can be rewritten from the form.
  Widget _sourceChip(ProxySite s) {
    if (s.managed) return const SizedBox.shrink();
    final tls = s.tlsMode == 'internal' ? ' · tls internal' : '';
    return Tooltip(
      message: s.editable
          ? 'Read from ${s.sourceFile}. Simple enough to edit here.'
          : 'Read from ${s.sourceFile}. ${s.readOnlyReason}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: BeacleColors.surfaceHi,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: BeacleColors.border),
        ),
        child: Text(
          s.editable ? 'Caddyfile$tls' : 'Caddyfile · read-only$tls',
          style: const TextStyle(fontSize: 10, color: BeacleColors.textDim),
        ),
      ),
    );
  }

  /// One-line recap of the switches that are on, so the list shows how a site
  /// is configured without opening the form.
  String _optionSummary(ProxySite s) {
    final on = [
      if (s.redirectWww) 'www redirect',
      if (s.webSocket) 'websockets',
      if (s.gzip) 'compression',
      if (s.basicAuthUser.isNotEmpty) 'basic auth',
      if (s.accessLog) 'access log',
      if (s.headers.isNotEmpty) '${s.headers.length} header${s.headers.length == 1 ? '' : 's'}',
    ];
    return on.join(' · ');
  }

  /// Whether anything is actually listening behind the domain. A site pointing
  /// at a dead port still serves — as a 502 — so this is the check that saves
  /// the "why is my site down" hunt.
  Widget _upstreamBadge(ProxySite s) {
    if (s.upstreamPort <= 0) {
      return const SizedBox.shrink();
    }
    final (color, label, icon) = s.upstreamHealthy
        ? (BeacleColors.ok, 'port ${s.upstreamPort} up', Icons.check_circle_outline)
        : s.portInUse
            ? (BeacleColors.warn, 'port ${s.upstreamPort} open', Icons.help_outline)
            : (BeacleColors.err, 'port ${s.upstreamPort} dead', Icons.error_outline);
    return Tooltip(
      message: s.upstreamHealthy
          ? 'Something is listening on ${s.upstreamPort} and answering HTTP.'
          : s.portInUse
              ? 'Port ${s.upstreamPort} accepts connections but did not answer HTTP.'
              : 'Nothing is listening on port ${s.upstreamPort} — this domain will return 502.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ]),
      ),
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
