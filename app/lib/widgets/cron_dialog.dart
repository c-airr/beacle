import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// Cron row editor: five schedule fields plus the command, with the same
/// validation the agent enforces, so typos fail fast in the panel.
Future<CronEntrySpec?> showCronEditor(
  BuildContext context, {
  CronEntry? existing,
  required String vpsName,
}) =>
    showDialog<CronEntrySpec>(
      context: context,
      builder: (_) => _CronEditorDialog(existing: existing, vpsName: vpsName),
    );

class _CronEditorDialog extends StatefulWidget {
  final CronEntry? existing;
  final String vpsName;
  const _CronEditorDialog({this.existing, required this.vpsName});

  @override
  State<_CronEditorDialog> createState() => _CronEditorDialogState();
}

class _CronEditorDialogState extends State<_CronEditorDialog> {
  late final TextEditingController _minute, _hour, _dom, _month, _dow, _command;
  String? _error;

  static const _bounds = [
    [0, 59], // minute
    [0, 23], // hour
    [1, 31], // day of month
    [1, 12], // month
    [0, 7], // day of week
  ];
  static const _names = [
    <String>{},
    <String>{},
    <String>{},
    {'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'},
    {'sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'},
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _minute = TextEditingController(text: e?.minute ?? '0');
    _hour = TextEditingController(text: e?.hour ?? '*');
    _dom = TextEditingController(text: e?.dayMonth ?? '*');
    _month = TextEditingController(text: e?.month ?? '*');
    _dow = TextEditingController(text: e?.dayWeek ?? '*');
    _command = TextEditingController(text: e?.command ?? '');
  }

  @override
  void dispose() {
    _minute.dispose();
    _hour.dispose();
    _dom.dispose();
    _month.dispose();
    _dow.dispose();
    _command.dispose();
    super.dispose();
  }

  bool _fieldOk(String field, int idx) {
    field = field.trim();
    if (field.isEmpty) return false;
    if (field == '*') return true;
    final num = RegExp(r'^[0-9]+$');
    for (final rawPart in field.split(',')) {
      var part = rawPart.trim().toLowerCase();
      if (part.isEmpty) return false;
      if (part.contains('/')) {
        final step = part.split('/');
        if (step.length != 2 || !num.hasMatch(step[1])) return false;
        final n = int.parse(step[1]);
        if (n < 1 || n > _bounds[idx][1]) return false;
        part = step[0];
        if (part.isEmpty) return false;
        if (part == '*') continue;
      }
      var lo = part, hi = part;
      if (part.contains('-')) {
        final range = part.split('-');
        if (range.length != 2) return false;
        lo = range[0];
        hi = range[1];
      }
      for (final v in [lo, hi]) {
        if (_names[idx].contains(v)) continue;
        if (!num.hasMatch(v)) return false;
        final n = int.parse(v);
        if (n < _bounds[idx][0] || n > _bounds[idx][1]) return false;
      }
    }
    return true;
  }

  /// One-line human reading of common schedules; anything fancy falls back
  /// to the raw expression.
  String _humanHint() {
    final m = _minute.text.trim(), h = _hour.text.trim(), dom = _dom.text.trim();
    final mon = _month.text.trim(), dow = _dow.text.trim();
    final fields = [m, h, dom, mon, dow];
    for (var i = 0; i < fields.length; i++) {
      if (!_fieldOk(fields[i], i)) return '';
    }
    if (m.startsWith('*/') && h == '*' && dom == '*' && mon == '*' && dow == '*') {
      return context.l.f('cronEveryNMin', {'n': m.substring(2)});
    }
    if (h == '*' && dom == '*' && mon == '*' && dow == '*' && RegExp(r'^[0-9]+$').hasMatch(m)) {
      return context.l.f('cronHourlyAt', {'m': m.padLeft(2, '0')});
    }
    if (dom == '*' && mon == '*' && dow == '*' && RegExp(r'^[0-9]+$').hasMatch(m) && RegExp(r'^[0-9]+$').hasMatch(h)) {
      return context.l.f('cronDailyAt', {'h': h.padLeft(2, '0'), 'm': m.padLeft(2, '0')});
    }
    return '';
  }

  void _save() {
    final fields = [_minute, _hour, _dom, _month, _dow];
    for (var i = 0; i < fields.length; i++) {
      if (!_fieldOk(fields[i].text, i)) {
        setState(() => _error = context.l.t('cronBadField'));
        return;
      }
    }
    if (_command.text.trim().isEmpty || _command.text.contains('\n')) {
      setState(() => _error = context.l.t('cronBadCommand'));
      return;
    }
    Navigator.pop(
      context,
      CronEntrySpec(
        minute: _minute.text.trim(),
        hour: _hour.text.trim(),
        dayMonth: _dom.text.trim(),
        month: _month.text.trim(),
        dayWeek: _dow.text.trim(),
        command: _command.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = [
      context.l.t('cronMinute'),
      context.l.t('cronHour'),
      context.l.t('cronDom'),
      context.l.t('cronMonth'),
      context.l.t('cronDow'),
    ];
    final ctrls = [_minute, _hour, _dom, _month, _dow];
    final hint = _humanHint();
    return AlertDialog(
      title: Text(
          '${widget.existing == null ? context.l.t('cronNew') : context.l.t('cronEdit')} · ${widget.vpsName}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < 5; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(labels[i],
                            style:
                                const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: ctrls[i],
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                          ),
                          style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            if (hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(hint,
                    style: const TextStyle(fontSize: 12, color: BeacleColors.ok)),
              ),
            const SizedBox(height: 10),
            Text(context.l.t('cronCommand'),
                style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            const SizedBox(height: 4),
            TextField(
              controller: _command,
              decoration: InputDecoration(
                hintText: '/opt/beacle/backup.sh >> /var/log/backup.log 2>&1',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              ),
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
            ),
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
            onPressed: () => Navigator.pop(context), child: Text(context.l.t('cancel'))),
        SmallButton(context.l.t('save'), icon: Icons.check, onPressed: _save),
      ],
    );
  }
}
