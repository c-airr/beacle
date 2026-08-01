import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/screens/shell.dart';

/// The sidebar is driven by a list, but jumping to a screen (Open VPS, the
/// alerts badge, KPI tiles) uses fixed indices. Removing the Processes tab
/// silently shifted Alerts from 7 to 6 and left the badge on Settings — this
/// pins the two indices to the labels they are supposed to mean.
void main() {
  test('tab order matches the indices used for navigation', () {
    final labels = [for (final item in AppShellState.items) item.$2];

    expect(labels.indexOf('Servers'), 2, reason: 'goToServer jumps to index 2');
    expect(labels.indexOf('Alerts'), 6, reason: 'goToAlerts and the badge use index 6');
  });

  test('every tab label is unique', () {
    final labels = [for (final item in AppShellState.items) item.$2];
    expect(labels.toSet().length, labels.length);
  });

  test('Processes is gone — it lives inside Services now', () {
    final labels = [for (final item in AppShellState.items) item.$2];
    expect(labels, contains('Services'));
    expect(labels, isNot(contains('Processes')));
  });
}
