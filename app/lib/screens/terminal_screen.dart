import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:xterm/xterm.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../user_config.dart';
import '../widgets/common.dart';
import '../widgets/ssh_host_panel.dart';
import '../widgets/temp_login_dialog.dart';

/// One shell on one server. The bytes travel app ⇄ backend ⇄ agent over
/// WebSockets (see backend/terminal.go), or, for a saved SSH host, app ⇄
/// backend ⇄ SSH server (backend/ssh_terminal.go). Either way the app speaks
/// the same frames and holds no key.
class TermSession {
  /// The Beacle server the shell is on; empty for a saved SSH host.
  final String vpsId;

  /// The saved SSH host the shell is on, if it is one.
  final String? sshHostId;
  final String name;

  /// Who the shell runs as; empty is the agent's own user, root.
  final String user;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  final VoidCallback onChange;

  IOWebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  // Output arrives in arbitrary byte chunks; a UTF-8 character split across
  // two frames must not turn into two replacement characters.
  StreamController<List<int>>? _bytes;
  bool connected = false;
  bool ended = false;

  TermSession({this.vpsId = '', this.sshHostId, required this.name, this.user = '', required this.onChange}) {
    terminal.onOutput = (data) => _send({'op': 'data', 'data': base64Encode(utf8.encode(data))});
    terminal.onResize = (w, h, _, __) => _send({'op': 'resize', 'cols': w, 'rows': h});
  }

  void _send(Map<String, Object> frame) {
    if (ended) return;
    _ws?.sink.add(jsonEncode(frame));
  }

  void connect() {
    _close();
    ended = false;
    final bytes = StreamController<List<int>>();
    _bytes = bytes;
    bytes.stream.transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);

    final cols = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
    final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 24;
    final base = backendUrl.replaceFirst('http', 'ws');
    final String url;
    if (sshHostId != null) {
      url = '$base/api/ssh/hosts/$sshHostId/terminal?cols=$cols&rows=$rows';
    } else {
      final as = user.isEmpty ? '' : '&user=${Uri.encodeQueryComponent(user)}';
      url = '$base/api/vps/$vpsId/terminal?cols=$cols&rows=$rows$as';
    }
    final ws = IOWebSocketChannel.connect(url);
    _ws = ws;
    connected = true;
    onChange();
    _wsSub = ws.stream.listen(
      (raw) {
        final f = jsonDecode(raw as String) as Map<String, dynamic>;
        switch (f['op']) {
          case 'data':
            bytes.add(base64Decode(f['data'] as String? ?? ''));
          case 'exit':
            _end('\r\n\x1b[2m[exit ${f['code'] ?? 0}]\x1b[0m\r\n');
          case 'error':
            _end('\r\n\x1b[31m[${f['error'] ?? 'error'}]\x1b[0m\r\n');
        }
      },
      onError: (Object e) => _end('\r\n\x1b[31m[$e]\x1b[0m\r\n'),
      onDone: () => _end(''),
    );
  }

  void _end(String note) {
    if (ended) return;
    ended = true;
    connected = false;
    if (note.isNotEmpty) _bytes?.add(utf8.encode(note));
    onChange();
  }

  void _close() {
    _wsSub?.cancel();
    _wsSub = null;
    _ws?.sink.close();
    _ws = null;
    _bytes?.close();
    _bytes = null;
  }

  /// Hangs up the shell on the server.
  void dispose() {
    _send({'op': 'close'});
    ended = true;
    _close();
  }

  String get label => user.isEmpty ? name : '$user@$name';
}

/// Copy/paste like Windows Terminal. xterm's defaults put "select all" on
/// Ctrl+A, which is beginning-of-line in bash and the prefix key in screen.
final _shortcuts = Platform.isMacOS
    ? {
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): CopySelectionTextIntent.copy,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const PasteTextIntent(SelectionChangedCause.keyboard),
      }
    : {
        const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): CopySelectionTextIntent.copy,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
            const PasteTextIntent(SelectionChangedCause.keyboard),
      };

