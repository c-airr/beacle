import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/update/agent_updater.dart';

/// Which release asset a server is compared against decides whether it is told
/// to update. Comparing a machine with the binary built for a different
/// architecture compares two files that are meant to differ, so the answer is
/// "update available" forever — including immediately after updating.
void main() {
  final release = AgentReleaseInfo(
    tag: '1.0.0',
    version: '1.0.0',
    digests: const {
      'amd64': 'sha256:aaaa',
      'arm64': 'sha256:bbbb',
    },
  );

  test('each architecture is measured against its own asset', () {
    expect(release.digestFor('amd64'), 'sha256:aaaa');
    expect(release.digestFor('arm64'), 'sha256:bbbb');
  });

  test('an arm64 server running the current arm64 build needs no update', () {
    // The bug: this compared 'sha256:bbbb' against the amd64 'sha256:aaaa'
    // and reported an update after every update.
    const running = 'sha256:bbbb';
    expect(release.digestFor('arm64') == running, isTrue,
        reason: 'an up-to-date arm64 agent must match its own asset');
  });

  test('an out-of-date agent is still caught', () {
    expect(release.digestFor('arm64') == 'sha256:old', isFalse);
    expect(release.digestFor('amd64') == 'sha256:old', isFalse);
  });

  test('an agent too old to report its architecture falls back to amd64', () {
    // Agents predating the arch field report an empty string; the fleet was
    // implicitly assumed to be amd64 before, so that stays the assumption.
    expect(release.digestFor(''), 'sha256:aaaa');
  });

  test('an unknown architecture falls back rather than returning nothing', () {
    // A digest of null drops the check through to comparing version numbers,
    // which is a worse answer than assuming the common case.
    expect(release.digestFor('riscv64'), 'sha256:aaaa');
  });

  test('a release with no digests at all reports none', () {
    final bare = AgentReleaseInfo(tag: '1.0.0', version: '1.0.0');
    expect(bare.digestFor('amd64'), isNull);
    expect(bare.digests, isEmpty);
  });
}
