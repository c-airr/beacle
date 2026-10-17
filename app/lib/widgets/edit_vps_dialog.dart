import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Edits server metadata: name, location label, tags and per-server alert
/// thresholds. Tags replace the whole list; empty threshold fields fall back
/// to the global defaults.
Future<void> showEditVpsDialog(BuildContext context, Vps vps) async {
  await showDialog(context: context, builder: (_) => _EditVpsDialog(vps: vps));
}

class _EditVpsDialog extends StatefulWidget {
  final Vps vps;
  const _EditVpsDialog({required this.vps});

  @override
  State<_EditVpsDialog> createState() => _EditVpsDialogState();
}

class _EditVpsDialogState extends State<_EditVpsDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.vps.name);
  late final TextEditingController _location = TextEditingController(text: widget.vps.location);
  late final TextEditingController _tags = TextEditingController(text: widget.vps.tags.join(', '));
  late final TextEditingController _cpu =
      TextEditingController(text: _numOrEmpty(widget.vps.thresholds?.cpuHigh));
  late final TextEditingController _mem =
      TextEditingController(text: _numOrEmpty(widget.vps.thresholds?.memHigh));
  late final TextEditingController _disk =
      TextEditingController(text: _numOrEmpty(widget.vps.thresholds?.diskHigh));
  bool _saving = false;
  bool _switchingBack = false;

  /// Plugin metrics that alert, keyed `plugin.metric`: their warn override.
  late final Map<String, TextEditingController> _pluginLevels = {
    for (final e in context.read<AppState>().pluginMetrics.entries)
      // A wildcard metric ("disk_*") has no single name to override.
      if (!e.key.endsWith('*') && (((e.value['warn'] as num?) ?? 0) > 0 || ((e.value['crit'] as num?) ?? 0) > 0))
        e.key: TextEditingController(text: _numOrEmpty(widget.vps.thresholds?.plugins[e.key])),
  };

  static String _numOrEmpty(double? v) =>
      v == null || v <= 0 ? '' : v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 1);

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _tags.dispose();
    _cpu.dispose();
    _mem.dispose();
    _disk.dispose();
    for (final c in _pluginLevels.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parse(TextEditingController c) {
    final t = c.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return 0;
    return double.tryParse(t);
  }

  Future<void> _switchBack() async {
    if (_switchingBack) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.t('wgSwitchBack')),
        content: Text(context.l.t('wgSwitchBackConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.l.t('wgSwitchBack'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _switchingBack = true);
    try {
      context.read<AppState>().onUserAction();
      await context.read<AppState>().api.switchBackTailscale(widget.vps.id);
      await context.read<AppState>().refreshAll();
      if (mounted) {
        Navigator.pop(context);
        showToast(context, context.l.t('serverUpdated'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _switchingBack = false);
        showToast(context, '$e', error: true);
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final cpu = _parse(_cpu), mem = _parse(_mem), disk = _parse(_disk);
    final plugins = {for (final e in _pluginLevels.entries) e.key: _parse(e.value)};
    if (cpu == null || mem == null || disk == null || plugins.containsValue(null)) {
      showToast(context, context.l.t('thresholdsHint'), error: true);
      return;
    }
    final tags = _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    setState(() => _saving = true);
    final state = context.read<AppState>();
    try {
      state.onUserAction();
      await state.api.updateVps(widget.vps.id, {
        'name': _name.text.trim(),
        'location': _location.text.trim(),
        'tags': tags,
        'thresholds': {
          'cpu_high': cpu,
          'mem_high': mem,
          'disk_high': disk,
          'plugins': {
            // Overrides of plugins not installed right now are kept, not lost.
            ...?widget.vps.thresholds?.plugins,
            for (final e in plugins.entries) e.key: e.value,
          },
        },
      });
      await state.refreshAll();
      if (mounted) {
        Navigator.pop(context);
        showToast(context, context.l.t('serverUpdated'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, '$e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true, // plugin levels can make it taller than the window
      title: Text('${context.l.t('editServer')} · ${widget.vps.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(context.l.t('serverName'), _name),
            const SizedBox(height: 10),
            _field(context.l.t('serverLocation'), _location),
            const SizedBox(height: 10),
            _field(context.l.t('serverTags'), _tags, hint: context.l.t('tagsHint')),
            const SizedBox(height: 16),
            Text(context.l.t('alertThresholds'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(context.l.t('thresholdsHint'),
                style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _numField(context.l.t('thresholdCpu'), _cpu)),
                const SizedBox(width: 8),
                Expanded(child: _numField(context.l.t('thresholdMem'), _mem)),
                const SizedBox(width: 8),
                Expanded(child: _numField(context.l.t('thresholdDisk'), _disk)),
              ],
            ),
            if (_pluginLevels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(context.l.t('plgThresholdsHint'),
                  style: TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.4)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in _pluginLevels.entries)
                  SizedBox(width: 130, child: _numField(_pluginLabel(e.key), e.value)),
              ]),
            ],
            if (widget.vps.isWireGuard || widget.vps.wgPublicKey.isNotEmpty) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _switchingBack || _saving ? null : _switchBack,
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: Text(_switchingBack ? context.l.t('runningEllipsis') : context.l.t('wgSwitchBack')),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.t('cancel'))),
        SmallButton(
          _saving ? context.l.t('runningEllipsis') : context.l.t('save'),
          icon: Icons.check,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }

  /// A plugin metric's field label: "CPU (°C)".
  String _pluginLabel(String key) {
    final d = context.read<AppState>().pluginMetrics[key] ?? const {};
    final unit = '${d['unit'] ?? ''}';
    return '${d['label'] ?? key}${unit.isEmpty ? '' : ' ($unit)'}';
  }

  Widget _numField(String label, TextEditingController c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: const InputDecoration(
            hintText: '—',
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}
