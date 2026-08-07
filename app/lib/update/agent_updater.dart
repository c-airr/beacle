import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../user_config.dart';
import 'app_updater.dart' hide githubRepo;

/// One GitHub release that carries agent binaries. [version] is the semver
/// from the release's VERSION asset when present — without it the rolling
/// tag has no ordering, so [version] stays null and the UI falls back to
/// showing the build date.
class AgentReleaseInfo {
  final String tag;
  final String? version;
  final DateTime? publishedAt;
  final bool prerelease;
  AgentReleaseInfo({required this.tag, this.version, this.publishedAt, this.prerelease = false});
}

/// Agent release lookups against GitHub. Unlike the desktop app (versioned
/// tags), agents ship on the rolling `agentbeta` tag, so "is there a newer
/// agent" is answered from the VERSION asset next to the binaries.
class AgentUpdater {
  static const _api = 'https://api.github.com/repos/$githubRepo/releases';
  static const _headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'beacle-app'};

  /// The current rolling agent release (agentbeta), with the VERSION asset
  /// resolved to a semver when the release carries one.
  static Future<AgentReleaseInfo?> latestAgentRelease() async {
    final resp = await http
        .get(Uri.parse('$_api/tags/$agentReleaseTag'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final rel = jsonDecode(resp.body) as Map<String, dynamic>;
    return AgentReleaseInfo(
      tag: agentReleaseTag,
      version: await _versionFromAssets(rel),
      publishedAt: DateTime.tryParse(rel['published_at'] as String? ?? ''),
      prerelease: rel['prerelease'] == true,
    );
  }

  /// Releases that carry agent binaries, newest first — the source for the
  /// version picker. Unlike desktop releases, prereleases are kept: the
  /// rolling agentbeta tag is a prerelease-shaped channel by design.
  static Future<List<AgentReleaseInfo>> agentReleases() async {
    final resp = await http
        .get(Uri.parse('$_api?per_page=30'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return [];
    final out = <AgentReleaseInfo>[];
    for (final r in (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>()) {
      if (r['draft'] == true) continue;
      final assets = (r['assets'] as List?) ?? [];
      final hasAgent = assets.any((a) =>
          ((a as Map<String, dynamic>)['name'] as String? ?? '').startsWith('beacle-agent-'));
      if (!hasAgent) continue;
      final tag = r['tag_name'] as String? ?? '';
      if (tag.isEmpty) continue;
      out.add(AgentReleaseInfo(
        tag: tag,
        version: tag == agentReleaseTag ? null : tag.replaceFirst(RegExp(r'^[vV]'), ''),
        publishedAt: DateTime.tryParse(r['published_at'] as String? ?? ''),
        prerelease: r['prerelease'] == true,
      ));
    }
    return out;
  }

  static Future<String?> _versionFromAssets(Map<String, dynamic> rel) async {
    final assets = (rel['assets'] as List?) ?? [];
    for (final a in assets.cast<Map<String, dynamic>>()) {
      if ((a['name'] as String? ?? '') != 'VERSION') continue;
      final url = a['browser_download_url'] as String?;
      if (url == null) return null;
      try {
        final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200) return null;
        final v = resp.body.trim().replaceFirst(RegExp(r'^[vV]'), '');
        return v.isEmpty ? null : v;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  // --- rollback notification suppression -------------------------------
  //
  // Same contract as AppUpdater.suppressedVersion: after a deliberate agent
  // downgrade the rolling release is still "newer", and the Update buttons
  // would nag forever. Persisted in settings.json (%AppData%\Beacle).
  static const _suppressKey = 'suppress_agent_update_version';

  static String? get suppressedVersion => UserSettings.load().raw[_suppressKey] as String?;

  static void suppressNotificationsFor(String version) {
    final s = UserSettings.load();
    s.raw[_suppressKey] = version;
    s.save();
  }

  static void clearSuppression() {
    final s = UserSettings.load();
    if (s.raw.remove(_suppressKey) != null) s.save();
  }

  /// True when [latest] beats [current] and is not the version the user
  /// deliberately downgraded away from.
  static bool isActionable(String latest, String current) {
    if (!AppUpdater.isNewer(latest, current)) return false;
    final suppressed = suppressedVersion;
    if (suppressed != null && !AppUpdater.isNewer(latest, suppressed)) return false;
    return true;
  }
}
