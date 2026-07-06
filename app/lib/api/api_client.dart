import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class PairingInfo {
  final String token;
  final String installCommand;
  final String setCommand;
  PairingInfo({required this.token, required this.installCommand, required this.setCommand});
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

  // --- backend ---

  Future<bool> health() async {
    try {
      final r = await get('/api/health');
      return r is Map && r['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Vps>> listVps() async =>
      ((await get('/api/vps')) as List? ?? []).map((e) => Vps.fromJson(e)).toList();

  Future<void> deleteVps(String id) => delete('/api/vps/$id');

  Future<Vps> updateVps(String id, Map<String, dynamic> fields) async =>
      Vps.fromJson(await _req('PATCH', '/api/vps/$id', body: fields));

  Future<VpsSnapshot> snapshot(String id) async =>
      VpsSnapshot.fromJson(await get('/api/vps/$id'));

  Future<PairingInfo> createPairingToken() async {
    final j = (await post('/api/pairing/tokens', body: {})) as Map<String, dynamic>;
    return PairingInfo(
      token: j['token'] as String,
      installCommand: j['install_command'] as String,
      setCommand: j['set_command'] as String,
    );
  }

  @Deprecated('use createPairingToken')
  Future<String> installCommand() async =>
      (await createPairingToken()).installCommand;

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

  // --- agent proxy ---

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

  Future<void> systemdAction(String vpsId, String unit, String action) =>
      post(_a(vpsId, 'services/systemd/$unit/$action'));

  Future<String> systemdLogs(String vpsId, String unit, {int lines = 200}) async =>
      ((await get(_a(vpsId, 'services/systemd/$unit/logs?lines=$lines'))) as Map)['logs']
          as String? ??
      '';

  Future<ProxyState> proxyState(String vpsId) async =>
      ProxyState.fromJson(await get(_a(vpsId, 'proxy')));

  Future<ProxySite> proxyAddSite(String vpsId, Map<String, dynamic> req) async =>
      ProxySite.fromJson(await post(_a(vpsId, 'proxy/sites'), body: req));

  Future<ProxySite> proxyUpdateSite(String vpsId, String siteId, Map<String, dynamic> req) async =>
      ProxySite.fromJson(await put(_a(vpsId, 'proxy/sites/$siteId'), body: req));

  Future<void> proxyDeleteSite(String vpsId, String siteId) =>
      delete(_a(vpsId, 'proxy/sites/$siteId'));

  Future<void> proxyReload(String vpsId) => post(_a(vpsId, 'proxy/reload'));

  Future<Map<String, dynamic>> proxyValidate(String vpsId) async =>
      (await post(_a(vpsId, 'proxy/validate'))) as Map<String, dynamic>;

  Future<String> agentUpdate(String vpsId) async =>
      ((await post(_a(vpsId, 'update'))) as Map)['result'] as String? ?? '';

  Future<String> agentRollback(String vpsId) async =>
      ((await post(_a(vpsId, 'rollback'))) as Map)['result'] as String? ?? '';
}
