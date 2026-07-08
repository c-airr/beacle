import 'dart:io';

import 'windows_firewall.dart';
import 'tailscale_serve_windows.dart';

/// Tailnet exposure for the embedded backend (agents connect via desktop Tailscale IP).
Future<void> ensureBackendTailnetExposure({String? backendExe}) async {
  if (Platform.isWindows) {
    await TailscaleServeWindows.exposeBackend();
    await WindowsFirewall.ensureBackendReachable(backendExe: backendExe);
    return;
  }
  // Linux desktop: bind 0.0.0.0 + ufw later.
}

Future<void> clearBackendTailnetExposure() async {
  if (Platform.isWindows) {
    await TailscaleServeWindows.clear();
  }
}
