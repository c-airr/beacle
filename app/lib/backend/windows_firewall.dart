import 'dart:io';

import 'package:flutter/foundation.dart';

/// Opens inbound TCP 8930 on Windows so Tailscale agents can reach the embedded backend.
class WindowsFirewall {
  WindowsFirewall._();

  static const backendPort = 8930;
  static const portRuleName = 'Beacle Backend (TCP 8930)';
  static const exeRuleName = 'Beacle Backend (executable)';

  static Future<void> ensureBackendReachable({String? backendExe}) async {
    if (!Platform.isWindows) return;

    if (await _portAllowed()) {
      debugPrint('beacle: firewall already allows inbound TCP $backendPort');
      return;
    }

    debugPrint('beacle: adding Windows Firewall rule for TCP $backendPort');
    if (await _addPortRule(elevated: false)) return;

    debugPrint('beacle: firewall rule needs elevation — accept UAC once');
    if (await _addPortRule(elevated: true)) return;

    if (backendExe != null && await File(backendExe).exists()) {
      if (await _addExeRule(backendExe, elevated: false)) return;
      await _addExeRule(backendExe, elevated: true);
    }

    if (!await _portAllowed()) {
      debugPrint('beacle: WARNING — inbound TCP $backendPort may still be blocked by Windows Firewall');
    }
  }

  /// True if any enabled inbound rule allows TCP on [backendPort].
  static Future<bool> _portAllowed() async {
    const ps = r'''
$rules = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction SilentlyContinue |
  Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
  Where-Object { $_.Protocol -eq 'TCP' -and $_.LocalPort -eq 8930 }
if ($rules) { 'yes' }
''';
    final r = await Process.run('powershell', ['-NoProfile', '-Command', ps], runInShell: true);
    return r.stdout.toString().trim() == 'yes';
  }

  static Future<bool> _ruleExists(String name) async {
    final r = await Process.run(
      'netsh',
      ['advfirewall', 'firewall', 'show', 'rule', 'name=$name'],
      runInShell: true,
    );
    final out = '${r.stdout}${r.stderr}';
    return r.exitCode == 0 && !out.contains('No rules match');
  }

  static Future<bool> _addPortRule({required bool elevated}) async {
    const args = [
      'advfirewall',
      'firewall',
      'add',
      'rule',
      'name=$portRuleName',
      'dir=in',
      'action=allow',
      'protocol=TCP',
      'localport=$backendPort',
      'profile=any',
      'enable=yes',
    ];
    return _runNetsh(args, elevated: elevated, verify: _portAllowed);
  }

  static Future<bool> _addExeRule(String exe, {required bool elevated}) async {
    if (await _ruleExists(exeRuleName)) return true;
    final args = [
      'advfirewall',
      'firewall',
      'add',
      'rule',
      'name=$exeRuleName',
      'dir=in',
      'action=allow',
      'program=$exe',
      'profile=any',
      'enable=yes',
    ];
    return _runNetsh(args, elevated: elevated, verify: () => _portAllowed());
  }

  static Future<bool> _runNetsh(
    List<String> args, {
    required bool elevated,
    required Future<bool> Function() verify,
  }) async {
    if (!elevated) {
      final r = await Process.run('netsh', args, runInShell: true);
      if (r.exitCode == 0 && await verify()) {
        debugPrint('beacle: firewall rule added');
        return true;
      }
      return false;
    }

    final argList = args.map((a) => "'${a.replaceAll("'", "''")}'").join(',');
    final ps = "Start-Process -FilePath netsh -ArgumentList $argList -Verb RunAs -Wait -WindowStyle Hidden";
    final r = await Process.run('powershell', ['-NoProfile', '-Command', ps], runInShell: true);
    if (r.exitCode == 0 && await verify()) {
      debugPrint('beacle: firewall rule added (elevated)');
      return true;
    }
    debugPrint('beacle: firewall rule failed (exit ${r.exitCode})');
    return false;
  }
}
