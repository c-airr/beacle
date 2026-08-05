/// Local-first: the panel always talks to the embedded backend on this machine.
const String localBackendUrl = 'http://127.0.0.1:9930';

/// Public GitHub release that hosts VPS agent binaries + install.sh.
const String agentReleaseTag = 'agentbeta';
const String agentBinaryAmdUrl =
    'https://github.com/c-airr/beacle/releases/download/$agentReleaseTag/beacle-agent-amd64';
const String agentBinaryArmUrl =
    'https://github.com/c-airr/beacle/releases/download/$agentReleaseTag/beacle-agent-arm64';
const String installScriptUrl =
    'https://github.com/c-airr/beacle/releases/download/$agentReleaseTag/install.sh';

/// Legacy alias (amd64).
const String agentBinaryUrl = agentBinaryAmdUrl;

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

/// One-liner: install.sh + agent binary both from GitHub agentbeta.
String vpsInstallCommand(String backendPublicUrl) =>
    'curl -fsSL $installScriptUrl | sudo bash -s $backendPublicUrl';
