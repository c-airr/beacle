import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';
import 'metric_chart.dart';

/// What one plugin put in one slot (GET /api/plugins/ui).
class SlotRender {
  final String plugin;
  final Map<String, dynamic> opts;
  final List<dynamic> blocks;

  /// servers.column only: the cell for each server id.
  final Map<String, dynamic> cells;
  final String error;
  SlotRender.fromJson(Map<String, dynamic> j)
      : plugin = '${j['plugin'] ?? ''}',
        opts = (j['opts'] as Map<String, dynamic>?) ?? const {},
        blocks = j['blocks'] is List ? j['blocks'] as List : const [],
        cells = (j['cells'] as Map<String, dynamic>?) ?? const {},
        error = '${j['error'] ?? ''}';

  String get title => '${opts['title'] ?? ''}';
}

/// Fetches one slot's blocks and hands them to [builder]: again when plugins
/// change, after a button, and every [_refresh] for blocks whose text comes
/// from Lua (blocks bound to a metric follow live data on their own).
class PluginSlot extends StatefulWidget {
  final String slot;
  final String? vpsId;
  final String? tab;
  final Widget Function(BuildContext context, List<SlotRender> renders, VoidCallback reload) builder;
  const PluginSlot({super.key, required this.slot, this.vpsId, this.tab, required this.builder});

  @override
  State<PluginSlot> createState() => _PluginSlotState();
}

class _PluginSlotState extends State<PluginSlot> {
  static const _refresh = Duration(seconds: 15);
  List<SlotRender> _renders = const [];
  int _revision = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_refresh, (_) => _load());
  }

  @override
  void didUpdateWidget(covariant PluginSlot old) {
    super.didUpdateWidget(old);
    if (old.vpsId != widget.vpsId || old.tab != widget.tab) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // No plugin, no request: most panels have none and every screen has slots.
    if (state.plugins.isEmpty) {
      if (_renders.isNotEmpty && mounted) setState(() => _renders = const []);
      return;
    }
    final q = [
      'slot=${Uri.encodeQueryComponent(widget.slot)}',
      if (widget.vpsId != null) 'server=${Uri.encodeQueryComponent(widget.vpsId!)}',
      if (widget.tab != null) 'tab=${Uri.encodeQueryComponent(widget.tab!)}',
    ].join('&');
    try {
      final r = await state.api.get('/api/plugins/ui?$q') as List? ?? [];
      if (!mounted) return;
      setState(() => _renders = [for (final e in r) SlotRender.fromJson(e as Map<String, dynamic>)]);
    } catch (_) {
      // Backend busy or restarting: keep what is on screen.
    }
  }

  @override
  Widget build(BuildContext context) {
    final rev = context.select<AppState, int>((s) => s.pluginsRevision);
    if (rev != _revision) {
      _revision = rev;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return widget.builder(context, _renders, _load);
  }
}

/// Each plugin's blocks in a card of its own, titled by the slot's opts.
Widget pluginCards(BuildContext context, List<SlotRender> renders, VoidCallback reload, {String? vpsId}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final r in renders)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: PanelCard(
            title: r.title.isEmpty ? null : r.title,
            child: PluginBlocks(render: r, vpsId: vpsId, onAction: reload),
          ),
        ),
    ],
  );
}

/// Draws the blocks of one render, or its error in one line.
class PluginBlocks extends StatelessWidget {
  final SlotRender render;
  final String? vpsId;
  final VoidCallback onAction;

  /// servers.column passes one cell instead of the render's block list.
  final Object? only;
  const PluginBlocks({super.key, required this.render, this.vpsId, required this.onAction, this.only});

