import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'smooth_scroll.dart';

/// OS package banner for the server stats page: pending APT/DNF updates,
/// reboot-required flag, and a dialog with the package list + one-click
/// background upgrade.
class OsUpdatesBanner extends StatefulWidget {
  final Vps vps;
  const OsUpdatesBanner({super.key, required this.vps});

  @override
  State<OsUpdatesBanner> createState() => _OsUpdatesBannerState();
}

class _OsUpdatesBannerState extends State<OsUpdatesBanner> {
  OSUpdates? _updates;
  OSUpdateJob? _job;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OsUpdatesBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vps.id != widget.vps.id) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      final u = await api.osUpdates(widget.vps.id);
      final j = await api.osUpdateStatus(widget.vps.id);
      if (!mounted) return;
      setState(() {
        _updates = u;
        _job = j;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A host without apt/dnf (or an old agent) simply hides the banner —
      // nagging about updates the agent cannot see helps nobody.
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox.shrink();
    }
    final u = _updates;
    if (_error != null || u == null) return const SizedBox.shrink();
    final upgrading = _job?.running == true;
    final attention = upgrading || u.packages.isNotEmpty || u.rebootRequired;
    final color = upgrading
        ? BeacleColors.accent
        : u.rebootRequired || u.securityCount > 0
            ? BeacleColors.err
            : u.packages.isNotEmpty
                ? BeacleColors.warn
                : BeacleColors.ok;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: attention ? color.withValues(alpha: 0.08) : BeacleColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: attention ? color.withValues(alpha: 0.4) : BeacleColors.border),
      ),
      child: Row(
        children: [
          Icon(
            upgrading
                ? Icons.system_update
                : u.packages.isEmpty && !u.rebootRequired
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              upgrading
                  ? context.l.t('osUpgrading')
                  : u.packages.isEmpty && !u.rebootRequired
                      ? context.l.t('osUpToDate')
                      : [
                          if (u.packages.isNotEmpty)
                            context.l.f('osUpdatesAvailable', {
                              'n': u.packages.length,
                              's': u.securityCount,
                            }),
                          if (u.rebootRequired) context.l.t('osRebootRequired'),
                        ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SmallButton(context.l.t('osDetails'),
              icon: Icons.list_alt_outlined,
              onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _OsUpdatesDialog(vps: widget.vps, updates: u),
                  ).then((_) => _load())),
        ],
      ),
    );
  }
}

class _OsUpdatesDialog extends StatefulWidget {
  final Vps vps;
  final OSUpdates updates;
  const _OsUpdatesDialog({required this.vps, required this.updates});

  @override
  State<_OsUpdatesDialog> createState() => _OsUpdatesDialogState();
}

class _OsUpdatesDialogState extends State<_OsUpdatesDialog> {
  OSUpdateJob? _job;
  Timer? _poll;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final j = await context.read<AppState>().api.osUpdateStatus(widget.vps.id);
      if (!mounted) return;
      setState(() => _job = j);
      if (j.running && _poll == null) {
        _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
      } else if (!j.running) {
        _poll?.cancel();
        _poll = null;
      }
    } catch (_) {}
  }

  Future<void> _upgrade() async {
    if (_starting) return;
    setState(() => _starting = true);
    final state = context.read<AppState>();
    try {
      state.onUserAction();
      await state.api.osUpdateApply(widget.vps.id);
      await _refresh();
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.updates;
    final job = _job;
    final running = job?.running == true;
    return AlertDialog(
      title: Text('${context.l.t('osUpdatesTitle')} · ${widget.vps.name}'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (u.rebootRequired)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(context.l.t('osRebootRequired'),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: BeacleColors.err)),
              ),
            if (u.packages.isEmpty)
              Text(context.l.t('osUpToDate'),
                  style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))
            else
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  decoration: BoxDecoration(
                    color: BeacleColors.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: BeacleColors.border),
                  ),
                  child: SmoothListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: u.packages.length,
                    itemBuilder: (ctx, i) {
                      final p = u.packages[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name,
                                      style: const TextStyle(
                                          fontSize: 12, fontWeight: FontWeight.w600)),
                                  Text(
                                    p.current.isEmpty ? p.latest : '${p.current} → ${p.latest}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'Consolas',
                                        color: BeacleColors.textDim),
                                  ),
                                ],
                              ),
                            ),
                            if (p.security)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: BeacleColors.err.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(context.l.t('osSecurity'),
                                    style: const TextStyle(fontSize: 10, color: BeacleColors.err)),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (running) ...[
              const SizedBox(height: 10),
              Row(children: [
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(context.l.t('osUpgrading'),
                        style: const TextStyle(fontSize: 12, color: BeacleColors.textDim))),
              ]),
            ],
            if (job != null && job.hasRun && !running && job.output.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                job.exitCode == 0 ? context.l.t('osUpgradeDone') : context.l.t('osUpgradeFailed'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: job.exitCode == 0 ? BeacleColors.ok : BeacleColors.err),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: BeacleColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BeacleColors.border),
                ),
                child: SmoothSingleChildScrollView(
                  child: SelectableText(job.output,
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.4)),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('close'))),
        if (!running && u.packages.isNotEmpty)
          SmallButton(
            _starting ? context.l.t('runningEllipsis') : context.l.t('osUpgrade'),
            icon: Icons.system_update_alt,
            onPressed: _starting ? null : _upgrade,
          ),
      ],
    );
  }
}