/// Green on near-black, like Termius: the same in the light and dark app
/// themes, as a terminal window is in most SSH clients.
const _theme = TerminalTheme(
  cursor: Color(0xFF33E27A),
  selection: Color(0x5533E27A),
  foreground: Color(0xFF33E27A),
  background: Color(0xFF0A0C0B),
  black: Color(0xFF1B211D),
  red: Color(0xFFFF5C7A),
  green: Color(0xFF33E27A),
  yellow: Color(0xFFE6DB74),
  blue: Color(0xFF5FB3FF),
  magenta: Color(0xFFFF5FAF),
  cyan: Color(0xFF4FE0D0),
  white: Color(0xFFC8F5D8),
  brightBlack: Color(0xFF5C6B62),
  brightRed: Color(0xFFFF8FA3),
  brightGreen: Color(0xFF7DFFA8),
  brightYellow: Color(0xFFF4EBA0),
  brightBlue: Color(0xFF9CCFFF),
  brightMagenta: Color(0xFFFF9BCD),
  brightCyan: Color(0xFF8DF0E5),
  brightWhite: Color(0xFFF0FFF5),
  searchHitBackground: Color(0xFFE6DB74),
  searchHitBackgroundCurrent: Color(0xFF33E27A),
  searchHitForeground: Color(0xFF000000),
);

/// The SSH tab: shells on your servers, one per tab.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => TerminalScreenState();
}

/// What the new-session menu opens: a Beacle server as an account, a saved
/// SSH host, or the form for a new host.
typedef _Pick = ({String? vpsId, String? user, SshHost? saved});

class TerminalScreenState extends State<TerminalScreen> {
  final List<TermSession> sessions = [];
  int active = 0;

  /// Accounts each server offers, by VPS id. An empty list is an agent
  /// without the picker, which opens root shells only.
  final Map<String, TerminalUsers> _users = {};
  final Map<String, Future<TerminalUsers>> _usersLoading = {};

  /// Saved SSH hosts, from the backend.
  List<SshHost> _saved = [];

  /// The host panel beside the screen: open, and the host it edits (null for
  /// a new one).
  bool _panelOpen = false;
  SshHost? _editing;

