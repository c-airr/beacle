import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// The reverse proxy site editor: a form that replaces editing a Caddyfile by
/// hand. Shows the config it will generate, so nothing about the result is a
/// surprise.
Future<bool> showProxySiteForm(
  BuildContext context, {
  required AppState state,
  required Vps vps,
  ProxySite? existing,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ProxySiteForm(state: state, vps: vps, existing: existing),
  );
  return saved ?? false;
}

class _ProxySiteForm extends StatefulWidget {
  final AppState state;
  final Vps vps;
  final ProxySite? existing;
  const _ProxySiteForm({required this.state, required this.vps, this.existing});

  @override
  State<_ProxySiteForm> createState() => _ProxySiteFormState();
}

class _ProxySiteFormState extends State<_ProxySiteForm> {
  late final _domain = TextEditingController(text: widget.existing?.domain ?? '');
  late final _upstream = TextEditingController(text: widget.existing?.upstream ?? '');
  late final _authUser = TextEditingController(text: widget.existing?.basicAuthUser ?? '');
  late final _authHash = TextEditingController(text: widget.existing?.basicAuthHash ?? '');

  late bool _ssl = widget.existing == null ? true : widget.existing!.ssl != 'disabled';
  late bool _redirectWww = widget.existing?.redirectWww ?? false;
  late bool _webSocket = widget.existing?.webSocket ?? false;
  late bool _gzip = widget.existing?.gzip ?? false;
  late bool _accessLog = widget.existing?.accessLog ?? false;
  late Map<String, String> _headers = {...?widget.existing?.headers};

  /// Raw mode edits the block as text instead of through the fields. It is the
  /// only way to touch config the form cannot model, so sites flagged
  /// non-editable open straight into it — as do sites already written by hand,
  /// where regenerating from the fields would throw the user's work away.
  late final _rawCtl = TextEditingController(
      text: widget.existing != null && widget.existing!.rawConfig.isNotEmpty
          ? widget.existing!.rawConfig
          : _preview);
  late bool _raw = widget.existing != null && (!widget.existing!.editable || widget.existing!.rawEdited);

  bool _advanced = false;
  bool _busy = false;
  String? _error;

  /// Raw editing rewrites a block in place; it needs a site that already exists.
  bool get _canEditRaw => widget.existing != null;

  @override
  void dispose() {
    _domain.dispose();
    _upstream.dispose();
    _authUser.dispose();
    _authHash.dispose();
    _rawCtl.dispose();
    super.dispose();
  }

  String get _normalizedUpstream {
    final up = _upstream.text.trim();
    if (up.isEmpty) return '';
    // Mirrors the agent: a bare port means localhost.
    if (int.tryParse(up) != null) return '127.0.0.1:$up';
    return up;
  }

  bool get _valid => _raw
      ? _rawCtl.text.trim().isNotEmpty
      : _domain.text.trim().isNotEmpty && _upstream.text.trim().isNotEmpty;

