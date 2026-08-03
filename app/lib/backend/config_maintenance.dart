import 'dart:io';

import '../paths.dart';

/// Housekeeping for the local config: reveal it, copy it somewhere safe, put it
/// back, throw the disposable parts away.
///
/// Backups are plain folders rather than archives. Dart has no zip in the SDK
/// and this is a handful of small JSON files, so a folder costs nothing and can
/// be read — and repaired — with a text editor on a day when the app itself
/// will not start.
class ConfigMaintenance {
  ConfigMaintenance._();

  static String get backupsDir => '${BeaclePaths.configDir}${Platform.pathSeparator}backups';

  /// Files worth keeping. state.json holds the VPS registry and its tokens,
  /// which is the part that actually hurts to lose.
  static List<String> get _sourceFiles => [
        BeaclePaths.configFile,
        BeaclePaths.serversFile,
        BeaclePaths.settingsFile,
        BeaclePaths.stateFile,
      ];

  /// Opens a folder in the platform's file manager.
  static Future<void> openFolder(String path) async {
    Directory(path).createSync(recursive: true);
    final (exe, args) = switch (Platform.operatingSystem) {
      'windows' => ('explorer', [path]),
      'macos' => ('open', [path]),
      _ => ('xdg-open', [path]),
    };
    // explorer.exe returns 1 even when it worked, so the exit code is not
    // worth checking on any of the three.
    await Process.run(exe, args);
  }

  static Future<void> openDataDirectory() => openFolder(BeaclePaths.configDir);

  /// Copies the config into `backups/<timestamp>/` and returns that folder.
  static Future<String> backup() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    final dest = Directory('$backupsDir${Platform.pathSeparator}$stamp');
    dest.createSync(recursive: true);

    var copied = 0;
    for (final path in _sourceFiles) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final name = path.split(Platform.pathSeparator).last;
      f.copySync('${dest.path}${Platform.pathSeparator}$name');
      copied++;
    }
    if (copied == 0) {
      dest.deleteSync(recursive: true);
      throw Exception('nothing to back up yet');
    }
    return dest.path;
  }

  /// Available backups, newest first.
  static List<Directory> backups() {
    final dir = Directory(backupsDir);
    if (!dir.existsSync()) return [];
    final out = dir.listSync().whereType<Directory>().toList();
    out.sort((a, b) => b.path.compareTo(a.path));
    return out;
  }

  /// Puts a backup back. The current files are copied aside first — restoring
  /// the wrong snapshot should not be the end of the story.
  static Future<int> restore(Directory backup) async {
    final safety = Directory(
        '$backupsDir${Platform.pathSeparator}before-restore-${DateTime.now().millisecondsSinceEpoch}');
    safety.createSync(recursive: true);
    for (final path in _sourceFiles) {
      final f = File(path);
      if (f.existsSync()) {
        f.copySync('${safety.path}${Platform.pathSeparator}${path.split(Platform.pathSeparator).last}');
      }
    }

    var restored = 0;
    for (final entry in backup.listSync().whereType<File>()) {
      final name = entry.path.split(Platform.pathSeparator).last;
      final target = switch (name) {
        'config.json' => BeaclePaths.configFile,
        'servers.json' => BeaclePaths.serversFile,
        'settings.json' => BeaclePaths.settingsFile,
        'state.json' => BeaclePaths.stateFile,
        _ => null,
      };
      if (target == null) continue;
      Directory(target.substring(0, target.lastIndexOf(Platform.pathSeparator)))
          .createSync(recursive: true);
      entry.copySync(target);
      restored++;
    }
    return restored;
  }

  /// Empties the cache directory. Everything in there is derived data the app
  /// rebuilds — never config, never the VPS registry.
  static Future<int> clearCache() async {
    final dir = Directory(BeaclePaths.cacheDir);
    if (!dir.existsSync()) return 0;
    var freed = 0;
    for (final entry in dir.listSync()) {
      try {
        if (entry is File) {
          freed += entry.lengthSync();
          entry.deleteSync();
        } else if (entry is Directory) {
          freed += entry
              .listSync(recursive: true)
              .whereType<File>()
              .fold<int>(0, (sum, f) => sum + f.lengthSync());
          entry.deleteSync(recursive: true);
        }
      } catch (_) {
        // A file held open by something else is not worth failing the whole
        // sweep over.
      }
    }
    return freed;
  }
}
