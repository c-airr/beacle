import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../alert_sound.dart';
import '../api/api_client.dart';
import '../config.dart';
import '../models/models.dart';
import '../tray.dart';
import '../user_config.dart';

/// Central reactive state: VPS registry, live snapshots, alerts, links.
class AppState extends ChangeNotifier {
  final ApiClient api = ApiClient(backendUrl);

  List<Vps> vpsList = [];
  final Map<String, VpsSnapshot> snapshots = {};
  List<Alert> alerts = [];
  List<ActionLog> actions = [];
  List<VpsLink> links = [];

  /// Rolling fleet averages for Overview sparklines (~24h at 1 sample / min).
  final List<FleetSample> fleetHistory = [];
  static const _historyMax = 24 * 60; // 1/min for 24h
  DateTime? _lastSampleAt;

  bool connected = false;
  String? lastError;

  /// UI power mode sent to backend: active, eco, or sleep.
  String uiPowerMode = 'active';

  IOWebSocketChannel? _ws;
  Timer? _reconnect;
  Timer? _staleCheck;
  Timer? _idleTimer;
  Timer? _sampleTimer;

  static const _idleTimeout = Duration(seconds: 45);

  DateTime alertsSeenAt = DateTime.now();
  int get unseenAlerts => alerts
      .where((a) => !a.resolved && !isMuted(a) && a.createdAt.isAfter(alertsSeenAt))
      .length;
  int get activeAlerts => alerts.where((a) => !a.resolved && !isMuted(a)).length;

  /// Muted "vpsId|type" pairs. Muting the condition rather than the alert row
  /// means the same problem firing again on the same host stays quiet, which is
  /// the point — an alert object is recreated every time it re-triggers.
  final Set<String> _muted = {};
  final UserSettings _settings = UserSettings.load();

  static String _muteKey(Alert a) => '${a.vpsId}|${a.type}';

  bool isMuted(Alert a) => _muted.contains(_muteKey(a));

  void toggleMute(Alert a) {
    final key = _muteKey(a);
    if (!_muted.remove(key)) _muted.add(key);
    _settings.raw['muted_alerts'] = _muted.toList();
    _settings.save();
    notifyListeners();
  }

  void _loadMutes() {
    final saved = _settings.raw['muted_alerts'];
    if (saved is List) {
      _muted.addAll(saved.whereType<String>());
    }
    animationsEnabled = _settings.raw['animations'] != false;
    startMinimised = _settings.raw['start_minimised'] == true;
    closeBehaviour = _settings.raw['close_behaviour'] as String? ?? 'tray';
  }

  /// Hover/selection transitions. No longer exposed as a setting — it stayed
  /// on for everyone anyway, and the flag is what widgets read.
  bool animationsEnabled = true;

  void setAnimationsEnabled(bool on) {
    if (animationsEnabled == on) return;
    animationsEnabled = on;
    _settings.raw['animations'] = on;
    _settings.save();
    notifyListeners();
  }

  /// Come up in the tray rather than on screen. Stored now, acted on once the
  /// tray exists — see the note in the Tray settings card.
  bool startMinimised = false;

  void setStartMinimised(bool on) {
    if (startMinimised == on) return;
    startMinimised = on;
    _settings.raw['start_minimised'] = on;
    _settings.save();
    notifyListeners();
  }

  /// What closing the window does: 'tray' keeps the backend and its alerts
  /// alive, 'quit' shuts the whole thing down.
  String closeBehaviour = 'tray';

  void setCloseBehaviour(String v) {
    if (closeBehaviour == v) return;
    closeBehaviour = v;
    _settings.raw['close_behaviour'] = v;
    _settings.save();
    Tray.setCloseToTray(v == 'tray');
    notifyListeners();
  }

  /// The runner starts with close-to-tray off and cannot read settings itself,
  /// so the stored choice has to be pushed to it once Dart is up.
  void applyTraySettings() => Tray.setCloseToTray(closeBehaviour == 'tray');

  bool get powerSaveMode => uiPowerMode != 'active';

  int get portsRefreshSeconds => switch (uiPowerMode) {
        'sleep' => 120,
        'eco' => 45,
        _ => 10,
      };

  int get staleThresholdSeconds => switch (uiPowerMode) {
        'sleep' => 130,
        'eco' => 50,
        _ => 12,
      };

  final StreamController<Alert> alertStream = StreamController.broadcast();

