import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme.dart';
import '../user_config.dart';
import 'common.dart';

/// A saved command for the SSH tab.
class Snippet {
  final String id, name, command;
  const Snippet({required this.id, required this.name, required this.command});

  Snippet.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        name = j['name'] as String? ?? '',
        command = j['command'] as String? ?? '';

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'command': command};
}

/// Where snippets live. They are this computer's, like the rest of the
/// panel's settings, so they sit in settings.json; tests hand in a store that
/// keeps them in memory.
class SnippetStore {
  static const _key = 'ssh_snippets';

  List<Snippet> load() {
    final raw = UserSettings.load().raw[_key];
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) Snippet.fromJson(e),
    ].where((s) => s.command.isNotEmpty).toList();
  }

  void save(List<Snippet> list) {
    final s = UserSettings.load();
    s.raw[_key] = [for (final x in list) x.toJson()];
    s.save();
  }

  static const _openKey = 'ssh_snippets_open';

  /// Whether the panel shows beside the shells; open until closed once.
  bool panelOpen() => UserSettings.load().raw[_openKey] as bool? ?? true;

  void setPanelOpen(bool open) {
    final s = UserSettings.load();
    s.raw[_openKey] = open;
    s.save();
  }
}

class MemorySnippetStore extends SnippetStore {
  List<Snippet> items;
  MemorySnippetStore([List<Snippet>? initial]) : items = [...?initial];

  @override
  List<Snippet> load() => [...items];

  @override
  void save(List<Snippet> list) => items = [...list];

  bool isOpen = true;

  @override
  bool panelOpen() => isOpen;

  @override
  void setPanelOpen(bool open) => isOpen = open;
}

/// Somewhere a command can be sent: a Beacle server (as an account) or a
/// saved SSH host.
class RunTarget {
  final String label;
  final String? vpsId, user;
  final String? sshHostId;
  const RunTarget({required this.label, this.vpsId, this.user, this.sshHostId});
}

/// The snippet list beside the shells.
///
/// Clicking a snippet pastes it into the current tab without pressing Enter,
/// so it can be looked over or finished first; the play button runs it.
/// "Run on…" sends one command to several servers, each in a tab of its own.
class SnippetsPanel extends StatefulWidget {
  final SnippetStore store;

  /// Null when no shell is open: there is nothing to paste into.
  final void Function(String command)? onPaste;
  final void Function(String command)? onRun;
  final List<RunTarget> targets;
  final void Function(String command, List<RunTarget> on) onRunOn;
  final VoidCallback onClose;

  const SnippetsPanel({
    super.key,
    required this.store,
    required this.onPaste,
    required this.onRun,
    required this.targets,
    required this.onRunOn,
    required this.onClose,
  });

