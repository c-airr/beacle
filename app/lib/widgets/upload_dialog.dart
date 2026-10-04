import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../native_dialogs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// What the upload dialog settled on: local files, a server and a folder.
class UploadPlan {
  final String vpsId;
  final String dir;
  final List<String> files;

  /// The target folder's names, for the "already exists" question.
  final Set<String> existing;
  UploadPlan(this.vpsId, this.dir, this.files, this.existing);
}

/// The Upload button: pick files, then a server from the list and a folder on
/// it by clicking through, instead of typing a path.
Future<UploadPlan?> showUploadDialog(BuildContext context, {required String vpsId, required String dir}) =>
    showDialog<UploadPlan>(context: context, builder: (_) => _UploadDialog(vpsId: vpsId, dir: dir));

class _UploadDialog extends StatefulWidget {
  final String vpsId;
  final String dir;
  const _UploadDialog({required this.vpsId, required this.dir});

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<_UploadDialog> {
  final List<String> _files = [];
  late String _vpsId = widget.vpsId;
  FsListing? _dir;
  String? _error;
  bool _loading = false;
  int _seq = 0;
  final _pathField = TextEditingController();

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _browse(widget.dir);
  }

  @override
  void dispose() {
    _pathField.dispose();
    super.dispose();
  }

  Future<void> _browse(String path) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await _api.fsDir(_vpsId, path, hidden: true);
      if (!mounted || seq != _seq) return;
      setState(() {
        _dir = l;
        _pathField.text = l.path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = fsErrorText(L.read(context), e);
      });
    }
  }

  Future<void> _pick() async {
    try {
      final paths = await NativeDialogs.openFiles();
      if (!mounted) return;
      setState(() {
        for (final p in paths) {
          if (!_files.contains(p)) _files.add(p);
        }
      });
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
  }

  String _base(String p) => p.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final state = context.watch<AppState>();
    final hosts = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    final dir = _dir;
    final folders = (dir?.entries ?? const <FsEntry>[]).where((e) => e.isDir).toList();
    final ready = _files.isNotEmpty && dir != null && !_loading;

    return AlertDialog(
      title: Text(l.t('fsUploadTitle')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label(l.t('fsUploadFiles')),
            if (_files.isEmpty)
              Text(l.t('fsUploadNoFiles'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in _files)
                      Row(children: [
                        Icon(Icons.insert_drive_file_outlined, size: 14, color: BeacleColors.textDim),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_base(f), style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                        Text(_size(f), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                        IconButton(
                          icon: const Icon(Icons.close, size: 14),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _files.remove(f)),
                        ),
                      ]),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            SmallButton(l.t('fsUploadPick'), icon: Icons.add, onPressed: _pick),
            const SizedBox(height: 18),
            _label(l.t('fsUploadServer')),
            DropdownButtonFormField<String>(
              initialValue: hosts.any((v) => v.id == _vpsId) ? _vpsId : null,
              isExpanded: true,
              dropdownColor: BeacleColors.surfaceHi,
              items: [
                for (final v in hosts)
                  DropdownMenuItem(
                    value: v.id,
                    enabled: v.online,
                    child: Row(children: [
                      StatusDot(v.status, size: 7),
                      const SizedBox(width: 8),
                      Text(v.name, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
              ],
              onChanged: (id) {
                if (id == null || id == _vpsId) return;
                setState(() {
                  _vpsId = id;
                  _dir = null;
                });
                // Another server: start in its home folder.
                _browse('');
              },
            ),
            const SizedBox(height: 18),
            _label(l.t('fsUploadDest')),
            TextField(
              controller: _pathField,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.folder_open_outlined, size: 16),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
              onSubmitted: (p) => _browse(p.trim()),
            ),
            const SizedBox(height: 8),
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: BeacleColors.bg,
                borderRadius: BorderRadius.circular(BeacleRadius.control),
                border: Border.all(color: BeacleColors.border),
              ),
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!, style: TextStyle(fontSize: 12, color: BeacleColors.err)),
                      ),
                    )
                  : dir == null
                      ? const SizedBox.shrink()
                      : ListView(
                          padding: const EdgeInsets.all(4),
                          children: [
                            if (dir.parent.isNotEmpty) _folderRow('..', () => _browse(dir.parent), up: true),
                            for (final f in folders) _folderRow(f.name, () => _browse(f.path)),
                            if (folders.isEmpty && dir.parent.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(l.t('fsEmpty'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.t('cancel'))),
        FilledButton.icon(
          onPressed: ready
              ? () => Navigator.pop(
                    context,
                    UploadPlan(_vpsId, dir.path, List.of(_files), {for (final e in dir.entries) e.name}),
                  )
              : null,
          icon: const Icon(Icons.upload_outlined, size: 16),
          label: Text(_files.length > 1 ? l.f('fsUploadN', {'n': _files.length}) : l.t('fsUpload')),
        ),
      ],
    );
  }

  String _size(String path) {
    try {
      return fmtBytes(File(path).lengthSync());
    } catch (_) {
      return '';
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.9, color: BeacleColors.textDim)),
      );

  Widget _folderRow(String name, VoidCallback onTap, {bool up = false}) => HoverRow(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            Icon(up ? Icons.arrow_upward : Icons.folder_outlined,
                size: 15, color: up ? BeacleColors.textDim : BeacleColors.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
          ]),
        ),
      );
}

/// What to say when a file call fails. A 404 is two different things: the
/// route missing on an agent from before the file explorer (plain-text body
/// from the router), or the path not existing (a JSON error from the agent).
String fsErrorText(L l, Object e) {
  if (e is ApiException && e.status == 404) {
    return e.body is Map ? l.f('fsNotFound', {'error': e.message}) : l.t('fsNotSupported');
  }
  return '$e';
}
