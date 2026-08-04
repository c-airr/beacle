import 'dart:io';

import 'package:flutter/foundation.dart';

/// Launch-at-login via the per-user Run key. HKCU needs no elevation, and
/// removing the value is all an uninstall has to do.
class Autostart {
  Autostart._();

  static const _keyPath = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'Beacle';

  static bool get supported => Platform.isWindows;

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    try {
      final r = await Process.run('reg', ['query', _keyPath, '/v', _valueName]);
      return r.exitCode == 0 && '${r.stdout}'.contains(_valueName);
    } catch (_) {
      return false;
    }
  }

  /// Whether the registered command starts the app straight into the tray.
  static Future<bool> isMinimised() async {
    if (!supported) return false;
    try {
      final r = await Process.run('reg', ['query', _keyPath, '/v', _valueName]);
      return r.exitCode == 0 && '${r.stdout}'.contains('--minimised');
    } catch (_) {
      return false;
    }
  }

  /// [minimised] appends the flag the runner looks for at launch. It lives in
  /// the registry command rather than in settings because the window is created
  /// before Dart could read a setting and say otherwise.
  static Future<bool> setEnabled(bool on, {bool minimised = false}) async {
    if (!supported) return false;
    try {
      if (!on) {
        final r = await Process.run('reg', ['delete', _keyPath, '/v', _valueName, '/f']);
        // Deleting a value that was never there is success as far as we care.
        return r.exitCode == 0 || !await isEnabled();
      }
      final exe = Platform.resolvedExecutable;
      final command = minimised ? '"$exe" --minimised' : '"$exe"';
      final r = await Process.run(
        'reg',
        ['add', _keyPath, '/v', _valueName, '/t', 'REG_SZ', '/d', command, '/f'],
      );
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('beacle: autostart toggle failed: $e');
      return false;
    }
  }
}
