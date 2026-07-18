// Dart mirrors of shared/models.go (protocol v1).

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;
int _i(dynamic v) => (v as num?)?.toInt() ?? 0;
String _s(dynamic v) => v as String? ?? '';
bool _b(dynamic v) => v as bool? ?? false;

DateTime _dt(dynamic v) =>
    v == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.tryParse(v as String) ?? DateTime.fromMillisecondsSinceEpoch(0);

List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    (v as List?)?.map((e) => f(e as Map<String, dynamic>)).toList() ?? [];

class DiskUsage {
  final String mount, filesystem;
  final int totalBytes, usedBytes;
  final double usedPercent;
  DiskUsage.fromJson(Map<String, dynamic> j)
      : mount = _s(j['mount']),
        filesystem = _s(j['filesystem']),
        totalBytes = _i(j['total_bytes']),
        usedBytes = _i(j['used_bytes']),
        usedPercent = _d(j['used_percent']);
}

class NetworkStats {
  final String iface;
  final int rxBytes, txBytes, rxPerSec, txPerSec;
  NetworkStats.fromJson(Map<String, dynamic> j)
      : iface = _s(j['interface']),
        rxBytes = _i(j['rx_bytes']),
        txBytes = _i(j['tx_bytes']),
        rxPerSec = _i(j['rx_per_sec']),
        txPerSec = _i(j['tx_per_sec']);
}

class SystemMetrics {
  final String hostname, os, kernel, arch, cpuModel;
  final double cpuPercent, memPercent, memPercentCached, load1, load5, load15;
  final int cpuCores, memTotalBytes, memUsedBytes, memCachedBytes, memUsedCachedBytes;
  final int swapTotal, swapUsed, uptimeSeconds;
  final List<double> cpuPerCore;
  final List<DiskUsage> disks;
  final List<NetworkStats> network;
  SystemMetrics.fromJson(Map<String, dynamic> j)
      : hostname = _s(j['hostname']),
        os = _s(j['os']),
        kernel = _s(j['kernel']),
        arch = _s(j['arch']),
        cpuModel = _s(j['cpu_model']),
        cpuPercent = _d(j['cpu_percent']),
        memPercent = _d(j['mem_percent']),
        memPercentCached = _d(j['mem_percent_cached']),
        load1 = _d(j['load1']),
        load5 = _d(j['load5']),
        load15 = _d(j['load15']),
        cpuCores = _i(j['cpu_cores']),
        memTotalBytes = _i(j['mem_total_bytes']),
        memUsedBytes = _i(j['mem_used_bytes']),
        memCachedBytes = _i(j['mem_cached_bytes']),
        memUsedCachedBytes = _i(j['mem_used_cached_bytes']),
        swapTotal = _i(j['swap_total_bytes']),
        swapUsed = _i(j['swap_used_bytes']),
        uptimeSeconds = _i(j['uptime_seconds']),
        cpuPerCore = (j['cpu_per_core'] as List?)?.map((e) => _d(e)).toList() ?? const [],
        disks = _list(j['disks'], DiskUsage.fromJson),
        network = _list(j['network'], NetworkStats.fromJson);
  SystemMetrics.empty() : this.fromJson(const {});
}

class ProcessInfo {
  final int pid, memBytes;
  final String name, user, command, state;
  final double cpuPercent, memPercent;
  ProcessInfo.fromJson(Map<String, dynamic> j)
      : pid = _i(j['pid']),
        memBytes = _i(j['mem_bytes']),
        name = _s(j['name']),
        user = _s(j['user']),
        command = _s(j['command']),
        state = _s(j['state']),
        cpuPercent = _d(j['cpu_percent']),
        memPercent = _d(j['mem_percent']);
}

class PortInfo {
  final int port, pid;
  final String protocol, listenAddr, processName, commandLine, healthDetail;
  final bool healthy;
  PortInfo.fromJson(Map<String, dynamic> j)
      : port = _i(j['port']),
        pid = _i(j['pid']),
        protocol = _s(j['protocol']),
        listenAddr = _s(j['listen_addr']),
        processName = _s(j['process_name']),
        commandLine = _s(j['command_line']),
        healthDetail = _s(j['health_detail']),
        healthy = _b(j['healthy']);
}

