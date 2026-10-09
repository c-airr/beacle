import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:beacle/models/models.dart';
import 'package:beacle/screens/terminal_screen.dart';
import 'package:beacle/state/app_state.dart';

void main() {
  AppState stateWith(List<Map<String, dynamic>> servers) {
    final s = AppState();
    s.vpsList = [for (final j in servers) Vps.fromJson(j)];
    for (final v in s.vpsList) {
      s.snapshots[v.id] = VpsSnapshot.fromJson(const {});
    }
    return s;
  }

  Future<GlobalKey<TerminalScreenState>> pump(WidgetTester tester, AppState state) async {
    final key = GlobalKey<TerminalScreenState>();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: Scaffold(body: TerminalScreen(key: key))),
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
}
