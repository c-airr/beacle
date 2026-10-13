import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:beacle/models/models.dart';
import 'package:beacle/screens/terminal_screen.dart';
import 'package:beacle/state/app_state.dart';
import 'package:beacle/widgets/ssh_snippets.dart';

void main() {
  AppState stateWith(List<Map<String, dynamic>> servers) {
    final s = AppState();
    s.vpsList = [for (final j in servers) Vps.fromJson(j)];
    for (final v in s.vpsList) {
      s.snapshots[v.id] = VpsSnapshot.fromJson(const {});
    }
    return s;
  }

  Future<GlobalKey<TerminalScreenState>> pump(WidgetTester tester, AppState state, {SnippetStore? snippets}) async {
    final key = GlobalKey<TerminalScreenState>();
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: Scaffold(body: TerminalScreen(key: key, snippets: snippets ?? MemorySnippetStore()))),
    ));
    return key;
  }

  testWidgets('with no shell open, the tab asks which server', (tester) async {
    await pump(tester, stateWith([
      {'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'},
      {'id': 'b', 'name': 'db-1', 'host': '10.0.0.2', 'status': 'offline'},
    ]));
    expect(find.text('Open a shell'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
  });

  testWidgets('the + tile opens the host form beside the grid, not over it', (tester) async {
    await pump(tester, stateWith([
      {'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'},
    ]));
    expect(find.text('Private key'), findsNothing);
    await tester.tap(find.text('New host'));
    await tester.pumpAndSettle();
    expect(find.text('Private key'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget, reason: 'the grid stays in view');

    // Saving without a host says what is missing instead of calling out.
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter the host and the user.'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Private key'), findsNothing);
  });

  testWidgets('opening a server shows its shell in a tab', (tester) async {
    final key = await pump(tester, stateWith([
      {'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'},
    ]));
    key.currentState!.open('a');
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget); // the tab
    expect(find.text('Open a shell'), findsNothing);

    // Typing reaches the shell. Keys come straight from the keyboard: xterm's
    // text input connection is refused on Windows (no view id).
    final typed = <String>[];
    key.currentState!.sessions.first.terminal.onOutput = typed.add;
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(typed.join(), 'ls\r');

    key.currentState!.open('a');
    await tester.pump();
    // Background tabs stay alive offstage in the IndexedStack.
    expect(find.byType(TerminalView, skipOffstage: false), findsNWidgets(2),
        reason: 'a second shell on the same box is a second tab');
    expect(find.text('web-1'), findsNWidgets(2));

    // Let AppState's idle timer (armed by open) run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('a snippet added in the panel is listed and kept', (tester) async {
    final store = MemorySnippetStore();
    await pump(tester, stateWith([]), snippets: store);
    expect(find.text('Snippets'), findsOneWidget);

    await tester.tap(find.byTooltip('New snippet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'disk');
    await tester.enterText(find.widgetWithText(TextField, 'Command'), 'df -h');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('disk'), findsOneWidget);
    expect(store.items.single.command, 'df -h');

    // Closing the panel is remembered.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('disk'), findsNothing);
    expect(store.isOpen, isFalse);
  });

  testWidgets('a snippet is pasted into the current tab, or run with ▶', (tester) async {
    final store = MemorySnippetStore([const Snippet(id: '1', name: 'up', command: 'uptime')]);
    final key = await pump(tester, stateWith([
      {'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'},
    ]), snippets: store);
    key.currentState!.open('a');
    await tester.pump();

    final sent = <String>[];
    key.currentState!.sessions.first.terminal.onOutput = sent.add;
    await tester.tap(find.text('up'));
    await tester.pump();
    expect(sent.join(), 'uptime', reason: 'a click pastes without pressing Enter');

    sent.clear();
    await tester.tap(find.byTooltip('Run in this tab'));
    await tester.pump();
    expect(sent.join(), 'uptime\r');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('a queued command waits until the shell has gone quiet', (tester) async {
    final s = TermSession(vpsId: 'a', name: 'web-1', onChange: () {});
    final sent = <String>[];
    s.terminal.onOutput = sent.add;

    s.runWhenReady('apt update');
    await tester.pump(const Duration(seconds: 2));
    expect(sent, isEmpty, reason: 'nothing has come from the shell yet');

    s.debugShellOutput(); // login message
    await tester.pump(const Duration(milliseconds: 300));
    s.debugShellOutput(); // prompt
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, isEmpty, reason: 'still printing');

    await tester.pump(const Duration(milliseconds: 300));
    expect(sent.join(), 'apt update\r');

    sent.clear();
    s.debugShellOutput(); // the command's own output
    await tester.pump(const Duration(seconds: 1));
    expect(sent, isEmpty, reason: 'runs once');
  });
}
