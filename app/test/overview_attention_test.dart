import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/models/models.dart';
import 'package:beacle/screens/overview_screen.dart';
import 'package:beacle/state/app_state.dart';

void main() {
  testWidgets('Needs attention follows the alerts, once per problem', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.now().toUtc().toIso8601String();
    final state = AppState()..connected = true;
    state.vpsList = [
      Vps.fromJson({'id': 'a', 'name': 'web-1', 'status': 'online', 'last_seen': now}),
      Vps.fromJson({'id': 'b', 'name': 'db-1', 'status': 'offline', 'last_seen': now}),
    ];
    // 86% full, under the server's alert threshold: no alert, so nothing to flag.
    state.snapshots['a'] = VpsSnapshot.fromJson({
      'metrics': {
        'disks': [
          {'mount': '/', 'used_percent': 86.0, 'total_bytes': 100, 'used_bytes': 86}
        ]
      }
    });
    state.alerts = [
      Alert.fromJson({'id': 'x', 'vps_id': 'b', 'vps_name': 'db-1', 'type': 'agent_offline', 'severity': 'critical', 'message': 'VPS offline', 'created_at': now}),
    ];

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: OverviewScreen())),
    ));
    await tester.pump();

    expect(find.textContaining('Disk /', findRichText: true), findsNothing, reason: 'the overview has no thresholds of its own');
    expect(find.textContaining('VPS offline', findRichText: true), findsOneWidget);
    expect(find.textContaining('—  Offline', findRichText: true), findsNothing, reason: 'the offline alert already says it');
  });
}