  @override
  Widget build(BuildContext context) {
    if (render.error.isNotEmpty) {
      return Text('${render.plugin}: ${render.error}',
          maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: BeacleColors.err));
    }
    if (only != null) return _block(context, only);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in render.blocks)
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _block(context, b)),
      ],
    );
  }

  String? get _server => vpsId;

  /// A bare metric name is one of this plugin's own.
  String _key(Object? metric) {
    final m = '$metric';
    return m.contains('.') ? m : '${render.plugin}.$m';
  }

  Widget _block(BuildContext context, Object? raw, {bool fill = false}) {
    if (raw is! Map) return const SizedBox.shrink();
    final b = raw.cast<String, dynamic>();
    final children = (b['children'] as List?) ?? const [];
    switch (b['type']) {
      case 'label':
        return Text('${b['text'] ?? ''}', style: TextStyle(fontSize: 12.5, color: _tone(b['tone'])));
      case 'stat':
        final v = _value(context, b);
        final def = _def(context, b);
        final label = '${b['label'] ?? def?['label'] ?? ''}';
        final unit = '${b['unit'] ?? def?['unit'] ?? ''}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty) Text(label, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            Text(v == null ? '—' : '${_fmt(v)}$unit',
                style: TextStyle(
                    fontSize: label.isEmpty ? 11 : 18,
                    fontWeight: FontWeight.w600,
                    color: b['tone'] != null ? _tone(b['tone']) : _levelTone(v, def))),
          ],
        );
      case 'bar':
        final v = _value(context, b) ?? 0;
        return MetricBar(
          label: '${b['label'] ?? _def(context, b)?['label'] ?? ''}',
          percent: v.clamp(0, 100).toDouble(),
          detail: b['detail'] == null ? null : '${b['detail']}',
        );
      case 'chart':
        final server = '${b['server'] ?? _server ?? ''}';
        if (server.isEmpty || b['metric'] == null) return const SizedBox.shrink();
        return _PluginChart(
          vpsId: server,
          metric: _key(b['metric']),
          hours: (b['hours'] as num?)?.toInt() ?? 24,
          title: '${b['title'] ?? _def(context, b)?['label'] ?? b['metric']}',
          unit: '${b['unit'] ?? _def(context, b)?['unit'] ?? ''}',
        );
      case 'table':
        final cols = [for (final c in (b['columns'] as List? ?? const [])) '$c'];
        final rows = [for (final r in (b['rows'] as List? ?? const [])) if (r is List) r];
        return Table(
          defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
          children: [
            if (cols.isNotEmpty)
              TableRow(children: [
                for (final c in cols)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6, right: 12),
                    child: Text(c, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ),
              ]),
            for (final r in rows)
              TableRow(children: [
                for (var i = 0; i < (cols.isEmpty ? r.length : cols.length); i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3).copyWith(right: 12),
                    child: Text(i < r.length ? '${r[i] ?? ''}' : '', style: const TextStyle(fontSize: 12)),
                  ),
              ]),
          ],
        );
      case 'button':
        final label = '${b['label'] ?? b['action'] ?? ''}';
        return Align(
          alignment: Alignment.centerLeft,
          child: SmallButton(label, onPressed: () async {
            if (b['confirm'] is String && !await _confirm(context, label, '${b['confirm']}')) return;
            if (context.mounted) {
              await _run(context, '${b['action'] ?? ''}', (b['args'] as Map?)?.cast<String, dynamic>() ?? {});
            }
          }),
        );
      case 'link':
        final url = '${b['url'] ?? ''}';
        return Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            onTap: () => openUrl(url),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${b['text'] ?? url}', style: TextStyle(fontSize: 12.5, color: BeacleColors.accent)),
              const SizedBox(width: 4),
              Icon(Icons.open_in_new, size: 12, color: BeacleColors.accent),
            ]),
          ),
        );
      case 'toggle':
        return Row(children: [
          Expanded(child: Text('${b['label'] ?? ''}', style: const TextStyle(fontSize: 12.5))),
          Switch(
            value: b['value'] == true,
            onChanged: (v) =>
                _run(context, '${b['action'] ?? ''}', {...?(b['args'] as Map?)?.cast<String, dynamic>(), 'value': v}),
          ),
        ]);
      case 'select':
        final options = [for (final o in (b['options'] as List? ?? const [])) '$o'];
        final value = options.contains('${b['value']}') ? '${b['value']}' : null;
        return Row(children: [
          if ('${b['label'] ?? ''}'.isNotEmpty) ...[
            Text('${b['label']}', style: const TextStyle(fontSize: 12.5)),
            const SizedBox(width: 12),
          ],
          DropdownButton<String>(
            value: value,
            isDense: true,
            style: TextStyle(fontSize: 12.5, color: BeacleColors.text),
            items: [for (final o in options) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: (v) => v == null
                ? null
                : _run(context, '${b['action'] ?? ''}', {...?(b['args'] as Map?)?.cast<String, dynamic>(), 'value': v}),
          ),
        ]);
      case 'code':
        return Container(
          constraints: BoxConstraints(maxHeight: ((b['height'] as num?) ?? 240).toDouble()),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: BeacleColors.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: BeacleColors.border),
          ),
          child: SingleChildScrollView(
            reverse: b['tail'] == true, // a log: keep the newest lines in view
            child: SelectableText('${b['text'] ?? ''}',
                style: const TextStyle(fontSize: 11.5, fontFamily: 'Consolas', height: 1.35)),
          ),
        );
      case 'input':
        return _PluginInput(
          label: '${b['label'] ?? ''}',
          hint: '${b['hint'] ?? ''}',
          value: '${b['value'] ?? ''}',
          onSubmit: (text) => _run(context, '${b['action'] ?? ''}', {'value': text}),
        );
      case 'row':
        // A row with cards in it is a row of tiles, one height like the
        // Overview's (see PanelCard for why IntrinsicHeight).
        final tiles = children.any((c) => c is Map && c['card'] == true);
        final row = Row(
          crossAxisAlignment: tiles ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              Expanded(child: _block(context, children[i], fill: tiles)),
            ],
          ],
        );
        return tiles ? IntrinsicHeight(child: row) : row;
      case 'column':
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in children) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _block(context, c)),
          ],
        );
        // ui.card: the same column, framed like the panel's own cards.
        if (b['card'] != true) return column;
        return PanelCard(title: b['title'] == null ? null : '${b['title']}', expand: fill, child: column);
    }
    return const SizedBox.shrink(); // a block type this panel does not know
  }

  Map<String, dynamic>? _def(BuildContext context, Map<String, dynamic> b) =>
      b['metric'] == null ? null : context.read<AppState>().pluginMetricDef(_key(b['metric']));

  /// `value` as given, or the live reading of `metric` on the block's server.
  double? _value(BuildContext context, Map<String, dynamic> b) {
    if (b['value'] is num) return (b['value'] as num).toDouble();
    final server = '${b['server'] ?? _server ?? ''}';
    if (b['metric'] == null || server.isEmpty) return null;
    final snap = context.select<AppState, VpsSnapshot?>((s) => s.snapshots[server]);
    return snap?.metrics.plugins[_key(b['metric'])];
  }

  Future<void> _run(BuildContext context, String action, Map<String, dynamic> args) async {
    final state = context.read<AppState>();
    state.onUserAction();
    try {
      final r = await state.api.post('/api/plugins/${render.plugin}/action', body: {
        'action': action,
        'args': {...args, if (_server != null) 'server': _server},
      }) as Map?;
      final res = r?['result'];
      if (res is String && res.isNotEmpty && context.mounted) showToast(context, res);
    } catch (e) {
      if (context.mounted) showToast(context, '$e', error: true);
    }
    onAction();
  }
}