  @override
  State<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends State<SnippetsPanel> {
  late List<Snippet> _items = widget.store.load();

  void _put(List<Snippet> list) {
    widget.store.save(list);
    setState(() => _items = list);
  }

  Future<void> _edit(Snippet? s) async {
    final out = await showDialog<Snippet>(context: context, builder: (_) => _SnippetDialog(snippet: s));
    if (out == null || !mounted) return;
    final i = _items.indexWhere((x) => x.id == out.id);
    _put(i < 0 ? [..._items, out] : ([..._items]..[i] = out));
  }

  void _delete(Snippet s) => _put(_items.where((x) => x.id != s.id).toList());

  Future<void> _runOn(Snippet? s) async {
    final out = await showRunOnDialog(context, targets: widget.targets, snippets: _items, initial: s);
    if (out == null || !mounted) return;
    widget.onRunOn(out.command, out.on);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: BeacleColors.surface,
        border: Border(left: BorderSide(color: BeacleColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: BeacleColors.border))),
            child: Row(children: [
              Text(l.t('snipTitle'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                tooltip: l.t('snipAdd'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add, size: 17),
                onPressed: () => _edit(null),
              ),
              IconButton(
                tooltip: l.t('close'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 15),
                onPressed: widget.onClose,
              ),
            ]),
          ),
          Expanded(
            child: _items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(l.t('snipEmpty'),
                        style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [for (final s in _items) _row(s)],
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: BeacleColors.border))),
            child: SmallButton(l.t('snipRunOn'), icon: Icons.dynamic_feed_outlined, onPressed: () => _runOn(null)),
          ),
        ],
      ),
    );
  }

  Widget _row(Snippet s) {
    final l = context.l;
    return Tooltip(
      message: s.command,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: widget.onPaste == null ? null : () => widget.onPaste!(s.command),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 2),
          child: Row(children: [
            Icon(Icons.chevron_right, size: 15, color: BeacleColors.textDim),
            const SizedBox(width: 4),
            Expanded(
              child: Text(s.name.isEmpty ? s.command : s.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            ),
            IconButton(
              tooltip: l.t('snipRun'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.play_arrow_rounded, size: 17, color: BeacleColors.ok),
              onPressed: widget.onRun == null ? null : () => widget.onRun!(s.command),
            ),
            PopupMenuButton<String>(
              tooltip: '',
              color: BeacleColors.surfaceHi,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_vert, size: 15, color: BeacleColors.textDim),
              onSelected: (v) => switch (v) {
                'on' => _runOn(s),
                'edit' => _edit(s),
                _ => _delete(s),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'on', child: Text(l.t('snipRunOn'))),
                PopupMenuItem(value: 'edit', child: Text(l.t('edit'))),
                PopupMenuItem(value: 'delete', child: Text(l.t('delete'), style: TextStyle(color: BeacleColors.err))),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _SnippetDialog extends StatefulWidget {
  final Snippet? snippet;
  const _SnippetDialog({this.snippet});

  @override
  State<_SnippetDialog> createState() => _SnippetDialogState();
}

class _SnippetDialogState extends State<_SnippetDialog> {
  late final _name = TextEditingController(text: widget.snippet?.name ?? '');
  late final _command = TextEditingController(text: widget.snippet?.command ?? '');

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  void _save() {
    final cmd = _command.text.trimRight();
    if (cmd.trim().isEmpty) return;
    Navigator.pop(
      context,
      Snippet(
        id: widget.snippet?.id ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _name.text.trim(),
        command: cmd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      backgroundColor: BeacleColors.surface,
      title: Text(l.t(widget.snippet == null ? 'snipAdd' : 'edit'), style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(labelText: l.t('snipName'), hintText: 'apt upgrade'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _command,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            decoration: InputDecoration(
              labelText: l.t('snipCommand'),
              hintText: 'sudo apt update && sudo apt upgrade -y',
              alignLabelWithHint: true,
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('cancel'))),
        TextButton(onPressed: _save, child: Text(l.t('save'))),
      ],
    );
  }
}

/// Asks what to run and where. The command can be a snippet or typed in.
Future<({String command, List<RunTarget> on})?> showRunOnDialog(
  BuildContext context, {
  required List<RunTarget> targets,
  required List<Snippet> snippets,
  Snippet? initial,
}) =>
    showDialog(
      context: context,
      builder: (_) => _RunOnDialog(targets: targets, snippets: snippets, initial: initial),
    );

class _RunOnDialog extends StatefulWidget {
  final List<RunTarget> targets;
  final List<Snippet> snippets;
  final Snippet? initial;
  const _RunOnDialog({required this.targets, required this.snippets, this.initial});

  @override
  State<_RunOnDialog> createState() => _RunOnDialogState();
}

class _RunOnDialogState extends State<_RunOnDialog> {
  late final _command = TextEditingController(text: widget.initial?.command ?? '');
  final Set<int> _picked = {};

  @override
  void initState() {
    super.initState();
    _command.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final ready = _command.text.trim().isNotEmpty && _picked.isNotEmpty;
    return AlertDialog(
      backgroundColor: BeacleColors.surface,
      title: Text(l.t('snipRunOnTitle'), style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.t('snipRunOnHint'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
          const SizedBox(height: 12),
          if (widget.snippets.isNotEmpty) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in widget.snippets)
                ActionChip(
                  label: Text(s.name.isEmpty ? s.command : s.name, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _command.text = s.command,
                ),
            ]),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _command,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            decoration: InputDecoration(labelText: l.t('snipCommand'), alignLabelWithHint: true),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: Column(children: [
                for (var i = 0; i < widget.targets.length; i++)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _picked.contains(i),
                    onChanged: (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
                    title: Text(widget.targets[i].label, style: const TextStyle(fontSize: 13)),
                  ),
              ]),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('cancel'))),
        TextButton(
          onPressed: ready
              ? () => Navigator.pop(context, (
                    command: _command.text.trimRight(),
                    on: [for (final i in _picked.toList()..sort()) widget.targets[i]],
                  ))
              : null,
          child: Text(l.f('snipRunN', {'n': _picked.length})),
        ),
      ],
    );
  }
}