class ContainerPort {
  final int privatePort, publicPort;
  final String protocol, ip;
  ContainerPort.fromJson(Map<String, dynamic> j)
      : privatePort = _i(j['private_port']),
        publicPort = _i(j['public_port']),
        protocol = _s(j['protocol']),
        ip = _s(j['ip']);
}

class ContainerInfo {
  final String id, name, image, state, status, composeProject, composeService;
  final int restartCount, exitCode;
  final List<ContainerPort> ports;
  ContainerInfo.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        image = _s(j['image']),
        state = _s(j['state']),
        status = _s(j['status']),
        composeProject = _s(j['compose_project']),
        composeService = _s(j['compose_service']),
        restartCount = _i(j['restart_count']),
        exitCode = _i(j['exit_code']),
        ports = _list(j['ports'], ContainerPort.fromJson);
  bool get running => state == 'running';
}

class ContainerStats {
  final String id, name;
  final double cpuPercent, memPercent;
  final int memUsage, memLimit, netRx, netTx, pids;
  ContainerStats.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        cpuPercent = _d(j['cpu_percent']),
        memPercent = _d(j['mem_percent']),
        memUsage = _i(j['mem_usage_bytes']),
        memLimit = _i(j['mem_limit_bytes']),
        netRx = _i(j['net_rx_bytes']),
        netTx = _i(j['net_tx_bytes']),
        pids = _i(j['pids']);
}

class ImageInfo {
  final String id;
  final List<String> tags;
  final int sizeBytes, createdAt;
  ImageInfo.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        tags = (j['tags'] as List?)?.cast<String>() ?? [],
        sizeBytes = _i(j['size_bytes']),
        createdAt = _i(j['created_at']);
}

class ComposeProject {
  final String name, workingDir, configFile;
  final List<String> services;
  final int running, total;
  ComposeProject.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        workingDir = _s(j['working_dir']),
        configFile = _s(j['config_file']),
        services = (j['services'] as List?)?.cast<String>() ?? [],
        running = _i(j['running']),
        total = _i(j['total']);
}

class DockerState {
  final bool available;
  final String error, version;
  final List<ContainerInfo> containers;
  final List<ContainerStats> stats;
  final List<ImageInfo> images;
  final List<ComposeProject> compose;
  DockerState.fromJson(Map<String, dynamic> j)
      : available = _b(j['available']),
        error = _s(j['error']),
        version = _s(j['version']),
        containers = _list(j['containers'], ContainerInfo.fromJson),
        stats = _list(j['stats'], ContainerStats.fromJson),
        images = _list(j['images'], ImageInfo.fromJson),
        compose = _list(j['compose'], ComposeProject.fromJson);
  DockerState.empty() : this.fromJson(const {});
}

class SystemdUnit {
  final String name, description, loadState, activeState, subState, enabled;
  SystemdUnit.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        description = _s(j['description']),
        loadState = _s(j['load_state']),
        activeState = _s(j['active_state']),
        subState = _s(j['sub_state']),
        enabled = _s(j['enabled']);
}

class ScreenSession {
  final int pid;
  final String name, created;
  final bool attached;
  ScreenSession.fromJson(Map<String, dynamic> j)
      : pid = _i(j['pid']),
        name = _s(j['name']),
        created = _s(j['created']),
        attached = _b(j['attached']);
}

class ServicesState {
  final List<SystemdUnit> systemd;
  final List<ScreenSession> screen;
  ServicesState.fromJson(Map<String, dynamic> j)
      : systemd = _list(j['systemd'], SystemdUnit.fromJson),
        screen = _list(j['screen'], ScreenSession.fromJson);
  ServicesState.empty() : this.fromJson(const {});
}

