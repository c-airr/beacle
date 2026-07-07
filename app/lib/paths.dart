import 'dart:io';

/// Install dir: %LocalAppData%\Beacle\ (beacle.exe, backend.exe, plugins\).
/// Config dir: %AppData%\Beacle\ (config, servers, settings, cache, logs).
class BeaclePaths {
  BeaclePaths._();

  static String get _sep => Platform.pathSeparator;

  static String get installDir {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final dir = '$local${_sep}Beacle';
      if (Directory(dir).existsSync()) return dir;
    }
    return File(Platform.resolvedExecutable).parent.path;
  }

  static String get configDir {
    final app = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return '$app${_sep}Beacle';
  }

  static String get configFile => '$configDir${_sep}config.json';
  static String get serversFile => '$configDir${_sep}servers.json';
  static String get settingsFile => '$configDir${_sep}settings.json';
  static String get dataDir => '$configDir${_sep}data';
  static String get cacheDir => '$configDir${_sep}cache';
  static String get logsDir => '$configDir${_sep}logs';
  static String get stateFile => '$dataDir${_sep}state.json';

  static String backendBinaryName() => Platform.isWindows ? 'beacle-backend.exe' : 'beacle-backend';

  static String get backendBinary => '$installDir${_sep}${backendBinaryName()}';

  static void ensureDirs() {
    for (final d in [configDir, dataDir, cacheDir, logsDir, '$dataDir${_sep}bin']) {
      Directory(d).createSync(recursive: true);
    }
  }
}
