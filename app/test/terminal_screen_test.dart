import 'package:flutter/material.dart';
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

  testWidgets('opening a server shows its shell in a tab', (tester) async {
    final key = await pump(tester, stateWith([
      {'id': 'a', 'name': 'web-1', 'host': '10.0.0.1', 'status': 'online'},
    ]));
    key.currentState!.open('a');
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget); // the tab
    expect(find.text('Open a shell'), findsNothing);

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
