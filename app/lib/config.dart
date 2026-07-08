/// Local-first: the panel always talks to the embedded backend on this machine.
const String localBackendUrl = 'http://127.0.0.1:8930';

const String githubRepo = 'c-airr/beacle';

/// Shown before adding a VPS — Tailscale is mandatory.
const String tailscaleRequirement =
    'Tailscale is required on this computer and on every VPS. '
    'All devices must be in the same tailnet before you can add a server.';

const String tailscaleNotOnPc =
    'Tailscale is not available on this computer. Install Tailscale, sign in to your tailnet, then restart Beacle.';

const String tailscaleNoPeers =
    'No other devices found in your tailnet. Install Tailscale on your VPS, sign in with the same account, '
    'then click Add VPS again.';

/// Optional override for development (`flutter run --dart-define=BEACLE_BACKEND=...`).
const String _backendFromBuild = String.fromEnvironment('BEACLE_BACKEND');

String get backendUrl {
  if (_backendFromBuild.isNotEmpty) {
    return _backendFromBuild.replaceAll(RegExp(r'/+$'), '');
  }
  return localBackendUrl;
}

bool get hasBackendUrl => true;

/// One-liner to run on the VPS — install script + agent binary served by the desktop backend.
String vpsInstallCommand(String backendPublicUrl) {
  final url = backendPublicUrl.replaceAll(RegExp(r'/+$'), '');
  return 'curl -fsSL $url/install | sudo bash';
}
