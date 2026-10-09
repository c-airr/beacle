import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/user_config.dart';

void main() {
  test('a setup from before Files carries its SSH choice over to Files', () {
    final cfg = UserConfig.fromJson({'onboarding_complete': true, 'ssh_display_mode': 'split_view'});
    expect(cfg.sshDisplayMode, SshDisplayMode.splitView);
    expect(cfg.filesDisplayMode, SshDisplayMode.splitView);
  });

  test('SSH and Files keep separate choices once both are saved', () {
    final cfg = UserConfig.fromJson(UserConfig(
      onboardingComplete: true,
      sshDisplayMode: SshDisplayMode.fullscreen,
      filesDisplayMode: SshDisplayMode.separateWindow,
    ).toJson());
    expect(cfg.sshDisplayMode, SshDisplayMode.fullscreen);
    expect(cfg.filesDisplayMode, SshDisplayMode.separateWindow);
  });

  test('SSH and Files open full screen until the user picks otherwise', () {
    expect(UserConfig().sshDisplayMode, SshDisplayMode.fullscreen);
    expect(UserConfig().filesDisplayMode, SshDisplayMode.fullscreen);
    final cfg = UserConfig.fromJson({'onboarding_complete': true});
    expect(cfg.sshDisplayMode, SshDisplayMode.fullscreen);
    expect(cfg.filesDisplayMode, SshDisplayMode.fullscreen);
  });
}
