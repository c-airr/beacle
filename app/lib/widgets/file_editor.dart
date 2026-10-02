import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Biggest file the editor opens; the agent refuses larger saves too.
const fsEditorMaxBytes = 2 << 20;

/// Opens a remote text file for editing. [create] starts an empty new file
/// instead of loading one. Returns true when something was saved.
Future<bool> showFileEditor(BuildContext context,
    {required String vpsId, required String path, bool create = false}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FileEditor(vpsId: vpsId, path: path, create: create),
  );
  return saved == true;
}

/// Reads a whole remote file chunk by chunk. Returns null bytes when the file
/// looks binary.
Future<(List<int>?, String)> readRemoteText(ApiClient api, String vpsId, String path) async {
  final bytes = <int>[];
  var offset = 0;
  var version = '';
  while (true) {
    final c = await api.fsRead(vpsId, path, offset: offset);
    if (offset == 0) {
      if (c.binary) return (null, c.version);
      if (c.size > fsEditorMaxBytes) throw ApiException('too large', 413);
    }
    version = c.version;
    final chunk = base64Decode(c.data);
    bytes.addAll(chunk);
    offset += chunk.length;
    if (c.eof || chunk.isEmpty) break;
  }
  return (bytes, version);
}

class _FileEditor extends StatefulWidget {
  final String vpsId, path;
  final bool create;
  const _FileEditor({required this.vpsId, required this.path, required this.create});

  @override
  State<_FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends State<_FileEditor> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String _version = '';
  String _loaded = '';
  bool _loading = true, _saving = false, _savedOnce = false;
  String? _error;

  bool get _dirty => _text.text != _loaded;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    if (widget.create) {
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (bytes, version) = await readRemoteText(context.read<AppState>().api, widget.vpsId, widget.path);
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _loading = false;
          _error = context.l.t('fsBinary');
        });
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      setState(() {
        _version = version;
        _loaded = text;
        _text.text = text;
        _loading = false;
      });
      _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException && e.status == 413 ? context.l.t('fsTooLarge') : '$e';
      });
    }
  }

  Future<void> _save({bool force = false}) async {
    if (_saving || _loading || _error != null) return;
    final api = context.read<AppState>().api;
    setState(() => _saving = true);
    try {
      var version = _version;
      if (force) {
        // Overwrite on purpose: take whatever is there now as the base.
        version = (await api.fsRead(widget.vpsId, widget.path, limit: 1)).version;
      }
      final e = await api.fsWrite(widget.vpsId, widget.path, _text.text, version: version);
      if (!mounted) return;
      setState(() {
        _version = e.version;
        _loaded = _text.text;
        _saving = false;
        _savedOnce = true;
      });
      showToast(context, context.l.t('fsSaved'));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (e.status == 409 && !force) {
        await _conflict(e.message);
      } else {
        showToast(context, e.message, error: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, '$e', error: true);
    }
  }

  /// The file changed on the server since it was opened. Neither side wins
  /// silently: reload (drop my edits) or overwrite (drop theirs).
  Future<void> _conflict(String message) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l.t('fsConflictTitle')),
        content: SizedBox(width: 420, child: Text('$message\n\n${context.l.t('fsConflictBody')}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'reload'), child: Text(context.l.t('fsReload'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'overwrite'),
              child: Text(context.l.t('fsOverwrite'), style: const TextStyle(color: BeacleColors.err))),
        ],
      ),
    );
    if (choice == 'reload') await _load();
    if (choice == 'overwrite') await _save(force: true);
  }

  Future<void> _close() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.l.t('fsUnsavedTitle')),
          content: Text(context.l.t('fsUnsavedBody')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(context.l.t('fsDiscard'), style: const TextStyle(color: BeacleColors.err))),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context, _savedOnce);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 120).clamp(520.0, 1200.0);
    final height = (screen.height - 100).clamp(380.0, 900.0);
    final lines = '\n'.allMatches(_text.text).length + 1;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.escape): () => _close(),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints.tight(Size(width, height)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.description_outlined, size: 16, color: BeacleColors.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(widget.path + (_dirty ? '  •' : ''),
                        style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  ),
                  if (_saving || _loading)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  if (!_loading && _error == null)
                    Text(context.l.f('fsLines', {'n': lines}),
                        style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  const SizedBox(width: 10),
                  SmallButton(context.l.t('fsSave'),
                      icon: Icons.save_outlined,
                      color: _dirty ? BeacleColors.ok : null,
                      onPressed: (_dirty || widget.create) && !_saving && _error == null ? () => _save() : null),
                  const SizedBox(width: 4),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _close),
                ]),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(color: BeacleColors.bg, borderRadius: BorderRadius.circular(6)),
                    child: _error != null
                        ? Center(
                            child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!,
                                textAlign: TextAlign.center, style: const TextStyle(color: BeacleColors.textDim)),
                          ))
                        : _loading
                            ? const SizedBox.shrink()
                            : TextField(
                                controller: _text,
                                focusNode: _focus,
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                keyboardType: TextInputType.multiline,
                                textAlignVertical: TextAlignVertical.top,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.all(12),
                                ),
                              ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(context.l.t('fsEditorHint'), style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
