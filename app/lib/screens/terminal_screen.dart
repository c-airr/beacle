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
import '../widgets/common.dart';

/// One shell on one server. The bytes travel app ⇄ backend ⇄ agent over
/// WebSockets (see backend/terminal.go); there is no SSH client and no key.
class TermSession {
  final String vpsId;
  final String vpsName;
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

  TermSession({required this.vpsId, required this.vpsName, required this.onChange}) {
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
    final url = '${backendUrl.replaceFirst('http', 'ws')}/api/vps/$vpsId/terminal?cols=$cols&rows=$rows';
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

const _theme = TerminalTheme(
  cursor: Color(0xCCF4F4F5),
  selection: Color(0x55A1A1AA),
  foreground: BeacleColors.text,
  background: BeacleColors.bg,
  black: Color(0xFF18181B),
  red: Color(0xFFF87171),
  green: Color(0xFF4ADE80),
  yellow: Color(0xFFFBBF24),
  blue: Color(0xFF60A5FA),
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: Color(0xFFE4E4E7),
  brightBlack: Color(0xFF71717A),
  brightRed: Color(0xFFFCA5A5),
  brightGreen: Color(0xFF86EFAC),
  brightYellow: Color(0xFFFDE68A),
  brightBlue: Color(0xFF93C5FD),
  brightMagenta: Color(0xFFD8B4FE),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFBBF24),
  searchHitBackgroundCurrent: Color(0xFF4ADE80),
  searchHitForeground: Color(0xFF000000),
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

  /// Opens a new shell on [vpsId] and shows it.
  void open(String vpsId) {
    final state = context.read<AppState>();
    state.bumpActivity();
    final vps = state.vpsList.where((v) => v.id == vpsId).firstOrNull;
    if (vps == null) return;
    final s = TermSession(vpsId: vps.id, vpsName: vps.name, onChange: () {
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
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: BeacleColors.border))),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [for (var i = 0; i < sessions.length; i++) _tab(i)]),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: context.l.t('sshNewSession'),
                icon: const Icon(Icons.add, size: 18),
                color: BeacleColors.surfaceHi,
                onSelected: open,
                itemBuilder: (_) => [
                  for (final v in hosts)
                    PopupMenuItem(
                      value: v.id,
                      enabled: v.online,
                      child: Row(children: [StatusDot(v.status, size: 7), const SizedBox(width: 8), Text(v.name)]),
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
              style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
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
            Text(s.vpsName,
                style: TextStyle(fontSize: 12, color: selected ? BeacleColors.text : BeacleColors.textDim)),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _closeTab(i),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 13, color: BeacleColors.textDim),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// No shell open yet: pick a server.
  Widget _picker(AppState state, List<Vps> hosts) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.terminal, size: 28, color: BeacleColors.textDim),
            const SizedBox(height: 12),
            Text(context.l.t('sshPickTitle'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(context.l.t('sshPickBody'), style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, height: 1.4)),
            const SizedBox(height: 16),
            if (hosts.isEmpty)
              Text(context.l.t('fsNoServers'), style: const TextStyle(color: BeacleColors.textDim))
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
                      Text(v.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                      const SizedBox(width: 12),
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
