import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/state/app_state.dart';
import 'package:beacle/widgets/plugins_settings.dart';

void main() {
  testWidgets('a plugin card says what the plugin can do, worst first', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()
      ..plugins = [
        {
          'id': 'x',
          'name': 'X',
          'version': '1',
          'enabled': true,
          'review': [
            {'kind': 'agent', 'level': 'info'},
            {'kind': 'http', 'level': 'warn', 'items': ['example.com']},
            {'kind': 'exec_shell', 'level': 'danger', 'items': ['bash']},
          ],
        },
      ];
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: PluginsSettings())),
    ));
    await tester.pump();
    final shell = find.textContaining('bash');
    final send = find.textContaining('example.com');
    expect(shell, findsOneWidget);
    expect(send, findsOneWidget);
    expect(tester.getTopLeft(shell).dy, lessThan(tester.getTopLeft(send).dy), reason: 'danger is listed first');
  });
}
