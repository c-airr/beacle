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
import '../widgets/temp_login_dialog.dart';

/// One shell on one server. The bytes travel app ⇄ backend ⇄ agent over
/// WebSockets (see backend/terminal.go); there is no SSH client and no key.
class TermSession {
  final String vpsId;
  final String vpsName;

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

  TermSession({required this.vpsId, required this.vpsName, this.user = '', required this.onChange}) {
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
    final as = user.isEmpty ? '' : '&user=${Uri.encodeQueryComponent(user)}';
    final url = '${backendUrl.replaceFirst('http', 'ws')}/api/vps/$vpsId/terminal?cols=$cols&rows=$rows$as';
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

  String get label => user.isEmpty ? vpsName : '$user@$vpsName';
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

TerminalTheme get _theme => BeacleColors.isDark ? _darkTheme : _lightTheme;

final _darkTheme = TerminalTheme(
  cursor: const Color(0xCCF4F4F5),
  selection: const Color(0x55A1A1AA),
  foreground: BeaclePalette.dark.text,
  background: BeaclePalette.dark.bg,
  black: const Color(0xFF18181B),
  red: const Color(0xFFF87171),
  green: const Color(0xFF4ADE80),
  yellow: const Color(0xFFFBBF24),
  blue: const Color(0xFF60A5FA),
  magenta: const Color(0xFFC084FC),
  cyan: const Color(0xFF22D3EE),
  white: const Color(0xFFE4E4E7),
  brightBlack: const Color(0xFF71717A),
  brightRed: const Color(0xFFFCA5A5),
  brightGreen: const Color(0xFF86EFAC),
  brightYellow: const Color(0xFFFDE68A),
  brightBlue: const Color(0xFF93C5FD),
  brightMagenta: const Color(0xFFD8B4FE),
  brightCyan: const Color(0xFF67E8F9),
  brightWhite: const Color(0xFFFFFFFF),
  searchHitBackground: const Color(0xFFFBBF24),
  searchHitBackgroundCurrent: const Color(0xFF4ADE80),
  searchHitForeground: const Color(0xFF000000),
);

/// ANSI colours dark enough to read on a pale background — the bright
/// variants of a dark-theme palette would vanish on it.
const _lightTheme = TerminalTheme(
  cursor: Color(0xCC24292F),
  selection: Color(0x4D6E7781),
  foreground: Color(0xFF24292F),
  background: Color(0xFFF3F4F6),
  black: Color(0xFF24292F),
  red: Color(0xFFCF222E),
  green: Color(0xFF116329),
  yellow: Color(0xFF7D4E00),
  blue: Color(0xFF0969DA),
  magenta: Color(0xFF8250DF),
  cyan: Color(0xFF1B7C83),
  white: Color(0xFF6E7781),
  brightBlack: Color(0xFF57606A),
  brightRed: Color(0xFFA40E26),
  brightGreen: Color(0xFF1A7F37),
  brightYellow: Color(0xFF633C01),
  brightBlue: Color(0xFF218BFF),
  brightMagenta: Color(0xFFA475F9),
  brightCyan: Color(0xFF3192AA),
  brightWhite: Color(0xFF8C959F),
  searchHitBackground: Color(0xFFFFDF5D),
  searchHitBackgroundCurrent: Color(0xFF4AC26B),
  searchHitForeground: Color(0xFF24292F),
);

/// The SSH tab: shells on your servers, one per tab.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => TerminalScreenState();
}

class TerminalScreenState extends State<TerminalScreen> {
  final List<TermSession> sessions = [];
  int active = 0;

  /// Accounts each server offers, by VPS id. An empty list is an agent
  /// without the picker, which opens root shells only.
  final Map<String, TerminalUsers> _users = {};
  final Map<String, Future<TerminalUsers>> _usersLoading = {};

  static const _userKey = 'terminal_user';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final v in _hosts(context.read<AppState>())) {
        if (v.online) _loadUsers(v.id);
      }
    });
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
    final s = TermSession(vpsId: vps.id, vpsName: vps.name, user: user, onChange: () {
      if (mounted) setState(() {});
    });
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
    if (sessions.isEmpty) return _picker(state, hosts);

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
              PopupMenuButton<(String, String?)>(
                tooltip: context.l.t('sshNewSession'),
                icon: const Icon(Icons.add, size: 18),
                color: BeacleColors.surfaceHi,
                onSelected: (p) => open(p.$1, user: p.$2),
                itemBuilder: (_) => [
                  for (final v in hosts)
                    // One entry per account where the server offers a choice.
                    for (final u in _accounts(v.id))
                      PopupMenuItem(
                        value: (v.id, u),
                        enabled: v.online,
                        child: Row(children: [
                          StatusDot(v.status, size: 7),
                          const SizedBox(width: 8),
                          Text(u == null ? v.name : '$u@${v.name}'),
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

  /// Which account the row opens as, switchable where there is a choice.
  Widget _userChip(Vps v) {
    final users = _users[v.id]?.users ?? const <String>[];
    final current = _userFor(v.id);
    final label = Text(current.isEmpty ? 'root' : current,
        style: TextStyle(fontSize: 12, fontFamily: 'Consolas', color: BeacleColors.text));
    if (users.length < 2 || !v.online) {
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: label);
    }
    return PopupMenuButton<String>(
      tooltip: context.l.t('sshAs'),
      color: BeacleColors.surfaceHi,
      onSelected: (u) => _pickUser(v.id, u),
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
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: BeacleColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.person_outline, size: 13, color: BeacleColors.textDim),
          const SizedBox(width: 4),
          label,
          Icon(Icons.arrow_drop_down, size: 16, color: BeacleColors.textDim),
        ]),
      ),
    );
  }

  /// No shell open yet: pick a server.
  Widget _picker(AppState state, List<Vps> hosts) {
    // A server that came online after the screen opened.
    final missing = hosts.where((v) => v.online && !_users.containsKey(v.id)).map((v) => v.id).toList();
    if (missing.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) missing.forEach(_loadUsers);
      });
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.terminal, size: 28, color: BeacleColors.textDim),
            const SizedBox(height: 12),
            Text(context.l.t('sshPickTitle'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(context.l.t('sshPickBody'), style: TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
            const SizedBox(height: 16),
            if (hosts.isEmpty)
              Text(context.l.t('fsNoServers'), style: TextStyle(color: BeacleColors.textDim))
            else
              for (final v in hosts)
                HoverRow(
                  onTap: v.online ? () => open(v.id) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    child: Row(children: [
                      StatusDot(v.status),
                      const SizedBox(width: 10),
                      Expanded(child: Text(v.name, style: const TextStyle(fontSize: 13))),
                      Text(v.host, style: TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                      const SizedBox(width: 8),
                      _userChip(v),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: context.l.t('tlButton'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.key_outlined, size: 15),
                        onPressed: v.online ? () => showTempLoginDialog(context, v) : null,
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward, size: 14, color: v.online ? BeacleColors.text : BeacleColors.border),
                    ]),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