Future<bool> _confirm(BuildContext context, String action, String question) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    ) ==
    true;

/// Opens a web page in the system browser. Only http(s): a plugin must not
/// be able to start programs through a file: or custom-scheme link.
Future<void> openUrl(String url) async {
  final u = Uri.tryParse(url);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return;
  final (exe, args) = switch (Platform.operatingSystem) {
    'windows' => ('explorer', [u.toString()]),
    'macos' => ('open', [u.toString()]),
    _ => ('xdg-open', [u.toString()]),
  };
  await Process.run(exe, args);
}

String _fmt(double v) => v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

Color _tone(Object? t) => switch (t) {
      'ok' => BeacleColors.ok,
      'warn' => BeacleColors.warn,
      'err' => BeacleColors.err,
      'dim' => BeacleColors.textDim,
      _ => BeacleColors.text,
    };

/// Colours a reading by the warn/crit levels its manifest declares.
Color _levelTone(double? v, Map<String, dynamic>? def) {
  if (v == null || def == null) return BeacleColors.text;
  final crit = (def['crit'] as num?)?.toDouble() ?? 0, warn = (def['warn'] as num?)?.toDouble() ?? 0;
  if (crit > 0 && v >= crit) return BeacleColors.err;
  if (warn > 0 && v >= warn) return BeacleColors.warn;
  return BeacleColors.text;
}

class _PluginInput extends StatefulWidget {
  final String label, hint, value;
  final void Function(String) onSubmit;
  const _PluginInput({required this.label, required this.hint, required this.value, required this.onSubmit});

  @override
  State<_PluginInput> createState() => _PluginInputState();
}

class _PluginInputState extends State<_PluginInput> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      onSubmitted: widget.onSubmit,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: widget.label.isEmpty ? null : widget.label,
        hintText: widget.hint.isEmpty ? null : widget.hint,
        isDense: true,
        suffixIcon: IconButton(
          icon: const Icon(Icons.keyboard_return, size: 16),
          tooltip: context.l.t('save'),
          onPressed: () => widget.onSubmit(_c.text),
        ),
      ),
    );
  }
}

/// A plugin metric's recorded history on one server.
class _PluginChart extends StatefulWidget {
  final String vpsId, metric, title, unit;
  final int hours;
  const _PluginChart(
      {required this.vpsId, required this.metric, required this.hours, required this.title, required this.unit});

  @override
  State<_PluginChart> createState() => _PluginChartState();
}

