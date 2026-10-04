import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/update/app_updater.dart';

/// Fixes are republished under the same version number. A build has to tell
/// that the 2.0.0 on GitHub is not the 2.0.0 it is, or it sits on a stale
/// build for good while the fixes it is waiting for are already out.
void main() {
  UpdateInfo rel(String v, String commit) => UpdateInfo(v, 'https://x/$v.zip', '', commit: commit);

  const mine = '1f1952d2d064924ffedee4a154ded16a082f79f4';
  const newer = '4c235d8aa1b2c3d4e5f60718293a4b5c6d7e8f90';

  test('a newer version wins over a rebuild', () {
    final u = AppUpdater.pickUpdate([rel('2.0.1', 'aaaaaaa1'), rel('2.0.0', newer)], '2.0.0', mine);
    expect(u!.version, '2.0.1');
    expect(u.rebuild, isFalse);
    expect(u.label, '2.0.1');
  });

  test('the same version built from another commit is offered as a rebuild', () {
    final u = AppUpdater.pickUpdate([rel('2.0.0', newer), rel('1.2.0', 'bbbbbbb2')], '2.0.0', mine);
    expect(u, isNotNull);
    expect(u!.rebuild, isTrue);
    expect(u.label, '2.0.0 (4c235d8)');
  });

  test('the build you already have is not an update', () {
    expect(AppUpdater.pickUpdate([rel('2.0.0', mine)], '2.0.0', mine), isNull);
  });

  test('a build that does not know its commit only looks for newer versions', () {
    expect(AppUpdater.pickUpdate([rel('2.0.0', newer)], '2.0.0', ''), isNull);
  });

  test('a release without a commit is never taken for a rebuild', () {
    expect(AppUpdater.pickUpdate([rel('2.0.0', 'main')], '2.0.0', mine), isNull);
  });
}
