/// Local-first: the panel always talks to the embedded backend on this machine.
const String localBackendUrl = 'http://127.0.0.1:8930';

/// Optional override for development (`flutter run --dart-define=BEACLE_BACKEND=...`).
const String _backendFromBuild = String.fromEnvironment('BEACLE_BACKEND');

String get backendUrl {
  if (_backendFromBuild.isNotEmpty) {
    return _backendFromBuild.replaceAll(RegExp(r'/+$'), '');
  }
  return localBackendUrl;
}

bool get hasBackendUrl => true;
