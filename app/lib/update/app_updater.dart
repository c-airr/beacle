import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const appVersion = '0.1.0';
const githubRepo = 'beacle/beacle'; // change to your fork

class UpdateInfo {
  final String version;
  final String assetUrl;
  final String notes;
  UpdateInfo(this.version, this.assetUrl, this.notes);
}

/// Desktop app self-update via GitHub Releases.
/// Strategy: download the release archive next to the executable, extract to
/// `versions/<ver>`, write a swap script that runs on next start. The current
/// version is kept in `versions/previous` for rollback. User settings are
/// stored in APPDATA and are never touched by updates.
class AppUpdater {
  static String get _installDir => File(Platform.resolvedExecutable).parent.path;
  static Directory get _versionsDir => Directory('$_installDir\\versions');

  static Future<UpdateInfo?> checkForUpdate() async {
    final resp = await http
        .get(Uri.parse('https://api.github.com/repos/$githubRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (tag.isEmpty || tag == appVersion) return null;
    final assets = (j['assets'] as List?) ?? [];
    final plat = Platform.isWindows ? 'windows' : 'linux';
    for (final a in assets) {
      final name = (a as Map)['name'] as String? ?? '';
      if (name.toLowerCase().contains(plat)) {
        return UpdateInfo(tag, a['browser_download_url'] as String, j['body'] as String? ?? '');
      }
    }
    return null;
  }

  /// Downloads the update and stages it; applied on next launch.
  static Future<String> downloadAndStage(UpdateInfo info) async {
    _versionsDir.createSync(recursive: true);
    final archive = File('${_versionsDir.path}\\beacle-${info.version}.zip');
    final resp = await http.get(Uri.parse(info.assetUrl));
    if (resp.statusCode != 200) {
      throw Exception('download failed: HTTP ${resp.statusCode}');
    }
    await archive.writeAsBytes(resp.bodyBytes);

    final stageDir = Directory('${_versionsDir.path}\\${info.version}');
    if (stageDir.existsSync()) stageDir.deleteSync(recursive: true);
    stageDir.createSync(recursive: true);
    final res = await Process.run('tar', ['-xf', archive.path, '-C', stageDir.path]);
    if (res.exitCode != 0) throw Exception('extract failed: ${res.stderr}');

    // swap script: backs up current install to versions/previous, copies the
    // staged version in. Settings live in APPDATA so they survive untouched.
    final script = File('$_installDir\\apply-update.bat');
    script.writeAsStringSync('''
@echo off
timeout /t 2 /nobreak >nul
robocopy "$_installDir" "${_versionsDir.path}\\previous" /MIR /XD versions /XF apply-update.bat >nul
robocopy "${stageDir.path}" "$_installDir" /E /XD versions >nul
start "" "$_installDir\\beacle.exe"
''');
    return 'Update ${info.version} staged. Restart Beacle and run apply-update.bat, or click "Apply and restart".';
  }

  static Future<void> applyAndRestart() async {
    final script = File('$_installDir\\apply-update.bat');
    if (!script.existsSync()) throw Exception('no staged update');
    await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  static bool get hasPrevious => Directory('${_versionsDir.path}\\previous').existsSync();

  static Future<void> rollbackAndRestart() async {
    final prev = Directory('${_versionsDir.path}\\previous');
    if (!prev.existsSync()) throw Exception('no previous version to roll back to');
    final script = File('$_installDir\\rollback.bat');
    script.writeAsStringSync('''
@echo off
timeout /t 2 /nobreak >nul
robocopy "${prev.path}" "$_installDir" /E /XD versions >nul
start "" "$_installDir\\beacle.exe"
''');
    await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
    exit(0);
  }
}
