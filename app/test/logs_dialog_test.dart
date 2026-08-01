import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/widgets/common.dart';

/// The log viewer used to size itself to its content, so every refresh that
/// returned fewer lines shrank the window under the cursor. It also only
/// loaded once, and never scrolled to new output.
void main() {
  Future<void> openDialog(WidgetTester tester, Future<String> Function() loader) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showLogsDialog(context, 'test.log', loader),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(); // route push
    await tester.pump(); // first load resolves
  }

  testWidgets('dialog size is pinned, whatever the output', (tester) async {
    var output = List.generate(200, (i) => 'line $i').join('\n');
    await openDialog(tester, () async => output);
    await tester.pump();

    final before = tester.getSize(find.byType(Dialog));
    expect(before.width, greaterThan(0));

    // A hardcopy of an idle session returns almost nothing.
    output = 'one line';
    await tester.pump(const Duration(seconds: 3)); // auto-refresh fires
    await tester.pump();

    expect(tester.getSize(find.byType(Dialog)), before,
        reason: 'window must not resize itself around the content');
  });

  testWidgets('refreshes on its own without pressing Reload', (tester) async {
    var calls = 0;
    await openDialog(tester, () async {
      calls++;
      return 'output $calls';
    });
    await tester.pump();
    expect(calls, 1);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(calls, greaterThan(1), reason: 'output should keep updating by itself');

    // Timer must not outlive the dialog.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    final after = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, after, reason: 'polling must stop once the dialog is closed');
  });

  testWidgets('follow mode can be toggled off', (tester) async {
    await openDialog(tester, () async => List.generate(200, (i) => 'line $i').join('\n'));
    await tester.pump();

    expect(find.text('Follow'), findsOneWidget);
    await tester.tap(find.text('Follow'));
    await tester.pump();
    expect(find.text('Paused'), findsOneWidget,
        reason: 'reading scrollback should not fight the auto-scroll');
  });

  testWidgets('reports how much output there is', (tester) async {
    await openDialog(tester, () async => 'a\nb\nc');
    await tester.pump();
    expect(find.text('3 lines'), findsOneWidget);
  });
}
