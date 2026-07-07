/// Local-first: the panel always talks to the embedded backend on this machine.
const String localBackendUrl = 'http://127.0.0.1:8930';

/// Agent binary on GitHub (amd64 VPS, BETA channel).
const String agentBinaryUrl =
    'https://github.com/c-airr/beacle/releases/download/BETA/beacle-agent-amd';

/// Install script on GitHub (BETA channel).
const String installScriptUrl =
    'https://github.com/c-airr/beacle/releases/download/BETA/install.sh';

const String githubRepo = 'c-airr/beacle';

/// Optional override for development (`flutter run --dart-define=BEACLE_BACKEND=...`).
const String _backendFromBuild = String.fromEnvironment('BEACLE_BACKEND');

String get backendUrl {
  if (_backendFromBuild.isNotEmpty) {
    return _backendFromBuild.replaceAll(RegExp(r'/+$'), '');
  }
  return localBackendUrl;
}

bool get hasBackendUrl => true;

/// One-liner to run on the VPS after picking it in Beacle (curl from GitHub only).
String vpsInstallCommand(String backendPublicUrl) =>
    'curl -fsSL $installScriptUrl | sudo bash -s $backendPublicUrl';
