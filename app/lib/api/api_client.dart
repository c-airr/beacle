import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/models.dart';

class TailscaleDevice {
  final String name, dns, os;
  final List<String> ips;
  final bool online, self;
  TailscaleDevice({
    required this.name,
    required this.dns,
    required this.ips,
    required this.os,
    required this.online,
    required this.self,
  });
  factory TailscaleDevice.fromJson(Map<String, dynamic> j) => TailscaleDevice(
        name: j['name'] as String? ?? '',
        dns: j['dns'] as String? ?? '',
        ips: ((j['ips'] as List?) ?? []).map((e) => e as String).toList(),
        os: j['os'] as String? ?? '',
        online: j['online'] == true,
        self: j['self'] == true,
      );
}

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

/// REST client for the Beacle backend. All agent operations go through the
/// backend proxy (`/api/vps/{id}/agent/...`), never directly to the agent.
class ApiClient {
  String baseUrl;
  final http.Client _http = http.Client();

  ApiClient(this.baseUrl);

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> _req(String method, String path, {Object? body}) async {
    final req = http.Request(method, _u(path));
    req.headers['Content-Type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final streamed = await _http.send(req).timeout(const Duration(seconds: 20));
    final resp = await http.Response.fromStream(streamed);
    dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      decoded = resp.body;
    }
    if (resp.statusCode >= 400) {
      final msg = decoded is Map ? (decoded['error'] ?? resp.body) : resp.body;
      throw ApiException('$msg', resp.statusCode);
    }
    return decoded;
  }

  Future<dynamic> get(String path) => _req('GET', path);
  Future<dynamic> post(String path, {Object? body}) => _req('POST', path, body: body);
  Future<dynamic> put(String path, {Object? body}) => _req('PUT', path, body: body);
  Future<dynamic> delete(String path) => _req('DELETE', path);

