import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'screens/files_screen.dart';
import 'screens/terminal_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'window_control.dart';

/// "Separate window" mode for SSH and Files.
///
/// A second window is a second Beacle process started with `--tool=ssh` or
/// `--tool=files`. It talks to the same local backend as the main window, so
/// it needs no native multi-window support and no plugin. The main window
/// keeps the process and sends it commands on stdin, one per line:
///   `open <vpsId>`  open a shell on that server (SSH)
///   `focus`         bring the window to the front
/// When stdin closes — the main window quit — the tool window quits too.
class ToolWindows {
  ToolWindows._();

  static final Map<String, Process> _running = {};

  /// Shows the [tool] window ('ssh' or 'files'), starting it if needed, and
  /// for SSH opens a shell on [vpsId].
  static Future<void> open(String tool, {String? vpsId}) async {
    final p = _running[tool];
    if (p != null) {
      try {
        WindowControl.allowForeground(p.pid);
        p.stdin.writeln(vpsId != null ? 'open $vpsId' : 'focus');
        await p.stdin.flush();
        return;
      } catch (_) {
        _running.remove(tool); // it died between the check and the write
      }
    }
    final proc = await Process.start(Platform.resolvedExecutable, [
      '--tool=$tool',
      if (vpsId != null) '--vps=$vpsId',
    ]);
    _running[tool] = proc;
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    unawaited(proc.exitCode.then((_) {
      if (identical(_running[tool], proc)) _running.remove(tool);
    }));
  }

  /// Closes every tool window (the main window is quitting).
  static void closeAll() {
    for (final p in _running.values) {
      p.stdin.close().ignore();
    }
    _running.clear();
  }
}

/// `--tool=…` and `--vps=…` from the command line, or null.
String? argValue(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('$name=')) return a.substring(name.length + 1);
  }
  return null;
}

/// Entry point of a tool window process.
void runToolWindow(String tool, String? vpsId) {
  final state = AppState();
  unawaited(state.startViewer());
  runApp(ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      title: 'Beacle',
      debugShowCheckedModeBanner: false,
      theme: beacleTheme(),
      home: _ToolWindow(tool: tool, initialVps: vpsId),
    ),
  ));
}

class _ToolWindow extends StatefulWidget {
  final String tool;
  final String? initialVps;
  const _ToolWindow({required this.tool, this.initialVps});

  @override
  State<_ToolWindow> createState() => _ToolWindowState();
}

class _ToolWindowState extends State<_ToolWindow> {
  final _terminal = GlobalKey<TerminalScreenState>();
  StreamSubscription? _commands;
  bool _titled = false;

  bool get _ssh => widget.tool == 'ssh';

  @override
  void initState() {
    super.initState();
    _commands = stdin.transform(utf8.decoder).transform(const LineSplitter()).listen(
      _command,
      // The main window is gone; nothing here works without it.
      onDone: () => exit(0),
      onError: (_) {},
    );
    if (widget.initialVps != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openWhenKnown(widget.initialVps!));
    }
  }

  @override
  void dispose() {
    _commands?.cancel();
    super.dispose();
  }

  void _command(String line) {
    final parts = line.trim().split(' ');
    switch (parts.first) {
      case 'open':
        if (parts.length > 1) _openWhenKnown(parts[1]);
        WindowControl.focus();
      case 'focus':
        WindowControl.focus();
    }
  }

  /// The server list arrives a moment after start; wait for it.
  Future<void> _openWhenKnown(String vpsId) async {
    final state = context.read<AppState>();
    for (var i = 0; i < 50 && !state.vpsList.any((v) => v.id == vpsId); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    _terminal.currentState?.open(vpsId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_titled) {
      _titled = true;
      final name = context.l.t(_ssh ? 'navSsh' : 'navFiles');
      WidgetsBinding.instance.addPostFrameCallback((_) => WindowControl.setTitle('Beacle — $name'));
    }
    return Scaffold(
      backgroundColor: BeacleColors.bg,
      body: _ssh ? TerminalScreen(key: _terminal) : const FilesScreen(),
    );
  }
}
