import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Reboot with an optional session restore. Confirm first, then a progress
/// dialog follows the VPS from restarting through the silence back to online,
/// and finally shows what the agent brought back.
Future<void> showRebootDialog(BuildContext context, Vps vps, VpsSnapshot snap) async {
  var restore = true;
  final screens = snap.services.screen.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('${context.l.t('rebootTitle')} · ${vps.name}'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l.t('rebootBody'),
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: restore,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(context.l.f('rebootRestore', {'n': screens}),
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(context.l.t('rebootRestoreHint'),
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                onChanged: (v) => setState(() => restore = v ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l.t('cancel'))),
          SmallButton(context.l.t('rebootNow'),
              icon: Icons.restart_alt,
              color: BeacleColors.warn,
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    context.read<AppState>().onUserAction();
    final res = await context.read<AppState>().api.reboot(vps.id, restore: restore);
    if (!context.mounted) return;
    if (res.screensQueued + res.nohupQueued > 0 && restore) {
      showToast(
          context,
          context.l.f('rebootQueued',
              {'s': res.screensQueued, 'n': res.nohupQueued}));
    }
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RebootProgressDialog(vpsId: vps.id, vpsName: vps.name, restore: restore),
    );
  } catch (e) {
    if (context.mounted) showToast(context, '$e', error: true);
  }
}

Future<void> showPoweroffDialog(BuildContext context, Vps vps) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${context.l.t('poweroffTitle')} · ${vps.name}'),
      content: SizedBox(
        width: 440,
        child: Text(context.l.t('poweroffBody'),
            style: const TextStyle(fontSize: 13)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l.t('cancel'))),
        SmallButton(context.l.t('poweroffNow'),
            icon: Icons.power_settings_new_outlined,
            color: BeacleColors.err,
            onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    context.read<AppState>().onUserAction();
    await context.read<AppState>().api.poweroff(vps.id);
    if (context.mounted) showToast(context, context.l.t('poweroffSent'));
  } catch (e) {
    if (context.mounted) showToast(context, '$e', error: true);
  }
}

class _RebootProgressDialog extends StatefulWidget {
  final String vpsId, vpsName;
  final bool restore;
  const _RebootProgressDialog(
      {required this.vpsId, required this.vpsName, required this.restore});

  @override
  State<_RebootProgressDialog> createState() => _RebootProgressDialogState();
}

class _RebootProgressDialogState extends State<_RebootProgressDialog> {
  Timer? _timer;
  RestoreResult? _result;
  bool _resultLoading = false;
  bool _expired = false;
  DateTime _start = DateTime.now();

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (!mounted) return;
    setState(() {}); // status comes from AppState; just re-render the phase
    final vps = context
        .read<AppState>()
        .vpsList
        .where((v) => v.id == widget.vpsId)
        .firstOrNull;
    if (DateTime.now().difference(_start).inMinutes >= 15) {
      setState(() => _expired = true);
      _timer?.cancel();
      return;
    }
    if (vps != null && vps.online && widget.restore && _result == null && !_resultLoading) {
      // The agent reconnects before its restore finishes (it waits out the
      // boot), so the first fetch may predate the result — retry a few times.
      _resultLoading = true;
      try {
        for (var i = 0; i < 6; i++) {
          final r = await context.read<AppState>().api.restoreStatus(widget.vpsId);
          if (!mounted) return;
          if (r.restored) {
            setState(() {
              _result = r;
              _resultLoading = false;
            });
            _timer?.cancel();
            return;
          }
          await Future.delayed(const Duration(seconds: 5));
          if (!mounted) return;
        }
        if (mounted) setState(() => _resultLoading = false);
      } catch (_) {
        if (mounted) setState(() => _resultLoading = false);
      }
    }
    if (vps != null && vps.online && !widget.restore) _timer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final vps = context
        .watch<AppState>()
        .vpsList
        .where((v) => v.id == widget.vpsId)
        .firstOrNull;
    final status = vps?.status ?? 'offline';
    final online = vps?.online ?? false;
    final result = _result;

    String phase;
    if (result != null) {
      phase = result.failed == 0
          ? context.l.f('rebootDone', {'n': result.total})
          : context.l.f('rebootPartial', {'n': result.total - result.failed, 'f': result.failed});
    } else if (_expired) {
      phase = context.l.t('rebootTimeout');
    } else if (online) {
      phase = widget.restore
          ? context.l.t('rebootRestoring')
          : context.l.t('rebootBackOnline');
    } else if (status == 'restarting') {
      phase = context.l.t('rebootRestarting');
    } else {
      phase = context.l.t('rebootWaiting');
    }
    final done = result != null || _expired || (online && !widget.restore);

    return AlertDialog(
      title: Text('${context.l.t('rebootProgress')} · ${widget.vpsName}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (!done)
                const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(
                    result != null && result.failed > 0
                        ? Icons.warning_amber_outlined
                        : Icons.check_circle_outline,
                    size: 18,
                    color: result != null && result.failed > 0
                        ? BeacleColors.warn
                        : BeacleColors.ok),
              const SizedBox(width: 10),
              Expanded(child: Text(phase, style: const TextStyle(fontSize: 13))),
            ]),
            if (result != null && result.total > 0) ...[
              const SizedBox(height: 12),
              for (final item in [...result.screens, ...result.nohup])
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Icon(item.ok ? Icons.check : Icons.close,
                        size: 14,
                        color: item.ok ? BeacleColors.ok : BeacleColors.err),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.ok ? item.name : '${item.name} — ${item.error}',
                        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                      ),
                    ),
                  ]),
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (done)
          SmallButton(context.l.t('close'),
              icon: Icons.check, onPressed: () => Navigator.pop(context))
        else
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l.t('rebootCloseBg'))),
      ],
    );
  }
}
