import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/widgets/common.dart';

/// Tabs in a row must not move when one is picked or a count changes: the
/// Services tabs used to grow and shrink with every click and every refresh.
void main() {
  Future<Size> sizeOf(WidgetTester tester, {required bool selected, int? count}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: TabChip(label: 'processes', count: count, selected: selected, onTap: () {}),
        ),
      ),
    ));
    return tester.getSize(find.byType(TabChip));
  }

  testWidgets('picking a tab does not change its width', (tester) async {
    final plain = await sizeOf(tester, selected: false, count: 12);
    final picked = await sizeOf(tester, selected: true, count: 12);
    expect(picked, plain);
  });

  testWidgets('a count up to three digits does not change its width', (tester) async {
    final one = await sizeOf(tester, selected: false, count: 0);
    final three = await sizeOf(tester, selected: false, count: 123);
    expect(three.width, one.width);
  });
}