  static const _userKey = 'terminal_user';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final v in _hosts(context.read<AppState>())) {
        if (v.online) _loadUsers(v.id);
      }
      _loadSaved();
    });
  }

  Future<void> _loadSaved() async {
    try {
      final list = await context.read<AppState>().api.sshHosts();
      if (mounted) setState(() => _saved = list);
    } catch (_) {
      // A backend from before saved hosts: the grid shows Beacle servers only.
    }
  }

  Future<TerminalUsers> _loadUsers(String vpsId) {
    final known = _users[vpsId];
    if (known != null) return Future.value(known);
    final api = context.read<AppState>().api;
    return _usersLoading[vpsId] ??= () async {
      var u = const TerminalUsers([], '');
      try {
        // An agent from before this route never answers it (the panel gives
        // up after 30 s); a shell should not wait that long to open.
        u = await api.terminalUsers(vpsId).timeout(const Duration(seconds: 5));
      } catch (_) {
        // An older agent: root only, as before.
      }
      _usersLoading.remove(vpsId);
      if (mounted) setState(() => _users[vpsId] = u);
      return u;
    }();
  }

  /// The account a shell on [vpsId] opens as: the one picked last time,
  /// else the server's main account (ubuntu, opc, ...), else root.
  String _userFor(String vpsId) {
    final u = _users[vpsId];
    if (u == null || u.users.isEmpty) return '';
    final saved = (UserSettings.load().raw[_userKey] as Map?)?[vpsId] as String?;
    if (saved != null && u.users.contains(saved)) return saved;
    return u.main.isNotEmpty ? u.main : u.users.first;
  }

  void _pickUser(String vpsId, String user) {
    final s = UserSettings.load();
    final m = Map<String, dynamic>.from(s.raw[_userKey] as Map? ?? {});
    m[vpsId] = user;
    s.raw[_userKey] = m;
    s.save();
    setState(() {});
  }

  /// Opens a new shell on [vpsId] and shows it, as [user] or as the account
  /// [_userFor] picks.
  Future<void> open(String vpsId, {String? user}) async {
    final state = context.read<AppState>();
    state.bumpActivity();
    final vps = state.vpsList.where((v) => v.id == vpsId).firstOrNull;
    if (vps == null) return;
    if (user == null) {
      await _loadUsers(vpsId);
      if (!mounted) return;
      user = _userFor(vpsId);
    }
    _start(TermSession(vpsId: vps.id, name: vps.name, user: user, onChange: _changed));
  }

  /// Opens a new shell on a saved SSH host.
  void openSaved(SshHost h) {
    context.read<AppState>().bumpActivity();
    _start(TermSession(sshHostId: h.id, name: h.label, user: h.user, onChange: _changed));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start(TermSession s) {
    setState(() {
      sessions.add(s);
      active = sessions.length - 1;
    });
    s.connect();
  }

  void _closeTab(int i) {
    final s = sessions[i];
    s.dispose();
    setState(() {
      sessions.removeAt(i);
      if (active >= sessions.length) active = sessions.isEmpty ? 0 : sessions.length - 1;
    });
  }

  void _editHost(SshHost? h) => setState(() {
        _panelOpen = true;
        _editing = h;
      });

  void _closePanel() => setState(() {
        _panelOpen = false;
        _editing = null;
      });

  void _hostSaved(SshHost h) {
    setState(() {
      final i = _saved.indexWhere((x) => x.id == h.id);
      if (i < 0) {
        _saved = [..._saved, h];
      } else {
        _saved = [..._saved]..[i] = h;
      }
      _panelOpen = false;
      _editing = null;
    });
  }

  Future<void> _deleteHost(SshHost h) async {
    final l = L.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BeacleColors.surface,
        content: Text(l.f('sshHostDeleteAsk', {'name': h.label})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('delete'), style: TextStyle(color: BeacleColors.err)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteSshHost(h.id);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _saved = _saved.where((x) => x.id != h.id).toList();
      if (_editing?.id == h.id) _closePanel();
    });
  }

  @override
  void dispose() {
    for (final s in sessions) {
      s.dispose();
    }
    super.dispose();
  }

  List<Vps> _hosts(AppState state) => state.vpsList.where((v) => state.snapshots.containsKey(v.id)).toList();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hosts = _hosts(state);
    final body = sessions.isEmpty ? _picker(state, hosts) : _shells(hosts);
    // The host form slides in beside whatever is showing, not over it.
    return Row(
      children: [
        Expanded(child: body),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) =>
              SizeTransition(sizeFactor: anim, axis: Axis.horizontal, alignment: Alignment.centerLeft, child: child),
          child: _panelOpen
              ? SshHostPanel(
                  key: ValueKey(_editing?.id ?? 'new'),
                  host: _editing,
                  onSaved: _hostSaved,
                  onDelete: _editing == null ? null : () => _deleteHost(_editing!),
                  onClose: _closePanel,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _shells(List<Vps> hosts) {
    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: BeacleColors.border))),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [for (var i = 0; i < sessions.length; i++) _tab(i)]),
                ),
              ),
              PopupMenuButton<_Pick>(
                tooltip: context.l.t('sshNewSession'),
                icon: const Icon(Icons.add, size: 18),
                color: BeacleColors.surfaceHi,
                onSelected: (p) {
                  if (p.vpsId != null) {
                    open(p.vpsId!, user: p.user);
                  } else if (p.saved != null) {
                    openSaved(p.saved!);
                  } else {
                    _editHost(null);
                  }
                },
                itemBuilder: (_) => [
                  for (final v in hosts)
                    // One entry per account where the server offers a choice.
                    for (final u in _accounts(v.id))
                      PopupMenuItem(
                        value: (vpsId: v.id, user: u, saved: null),
                        enabled: v.online,
                        child: Row(children: [
                          StatusDot(v.status, size: 7),
                          const SizedBox(width: 8),
                          Text(u == null ? v.name : '$u@${v.name}'),
                        ]),
                      ),
                  for (final h in _saved)
                    PopupMenuItem(
                      value: (vpsId: null, user: null, saved: h),
                      child: Row(children: [
                        Icon(Icons.vpn_key_outlined, size: 13, color: BeacleColors.textDim),
                        const SizedBox(width: 8),
                        Text('${h.user}@${h.label}'),
                      ]),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: (vpsId: null, user: null, saved: null),
                    child: Row(children: [
                      Icon(Icons.add, size: 15, color: BeacleColors.textDim),
                      const SizedBox(width: 8),
                      Text(context.l.t('sshNewHost')),
                    ]),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: active,
            children: [
              for (final s in sessions)
                Stack(
                  children: [
                    Positioned.fill(
                      child: TerminalView(
                        s.terminal,
                        controller: s.controller,
                        theme: _theme,
                        textStyle: const TerminalStyle(fontSize: 13),
                        padding: const EdgeInsets.all(8),
                        autofocus: true,
                        // xterm 4.0 attaches its text input without a view
                        // id, which Flutter on Windows rejects ("view ID is
                        // null") and no key ever arrives. Key events carry the
                        // typed character, AltGr letters included.
                        hardwareKeyboardOnly: true,
                        shortcuts: _shortcuts,
                      ),
                    ),
                    if (s.ended)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: SmallButton(context.l.t('sshReconnect'), icon: Icons.refresh, onPressed: s.connect),
                      ),
                  ],
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Text(context.l.t(Platform.isMacOS ? 'sshHintMac' : 'sshHint'),
              style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
        ),
      ],
    );
  }

  Widget _tab(int i) {
    final s = sessions[i];
    final selected = i == active;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => active = i),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
          decoration: BoxDecoration(
            color: selected ? BeacleColors.surfaceHi : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? BeacleColors.borderGlow : Colors.transparent),
          ),
          child: Row(children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: s.ended ? BeacleColors.textDim : BeacleColors.ok,
              ),
            ),
            const SizedBox(width: 8),
            Text(s.label,
                style: TextStyle(fontSize: 12, color: selected ? BeacleColors.text : BeacleColors.textDim)),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _closeTab(i),
              child: Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 13, color: BeacleColors.textDim),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// The accounts to offer for [vpsId] in the new-tab menu; a lone null is
  /// "the agent's default" for a server that offers no choice.
  List<String?> _accounts(String vpsId) {
    final u = _users[vpsId]?.users ?? const [];
    return u.length > 1 ? u : const [null];
  }

  /// Switches the account a server's tile opens as, where there is a choice.
  Widget? _userMenu(Vps v) {
    final users = _users[v.id]?.users ?? const <String>[];
    if (users.length < 2 || !v.online) return null;
    final current = _userFor(v.id);
    return PopupMenuButton<String>(
      tooltip: context.l.t('sshAs'),
      color: BeacleColors.surfaceHi,
      onSelected: (u) => _pickUser(v.id, u),
      icon: Icon(Icons.person_outline, size: 16, color: BeacleColors.textDim),
      padding: EdgeInsets.zero,
      iconSize: 16,
      itemBuilder: (_) => [
        for (final u in users)
          PopupMenuItem(
            value: u,
            child: Row(children: [
              Icon(u == current ? Icons.check : Icons.person_outline, size: 15, color: BeacleColors.textDim),
              const SizedBox(width: 8),
              Text(u, style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
              if (u == 'root') ...[
                const SizedBox(width: 8),
                Text(context.l.t('sshAsRoot'), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
              ],
            ]),
          ),
      ],
    );
  }

  /// No shell open yet: the title above, and below it every server and saved
  /// host as a tile, with a "+" tile to add one.
  Widget _picker(AppState state, List<Vps> hosts) {
    // A server that came online after the screen opened.
    final missing = hosts.where((v) => v.online && !_users.containsKey(v.id)).map((v) => v.id).toList();
    if (missing.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) missing.forEach(_loadUsers);
      });
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _theme.background,
                    borderRadius: BorderRadius.circular(BeacleRadius.control),
                  ),
                  child: Icon(Icons.terminal, size: 20, color: _theme.foreground),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.l.t('sshPickTitle'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(context.l.t('sshPickBody'),
                        style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.topLeft,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: BeacleColors.card,
                    borderRadius: BorderRadius.circular(BeacleRadius.card),
                    border: Border.all(color: BeacleColors.cardBorder),
                  ),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final v in hosts)
                          _HostTile(
                            icon: Icons.dns_outlined,
                            title: v.name,
                            subtitle: '${_userFor(v.id).isEmpty ? 'root' : _userFor(v.id)}@${v.host}',
                            status: v.status,
                            onTap: v.online ? () => open(v.id) : null,
                            actions: [
                              if (_userMenu(v) case final menu?) menu,
                              IconButton(
                                tooltip: context.l.t('tlButton'),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.key_outlined, size: 15),
                                onPressed: v.online ? () => showTempLoginDialog(context, v) : null,
                              ),
                            ],
                          ),
                        for (final h in _saved)
                          _HostTile(
                            icon: Icons.vpn_key_outlined,
                            title: h.label,
                            subtitle: h.address,
                            onTap: () => openSaved(h),
                            actions: [
                              PopupMenuButton<bool>(
                                tooltip: '',
                                color: BeacleColors.surfaceHi,
                                icon: Icon(Icons.more_vert, size: 16, color: BeacleColors.textDim),
                                padding: EdgeInsets.zero,
                                onSelected: (edit) => edit ? _editHost(h) : _deleteHost(h),
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: true, child: Text(context.l.t('edit'))),
                                  PopupMenuItem(
                                    value: false,
                                    child: Text(context.l.t('delete'), style: TextStyle(color: BeacleColors.err)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        _AddTile(onTap: () => _editHost(null)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _tileWidth = 280.0;
const _tileHeight = 68.0;

/// One server or saved host in the picker grid.
class _HostTile extends StatefulWidget {
  final IconData icon;
  final String title, subtitle;

  /// A Beacle server's status, for the dot on its icon; null for a saved host.
  final String? status;
  final VoidCallback? onTap;
  final List<Widget> actions;
  const _HostTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.status,
    this.onTap,
    this.actions = const [],
  });

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _tileWidth,
          height: _tileHeight,
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: BoxDecoration(
            color: _hover && enabled ? BeacleColors.hover : BeacleColors.surfaceHi,
            borderRadius: BorderRadius.circular(BeacleRadius.control),
            border: Border.all(color: _hover && enabled ? _theme.foreground.withValues(alpha: 0.6) : BeacleColors.border),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Row(children: [
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _theme.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(widget.icon, size: 18, color: _theme.foreground),
                ),
                if (widget.status != null)
                  Positioned(right: -2, bottom: -2, child: StatusDot(widget.status!, size: 9)),
              ]),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, fontFamily: 'Consolas', color: BeacleColors.textDim)),
                  ],
                ),
              ),
              ...widget.actions,
            ]),
          ),
        ),
      ),
    );
  }
}

/// The "+" tile: add a host the SSH client reaches directly.
class _AddTile extends StatefulWidget {
  final VoidCallback onTap;
  const _AddTile({required this.onTap});

  @override
  State<_AddTile> createState() => _AddTileState();
}

class _AddTileState extends State<_AddTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? _theme.foreground : BeacleColors.textDim;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _tileWidth,
          height: _tileHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BeacleRadius.control),
            border: Border.all(color: _hover ? _theme.foreground.withValues(alpha: 0.6) : BeacleColors.borderGlow),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add, size: 18, color: color),
            const SizedBox(width: 8),
            Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.l.t('sshNewHost'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _hover ? BeacleColors.text : color)),
              Text(context.l.t('sshNewHostSub'), style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
            ]),
          ]),
        ),
      ),
    );
  }
}
