import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/update/app_updater.dart';

/// Version comparison decides whether anyone is ever offered an update, so a
/// wrong answer here is silent: the button simply stays grey and nobody is
/// told why. These lock down the cases that actually turn up in this repo's
/// tags rather than the whole semver grammar.
void main() {
  int cmp(String a, String b) => AppUpdater.compareVersions(a, b);

  test('ordinary releases order by number', () {
    expect(cmp('1.0.0', '0.9.1'), greaterThan(0));
    expect(cmp('0.9.1', '0.9.2'), lessThan(0));
    expect(cmp('0.9.1', '0.9.1'), 0);
    // Ten is not one: a digit-wise comparison would get this backwards.
    expect(cmp('0.10.0', '0.9.9'), greaterThan(0));
  });

  test('a release candidate is older than the release it leads to', () {
    // The bug this guards: splitting on '-' and parsing 'rc' as 0 made these
    // two compare equal, so a machine on the RC was never offered the final
    // build — it already looked up to date.
    expect(cmp('1.0.0-rc.1', '1.0.0'), lessThan(0));
    expect(cmp('1.0.0', '1.0.0-rc.1'), greaterThan(0));
    expect(AppUpdater.isNewer('1.0.0', '1.0.0-rc.1'), isTrue);
  });

  test('release candidates order among themselves', () {
    expect(cmp('1.0.0-rc.2', '1.0.0-rc.1'), greaterThan(0));
    // Ten again, this time inside the pre-release part.
    expect(cmp('1.0.0-rc.10', '1.0.0-rc.9'), greaterThan(0));
    expect(cmp('1.0.0-rc.1', '1.0.0-rc.1'), 0);
  });

  test('a suffix without a dot still ranks below the release', () {
    // 1.0-rc1 is the shape the tag nearly shipped as; it has to keep working
    // for anyone already running it.
    expect(cmp('1.0-rc1', '1.0'), lessThan(0));
    expect(cmp('1.0.0', '1.0-rc1'), greaterThan(0));
  });

  test('a leading v and build metadata are ignored', () {
    expect(cmp('v1.0.0', '1.0.0'), 0);
    expect(cmp('1.0.0+build7', '1.0.0'), 0);
    expect(cmp('v1.0.1', '1.0.0+build7'), greaterThan(0));
  });

  test('missing trailing components read as zero', () {
    expect(cmp('1.0', '1.0.0'), 0);
    expect(cmp('1.0.1', '1.0'), greaterThan(0));
  });

  test('an unparsable tag never outranks a real one', () {
    // releases() feeds tag names straight in; a junk tag must not look newer
    // than the running build and trigger a pointless update prompt.
    expect(AppUpdater.isNewer('garbage', '0.9.1'), isFalse);
    expect(AppUpdater.isNewer('', '0.9.1'), isFalse);
  });
}
