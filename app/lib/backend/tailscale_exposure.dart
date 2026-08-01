import 'dart:io';

import 'package:flutter/foundation.dart';

/// Port the Go backend listens on (must match backend/main.go default).
const int backendPort = 9930;

/// Ensures the backend is reachable from the tailnet.
///
/// The backend already binds 0.0.0.0, so on a machine whose firewall allows
/// inbound $backendPort the tailnet address works on its own. `tailscale serve`
/// is the fallback for the machines where it does not: it needs no admin
/// rights, but it makes tailscaled own the tailnet address and proxy every
/// byte to 127.0.0.1 — an extra hop that can fail independently of the backend.
///
/// So: only claim the address when the direct path is not already working.
Future<void> ensureBackendTailnetExposure({String? backendExe}) async {
  if (!Platform.isWindows) return;

  // An existing mapping would answer our probe itself, so a machine that once
  // needed `serve` would keep the extra hop forever. Drop it first, then find
  // out whether the plain listener is enough.
  if (await _servesOurPort()) {
    debugPrint('beacle: releasing existing tailscale serve to test the direct path');
    await _serveOff();
  }

  if (await _directlyReachable()) {
    debugPrint('beacle: tailnet address reaches the backend directly, no tailscale serve needed');
    return;
  }

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

/// Is tailscaled currently holding the tailnet address for our port?
Future<bool> _servesOurPort() async {
  try {
    final r = await Process.run('tailscale', ['serve', 'status'], runInShell: true);
    if (r.exitCode != 0) return false;
    return '${r.stdout}'.contains(':$backendPort');
  } catch (_) {
    return false;
  }
}

Future<void> _serveOff() async {
  try {
    await Process.run('tailscale', ['serve', '--tcp=$backendPort', 'off'], runInShell: true);
    // tailscaled releases the listener asynchronously.
    await Future.delayed(const Duration(milliseconds: 600));
  } catch (_) {}
}

/// This machine's Tailscale IPv4, or null when Tailscale is not up.
Future<String?> _tailscaleIPv4() async {
  try {
    final r = await Process.run('tailscale', ['ip', '-4'], runInShell: true);
    if (r.exitCode != 0) return null;
    final ip = '${r.stdout}'.trim().split('\n').first.trim();
    return ip.isEmpty ? null : ip;
  } catch (_) {
    return null;
  }
}

/// Can an agent reach the backend on the tailnet address without `serve`?
/// Probing 127.0.0.1 would answer nothing — it works either way. This dials
/// the same address the agents dial.
Future<bool> _directlyReachable() async {
  final ip = await _tailscaleIPv4();
  if (ip == null) return false;
  try {
    final socket = await Socket.connect(ip, backendPort, timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Releases the tailnet address if we were the ones holding it.
///
/// Deliberately does nothing now: tearing the mapping down on exit dropped
/// every established agent connection, and an orphaned backend outliving the
/// window was then unreachable despite listening. A stale `serve` entry
/// pointing at a closed port is harmless — it just refuses connections, which
/// is what a closed port does anyway.
Future<void> clearBackendTailnetExposure() async {
  return;
}
