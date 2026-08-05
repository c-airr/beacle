import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const appVersion = '0.5.0';
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

  // ==========================================================================
  // PLANNED UPDATE SYSTEM — kept commented until the current flow is reworked.
  // Uncomment as one piece, together with the matching block in
  // settings_screen.dart (_updatesTab). Needs `import 'dart:async';` and
  // `import '../user_config.dart';` at the top of this file.
  //
  // What changes versus what runs today:
  //   * checking and downloading stop being one action. checkForUpdate() above
  //     downloads and stages the moment it finds anything, which is why there
  //     is no button that can be greyed out — availableUpdate() only looks.
  //   * auto-update becomes opt-in and off by default. The agent-side loop in
  //     agent/updater.go (AutoUpdateLoop, unconditional every 6 h) has to be
  //     gated on the same setting when this is switched on, otherwise the
  //     panel says "off" while agents keep updating themselves.
  //   * rollback stops depending on a versions/previous folder that only
  //     exists if this install ever updated in place, and fetches the release
  //     below the running one from GitHub instead.
  // ==========================================================================

  // /// One GitHub release. The list endpoint returns these newest first.
  // static const autoUpdateKey = 'auto_update';
  // static const autoUpdateEvery = Duration(hours: 6);
  //
  // /// Off unless the user asks for it. An update that restarts the panel
  // /// unannounced is worse than being a version behind.
  // static bool get autoUpdateEnabled => UserSettings.load().raw[autoUpdateKey] == true;
  //
  // static void setAutoUpdate(bool on) {
  //   final s = UserSettings.load();
  //   s.raw[autoUpdateKey] = on;
  //   s.save();
  // }
  //
  // /// Every release, newest first, drafts and prereleases dropped. One call
  // /// answers both "is there something newer" and "what is below me", so the
  // /// two buttons can never disagree about what is on GitHub.
  // static Future<List<UpdateInfo>> releases() async {
  //   final resp = await http.get(
  //     Uri.parse('https://api.github.com/repos/$githubRepo/releases'),
  //     headers: {'Accept': 'application/vnd.github+json'},
  //   ).timeout(const Duration(seconds: 15));
  //   if (resp.statusCode != 200) return [];
  //   final plat = Platform.isWindows ? 'windows' : 'linux';
  //   final out = <UpdateInfo>[];
  //   for (final r in (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>()) {
  //     if (r['draft'] == true || r['prerelease'] == true) continue;
  //     final tag = (r['tag_name'] as String? ?? '').replaceFirst('v', '');
  //     if (tag.isEmpty) continue;
  //     for (final a in ((r['assets'] as List?) ?? []).cast<Map<String, dynamic>>()) {
  //       if ((a['name'] as String? ?? '').toLowerCase().contains(plat)) {
  //         out.add(UpdateInfo(tag, a['browser_download_url'] as String, r['body'] as String? ?? ''));
  //         break;
  //       }
  //     }
  //   }
  //   return out;
  // }
  //
  // /// Detection only, nothing is fetched. null keeps the Update button grey.
  // static Future<UpdateInfo?> availableUpdate() async {
  //   for (final r in await releases()) {
  //     if (_isNewer(r.version, appVersion)) return r;
  //   }
  //   return null;
  // }
  //
  // /// What Rollback goes back to: the newest release *older* than the running
  // /// build. On the latest version that is the second-to-last; for someone
  // /// already sitting on the second-to-last it is the one before that, so
  // /// pressing Rollback twice keeps walking backwards instead of doing
  // /// nothing. ASSUMPTION — if it should refuse once you are below latest
  // /// rather than keep going, this loop is the line to change.
  // static Future<UpdateInfo?> rollbackTarget() async {
  //   for (final r in await releases()) {
  //     if (_isNewer(appVersion, r.version)) return r;
  //   }
  //   return null;
  // }
  //
  // /// Rollback reuses the staging path, so going back is the same operation
  // /// as going forward and gets the same swap script and the same recovery.
  // static Future<String> rollbackToRelease(UpdateInfo target) => downloadAndStage(target);
  //
  // /// Every release the user is allowed to jump to, newest first, with the
  // /// running one marked. Feeds the version picker: pinning a known-good
  // /// build matters more than moving forward when something just broke.
  // ///
  // /// Returns an empty list on a rolling-release tag like `agentbeta`, where
  // /// there is one tag that keeps being overwritten and so nothing to choose
  // /// between — the picker says so rather than showing a list of one.
  // static Future<List<UpdateInfo>> selectableVersions() async {
  //   final all = await releases();
  //   return all.length < 2 ? const [] : all;
  // }
  //
  // /// Installs a specific release, forwards or backwards. Same staging and
  // /// the same swap script as an update, because "install this exact build"
  // /// is the general case and update/rollback are just two picks from it.
  // static Future<String> installVersion(UpdateInfo target) => downloadAndStage(target);
  //
  // /// Tolerates "v1.2.3", "1.2" and build suffixes; anything unparsable
  // /// counts as 0 so a malformed tag can never look newer than a real one.
  // static bool _isNewer(String a, String b) {
  //   List<int> parts(String v) =>
  //       v.split(RegExp(r'[.\-+]')).map((p) => int.tryParse(p) ?? 0).toList();
  //   final x = parts(a), y = parts(b);
  //   for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
  //     final xi = i < x.length ? x[i] : 0;
  //     final yi = i < y.length ? y[i] : 0;
  //     if (xi != yi) return xi > yi;
  //   }
  //   return false;
  // }
  //
  // /// The opt-in loop. First check runs a minute after launch so a cold start
  // /// is not racing a download, then every 6 h. Returns the timer so the
  // /// settings toggle can cancel it the moment auto-update is switched off.
  // static Timer startAutoUpdates({required void Function(String) onStatus}) {
  //   Future<void> tick() async {
  //     if (!autoUpdateEnabled) return;
  //     try {
  //       final info = await availableUpdate();
  //       if (info == null) return;
  //       onStatus(await downloadAndStage(info));
  //     } catch (e) {
  //       onStatus('Auto-update check failed: $e');
  //     }
  //   }
  //
  //   Timer(const Duration(minutes: 1), tick);
  //   return Timer.periodic(autoUpdateEvery, (_) => tick());
  // }
}
