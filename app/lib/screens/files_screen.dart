import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../native_dialogs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_editor.dart';

/// Upload chunk size. Base64 inflates it by a third and the whole thing rides
/// one JSON frame through the agent tunnel, so stay well under the agent's
/// 1 MiB cap.
const _uploadChunk = 512 << 10;

/// Remote file explorer: browse, edit text files, download and upload.
/// Everything goes through the agent, so it works the same over Tailscale
/// and WireGuard and needs no SSH keys.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

/// A running download or upload, shown in the strip at the bottom.
class _Transfer {
  final String label;
  final bool upload;
  int done = 0;
  int total;
  bool cancelled = false;
  _Transfer(this.label, this.upload, this.total);
}

class _FilesScreenState extends State<FilesScreen> {
  String? selectedId;

  /// Last directory per server, so switching hosts and back keeps your place.
  final Map<String, String> _pathByVps = {};
  FsListing? listing;
  String? _listingVps;
  bool loading = false;
  String? error;
  bool showHidden = false;
  String filter = '';
  _Transfer? transfer;
  final _pathField = TextEditingController();

  ApiClient get _api => context.read<AppState>().api;

  @override
  void dispose() {
    _pathField.dispose();
    super.dispose();
  }

  Future<void> _open(String vpsId, String path) async {
    context.read<AppState>().bumpActivity();
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final l = await _api.fsDir(vpsId, path, hidden: showHidden);
      if (!mounted || selectedId != vpsId) return;
      setState(() {
        listing = l;
        _listingVps = vpsId;
        _pathByVps[vpsId] = l.path;
        _pathField.text = l.path;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e is ApiException && e.status == 404 ? context.l.t('fsNotSupported') : '$e';
        // Keep the old listing for this host only; another host's would lie.
        if (_listingVps != vpsId) listing = null;
      });
    }
  }

  Future<void> _reload() async {
    final id = selectedId;
    if (id == null) return;
    await _open(id, listing?.path ?? _pathByVps[id] ?? '');
  }

  String _join(String dir, String name) => dir == '/' ? '/$name' : '$dir/$name';

  // --- actions ---------------------------------------------------------------

  Future<String?> _ask(String title, {String initial = '', String? hint}) async {
    final ctl = TextEditingController(text: initial);
    // Select the stem so renaming "nginx.conf" starts on "nginx".
    final dot = initial.lastIndexOf('.');
    ctl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.l.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(context.l.t('ok'))),
        ],
      ),
    );
    ctl.dispose();
    final v = r?.trim();
    if (v == null || v.isEmpty) return null;
    if (v.contains('/')) {
      if (mounted) showToast(context, context.l.t('fsNoSlash'), error: true);
      return null;
    }
    return v;
  }

  Future<void> _run(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
    }
    await _reload();
  }

  Future<void> _mkdir(String vpsId, String dir) async {
    final name = await _ask(context.l.t('fsNewFolder'));
    if (name == null) return;
    await _run(() => _api.fsMkdir(vpsId, _join(dir, name)));
  }

  Future<void> _newFile(String vpsId, String dir) async {
    final name = await _ask(context.l.t('fsNewFile'), hint: 'config.yml');
    if (name == null || !mounted) return;
    if (await showFileEditor(context, vpsId: vpsId, path: _join(dir, name), create: true)) await _reload();
  }

  Future<void> _rename(String vpsId, FsEntry e) async {
    final name = await _ask(context.l.t('fsRename'), initial: e.name);
    if (name == null || name == e.name) return;
    final dir = e.path.substring(0, e.path.length - e.name.length);
    await _run(() => _api.fsRename(vpsId, e.path, '$dir$name'));
  }

  Future<void> _delete(String vpsId, FsEntry e) async {
    var recursive = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(context.l.t('fsDeleteTitle')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(e.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                const SizedBox(height: 10),
                Text(context.l.t(e.isDir && e.link.isEmpty ? 'fsDeleteDirBody' : 'fsDeleteBody'),
                    style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                if (e.isDir && e.link.isEmpty)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: recursive,
                    onChanged: (v) => setLocal(() => recursive = v ?? false),
                    title: Text(context.l.t('fsDeleteRecursive'), style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(context.l.t('remove'), style: const TextStyle(color: BeacleColors.err))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(() => _api.fsDelete(vpsId, e.path, recursive: recursive));
  }

  Future<void> _edit(String vpsId, FsEntry e) async {
    if (e.size > fsEditorMaxBytes) {
      showToast(context, context.l.t('fsTooLarge'), error: true);
      return;
    }
    if (await showFileEditor(context, vpsId: vpsId, path: e.path)) await _reload();
  }

  Future<void> _download(String vpsId, FsEntry e) async {
    if (transfer != null) return;
    final String? dest;
    try {
      dest = await NativeDialogs.saveFile(e.name);
    } catch (err) {
      if (mounted) showToast(context, '$err', error: true);
      return;
    }
    if (dest == null || !mounted) return;
    final t = _Transfer(e.name, false, e.size);
    setState(() => transfer = t);
    final out = File(dest);
    RandomAccessFile? raf;
    try {
      raf = await out.open(mode: FileMode.write);
      var offset = 0;
      while (!t.cancelled) {
        final c = await _api.fsRead(vpsId, e.path, offset: offset);
        final bytes = base64Decode(c.data);
        await raf.writeFrom(bytes);
        offset += bytes.length;
        if (mounted) setState(() => t..done = offset..total = c.size);
        if (c.eof || bytes.isEmpty) break;
      }
      await raf.close();
      raf = null;
      if (t.cancelled) {
        await out.delete();
      } else if (mounted) {
        showToast(context, context.l.f('fsDownloaded', {'name': e.name}));
      }
    } catch (err) {
      await raf?.close();
      if (mounted) showToast(context, '$err', error: true);
    } finally {
      if (mounted) setState(() => transfer = null);
    }
  }

  Future<void> _upload(String vpsId, String dir) async {
    if (transfer != null) return;
    final List<String> paths;
    try {
      paths = await NativeDialogs.openFiles();
    } catch (err) {
      if (mounted) showToast(context, '$err', error: true);
      return;
    }
    if (paths.isEmpty || !mounted) return;
    final files = [for (final p in paths) File(p)];
    final names = {for (final e in listing?.entries ?? const <FsEntry>[]) e.name};
    for (final f in files) {
      if (!mounted) return;
      var overwrite = false;
      final name = _baseName(f.path);
      if (names.contains(name)) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(context.l.t('fsExistsTitle')),
            content: Text(context.l.f('fsExistsBody', {'name': name})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.l.t('fsSkip'))),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(context.l.t('fsOverwrite'), style: const TextStyle(color: BeacleColors.err))),
            ],
          ),
        );
        if (ok != true) continue;
        overwrite = true;
      }
      if (!await _uploadOne(vpsId, f, _join(dir, name), overwrite)) break;
    }
    await _reload();
  }

  /// Returns false when the user cancelled or it failed, which stops a batch.
  String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  Future<bool> _uploadOne(String vpsId, File f, String dest, bool overwrite) async {
    final total = await f.length();
    final label = _baseName(f.path);
    final t = _Transfer(label, true, total);
    setState(() => transfer = t);
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      var offset = 0;
      do {
        if (t.cancelled) return false;
        await raf.setPosition(offset);
        final chunk = await raf.read(_uploadChunk);
        final last = offset + chunk.length >= total;
        try {
          final (received, _) = await _api.fsUpload(vpsId, dest, offset, base64Encode(chunk),
              finalChunk: last, overwrite: overwrite);
          offset = received;
        } on ApiException catch (e) {
          // A chunk that landed but whose answer got lost: the agent says
          // where it is, so resume there instead of starting over.
          final body = e.body;
          if (e.status == 409 && body is Map && body['received'] is num) {
            offset = (body['received'] as num).toInt();
            continue;
          }
          rethrow;
        }
        if (mounted) setState(() => t.done = offset);
        if (last) break;
      } while (true);
      return true;
    } catch (e) {
      if (mounted) showToast(context, '$label: $e', error: true);
      return false;
    } finally {
      await raf?.close();
      if (mounted) setState(() => transfer = null);
    }
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hosts = state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();
    if (hosts.isEmpty) {
      return Center(child: Text(context.l.t('fsNoServers'), style: const TextStyle(color: BeacleColors.textDim)));
    }
    final vps = hosts.where((v) => v.id == selectedId).firstOrNull ?? hosts.first;
    if (selectedId != vps.id) {
      selectedId = vps.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(vps.id, _pathByVps[vps.id] ?? '');
      });
    }
    final online = vps.online && !state.isReportStale(vps);
    final l = _listingVps == vps.id ? listing : null;
    final dir = l?.path ?? '/';
    final shown = (l?.entries ?? const <FsEntry>[])
        .where((e) => filter.isEmpty || e.name.toLowerCase().contains(filter))
        .toList();

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
                    for (final v in hosts)
                      DropdownMenuItem(
                          value: v.id,
                          child: Row(children: [StatusDot(v.status, size: 7), const SizedBox(width: 8), Text(v.name)]))
                  ],
                  onChanged: (v) => setState(() => selectedId = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pathField,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.folder_open_outlined, size: 16)),
                  onSubmitted: (p) => _open(vps.id, p.trim()),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 180,
                child: TextField(
                  decoration: InputDecoration(
                      hintText: context.l.t('fsFilterHint'), prefixIcon: const Icon(Icons.search, size: 16)),
                  onChanged: (v) => setState(() => filter = v.toLowerCase()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.l.t('fsShowHidden'),
                icon: Icon(showHidden ? Icons.visibility : Icons.visibility_off_outlined,
                    size: 18, color: showHidden ? BeacleColors.text : BeacleColors.textDim),
                onPressed: () {
                  setState(() => showHidden = !showHidden);
                  _reload();
                },
              ),
              IconButton(
                tooltip: context.l.t('refresh'),
                icon: loading
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
                onPressed: loading ? null : _reload,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(child: _breadcrumb(vps.id, dir)),
              SmallButton(context.l.t('fsNewFolder'),
                  icon: Icons.create_new_folder_outlined,
                  onPressed: online && l != null ? () => _mkdir(vps.id, dir) : null),
              const SizedBox(width: 8),
              SmallButton(context.l.t('fsNewFile'),
                  icon: Icons.note_add_outlined, onPressed: online && l != null ? () => _newFile(vps.id, dir) : null),
              const SizedBox(width: 8),
              SmallButton(context.l.t('fsUpload'),
                  icon: Icons.upload_outlined,
                  onPressed: online && l != null && transfer == null ? () => _upload(vps.id, dir) : null),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: error != null && l == null
              ? Center(child: Text(error!, style: const TextStyle(color: BeacleColors.err)))
              : l == null
                  ? const SizedBox.shrink()
                  : shown.isEmpty
                      ? Center(
                          child: Text(context.l.t('fsEmpty'), style: const TextStyle(color: BeacleColors.textDim)))
                      : SmoothListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: shown.length,
                          itemBuilder: (_, i) => _row(vps.id, shown[i], online),
                        ),
        ),
        if (error != null && l != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: BeacleColors.card,
            child: Text(error!, style: const TextStyle(fontSize: 12, color: BeacleColors.err)),
          ),
        if (transfer != null) _transferStrip(transfer!),
      ],
    );
  }

  Widget _breadcrumb(String vpsId, String dir) {
    final parts = dir.split('/').where((p) => p.isNotEmpty).toList();
    Widget crumb(String label, String path) => InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _open(vpsId, path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(label, style: const TextStyle(fontSize: 13, color: BeacleColors.text)),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: [
        crumb('/', '/'),
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const Text('/', style: TextStyle(color: BeacleColors.textDim)),
          crumb(parts[i], '/${parts.sublist(0, i + 1).join('/')}'),
        ],
      ]),
    );
  }

  Widget _row(String vpsId, FsEntry e, bool online) {
    final dim = const TextStyle(fontSize: 11, color: BeacleColors.textDim);
    return HoverRow(
      onTap: () => e.isDir ? _open(vpsId, e.path) : (online ? _edit(vpsId, e) : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            Icon(
              e.isDir
                  ? Icons.folder_outlined
                  : e.link.isNotEmpty
                      ? Icons.link
                      : Icons.insert_drive_file_outlined,
              size: 16,
              color: e.isDir ? BeacleColors.accent : BeacleColors.textDim,
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 5,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: e.name, style: const TextStyle(fontSize: 13)),
                  if (e.link.isNotEmpty) TextSpan(text: '  → ${e.link}', style: dim),
                ]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: 80, child: Text(e.isDir ? '' : fmtBytes(e.size), style: dim, textAlign: TextAlign.right)),
            const SizedBox(width: 16),
            SizedBox(width: 120, child: Text(e.modTime == null ? '' : _fmtTime(e.modTime!), style: dim)),
            SizedBox(width: 80, child: Text(e.owner, style: dim, overflow: TextOverflow.ellipsis)),
            SizedBox(width: 90, child: Text(e.mode, style: dim.copyWith(fontFamily: 'monospace'))),
            PopupMenuButton<String>(
              enabled: online,
              icon: const Icon(Icons.more_horiz, size: 16, color: BeacleColors.textDim),
              tooltip: '',
              color: BeacleColors.surfaceHi,
              onSelected: (a) {
                switch (a) {
                  case 'edit':
                    _edit(vpsId, e);
                  case 'download':
                    _download(vpsId, e);
                  case 'rename':
                    _rename(vpsId, e);
                  case 'copyPath':
                    Clipboard.setData(ClipboardData(text: e.path));
                    showToast(context, context.l.t('copied'));
                  case 'delete':
                    _delete(vpsId, e);
                }
              },
              itemBuilder: (_) => [
                if (!e.isDir) PopupMenuItem(value: 'edit', child: Text(context.l.t('fsEdit'))),
                if (!e.isDir)
                  PopupMenuItem(
                      value: 'download', enabled: transfer == null, child: Text(context.l.t('fsDownload'))),
                PopupMenuItem(value: 'rename', child: Text(context.l.t('fsRename'))),
                PopupMenuItem(value: 'copyPath', child: Text(context.l.t('fsCopyPath'))),
                PopupMenuItem(
                    value: 'delete',
                    child: Text(context.l.t('remove'), style: const TextStyle(color: BeacleColors.err))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _transferStrip(_Transfer t) {
    final pct = t.total > 0 ? (t.done / t.total).clamp(0.0, 1.0) : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: BeacleColors.card,
      child: Row(
        children: [
          Icon(t.upload ? Icons.upload_outlined : Icons.download_outlined, size: 16, color: BeacleColors.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${t.label} · ${fmtBytes(t.done)} / ${fmtBytes(t.total)}', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: pct, minHeight: 3),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SmallButton(context.l.t('cancel'), onPressed: () => setState(() => t.cancelled = true)),
        ],
      ),
    );
  }
}