  Future<void> start() async {
    _loadMutes();
    applyTraySettings();
    await refreshAll();
    _connectWs();
    _staleCheck?.cancel();
    _staleCheck = Timer.periodic(const Duration(seconds: 10), (_) {
      _pruneSnapshots();
      notifyListeners();
    });
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 60), (_) => _sampleFleet());
    _sampleFleet();
    _scheduleIdleTimer();
  }

  /// Set when the power mode changes: agents keep the old tick rate until the
  /// backend has told them about the new one, so for a moment their reports
  /// look late against the new threshold. Without this grace, switching back to
  /// active mode blanked every server for one tick.
  DateTime _powerModeChangedAt = DateTime.now();

  bool isReportStale(Vps v) {
    if (!v.online) return true;
    final age = DateTime.now().difference(v.lastSeen.toLocal()).inSeconds;
    final sinceModeChange = DateTime.now().difference(_powerModeChangedAt).inSeconds;
    if (sinceModeChange < 15 && age <= 60) return false;
    return age > staleThresholdSeconds;
  }

  void bumpActivity() {
    if (uiPowerMode != 'active') {
      uiPowerMode = 'active';
      unawaited(_applyPowerMode());
      unawaited(refreshAll());
    }
    _scheduleIdleTimer();
    notifyListeners();
  }

  void enterEcoMode() {
    if (uiPowerMode == 'eco' || uiPowerMode == 'sleep') return;
    uiPowerMode = 'eco';
    unawaited(_applyPowerMode());
    notifyListeners();
  }

  void enterSleepMode() {
    if (uiPowerMode == 'sleep') return;
    uiPowerMode = 'sleep';
    unawaited(_applyPowerMode());
    notifyListeners();
  }

  void onUserAction() => bumpActivity();

  /// Window regained focus / machine woke up. Anything may have happened to the
  /// socket while we were away, so stop waiting out a backoff and re-check now.
  Future<void> onAppResumed() async {
    bumpActivity();
    _wsBackoff = _wsBackoffMin;
    await refreshAll();
    if (!connected) {
      _reconnect?.cancel();
      _connectWs();
    }
  }

  void _scheduleIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, enterEcoMode);
  }

  Future<void> _applyPowerMode() async {
    _powerModeChangedAt = DateTime.now();
    try {
      await api.setPowerMode(uiPowerMode);
    } catch (_) {}
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
      lastError = null;
      _sampleFleet(force: true);
    } catch (e) {
      // Backend not reachable at all — the live socket is the source of truth
      // for `connected`, but a failed REST call already proves it is down.
      connected = false;
      lastError = '$e';
    }
    notifyListeners();
  }

  void _connectWs() {
    _reconnect?.cancel();
    _ws?.sink.close();
    final wsUrl = '${backendUrl.replaceFirst('http', 'ws')}/ws';
    try {
      final ws = IOWebSocketChannel.connect(wsUrl, pingInterval: const Duration(seconds: 10));
      _ws = ws;
      // Every handler checks it still owns the current socket: closing the old
      // one fires onDone *after* the replacement is live, and acting on that
      // would tear down the healthy connection we just made.
      ws.stream.listen(
        _onWsMessage,
        onDone: () => _onWsClosed(ws),
        onError: (_) => _onWsClosed(ws),
      );
      // Only claim to be connected once the socket is really open — reporting it
      // optimistically hid a backend that was still starting up.
      ws.ready.then((_) {
        if (_ws != ws) return;
        _wsBackoff = _wsBackoffMin;
        connected = true;
        lastError = null;
        notifyListeners();
      }).catchError((Object e) {
        if (_ws != ws) return;
        lastError = '$e';
        _scheduleReconnect();
      });
    } catch (e) {
      lastError = '$e';
      _scheduleReconnect();
    }
  }

  static const _wsBackoffMin = Duration(seconds: 1);
  static const _wsBackoffMax = Duration(seconds: 5);
  Duration _wsBackoff = _wsBackoffMin;

  void _onWsClosed(IOWebSocketChannel ws) {
    if (_ws != ws) return; // a superseded socket finishing its teardown
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    connected = false;
    notifyListeners();
    if (_reconnect?.isActive ?? false) return;
    final wait = _wsBackoff;
    _wsBackoff = wait * 2 > _wsBackoffMax ? _wsBackoffMax : wait * 2;
    _reconnect = Timer(wait, () {
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
        _pruneSnapshots();
        break;
      case 'alert':
        final a = Alert.fromJson(payload as Map<String, dynamic>);
        // The same alert arrives again when its condition clears, carrying the
        // same id and resolved: true. Replacing it is what makes the row leave
        // the active list instead of appearing twice.
        final existing = alerts.indexWhere((x) => x.id == a.id);
        if (existing >= 0) {
          alerts[existing] = a;
        } else {
          alerts.insert(0, a);
        }
        alertStream.add(a);
        // Muted conditions stay silent: muting is a promise to stop bringing
        // this one up, and a chime is bringing it up.
        if (!a.resolved && existing < 0 && !isMuted(a)) AlertSound.play(a.severity);
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

  /// Drops snapshots of servers that left the registry. A late or missing
  /// report is *not* a reason to throw the data away: every screen already
  /// gates on [isReportStale], and discarding it meant a two-second network
  /// blip emptied the whole panel until the next full push arrived.
  void _pruneSnapshots() {
    final known = vpsList.map((v) => v.id).toSet();
    snapshots.removeWhere((id, _) => !known.contains(id));
  }

  void _sampleFleet({bool force = false}) {
    final now = DateTime.now();
    if (!force && _lastSampleAt != null && now.difference(_lastSampleAt!) < const Duration(seconds: 45)) {
      return;
    }
    double cpu = 0, ram = 0, netIn = 0, netOut = 0;
    var n = 0;
    for (final v in vpsList) {
      if (!v.online || isReportStale(v)) continue;
      final m = snapshots[v.id]?.metrics;
      if (m == null) continue;
      cpu += m.cpuPercent;
      ram += m.memPercent;
      for (final net in m.network) {
        netIn += net.rxPerSec.toDouble();
        netOut += net.txPerSec.toDouble();
      }
      n++;
    }
    if (n == 0) return;
    _lastSampleAt = now;
    fleetHistory.add(FleetSample(
      at: now,
      cpu: cpu / n,
      ram: ram / n,
      netIn: netIn,
      netOut: netOut,
    ));
    while (fleetHistory.length > _historyMax) {
      fleetHistory.removeAt(0);
    }
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
    _staleCheck?.cancel();
    _idleTimer?.cancel();
    _sampleTimer?.cancel();
    alertStream.close();
    super.dispose();
  }
}

/// One fleet-wide metric sample for Overview charts.
class FleetSample {
  final DateTime at;
  final double cpu, ram, netIn, netOut;
  const FleetSample({
    required this.at,
    required this.cpu,
    required this.ram,
    required this.netIn,
    required this.netOut,
  });
}
