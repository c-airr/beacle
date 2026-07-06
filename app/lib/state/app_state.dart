import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../models/models.dart';

/// Central reactive state: VPS registry, live snapshots, alerts, links.
class AppState extends ChangeNotifier {
  final ApiClient api = ApiClient(backendUrl);

  List<Vps> vpsList = [];
  final Map<String, VpsSnapshot> snapshots = {};
  List<Alert> alerts = [];
  List<ActionLog> actions = [];
  List<VpsLink> links = [];

  bool connected = false;
  bool hubActive = false;
  String? hubUrl;
  String? hubMessage;
  String? lastError;

  IOWebSocketChannel? _ws;
  Timer? _reconnect;

  DateTime alertsSeenAt = DateTime.now();
  int get unseenAlerts =>
      alerts.where((a) => !a.resolved && a.createdAt.isAfter(alertsSeenAt)).length;
  int get activeAlerts => alerts.where((a) => !a.resolved).length;

  final StreamController<Alert> alertStream = StreamController.broadcast();

  Future<void> start() async {
    await refreshAll();
    _connectWs();
  }

  Future<void> refreshAll() async {
    try {
      final o = await api.overview();
      vpsList = ((o['vps'] as List?) ?? []).map((e) => Vps.fromJson(e)).toList();
      for (final s in (o['snapshots'] as List?) ?? []) {
        final snap = VpsSnapshot.fromJson(s as Map<String, dynamic>);
        snapshots[snap.vps.id] = snap;
      }
      alerts = ((o['alerts'] as List?) ?? []).map((e) => Alert.fromJson(e)).toList().reversed.toList();
      actions = ((o['actions'] as List?) ?? []).map((e) => ActionLog.fromJson(e)).toList().reversed.toList();
      links = ((o['links'] as List?) ?? []).map((e) => VpsLink.fromJson(e)).toList();
      final hub = o['hub'] as Map<String, dynamic>?;
      hubActive = hub?['active'] == true;
      hubUrl = hub?['hub_url'] as String?;
      hubMessage = hub?['message'] as String?;
      connected = true;
      lastError = null;
    } catch (e) {
      connected = false;
      lastError = '$e';
    }
    notifyListeners();
  }

  void _connectWs() {
    _ws?.sink.close();
    final wsUrl = '${backendUrl.replaceFirst('http', 'ws')}/ws';
    try {
      _ws = IOWebSocketChannel.connect(wsUrl, pingInterval: const Duration(seconds: 15));
      _ws!.stream.listen(_onWsMessage, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
      connected = true;
      notifyListeners();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    connected = false;
    notifyListeners();
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), () {
      refreshAll();
      _connectWs();
    });
  }

  void _onWsMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final payload = msg['payload'];
    switch (msg['type']) {
      case 'vps_update':
        final snap = VpsSnapshot.fromJson(payload as Map<String, dynamic>);
        snapshots[snap.vps.id] = snap;
        final i = vpsList.indexWhere((v) => v.id == snap.vps.id);
        if (i >= 0) {
          vpsList[i] = snap.vps;
        } else {
          vpsList.add(snap.vps);
        }
        break;
      case 'vps_list':
        vpsList = ((payload as List?) ?? []).map((e) => Vps.fromJson(e)).toList();
        break;
      case 'alert':
        final a = Alert.fromJson(payload as Map<String, dynamic>);
        alerts.insert(0, a);
        alertStream.add(a);
        break;
      case 'link_update':
        final l = VpsLink.fromJson(payload as Map<String, dynamic>);
        final i = links.indexWhere((x) => x.id == l.id);
        if (i >= 0) {
          links[i] = l;
        } else {
          links.add(l);
        }
        break;
      case 'action':
        actions.insert(0, ActionLog.fromJson(payload as Map<String, dynamic>));
        if (actions.length > 300) actions.removeLast();
        break;
    }
    notifyListeners();
  }

  void markAlertsSeen() {
    alertsSeenAt = DateTime.now();
    notifyListeners();
  }

  Future<void> resolveAlert(String id) async {
    await api.resolveAlert(id);
    alerts = await api.alerts();
    alerts = alerts.reversed.toList();
    notifyListeners();
  }

  Future<void> refreshLinks() async {
    links = await api.links();
    notifyListeners();
  }

  @override
  void dispose() {
    _ws?.sink.close();
    _reconnect?.cancel();
    alertStream.close();
    super.dispose();
  }
}