  Future<bool> health() async {
    try {
      final r = await get('/api/health');
      return r is Map && r['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<TailscaleDevice>> tailscaleDevices() async =>
      ((await get('/api/tailscale/devices')) as List? ?? [])
          .map((e) => TailscaleDevice.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<Vps> createVps({required String name, required String tailscaleName, required String tailscaleIp}) async =>
      Vps.fromJson(await post('/api/vps', body: {
        'name': name,
        'tailscale_name': tailscaleName,
        'tailscale_ip': tailscaleIp,
      }));

  Future<String> installCommand() async {
    final r = (await get('/api/install-command')) as Map;
    final backend = (r['backend_url'] as String? ?? '').trim();
    if (backend.isEmpty) {
      throw ApiException(tailscaleNotOnPc, 503);
    }
    // Always build from config.dart — never trust stale backend.exe install_command text.
    return vpsInstallCommand(backend);
  }

  Future<List<Vps>> listVps() async =>
      ((await get('/api/vps')) as List? ?? []).map((e) => Vps.fromJson(e)).toList();

  Future<void> deleteVps(String id) => delete('/api/vps/$id');

  Future<Vps> updateVps(String id, Map<String, dynamic> fields) async =>
      Vps.fromJson(await _req('PATCH', '/api/vps/$id', body: fields));

  Future<VpsSnapshot> snapshot(String id) async =>
      VpsSnapshot.fromJson(await get('/api/vps/$id'));

  Future<Map<String, dynamic>> overview() async =>
      (await get('/api/overview')) as Map<String, dynamic>;

  Future<List<Alert>> alerts() async =>
      ((await get('/api/alerts')) as List? ?? []).map((e) => Alert.fromJson(e)).toList();

  Future<void> resolveAlert(String id) => post('/api/alerts/$id/resolve');

  Future<List<VpsLink>> links() async =>
      ((await get('/api/links')) as List? ?? []).map((e) => VpsLink.fromJson(e)).toList();

  Future<VpsLink> createLink(String from, String to) async =>
      VpsLink.fromJson(await post('/api/links', body: {'from_vps_id': from, 'to_vps_id': to}));

  Future<void> deleteLink(String id) => delete('/api/links/$id');

  String _a(String vpsId, String rest) => '/api/vps/$vpsId/agent/$rest';

  Future<List<ProcessInfo>> processes(String vpsId) async =>
      ((await get(_a(vpsId, 'system/processes'))) as List? ?? [])
          .map((e) => ProcessInfo.fromJson(e))
          .toList();

  Future<List<PortInfo>> ports(String vpsId) async =>
      ((await get(_a(vpsId, 'system/ports'))) as List? ?? [])
          .map((e) => PortInfo.fromJson(e))
          .toList();

  Future<PortInfo> portDetail(String vpsId, int port) async =>
      PortInfo.fromJson(await get(_a(vpsId, 'system/ports/$port')));

  Future<void> dockerAction(String vpsId, String containerId, String action) =>
      post(_a(vpsId, 'docker/containers/$containerId/$action'));

  Future<String> dockerLogs(String vpsId, String containerId, {int tail = 200}) async =>
      ((await get(_a(vpsId, 'docker/containers/$containerId/logs?tail=$tail'))) as Map)['logs']
          as String? ??
      '';

  Future<ContainerStats> dockerStats(String vpsId, String containerId) async =>
      ContainerStats.fromJson(await get(_a(vpsId, 'docker/containers/$containerId/stats')));

  Future<void> systemdAction(String vpsId, String unit, String action) =>
      post(_a(vpsId, 'services/systemd/$unit/$action'));

  Future<String> systemdLogs(String vpsId, String unit, {int lines = 200}) async =>
      ((await get(_a(vpsId, 'services/systemd/$unit/logs?lines=$lines'))) as Map)['logs']
          as String? ??
      '';

  Future<List<ScreenSession>> screenSessions(String vpsId) async =>
      ((await get(_a(vpsId, 'services/screen'))) as List? ?? [])
          .map((e) => ScreenSession.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<void> screenStart(String vpsId, {required String name, required String dir, required String command}) =>
      post(_a(vpsId, 'services/screen'), body: {'name': name, 'dir': dir, 'command': command});

  Future<void> screenStop(String vpsId, String name) =>
      post(_a(vpsId, 'services/screen/$name/stop'));

  /// Removes the session itself, unlike [screenStop] which only interrupts
  /// what is running inside it.
  Future<void> screenKill(String vpsId, String name) =>
      delete(_a(vpsId, 'services/screen/$name'));

  Future<String> screenLogs(String vpsId, String name) async =>
      ((await get(_a(vpsId, 'services/screen/$name/logs'))) as Map)['logs'] as String? ?? '';

  /// Recorded metric history for one server. [hours] looks back from now;
  /// [from]/[to] pin an explicit window for scrolling to a particular night.
  Future<MetricHistory> vpsHistory(
    String vpsId, {
    int hours = 24,
    DateTime? from,
    DateTime? to,
  }) async {
    final q = <String>[];
    if (from != null) {
      q.add('from=${Uri.encodeQueryComponent(from.toUtc().toIso8601String())}');
      if (to != null) {
        q.add('to=${Uri.encodeQueryComponent(to.toUtc().toIso8601String())}');
      }
    } else {
      q.add('hours=$hours');
    }
    return MetricHistory.fromJson(
        await get('/api/vps/$vpsId/history?${q.join('&')}') as Map<String, dynamic>);
  }

  Future<List<NohupJob>> nohupJobs(String vpsId) async =>
      ((await get(_a(vpsId, 'services/nohup'))) as List? ?? [])
          .map((e) => NohupJob.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<NohupJob> nohupStart(String vpsId,
          {required String name, required String dir, required String command}) async =>
      NohupJob.fromJson(await post(_a(vpsId, 'services/nohup'),
          body: {'name': name, 'dir': dir, 'command': command}) as Map<String, dynamic>);

  Future<void> nohupStop(String vpsId, String name) =>
      delete(_a(vpsId, 'services/nohup/$name'));

  Future<String> nohupLogs(String vpsId, String name) async =>
      ((await get(_a(vpsId, 'services/nohup/$name/logs'))) as Map)['logs'] as String? ?? '';

  Future<FsListing> listDir(String vpsId, String path) async =>
      FsListing.fromJson(await get(_a(vpsId, 'fs/list?path=${Uri.encodeQueryComponent(path)}')));

  Future<ProxyState> proxyState(String vpsId) async =>
      ProxyState.fromJson(await get(_a(vpsId, 'proxy')));

  Future<ProxySite> proxyAddSite(String vpsId, Map<String, dynamic> req) async =>
      ProxySite.fromJson(await post(_a(vpsId, 'proxy/sites'), body: req));

  Future<ProxySite> proxyUpdateSite(String vpsId, String siteId, Map<String, dynamic> req) async =>
      ProxySite.fromJson(await put(_a(vpsId, 'proxy/sites/$siteId'), body: req));

  /// Writes a site block verbatim. The id goes in the body: sites read out of
  /// the Caddyfile are identified as `caddyfile:<domain>`, which does not
  /// belong in a URL path.
  Future<ProxySite> proxyUpdateSiteRaw(String vpsId, String siteId, String raw) async =>
      ProxySite.fromJson(await put(_a(vpsId, 'proxy/raw'), body: {'id': siteId, 'raw': raw}));

  Future<void> proxyDeleteSite(String vpsId, String siteId) =>
      delete(_a(vpsId, 'proxy/sites/$siteId'));

  Future<void> proxyReload(String vpsId) => post(_a(vpsId, 'proxy/reload'));

  Future<Map<String, dynamic>> proxyValidate(String vpsId) async =>
      (await post(_a(vpsId, 'proxy/validate'))) as Map<String, dynamic>;

  /// [tag] pins a specific GitHub release (Settings version picker);
  /// null = the panel's default rolling release.
  Future<String> agentUpdate(String vpsId, {String? tag}) async =>
      ((await post(_a(vpsId, 'update'), body: tag == null ? const {} : {'tag': tag})) as Map)['result']
          as String? ??
      '';

  Future<String> agentRollback(String vpsId) async =>
      ((await post(_a(vpsId, 'rollback'))) as Map)['result'] as String? ?? '';

  Future<void> setPowerMode(String mode) =>
      post('/api/ui/power-mode', body: {'mode': mode});
}
