import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/models/models.dart';
import 'package:beacle/state/app_state.dart';

Alert _alert({
  String id = 'a1',
  String vpsId = 'vps1',
  String type = 'cpu_high',
  String severity = 'warning',
  bool resolved = false,
}) =>
    Alert.fromJson({
      'id': id,
      'vps_id': vpsId,
      'vps_name': 'host',
      'type': type,
      'severity': severity,
      'message': 'CPU usage 95%',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'resolved': resolved,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('muting hides the alert from the active count', () {
    final state = AppState();
    final a = _alert();
    state.alerts = [a];

    expect(state.activeAlerts, 1);
    expect(state.isMuted(a), isFalse);

    state.toggleMute(a);

    expect(state.isMuted(a), isTrue);
    expect(state.activeAlerts, 0);
  });

  test('mute follows the condition, not the alert row', () {
    final state = AppState();
    final first = _alert(id: 'a1');
    state.alerts = [first];
    state.toggleMute(first);

    // Same host, same condition, brand new alert object after it re-fired.
    final refired = _alert(id: 'a2');
    expect(state.isMuted(refired), isTrue,
        reason: 'a re-triggered condition must stay muted');

    // Different condition on the same host is unaffected.
    expect(state.isMuted(_alert(id: 'a3', type: 'disk_high')), isFalse);
    // Same condition on another host is unaffected.
    expect(state.isMuted(_alert(id: 'a4', vpsId: 'vps2')), isFalse);
  });

  test('unmuting brings the alert back', () {
    final state = AppState();
    final a = _alert();
    state.alerts = [a];

    state.toggleMute(a);
    expect(state.activeAlerts, 0);

    state.toggleMute(a);
    expect(state.isMuted(a), isFalse);
    expect(state.activeAlerts, 1);
  });

  test('resolved alerts are never counted as active', () {
    final state = AppState();
    state.alerts = [_alert(resolved: true)];
    expect(state.activeAlerts, 0);
  });
}