  /// Preview of what lands in the site file. Kept in step with the agent's
  /// renderer — this is the whole point of a GUI over a config file.
  String get _preview {
    final domain = _domain.text.trim().isEmpty ? '<domain>' : _domain.text.trim();
    final up = _normalizedUpstream.isEmpty ? '<upstream>' : _normalizedUpstream;
    final b = StringBuffer();
    if (_redirectWww && !domain.startsWith('www.')) {
      b.writeln('${_ssl ? '' : 'http://'}www.$domain {');
      b.writeln('\tredir https://$domain{uri} permanent');
      b.writeln('}');
      b.writeln();
    }
    b.writeln('${_ssl ? '' : 'http://'}$domain {');
    if (_gzip) b.writeln('\tencode gzip zstd');
    if (_authUser.text.trim().isNotEmpty && _authHash.text.trim().isNotEmpty) {
      b.writeln('\tbasic_auth {');
      b.writeln('\t\t${_authUser.text.trim()} ${_authHash.text.trim()}');
      b.writeln('\t}');
    }
    if (_headers.isNotEmpty) {
      b.writeln('\theader {');
      for (final k in _headers.keys.toList()..sort()) {
        b.writeln('\t\t$k "${_headers[k]}"');
      }
      b.writeln('\t}');
    }
    if (_accessLog) {
      b.writeln('\tlog {');
      b.writeln('\t\toutput file /var/log/caddy/$domain.log');
      b.writeln('\t}');
    }
    if (_webSocket) {
      b.writeln('\treverse_proxy $up {');
      b.writeln('\t\theader_up Host {upstream_hostport}');
      b.writeln('\t\theader_up X-Real-IP {remote_host}');
      b.writeln('\t}');
    } else {
      b.writeln('\treverse_proxy $up');
    }
    b.write('}');
    return b.toString();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_raw) {
      try {
        widget.state.onUserAction();
        await widget.state.api.proxyUpdateSiteRaw(widget.vps.id, widget.existing!.id, _rawCtl.text);
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = '$e';
            _busy = false;
          });
        }
      }
      return;
    }
    final body = {
      'domain': _domain.text.trim(),
      'upstream': _upstream.text.trim(),
      'enable_ssl': _ssl,
      'redirect_www': _redirectWww,
      'websocket': _webSocket,
      'gzip': _gzip,
      'access_log': _accessLog,
      'basic_auth_user': _authUser.text.trim(),
      'basic_auth_hash': _authHash.text.trim(),
      'headers': _headers,
    };
    try {
      widget.state.onUserAction();
      if (widget.existing == null) {
        await widget.state.api.proxyAddSite(widget.vps.id, body);
      } else {
        await widget.state.api.proxyUpdateSite(widget.vps.id, widget.existing!.id, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = _modeNotice();
    return Dialog(
      child: Container(
        width: 720,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                child: Text(widget.existing == null ? 'Add site' : 'Edit ${widget.existing!.domain}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context, false)),
            ]),
            const SizedBox(height: 16),

            Flexible(
              child: SmoothSingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (notice != null) notice,
                    // The fields describe a site the form can generate. In raw
                    // mode they no longer drive the save, so they stop
                    // accepting input rather than quietly lying.
                    IgnorePointer(
                      ignoring: _raw,
                      child: Opacity(
                        opacity: _raw ? 0.4 : 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                    TextField(
                      controller: _domain,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Domain',
                        hintText: 'app.example.com',
                        helperText: 'Point this domain\'s DNS at the VPS first.',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _upstream,
                      decoration: const InputDecoration(
                        labelText: 'Forward to',
                        hintText: '3000',
                        helperText: 'A port (3000) means 127.0.0.1:3000. Full addresses also work.',
                      ),
                      style: const TextStyle(fontFamily: 'Consolas'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),

                    _switch(
                      'HTTPS',
                      'Caddy requests and renews a certificate automatically.',
                      _ssl,
                      (v) => setState(() => _ssl = v),
                    ),
                    _switch(
                      'Redirect www',
                      'Send www.${_domain.text.trim().isEmpty ? 'domain' : _domain.text.trim()} to the bare domain.',
                      _redirectWww,
                      (v) => setState(() => _redirectWww = v),
                    ),
                    _switch(
                      'WebSockets',
                      'Forward upgrade requests and the original host header.',
                      _webSocket,
                      (v) => setState(() => _webSocket = v),
                    ),
                    _switch(
                      'Compression',
                      'gzip and zstd for text responses.',
                      _gzip,
                      (v) => setState(() => _gzip = v),
                    ),

                    const SizedBox(height: 6),
                    HoverRow(
                      onTap: () => setState(() => _advanced = !_advanced),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                        child: Row(children: [
                          Icon(_advanced ? Icons.expand_less : Icons.expand_more,
                              size: 16, color: BeacleColors.textDim),
                          const SizedBox(width: 6),
                          const Text('Advanced',
                              style: TextStyle(fontSize: 12, color: BeacleColors.textDim, letterSpacing: 0.3)),
                        ]),
                      ),
                    ),
                    if (_advanced) ...[
                      _switch(
                        'Access log',
                        'Write this site\'s requests to /var/log/caddy/<domain>.log.',
                        _accessLog,
                        (v) => setState(() => _accessLog = v),
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _authUser,
                            decoration: const InputDecoration(labelText: 'Basic auth user'),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _authHash,
                            decoration: const InputDecoration(
                              labelText: 'Password hash',
                              hintText: r'$2a$14$...',
                              helperText: 'From: caddy hash-password',
                            ),
                            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      _HeaderEditor(
                        headers: _headers,
                        onChanged: (h) => setState(() => _headers = h),
                      ),
                    ],
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),
                    Row(children: [
                      Text(_raw ? 'SITE CONFIG' : 'GENERATED CONFIG',
                          style: const TextStyle(
                              fontSize: 11,
                              color: BeacleColors.textDim,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4)),
                      const Spacer(),
                      // Sites the form cannot model have nothing to go back to,
                      // so they stay in raw mode instead of offering a switch
                      // that would rewrite them into something plainer.
                      if (_canEditRaw && (widget.existing!.editable || widget.existing!.managed))
                        SmallButton(
                          _raw ? 'Back to form' : 'Edit as config',
                          icon: _raw ? Icons.tune : Icons.code,
                          onPressed: () => setState(() {
                            _raw = !_raw;
                            if (_raw) _rawCtl.text = _preview;
                          }),
                        ),
                    ]),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: BeacleColors.bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _raw ? BeacleColors.accent : BeacleColors.border),
                      ),
                      child: _raw
                          ? TextField(
                              controller: _rawCtl,
                              maxLines: null,
                              minLines: 8,
                              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.5),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: (_) => setState(() {}),
                            )
                          : SelectableText(
                              _preview,
                              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.5),
                            ),
                    ),
                  ],
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: BeacleColors.err, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SmallButton('Cancel', onPressed: _busy ? null : () => Navigator.pop(context, false)),
                const SizedBox(width: 10),
                if (_busy)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  SmallButton(
                    widget.existing == null ? 'Create site' : 'Save',
                    icon: Icons.check,
                    color: _valid ? BeacleColors.ok : null,
                    onPressed: _valid ? _save : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Says what Save is about to do, which is a different answer per mode: the
  /// form rewrites the block from the fields, raw mode swaps the text in place.
  Widget? _modeNotice() {
    final s = widget.existing;
    if (_raw) {
      if (s == null) return null;
      return _notice(
        Icons.code,
        BeacleColors.accent,
        'Saved exactly as written, into ${s.sourceFile.isEmpty ? 'this site\'s config file' : s.sourceFile}. '
        'Only this block changes — the rest of the file is left alone. Caddy checks the result '
        'first, and if it will not load, the previous config is put back.',
      );
    }
    if (s != null && !s.managed) {
      return _notice(
        Icons.warning_amber_rounded,
        BeacleColors.warn,
        'This site lives in ${s.sourceFile}. Saving moves it into Beacle\'s own config and '
        'rewrites the block from the fields above — anything not shown here is lost. '
        'Use "Edit as config" below to change it where it is instead.',
      );
    }
    // Going back to the form on a block someone wrote by hand throws that work
    // away just as surely, so it gets the same warning.
    if (s != null && s.rawEdited) {
      return _notice(
        Icons.warning_amber_rounded,
        BeacleColors.warn,
        'This block was written by hand. Saving from the form rebuilds it from these fields '
        'and discards everything you typed — switch back to "Edit as config" to keep it.',
      );
    }
    return null;
  }

  Widget _notice(IconData icon, Color color, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 11, color: color, height: 1.45)),
          ),
        ],
      ),
    );
  }

  Widget _switch(String label, String detail, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Free-form response headers, e.g. HSTS.
class _HeaderEditor extends StatefulWidget {
  final Map<String, String> headers;
  final ValueChanged<Map<String, String>> onChanged;
  const _HeaderEditor({required this.headers, required this.onChanged});

  @override
  State<_HeaderEditor> createState() => _HeaderEditorState();
}

class _HeaderEditorState extends State<_HeaderEditor> {
  final _key = TextEditingController();
  final _value = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  void _add() {
    final k = _key.text.trim();
    final v = _value.text.trim();
    if (k.isEmpty || v.isEmpty) return;
    widget.onChanged({...widget.headers, k: v});
    _key.clear();
    _value.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Response headers',
            style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
        const SizedBox(height: 8),
        for (final e in widget.headers.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(
                child: Text('${e.key}: ${e.value}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14, color: BeacleColors.err),
                onPressed: () {
                  final next = {...widget.headers}..remove(e.key);
                  widget.onChanged(next);
                },
              ),
            ]),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _key,
              decoration: const InputDecoration(hintText: 'Strict-Transport-Security'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _value,
              decoration: const InputDecoration(hintText: 'max-age=31536000'),
              style: const TextStyle(fontSize: 12),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          SmallButton('Add', icon: Icons.add, onPressed: _add),
        ]),
      ],
    );
  }
}