class ProxySite {
  final String id, domain, upstream, ssl, provider;
  final bool enabled;
  final Map<String, String> extra;
  ProxySite.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        domain = _s(j['domain']),
        upstream = _s(j['upstream']),
        ssl = _s(j['ssl']),
        provider = _s(j['provider']),
        enabled = _b(j['enabled']),
        extra = (j['extra'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? {};
}

class ProxyState {
  final String provider, version, lastError;
  final bool running;
  final List<ProxySite> sites;
  ProxyState.fromJson(Map<String, dynamic> j)
      : provider = _s(j['provider']),
        version = _s(j['version']),
        lastError = _s(j['last_error']),
        running = _b(j['running']),
        sites = _list(j['sites'], ProxySite.fromJson);
  ProxyState.empty() : this.fromJson(const {});
}

class PingResult {
  final String target;
  final double latencyMs, packetLoss;
  final bool reachable;
  PingResult.fromJson(Map<String, dynamic> j)
      : target = _s(j['target']),
        latencyMs = _d(j['latency_ms']),
        packetLoss = _d(j['packet_loss']),
        reachable = _b(j['reachable']);
}

class Vps {
  final String id, name, host, tailscaleName, publicIp, location, status, agentVersion;
  final double latitude, longitude;
  final int weight, agentPort;
  final DateTime createdAt, lastSeen;
  Vps.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        host = _s(j['host']),
        tailscaleName = _s(j['tailscale_name']),
        publicIp = _s(j['public_ip']),
        location = _s(j['location']),
        status = _s(j['status']),
        agentVersion = _s(j['agent_version']),
        latitude = _d(j['latitude']),
        longitude = _d(j['longitude']),
        weight = _i(j['weight']),
        agentPort = _i(j['agent_port']),
        createdAt = _dt(j['created_at']),
        lastSeen = _dt(j['last_seen']);

  bool get online => status == 'online' || status == 'high_load';

  /// True when agent reports stopped arriving (metrics/processes may be stale).
  bool get reportStale {
    if (!online) return true;
    return DateTime.now().difference(lastSeen.toLocal()).inSeconds > 12;
  }
}

class VpsLink {
  final String id, fromVpsId, toVpsId, status;
  final double latencyMs, packetLoss;
  final DateTime checkedAt;
  VpsLink.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        fromVpsId = _s(j['from_vps_id']),
        toVpsId = _s(j['to_vps_id']),
        status = _s(j['status']),
        latencyMs = _d(j['latency_ms']),
        packetLoss = _d(j['packet_loss']),
        checkedAt = _dt(j['checked_at']);
}

class Alert {
  final String id, vpsId, vpsName, type, severity, message;
  final DateTime createdAt;
  final bool resolved;
  Alert.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        vpsId = _s(j['vps_id']),
        vpsName = _s(j['vps_name']),
        type = _s(j['type']),
        severity = _s(j['severity']),
        message = _s(j['message']),
        createdAt = _dt(j['created_at']),
        resolved = _b(j['resolved']);
}

class ActionLog {
  final String id, vpsId, vpsName, action, detail;
  final bool ok;
  final DateTime createdAt;
  ActionLog.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        vpsId = _s(j['vps_id']),
        vpsName = _s(j['vps_name']),
        action = _s(j['action']),
        detail = _s(j['detail']),
        ok = _b(j['ok']),
        createdAt = _dt(j['created_at']);
}

class VpsSnapshot {
  final Vps vps;
  final SystemMetrics metrics;
  final DockerState docker;
  final ServicesState services;
  final ProxyState proxy;
  final List<PortInfo> ports;
  final DateTime updated;
  VpsSnapshot.fromJson(Map<String, dynamic> j)
      : vps = Vps.fromJson(j['vps'] as Map<String, dynamic>? ?? const {}),
        metrics = SystemMetrics.fromJson(j['metrics'] as Map<String, dynamic>? ?? const {}),
        docker = DockerState.fromJson(j['docker'] as Map<String, dynamic>? ?? const {}),
        services = ServicesState.fromJson(j['services'] as Map<String, dynamic>? ?? const {}),
        proxy = ProxyState.fromJson(j['proxy'] as Map<String, dynamic>? ?? const {}),
        ports = _list(j['ports'], PortInfo.fromJson),
        updated = _dt(j['updated']);
}

/// Formats bytes for display.
String fmtBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
}

String fmtUptime(int seconds) {
  final d = seconds ~/ 86400, h = (seconds % 86400) ~/ 3600, m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

String fmtAgo(DateTime when) {
  final sec = DateTime.now().difference(when.toLocal()).inSeconds;
  if (sec < 5) return 'just now';
  if (sec < 60) return '${sec}s ago';
  if (sec < 3600) return '${sec ~/ 60}m ago';
  if (sec < 86400) return '${sec ~/ 3600}h ago';
  return '${sec ~/ 86400}d ago';
}
