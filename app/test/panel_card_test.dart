import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/widgets/common.dart';

/// Regression guard for the Servers screen rendering as an empty page.
///
/// PanelCard used to wrap itself in a LayoutBuilder, which cannot answer an
/// intrinsic-height query. Inside the IntrinsicHeight rows the Servers screen
/// builds, that threw in debug and silently measured 0 in release — so every
/// panel except the one outside IntrinsicHeight collapsed to nothing and the
/// screen looked empty apart from the CPU cores tile.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  testWidgets('panels in an IntrinsicHeight row keep their height', (tester) async {
    await tester.pumpWidget(host(
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            Expanded(
              child: PanelCard(expand: true, title: 'CPU', child: Text('42%')),
            ),
            SizedBox(width: 12),
            Expanded(
              child: PanelCard(
                expand: true,
                title: 'MEMORY',
                child: Column(children: [Text('line 1'), Text('line 2'), Text('line 3')]),
              ),
            ),
          ],
        ),
      ),
    ));

    final cpu = tester.getSize(find.ancestor(
      of: find.text('42%'),
      matching: find.byType(PanelCard),
    ));
    final mem = tester.getSize(find.ancestor(
      of: find.text('line 1'),
      matching: find.byType(PanelCard),
    ));

    expect(cpu.height, greaterThan(0));
    expect(cpu.width, greaterThan(0));
    // The taller card drives the row; both end up equal.
    expect(cpu.height, equals(mem.height));
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
  });

  testWidgets('a plain panel still sizes to its content', (tester) async {
    await tester.pumpWidget(host(
      const PanelCard(title: 'CPU CORES', child: Text('cpu0')),
    ));

    final size = tester.getSize(find.byType(PanelCard));
    expect(size.height, greaterThan(0));
    expect(find.text('cpu0'), findsOneWidget);
  });
}
