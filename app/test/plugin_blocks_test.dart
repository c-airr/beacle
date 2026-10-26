import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/l10n/language.dart';
import 'package:beacle/l10n/strings.dart';
import 'package:beacle/models/models.dart';
import 'package:beacle/state/app_state.dart';
import 'package:beacle/widgets/common.dart';
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

  testWidgets('a card is a titled frame around its blocks', (tester) async {
    await _pump(
        tester,
        state,
        SlotRender.fromJson({
          'plugin': 'temps',
          'blocks': [
            {
              'type': 'row',
              'children': [
                {'type': 'column', 'card': true, 'title': 'Pico', 'children': [{'type': 'label', 'text': '33.6'}]},
                {'type': 'column', 'children': [{'type': 'label', 'text': 'plain'}]},
              ],
            },
          ],
        }));
    expect(find.widgetWithText(PanelCard, 'Pico'), findsOneWidget);
    expect(find.widgetWithText(PanelCard, '33.6'), findsOneWidget);
    expect(find.widgetWithText(PanelCard, 'plain'), findsNothing, reason: 'a plain column has no frame');
    expect(find.byType(IntrinsicHeight), findsOneWidget, reason: 'tiles in a row share one height');
  });

  testWidgets('a failing view shows its error instead of blocks', (tester) async {
    await _pump(tester, state, SlotRender.fromJson({'plugin': 'temps', 'error': 'backend.lua:3: boom'}));
    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('link, toggle, select and code render; a wildcard metric finds its declaration', (tester) async {
    state.plugins = [
      {
        'id': 'disks',
        'name': 'Disks',
        'enabled': true,
        'metrics': {
          'used_*': {'label': 'Used', 'unit': '%'},
        },
      },
    ];
    state.snapshots['a'] = VpsSnapshot.fromJson({
      'metrics': {
        'plugins': {'disks.used_sda': 42.0},
      },
    });
    await _pump(
        tester,
        state,
        SlotRender.fromJson({
          'plugin': 'disks',
          'blocks': [
            {'type': 'link', 'text': 'Docs', 'url': 'https://example.com'},
            {'type': 'toggle', 'label': 'Watch', 'value': true, 'action': 'watch'},
            {'type': 'select', 'label': 'Mode', 'value': 'b', 'options': ['a', 'b'], 'action': 'mode'},
            {'type': 'code', 'text': 'line 1\nline 2'},
            {'type': 'stat', 'metric': 'used_sda'},
            {'type': 'button', 'label': 'Wipe', 'action': 'wipe', 'confirm': 'Really wipe?'},
          ],
        }));
    expect(find.text('Docs'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('b'), findsOneWidget, reason: 'the select shows its value');
    expect(find.text('line 1\nline 2'), findsOneWidget);
    expect(find.text('Used'), findsOneWidget, reason: 'label from the wildcard declaration');
    expect(find.text('42%'), findsOneWidget);
    await tester.tap(find.text('Wipe'));
    await tester.pumpAndSettle();
    expect(find.text('Really wipe?'), findsOneWidget, reason: 'confirm asks first');
    expect(tester.takeException(), isNull);
  });

  test('plugin texts win over every language', () {
    addTearDown(() => L.overrides = const {});
    L.overrides = {'navAlerts': 'Fires'};
    expect(const L(AppLanguage.pl).t('navAlerts'), 'Fires');
    expect(const L(AppLanguage.en).t('navServers'), isNot('Fires'));
  });

  testWidgets('a setup screen: a masked secret and a checklist', (tester) async {
    await _pump(
        tester,
        state,
        SlotRender.fromJson({
          'plugin': 'temps',
          'blocks': [
            {'type': 'input', 'label': 'API key', 'secret': true, 'value': 'never shown', 'action': 'set'},
            {
              'type': 'checklist',
              'label': 'Monitors',
              'options': ['Web', 'DB'],
              'values': ['Web'],
              'action': 'pick',
            },
          ],
        }));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.controller?.text, isEmpty, reason: 'a secret is never put back into the field');
    expect(find.text('Monitors'), findsOneWidget);
    final boxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
    expect(boxes.map((b) => b.value), [true, false]);
    expect(tester.takeException(), isNull);
  });
}
