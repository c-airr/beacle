import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/update/app_updater.dart';

void main() {
  test('test builds are never offered as updates', () {
    bool t(String tag, [String name = '', bool pre = false]) =>
        AppUpdater.isTestRelease({'tag_name': tag, 'name': name, 'prerelease': pre});

    expect(t('2.0.1-test1'), isTrue);
    expect(t('2.0.1', 'Beacle 2.0.1 TEST'), isTrue, reason: 'title alone is enough');
    expect(t('2.1.0-beta2'), isTrue);
    expect(t('2.1.0-rc1'), isTrue);
    expect(t('2.0.1', 'Beacle 2.0.1', true), isTrue, reason: 'marked pre-release on GitHub');

    expect(t('2.0.0', 'Beacle 2.0.0'), isFalse);
    expect(t('2.0.1', 'Beacle 2.0.1 — sources and fixes'), isFalse, reason: 'no false hit inside words');
  });
}
