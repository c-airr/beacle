import 'dart:io';

import 'package:flutter/foundation.dart';

/// Port the Go backend listens on (must match backend/main.go default).
const int backendPort = 9930;

/// Ensures the backend is reachable from the tailnet.
/// We use `tailscale serve` to expose the backend without touching the Windows Firewall.
/// This bypasses any routing or firewall ghosts and requires NO administrator privileges.
Future<void> ensureBackendTailnetExposure({String? backendExe}) async {
  if (!Platform.isWindows) return;

  debugPrint('beacle: ensuring tailscale serve for TCP $backendPort');
  try {
    final r = await Process.run(
      'tailscale',
      ['serve', '--bg', '--tcp=$backendPort', 'tcp://127.0.0.1:$backendPort'],
      runInShell: true,
    );
    if (r.exitCode == 0) {
      debugPrint('beacle: tailscale serve running on TCP $backendPort');
    } else {
      debugPrint('beacle: tailscale serve failed (exit ${r.exitCode}): ${r.stderr}');
    }
  } catch (e) {
    debugPrint('beacle: tailscale serve exception: $e');
  }
}

Future<void> clearBackendTailnetExposure() async {
  if (!Platform.isWindows) return;

  debugPrint('beacle: clearing tailscale serve for TCP $backendPort');
  try {
    await Process.run(
      'tailscale',
      ['serve', '--tcp=$backendPort', 'off'],
      runInShell: true,
    );
  } catch (e) {
    debugPrint('beacle: clear tailscale serve exception: $e');
  }
}
