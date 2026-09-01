import 'dart:io';

/// Install dir: %LocalAppData%\Beacle\ (beacle.exe, backend.exe, plugins\).
/// Config dir: %AppData%\Beacle\ (config, servers, settings, cache, logs).
class BeaclePaths {
  BeaclePaths._();

  static String get _sep => Platform.pathSeparator;

  /// Where this running copy of Beacle lives.
  ///
  /// The directory holding the running executable wins. It used to prefer
  /// %LOCALAPPDATA%\Beacle whenever that existed, which meant that once the
  /// installer had been run, launching any other build silently started the
  /// *installed* backend instead of the one next to it — so a freshly built
  /// binary ran week-old code, and nothing said so.
  ///
  /// The installed location is still the fallback, for a launch from somewhere
  /// with no backend beside it.
  static String get installDir {
    final beside = File(Platform.resolvedExecutable).parent.path;
    if (File('$beside$_sep${backendBinaryName()}').existsSync()) return beside;

    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final dir = '$local${_sep}Beacle';
      if (Directory(dir).existsSync()) return dir;
    }
    return beside;
  }

  static String get configDir {
    // macOS keeps application data under Library/Application Support; putting
    // a bare "Beacle" folder in the home directory would work but is not where
    // anyone would look for it, or where a backup tool expects it.
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return '$home${_sep}Library${_sep}Application Support${_sep}Beacle';
      }
    }
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
