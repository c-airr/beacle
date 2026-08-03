import 'dart:io';

import 'package:flutter/services.dart';

import 'user_config.dart';

/// The audible half of an alert. A panel that only flashes a badge is a panel
/// you have to be looking at, which defeats the point of running it on a second
/// monitor.
///
/// Uses the platform's own alert sound rather than a bundled asset: it respects
/// system volume and Do Not Disturb, needs no audio plugin, and sounds native
/// on each desktop.
class AlertSound {
  AlertSound._();

  static const _key = 'alert_sound';

  /// On by default. Someone who wants silence turns it off once; someone who
  /// misses an outage because the panel was quiet does not get that time back.
  static bool get enabled => UserSettings.load().raw[_key] != false;

  static void setEnabled(bool on) {
    final s = UserSettings.load();
    s.raw[_key] = on;
    s.save();
  }

  /// The Linux embedder has no system alert sound, so the toggle can say that
  /// plainly instead of pretending it does something.
  static bool get supported => !Platform.isLinux;

  /// Plays once for a new alert. Severity is passed in so this stays the only
  /// place deciding what is worth interrupting someone for.
  static void play(String severity) {
    if (!enabled || !supported) return;
    if (severity == 'info') return; // info is for reading, not for hearing
    SystemSound.play(SystemSoundType.alert);
  }
}
