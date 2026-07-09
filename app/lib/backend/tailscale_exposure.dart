import 'dart:io';

import 'package:flutter/foundation.dart';

/// Port the Go backend listens on (must match backend/main.go default).
const int backendPort = 9930;

/// Ensures the backend is reachable from the tailnet.
/// Backend binds 0.0.0.0 directly — no `tailscale serve` needed.
/// We only need a Windows Firewall inbound rule (added once, persists across reboots).
Future<void> ensureBackendTailnetExposure({String? backendExe}) async {
  if (!Platform.isWindows) return;
  await _ensureFirewallRule(backendExe: backendExe);
}

Future<void> clearBackendTailnetExposure() async {
  // Nothing to clean up — firewall rule persists intentionally.
}

// ---------------------------------------------------------------------------
// Windows Firewall — one-time, persisted rule
// ---------------------------------------------------------------------------

const _portRuleName = 'BeacleBackend_TCP_$backendPort';

/// Returns true if an inbound-allow rule for our port already exists.
Future<bool> _firewallRuleExists() async {
  final r = await Process.run(
    'netsh',
    ['advfirewall', 'firewall', 'show', 'rule', 'name=$_portRuleName'],
    runInShell: true,
  );
  final out = '${r.stdout}${r.stderr}';
  return r.exitCode == 0 && !out.contains('No rules match');
}

Future<void> _ensureFirewallRule({String? backendExe}) async {
  if (await _firewallRuleExists()) {
    debugPrint('beacle: firewall rule already exists for TCP $backendPort');
    return;
  }

  debugPrint('beacle: adding firewall rule for TCP $backendPort');

  // Try without elevation first (works if running as admin already).
  if (await _addPortRule(elevated: false)) return;

  // Try with elevation (one-time UAC prompt — rule persists across reboots).
  debugPrint('beacle: firewall rule needs elevation — one-time UAC prompt');
  if (await _addPortRule(elevated: true)) return;

  // Last resort: allow the backend exe itself.
  if (backendExe != null && await File(backendExe).exists()) {
    if (await _addExeRule(backendExe, elevated: false)) return;
    if (await _addExeRule(backendExe, elevated: true)) return;
  }

  debugPrint('beacle: WARNING — could not add firewall rule for TCP $backendPort');
}

Future<bool> _addPortRule({required bool elevated}) async {
  final args = [
    'advfirewall', 'firewall', 'add', 'rule',
    'name=$_portRuleName',
    'dir=in', 'action=allow', 'protocol=TCP',
    'localport=$backendPort', 'profile=any', 'enable=yes',
  ];
  return _runNetsh(args, elevated: elevated);
}

Future<bool> _addExeRule(String exe, {required bool elevated}) async {
  final args = [
    'advfirewall', 'firewall', 'add', 'rule',
    'name=BeacleBackend_EXE',
    'dir=in', 'action=allow',
    'program=$exe', 'profile=any', 'enable=yes',
  ];
  return _runNetsh(args, elevated: elevated);
}

Future<bool> _runNetsh(List<String> args, {required bool elevated}) async {
  if (!elevated) {
    final r = await Process.run('netsh', args, runInShell: true);
    if (r.exitCode == 0 && await _firewallRuleExists()) {
      debugPrint('beacle: firewall rule added');
      return true;
    }
    return false;
  }

  // Elevated: pass arguments correctly quoted to PowerShell's Start-Process.
  final argList = args.map((a) => "'${a.replaceAll("'", "''")}'").join(', ');
  try {
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', 'Start-Process netsh -ArgumentList $argList -Verb RunAs -Wait -WindowStyle Hidden'],
      runInShell: true,
    );
    if (r.exitCode == 0 && await _firewallRuleExists()) {
      debugPrint('beacle: firewall rule added (elevated)');
      return true;
    }
  } catch (e) {
    debugPrint('beacle: elevated netsh failed: $e');
  }
  return false;
}
