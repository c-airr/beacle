import 'dart:convert';
import 'dart:io';

/// Per-user local settings (isolated environment). Stored under APPDATA/HOME.
class LocalSettings {
  LocalSettings._();

  static File _file() {
    final root = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return File('$root${Platform.pathSeparator}beacle${Platform.pathSeparator}local.json');
  }

  static Map<String, dynamic> load() {
    try {
      final f = _file();
      if (!f.existsSync()) return {};
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static void save(Map<String, dynamic> data) {
    final f = _file();
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(data));
  }

  /// Optional override: URL remote agents use to reach this user's local backend.
  static String? get agentPublicUrlOverride {
    final v = load()['agent_public_url'] as String?;
    if (v == null || v.trim().isEmpty) return null;
    return v.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static set agentPublicUrlOverride(String? url) {
    final data = load();
    if (url == null || url.trim().isEmpty) {
      data.remove('agent_public_url');
    } else {
      data['agent_public_url'] = url.trim().replaceAll(RegExp(r'/+$'), '');
    }
    save(data);
  }

  /// Best-effort public URL for install commands (agents connect outbound here).
  static Future<String> resolveAgentPublicUrl() async {
    final override = agentPublicUrlOverride;
    if (override != null) return override;

    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('https://api.ipify.org'));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final ip = (await resp.transform(utf8.decoder).join()).trim();
        if (ip.isNotEmpty) return 'http://$ip:8930';
      }
      client.close();
    } catch (_) {}

    return 'http://127.0.0.1:8930';
  }
}
