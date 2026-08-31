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

  /// sha256 of each agent asset, keyed by architecture ("amd64", "arm64"), as
  /// GitHub reports it. This is what makes "would updating change anything"
  /// answerable: version numbers say nothing about a rebuild republished under
  /// the same tag.
  ///
  /// Keyed by architecture because a fleet is not always one: comparing an
  /// arm64 server against the amd64 asset compares two files that are supposed
  /// to differ, so that server asked to update again the moment it finished
  /// updating.
  final Map<String, String> digests;

  AgentReleaseInfo({
    required this.tag,
    this.version,
    this.publishedAt,
    this.prerelease = false,
    this.digests = const {},
  });

  /// The digest to measure a server against. Falls back to amd64 for agents
  /// too old to report their architecture, which is what the fleet was
  /// implicitly assumed to be before.
  String? digestFor(String arch) =>
      digests[arch.isEmpty ? 'amd64' : arch] ?? digests['amd64'];
}

/// Agent release lookups against GitHub.
///
/// Agents follow the same Latest release the desktop app does. They used to
/// follow a pinned `agentbeta` tag, which drifted two months behind: a VPS
/// installed from Latest would be *downgraded* by pressing Update.
class AgentUpdater {
  static const _api = 'https://api.github.com/repos/$githubRepo/releases';
  static const _headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'beacle-app'};

  /// The agent release on GitHub's Latest, which is what a fresh install and
  /// the Update button both pull from.
  static Future<AgentReleaseInfo?> latestAgentRelease() async {
    final resp = await http
        .get(Uri.parse('$_api/latest'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final rel = jsonDecode(resp.body) as Map<String, dynamic>;
    final tag = rel['tag_name'] as String? ?? '';
    return AgentReleaseInfo(
      tag: tag,
      // A tag like 0.9 is already the version; the VERSION asset is only
      // consulted when the tag carries no ordering of its own.
      version: await _versionFromAssets(rel) ?? _versionFromTag(tag),
      publishedAt: DateTime.tryParse(rel['published_at'] as String? ?? ''),
      prerelease: rel['prerelease'] == true,
      digests: _digestsFromAssets(rel),
    );
  }

  /// Every agent asset's digest, keyed by the architecture in its name.
  ///
  /// This used to read the amd64 asset alone, on the reasoning that a fleet is
  /// almost always one architecture. It is not: one arm64 box among four amd64
  /// ones was measured against the wrong file and so differed permanently,
  /// showing an Update button that stayed after every update it was given.
  static Map<String, String> _digestsFromAssets(Map<String, dynamic> rel) {
    const prefix = 'beacle-agent-';
    final out = <String, String>{};
    for (final a in ((rel['assets'] as List?) ?? []).cast<Map<String, dynamic>>()) {
      final name = (a['name'] as String? ?? '');
      if (!name.startsWith(prefix)) continue;
      final arch = name.substring(prefix.length);
      if (arch.isEmpty || arch.contains('.')) continue; // not a bare binary
      final d = (a['digest'] as String? ?? '').trim();
      if (d.isNotEmpty) out[arch] = d;
    }
    return out;
  }

  /// Strips a leading v so "v0.9" and "0.9" compare as the same version.
  /// Returns null for a tag that is a channel name rather than a version.
  static String? _versionFromTag(String tag) {
    final t = tag.replaceFirst(RegExp(r'^[vV]'), '');
    return RegExp(r'^\d').hasMatch(t) ? t : null;
  }

  /// Releases that carry agent binaries, newest first — the source for the
  /// version picker. Prereleases are kept: pinning an agent to an older or
  /// pre-release build is exactly what the picker is for, even though Update
  /// on its own always means Latest.
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
        version: _versionFromTag(tag),
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
