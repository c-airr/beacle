import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Result of the launcher dialog: what to run, where, under which session name.
class ScreenLaunchSpec {
  final String name, dir, command;
  const ScreenLaunchSpec({required this.name, required this.dir, required this.command});
}

/// Picks a working directory and a script on the VPS, then builds the command.
/// Equivalent to doing this by hand:
///   screen -S bot
///   cd /home/ubuntu/bot-python
///   python3 main.py
Future<ScreenLaunchSpec?> showScreenLauncher(
  BuildContext context, {
  required AppState state,
  required String vpsId,
  String? fixedName,
}) {
  return showDialog<ScreenLaunchSpec>(
    context: context,
    builder: (_) => _ScreenLauncherDialog(state: state, vpsId: vpsId, fixedName: fixedName),
  );
}

/// Maps a picked file to the command that runs it. Editable afterwards — this
/// is a starting point, not a guess the user is stuck with.
String _defaultCommandFor(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.py')) return 'python3 $fileName';
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) return 'node $fileName';
  if (lower.endsWith('.ts')) return 'npx tsx $fileName';
  if (lower.endsWith('.sh')) return 'bash $fileName';
  if (lower.endsWith('.jar')) return 'java -jar $fileName';
  if (lower.endsWith('.rb')) return 'ruby $fileName';
  if (lower.endsWith('.php')) return 'php $fileName';
  return './$fileName';
}

class _ScreenLauncherDialog extends StatefulWidget {
  final AppState state;
  final String vpsId;
  final String? fixedName;
  const _ScreenLauncherDialog({required this.state, required this.vpsId, this.fixedName});

  @override
  State<_ScreenLauncherDialog> createState() => _ScreenLauncherDialogState();
}

class _ScreenLauncherDialogState extends State<_ScreenLauncherDialog> {
  FsListing? listing;
  String? error;
  bool loading = true;

  String? pickedFile; // file name inside the current directory
  final _nameCtrl = TextEditingController();
  final _cmdCtrl = TextEditingController();

  /// The working directory, as a real field. Browsing fills it in, but it is
  /// the text here that runs — "~/" means wherever the session already opens.
  final _dirCtrl = TextEditingController(text: '~/');

  @override
  void initState() {
    super.initState();
    if (widget.fixedName != null) _nameCtrl.text = widget.fixedName!;
    _browse('');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cmdCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _browse(String path) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final l = await widget.state.api.listDir(widget.vpsId, path);
      if (!mounted) return;
      setState(() {
        listing = l;
        pickedFile = null;
        loading = false;
        // Browsing is a way to fill the field, not a replacement for it.
        _dirCtrl.text = l.path;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = '$e';
        loading = false;
      });
    }
  }

  void _pickFile(FsEntry e) {
    setState(() {
      pickedFile = e.name;
      _cmdCtrl.text = _defaultCommandFor(e.name);
      if (_nameCtrl.text.isEmpty && widget.fixedName == null) {
        // Session name defaults to the folder, which is what people call these.
        final dir = listing?.path ?? '';
        final base = dir.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'session';
        _nameCtrl.text = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
      }
    });
  }

  /// Directory as typed, with the "session default" spellings normalised away.
  String get _dir {
    final d = _dirCtrl.text.trim();
    return (d == '~' || d == '~/') ? '' : d;
  }

  /// The cd line, or empty when the session's own starting directory is used.
  String get _cdLine => _dir.isEmpty ? '' : 'cd $_dir';

  // A file no longer has to be picked: the command is a text field, and
  // browsing is only a shortcut for filling it in.
  bool get _valid => _nameCtrl.text.trim().isNotEmpty && _cmdCtrl.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l = listing;
    return Dialog(
      child: Container(
        width: 720,
        height: 620,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Run in a screen session', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l == null ? '' : l.path,
              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas'),
            ),
            const SizedBox(height: 12),

            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: BeacleColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: BeacleColors.border),
                ),
                child: error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(error!, style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
                        ),
                      )
                    : loading
                        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                        : ListView(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            children: [
                              if (l != null && l.parent.isNotEmpty)
                                HoverRow(
                                  onTap: () => _browse(l.parent),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    child: Row(children: [
                                      Icon(Icons.arrow_upward, size: 15, color: BeacleColors.textDim),
                                      SizedBox(width: 12),
                                      Text('..', style: TextStyle(fontSize: 13, color: BeacleColors.textDim)),
                                    ]),
                                  ),
                                ),
                              for (final e in l?.entries ?? const <FsEntry>[])
                                HoverRow(
                                  selected: !e.isDir && e.name == pickedFile,
                                  onTap: () => e.isDir ? _browse(e.path) : _pickFile(e),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    child: Row(
                                      children: [
                                        Icon(
                                          e.isDir ? Icons.folder_outlined : Icons.description_outlined,
                                          size: 15,
                                          color: e.isDir ? BeacleColors.warn : BeacleColors.textDim,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(e.name,
                                              style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                                        ),
                                        if (!e.isDir)
                                          Text(fmtBytes(e.size),
                                              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
              ),
            ),

            const SizedBox(height: 14),
            Row(
              children: [
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _nameCtrl,
                    enabled: widget.fixedName == null,
                    decoration: const InputDecoration(labelText: 'Session name'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _dirCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Directory',
                      hintText: '~/',
                    ),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cmdCtrl,
              decoration: const InputDecoration(
                labelText: 'Command',
                hintText: 'python3 bot.py',
              ),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: BeacleColors.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: BeacleColors.border),
              ),
              child: Text(
                _valid
                    ? 'screen -S ${_nameCtrl.text.trim()}\n'
                        '${_cdLine.isEmpty ? '' : '$_cdLine\n'}'
                        '${_cmdCtrl.text.trim()}'
                    : 'Name the session and enter a command.',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.5,
                  color: _valid ? BeacleColors.ok : BeacleColors.textDim,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SmallButton('Cancel', onPressed: () => Navigator.pop(context)),
                const SizedBox(width: 10),
                SmallButton(
                  'Start',
                  icon: Icons.play_arrow,
                  color: _valid ? BeacleColors.ok : null,
                  onPressed: !_valid
                      ? null
                      : () => Navigator.pop(
                            context,
                            ScreenLaunchSpec(
                              name: _nameCtrl.text.trim(),
                              dir: _dir,
                              command: _cmdCtrl.text.trim(),
                            ),
                          ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
