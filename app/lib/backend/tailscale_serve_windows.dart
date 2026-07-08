import 'dart:io';

import 'package:flutter/foundation.dart';

/// Exposes localhost:8930 to the tailnet via `tailscale serve` (Windows).
/// Direct bind on 0.0.0.0 is unreliable on Windows+Tailscale; serve proxies inbound TCP.
class TailscaleServeWindows {
  TailscaleServeWindows._();

  static const backendPort = 8930;

  static Future<void> exposeBackend() async {
    if (!Platform.isWindows) return;

    if (!await _tailscaleAvailable()) {
      debugPrint('beacle: tailscale CLI not found — agents need manual port forwarding');
      return;
    }

    if (await _alreadyServing()) {
      debugPrint('beacle: tailscale serve already exposing :$backendPort');
      return;
    }

    debugPrint('beacle: tailscale serve tcp://$backendPort -> 127.0.0.1:$backendPort');
    final r = await Process.run(
      'tailscale',
      ['serve', '--bg', '--yes', '--tcp=$backendPort', 'tcp://127.0.0.1:$backendPort'],
      runInShell: true,
    );
    if (r.exitCode != 0) {
      debugPrint('beacle: tailscale serve failed: ${r.stderr}${r.stdout}');
      return;
    }
    debugPrint('beacle: tailscale serve active on tailnet port $backendPort');
  }

  static Future<void> clear() async {
    if (!Platform.isWindows) return;
    if (!await _tailscaleAvailable()) return;
    await Process.run('tailscale', ['serve', '--tcp=$backendPort', 'off'], runInShell: true);
  }

  static Future<bool> _tailscaleAvailable() async {
    final r = await Process.run('tailscale', ['version'], runInShell: true);
    return r.exitCode == 0;
  }

  static Future<bool> _alreadyServing() async {
    final r = await Process.run('tailscale', ['serve', 'status'], runInShell: true);
    if (r.exitCode != 0) return false;
    return r.stdout.toString().contains('127.0.0.1:$backendPort');
  }
}
