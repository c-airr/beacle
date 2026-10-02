import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/screens/shell.dart';

/// The sidebar is driven by a list, but jumping to a screen (Open VPS, the
/// alerts badge, KPI tiles) uses fixed indices. Removing the Processes tab
/// silently shifted Alerts from 7 to 6 and left the badge on Settings — this
/// pins the two indices to the tabs they are supposed to mean.
///
/// Since 1.2 the list holds localization keys (resolved via `L.t` at build
/// time), not English labels — keys are the stabler thing to pin.
void main() {
  test('tab order matches the indices used for navigation', () {
    final keys = [for (final item in AppShellState.items) item.$2];

    expect(keys.indexOf('navServers'), 2, reason: 'goToServer jumps to index 2');
    expect(keys.indexOf('navAlerts'), 6, reason: 'goToAlerts and the badge use index 6');
  });

  test('every tab key is unique', () {
    final keys = [
      for (final item in AppShellState.items) item.$2,
      for (final item in AppShellState.toolItems) item.$2,
    ];
    expect(keys.toSet().length, keys.length);
  });

  test('Processes is gone — it lives inside Services now', () {
    final keys = [for (final item in AppShellState.items) item.$2];
    expect(keys, contains('navServices'));
    expect(keys, isNot(contains('navProcesses')));
  });
  test('Settings closes the main list; remote tools sit apart below it', () {
    // The update banner jumps to items.length - 1 for Settings.
    expect(AppShellState.items.last.$2, 'navSettings');
    final tools = [for (final item in AppShellState.toolItems) item.$2];
    expect(tools, ['navSsh', 'navFiles'], reason: 'SSH on top, Files below it');
    for (final t in tools) {
      expect([for (final i in AppShellState.items) i.$2], isNot(contains(t)));
    }
  });
}
