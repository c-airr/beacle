import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/l10n/language.dart';
import 'package:beacle/l10n/strings.dart';
import 'package:beacle/models/models.dart';
import 'package:beacle/state/app_state.dart';
import 'package:beacle/widgets/plugin_blocks.dart';

Future<void> _pump(WidgetTester tester, AppState state, SlotRender render) async {
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, child: PluginBlocks(render: render, vpsId: 'a', onAction: () {})),
      ),
    ),
  ));
}

void main() {
  late AppState state;
  setUp(() {
    state = AppState();
    state.plugins = [
      {
        'id': 'temps',
        'name': 'Temps',
        'enabled': true,
        'metrics': {
          'cpu_temp': {'label': 'CPU', 'unit': '°C', 'warn': 60},
        },
      },
    ];
    state.snapshots['a'] = VpsSnapshot.fromJson({
      'metrics': {
        'plugins': {'temps.cpu_temp': 61.5},
      },
    });
  });

  testWidgets('blocks render, a bare metric name means the plugin\'s own', (tester) async {
    await _pump(
        tester,
        state,
        SlotRender.fromJson({
          'plugin': 'temps',
          'blocks': [
            {'type': 'label', 'text': 'hello'},
            {
              'type': 'row',
              'children': [
                {'type': 'stat', 'metric': 'cpu_temp'},
                {'type': 'bar', 'label': 'fan', 'value': 40},
              ],
            },
            {
              'type': 'table',
              'columns': ['sensor', 'value'],
              'rows': [
                ['core0', '55'],
              ],
            },
            {'type': 'something_newer', 'text': 'invisible'},
          ],
        }));
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget, reason: 'label taken from the manifest');
    expect(find.text('61.5°C'), findsOneWidget, reason: 'live value from the snapshot');
    expect(find.text('fan'), findsOneWidget);
    expect(find.text('core0'), findsOneWidget);
    expect(find.text('invisible'), findsNothing, reason: 'unknown blocks are skipped');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failing view shows its error instead of blocks', (tester) async {
    await _pump(tester, state, SlotRender.fromJson({'plugin': 'temps', 'error': 'backend.lua:3: boom'}));
    expect(find.textContaining('boom'), findsOneWidget);
  });

  test('plugin texts win over every language', () {
    addTearDown(() => L.overrides = const {});
    L.overrides = {'navAlerts': 'Fires'};
    expect(const L(AppLanguage.pl).t('navAlerts'), 'Fires');
    expect(const L(AppLanguage.en).t('navServers'), isNot('Fires'));
  });
}
