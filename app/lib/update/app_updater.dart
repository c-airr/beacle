import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const appVersion = '0.5.0';
// Same repo as config.dart's agent release — kept here too so the updater
// does not need a cross-file import just to read a constant.
const githubRepo = 'c-airr/beacle';

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

  /// Every release, newest first, drafts and prereleases dropped. One call
  /// answers both "is there something newer" and "what is below me", so the
  /// Check and Rollback buttons can never disagree about what is on GitHub.
  static Future<List<UpdateInfo>> releases() async {
    final resp = await http
        .get(Uri.parse('https://api.github.com/repos/$githubRepo/releases'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return [];
    final plat = Platform.isWindows ? 'windows' : 'linux';
    final out = <UpdateInfo>[];
    for (final r in (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>()) {
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final tag = (r['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (tag.isEmpty) continue;
      for (final a in ((r['assets'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        if ((a['name'] as String? ?? '').toLowerCase().contains(plat)) {
          out.add(UpdateInfo(tag, a['browser_download_url'] as String, r['body'] as String? ?? ''));
          break;
        }
      }
    }
    return out;
  }

  /// Detection only, nothing is fetched. null keeps the Update button grey.
  static Future<UpdateInfo?> availableUpdate() async {
    for (final r in await releases()) {
      if (_isNewer(r.version, appVersion)) return r;
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

  /// True if an in-place update ever ran, leaving a previous build behind to
  /// go back to. This is the gate for the Rollback button — it only appears
  /// when there is actually something on disk to roll back to.
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

  /// Tolerates "v1.2.3", "1.2" and build suffixes; anything unparsable counts
  /// as 0 so a malformed tag can never look newer than a real one.
  static bool _isNewer(String a, String b) {
    List<int> parts(String v) =>
        v.split(RegExp(r'[.\-+]')).map((p) => int.tryParse(p) ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final xi = i < x.length ? x[i] : 0;
      final yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi > yi;
    }
    return false;
  }
}