class _PluginChartState extends State<_PluginChart> {
  MetricHistory? _h;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await context.read<AppState>().api.vpsHistory(widget.vpsId, hours: widget.hours);
      if (mounted) setState(() => _h = h);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    if (h == null) return const SizedBox(height: 150);
    final now = DateTime.now();
    return MetricChart(
      title: widget.title,
      samples: h.samples,
      from: now.subtract(Duration(hours: widget.hours)),
      to: now,
      series: [
        ChartSeries(
          label: widget.title,
          color: ChartColors.cpu,
          value: (s) => s.plugins[widget.metric],
          format: (v) => '${_fmt(v)}${widget.unit}',
        ),
      ],
    );
  }
}

/// Icons a plugin can name for its tab. Material icons cannot be looked up by
/// name at runtime (the font is tree-shaken), so the choice is this list.
IconData pluginIcon(String name) => switch (name) {
      'thermostat' => Icons.thermostat,
      'memory' => Icons.memory,
      'speed' => Icons.speed,
      'storage' => Icons.storage_outlined,
      'bolt' => Icons.bolt,
      'chart' => Icons.show_chart,
      'heart' => Icons.monitor_heart_outlined,
      'cloud' => Icons.cloud_outlined,
      'power' => Icons.power_settings_new,
      'network' => Icons.lan_outlined,
      'shield' => Icons.shield_outlined,
      'list' => Icons.list_alt,
      'home' => Icons.home_outlined,
      'dashboard' => Icons.dashboard_outlined,
      'settings' => Icons.settings_outlined,
      'terminal' => Icons.terminal,
      'code' => Icons.code,
      'bug' => Icons.bug_report_outlined,
      'build' => Icons.build_outlined,
      'cpu' => Icons.developer_board,
      'gpu' => Icons.videogame_asset_outlined,
      'disk' => Icons.album_outlined,
      'folder' => Icons.folder_outlined,
      'file' => Icons.description_outlined,
      'database' => Icons.dns_outlined,
      'server' => Icons.dns,
      'docker' => Icons.view_in_ar_outlined,
      'wifi' => Icons.wifi,
      'router' => Icons.router_outlined,
      'globe' => Icons.public,
      'link' => Icons.link,
      'lock' => Icons.lock_outline,
      'key' => Icons.key_outlined,
      'user' => Icons.person_outline,
      'users' => Icons.group_outlined,
      'mail' => Icons.mail_outline,
      'chat' => Icons.chat_bubble_outline,
      'bell' => Icons.notifications_none,
      'warning' => Icons.warning_amber_outlined,
      'error' => Icons.error_outline,
      'check' => Icons.check_circle_outline,
      'info' => Icons.info_outline,
      'clock' => Icons.schedule,
      'calendar' => Icons.calendar_today_outlined,
      'timer' => Icons.timer_outlined,
      'history' => Icons.history,
      'sync' => Icons.sync,
      'download' => Icons.download_outlined,
      'upload' => Icons.upload_outlined,
      'search' => Icons.search,
      'star' => Icons.star_outline,
      'flag' => Icons.flag_outlined,
      'battery' => Icons.battery_std,
      'sun' => Icons.wb_sunny_outlined,
      'moon' => Icons.dark_mode_outlined,
      'water' => Icons.water_drop_outlined,
      'fan' => Icons.toys_outlined,
      'camera' => Icons.photo_camera_outlined,
      'music' => Icons.music_note_outlined,
      'game' => Icons.sports_esports_outlined,
      'money' => Icons.payments_outlined,
      'cart' => Icons.shopping_cart_outlined,
      'robot' => Icons.smart_toy_outlined,
      'puzzle' => Icons.extension_outlined,
      _ => Icons.extension_outlined,
    };

/// server.actions: what plugins put in a server's header, in one line.
class PluginServerActions extends StatelessWidget {
  final String vpsId;
  const PluginServerActions({super.key, required this.vpsId});

  @override
  Widget build(BuildContext context) {
    return PluginSlot(
      slot: 'server.actions',
      vpsId: vpsId,
      builder: (context, renders, reload) => Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final r in renders)
            if (r.error.isNotEmpty)
              PluginBlocks(render: r, vpsId: vpsId, onAction: reload)
            else
              for (final b in r.blocks) PluginBlocks(render: r, vpsId: vpsId, onAction: reload, only: b),
        ],
      ),
    );
  }
}

/// A whole page from a plugin's nav.tab slot.
class PluginTabScreen extends StatelessWidget {
  final PluginTab tab;
  const PluginTabScreen({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    return PluginSlot(
      slot: 'nav.tab',
      tab: tab.id,
      builder: (context, renders, reload) => SmoothListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          for (final r in renders.where((r) => r.plugin == tab.plugin))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: PluginBlocks(render: r, onAction: reload),
            ),
        ],
      ),
    );
  }
}
