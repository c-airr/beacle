import 'dart:io';

import 'package:flutter/services.dart';

/// The notification-area icon.
///
/// There is no plugin behind this: the tray lives in the Windows runner
/// (`windows/runner/tray_handler.cpp`) and talks over a method channel. Plugins
/// would have been less work, but every Flutter plugin makes the Windows build
/// create symlinks, which the OS only permits with Developer Mode switched on —
/// so the app would stop building on a plain machine.
///
/// The native side owns the behaviour that has to survive a busy or wedged Dart
/// isolate: showing the window again, and quitting from the menu. Dart only
/// tells it what closing the window should do.
class Tray {
  Tray._();

  static const _channel = MethodChannel('beacle/tray');

  /// Only the Windows runner implements this so far. macOS wants an
  /// NSStatusItem and Linux an app indicator, each in its own runner.
  static bool get supported => Platform.isWindows;

  /// Whether closing the window hides it instead of ending the process.
  /// Pushed to the runner on startup and on every change, since the runner
  /// starts with it off and has no way to read settings itself.
  static Future<void> setCloseToTray(bool enabled) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('setCloseToTray', enabled);
    } on PlatformException {
      // An older beacle.exe without the tray: closing behaves normally, which
      // is a fine thing to fall back to.
    } on MissingPluginException {
      // Same, for a runner built before the channel existed.
    }
  }

  static Future<void> show() => _invoke('show');

  static Future<void> hide() => _invoke('hide');

  /// Quits for real, ignoring the close-to-tray setting.
  static Future<void> quit() => _invoke('quit');

  static Future<void> _invoke(String method) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod(method);
    } on PlatformException {
      // Nothing useful to do here — the window simply stays as it is.
    } on MissingPluginException {
      // Runner without tray support.
    }
  }
}
