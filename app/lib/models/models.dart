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

class DockerVolume {
  final String name, driver, mountpoint, scope, createdAt;
  DockerVolume.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        driver = _s(j['driver']),
        mountpoint = _s(j['mountpoint']),
        scope = _s(j['scope']),
        createdAt = _s(j['created_at']);
}

class DockerNetwork {
  final String id, name, driver, scope;
  final int containers;
  DockerNetwork.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        driver = _s(j['driver']),
        scope = _s(j['scope']),
        containers = _i(j['containers']);
}

class DockerState {
  final bool available;
  final String error, version;
  final List<ContainerInfo> containers;
  final List<ContainerStats> stats;
  final List<ImageInfo> images;
  final List<ComposeProject> compose;
  final List<DockerVolume> volumes;
  final List<DockerNetwork> networks;
  DockerState.fromJson(Map<String, dynamic> j)
      : available = _b(j['available']),
        error = _s(j['error']),
        version = _s(j['version']),
        containers = _list(j['containers'], ContainerInfo.fromJson),
        stats = _list(j['stats'], ContainerStats.fromJson),
        images = _list(j['images'], ImageInfo.fromJson),
        compose = _list(j['compose'], ComposeProject.fromJson),
        volumes = _list(j['volumes'], DockerVolume.fromJson),
        networks = _list(j['networks'], DockerNetwork.fromJson);
  DockerState.empty() : this.fromJson(const {});
}

class SystemdUnit {
  final String name, description, loadState, activeState, subState, enabled;

  /// The unit's process, so a service can be shown with the CPU and memory of
  /// what it actually runs. 0 when the unit is not running.
  final int mainPid;
  SystemdUnit.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        description = _s(j['description']),
        loadState = _s(j['load_state']),
        activeState = _s(j['active_state']),
        subState = _s(j['sub_state']),
        enabled = _s(j['enabled']),
        mainPid = _i(j['main_pid']);
}

class ScreenSession {
  final int pid, childPid;
  final String name, created, command;
  final bool attached, running;
  ScreenSession.fromJson(Map<String, dynamic> j)
      : pid = _i(j['pid']),
        childPid = _i(j['child_pid']),
        name = _s(j['name']),
        created = _s(j['created']),
        command = _s(j['command']),
        attached = _b(j['attached']),
        running = _b(j['running']);
}

/// One recorded point in a server's history. Written once a minute by the
/// backend and kept for a fortnight, so the panel can answer questions asked
/// after the fact — what was this box doing at 4am.
class MetricSample {
  final DateTime at;
  final double cpu, mem, disk, load1;
  final int rxPerS, txPerS;
  MetricSample.fromJson(Map<String, dynamic> j)
      : at = _dt(j['at']),
        cpu = _d(j['cpu']),
        mem = _d(j['mem']),
        disk = _d(j['disk']),
        load1 = _d(j['load1']),
        rxPerS = _i(j['rx']),
        txPerS = _i(j['tx']);
}

/// A server's history plus the span actually on disk, so the chart can bound
/// scrolling to real data instead of offering two empty weeks.
/// A stretch when the panel itself was not running.
///
/// History is recorded by the backend, so nothing is written while the app is
/// closed. Those gaps look exactly like a server that went away, and were
/// drawn as outages — a fortnight of ordinary nights read as a fleet that kept
/// falling over.
class PanelDowntime {
  final DateTime from, to;
  const PanelDowntime(this.from, this.to);
}

/// One process as it was during a spike.
class SpikeProcess {
  final int pid;
  final String name, user, command;
  final double cpu, mem;
  SpikeProcess.fromJson(Map<String, dynamic> j)
      : pid = _i(j['pid']),
        name = _s(j['name']),
        user = _s(j['user']),
        command = _s(j['cmd']),
        cpu = _d(j['cpu']),
        mem = _d(j['mem']);
}

/// What a server was running when a metric jumped.
///
/// The chart says when something happened; this says what. A process list only
/// describes the present, so by morning the cause of a four a.m. spike is gone
/// unless something wrote it down at the time — which is what the agent does.
class SpikeRecord {
  final DateTime at;

  /// "cpu" or "mem".
  final String metric;

  /// The reading, and what this machine normally sits at, so the panel can say
  /// "30%, usually 8%" rather than a bare number that means nothing without it.
  final double value, baseline;
  final List<SpikeProcess> top;

  SpikeRecord.fromJson(Map<String, dynamic> j)
      : at = _dt(j['at']),
        metric = _s(j['metric']),
        value = _d(j['value']),
        baseline = _d(j['baseline']),
        top = ((j['top'] as List?) ?? const [])
            .map((e) => SpikeProcess.fromJson(e as Map<String, dynamic>))
            .toList();
}

class MetricHistory {
  final List<MetricSample> samples;
  final DateTime? first, last;

  /// Windows the panel was closed for, so a gap can say which it is.
  final List<PanelDowntime> panelDown;

  /// Moments a metric departed from this machine's baseline, with what was
  /// running at the time.
  final List<SpikeRecord> spikes;

  MetricHistory({
    required this.samples,
    this.first,
    this.last,
    this.panelDown = const [],
    this.spikes = const [],
  });

  factory MetricHistory.fromJson(Map<String, dynamic> j) {
    DateTime? bound(dynamic v) {
      final t = _dt(v);
      // The backend sends a zero time when it holds nothing for this server.
      return t.millisecondsSinceEpoch == 0 || t.year < 2000 ? null : t;
    }

    return MetricHistory(
      samples: ((j['samples'] as List?) ?? const [])
          .map((e) => MetricSample.fromJson(e as Map<String, dynamic>))
          .toList(),
      first: bound(j['first']),
      last: bound(j['last']),
      panelDown: ((j['panel_down'] as List?) ?? const [])
          .map((e) => PanelDowntime(
                _dt((e as Map<String, dynamic>)['from']),
                _dt(e['to']),
              ))
          .toList(),
      spikes: ((j['spikes'] as List?) ?? const [])
          .map((e) => SpikeRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isEmpty => samples.isEmpty;
}

/// What the panel sends to create a service. The agent renders this into the
/// unit file — the panel never composes unit text itself, so there is one
/// place that decides what a Beacle-made unit looks like.
class SystemdUnitSpec {
  final String name, description, execStart, workingDir, user, restart, after;
  final int restartSec;
  final Map<String, String> env;
  final bool enableAtBoot, startNow, overwrite;

  const SystemdUnitSpec({
    required this.name,
    required this.execStart,
    this.description = '',
    this.workingDir = '',
    this.user = '',
    this.restart = 'always',
    this.restartSec = 3,
    this.after = '',
    this.env = const {},
    this.enableAtBoot = true,
    this.startNow = true,
    this.overwrite = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'exec_start': execStart,
        'working_dir': workingDir,
        'user': user,
        'restart': restart,
        'restart_sec': restartSec,
        'after': after,
        'env': env,
        'enable_at_boot': enableAtBoot,
        'start_now': startNow,
        'overwrite': overwrite,
      };
}

/// The rendered unit plus systemd's verdict on it, so the panel can show
/// exactly what would be written before anything is.
class SystemdUnitPreview {
  final String path, unit, output;
  final bool valid, exists;
  SystemdUnitPreview.fromJson(Map<String, dynamic> j)
      : path = _s(j['path']),
        unit = _s(j['unit']),
        output = _s(j['output']),
        valid = _b(j['valid']),
        exists = _b(j['exists']);
}

/// The combined stdout/stderr of a one-shot `docker exec` command.
class DockerExecResult {
  final String output;
  final int exitCode;
  final bool truncated;
  DockerExecResult.fromJson(Map<String, dynamic> j)
      : output = _s(j['output']),
        exitCode = _i(j['exit_code']),
        truncated = _b(j['truncated']);
}

/// Estimate of what a docker prune would reclaim, shown on the confirmation.
class PrunePreview {
  final int danglingImages, unusedVolumes;
  final int danglingBytes, unusedVolumesBytes;
  PrunePreview.fromJson(Map<String, dynamic> j)
      : danglingImages = _i(j['dangling_images']),
        unusedVolumes = _i(j['unused_volumes']),
        danglingBytes = _i(j['dangling_bytes']),
        unusedVolumesBytes = _i(j['unused_volumes_bytes']);
  int get totalBytes => danglingBytes + unusedVolumesBytes;
}

/// What a docker prune actually removed.
class PruneResult {
  final int imagesDeleted, volumesDeleted, spaceReclaimed;
  final String output;
  PruneResult.fromJson(Map<String, dynamic> j)
      : imagesDeleted = _i(j['images_deleted']),
        volumesDeleted = _i(j['volumes_deleted']),
        spaceReclaimed = _i(j['space_reclaimed_bytes']),
        output = _s(j['output']);
}

/// One readable system log on a VPS. The UI only ever sends [id] back.
class SystemLogFile {
  final String id, label, path;
  SystemLogFile.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        label = _s(j['label']),
        path = _s(j['path']);
}

/// One upgradable system package.
class OSPackage {
  final String name, current, latest;
  final bool security;

  /// Listed as upgradable, but an upgrade would not install it (a phased
  /// rollout, or it needs another package removed).
  final bool held;
  OSPackage.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        current = _s(j['current']),
        latest = _s(j['latest']),
        security = _b(j['security']),
        held = _b(j['held']);
}

/// Pending system updates of a host.
class OSUpdates {
  final String manager, checkedAt;
  /// What an upgrade would install. Held packages are kept apart: counting
  /// them offered an upgrade that changed nothing, again and again.
  final List<OSPackage> packages;
  final List<OSPackage> held;
  final int securityCount;
  final bool rebootRequired;
  OSUpdates._(this.manager, this.checkedAt, List<OSPackage> all, this.securityCount, this.rebootRequired)
      : packages = all.where((p) => !p.held).toList(),
        held = all.where((p) => p.held).toList();
  OSUpdates.fromJson(Map<String, dynamic> j)
      : this._(
          _s(j['manager']),
          _s(j['checked_at']),
          _list(j['packages'], OSPackage.fromJson),
          _i(j['security_count']),
          _b(j['reboot_required']),
        );
}

/// A background `upgrade -y` run.
class OSUpdateJob {
  final bool running;
  final String startedAt, finishedAt, output;
  final int exitCode;
  OSUpdateJob.fromJson(Map<String, dynamic> j)
      : running = _b(j['running']),
        startedAt = _s(j['started_at']),
        finishedAt = _s(j['finished_at']),
        output = _s(j['output']),
        exitCode = _i(j['exit_code']);
  bool get hasRun => startedAt.isNotEmpty;
}

/// One scheduled job: a row of root's crontab (editable), a system cron file
/// row (read-only) or a systemd timer (read-only, separate list).
class CronEntry {
  final String id, source, minute, hour, dayMonth, month, dayWeek;
  final String user, command;
  final bool editable;
  CronEntry.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        source = _s(j['source']),
        minute = _s(j['minute']),
        hour = _s(j['hour']),
        dayMonth = _s(j['day_month']),
        month = _s(j['month']),
        dayWeek = _s(j['day_week']),
        user = _s(j['user']),
        command = _s(j['command']),
        editable = _b(j['editable']);
  String get schedule => minute == '@reboot' ? '@reboot' : '$minute $hour $dayMonth $month $dayWeek';
}

/// One row of `systemctl list-timers`.
class SystemdTimer {
  final String unit, active, next, last;
  SystemdTimer.fromJson(Map<String, dynamic> j)
      : unit = _s(j['unit']),
        active = _s(j['active']),
        next = _s(j['next']),
        last = _s(j['last']);
}

class CronState {
  final List<CronEntry> entries;
  final List<SystemdTimer> timers;
  final bool cronAvailable;
  CronState.fromJson(Map<String, dynamic> j)
      : entries = _list(j['entries'], CronEntry.fromJson),
        timers = _list(j['timers'], SystemdTimer.fromJson),
        cronAvailable = _b(j['cron_available']);
}

/// Editable shape of a crontab row.
class CronEntrySpec {
  String minute, hour, dayMonth, month, dayWeek, command;
  CronEntrySpec(
      {this.minute = '*',
      this.hour = '*',
      this.dayMonth = '*',
      this.month = '*',
      this.dayWeek = '*',
      this.command = ''});
  CronEntrySpec.fromEntry(CronEntry e)
      : minute = e.minute,
        hour = e.hour,
        dayMonth = e.dayMonth,
        month = e.month,
        dayWeek = e.dayWeek,
        command = e.command;
  Map<String, dynamic> toJson() => {
        'minute': minute,
        'hour': hour,
        'day_month': dayMonth,
        'month': month,
        'day_week': dayWeek,
        'command': command,
      };
}

/// One input rule in the active firewall backend's native terms.
class FirewallRule {
  final String id, action, proto, port, source, comment, raw;
  final bool protected;
  FirewallRule.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        action = _s(j['action']),
        proto = _s(j['proto']),
        port = _s(j['port']),
        source = _s(j['source']),
        comment = _s(j['comment']),
        raw = _s(j['raw']),
        protected = _b(j['protected']);
  String get summary {
    final what = port.isEmpty ? (source.isEmpty ? 'all' : source) : '$port/$proto';
    final from = port.isEmpty || source.isEmpty ? '' : ' from $source';
    return '$action $what$from';
  }
}

class FirewallStatus {
  final String backend, backendDetail, defaultIncoming, note;
  final bool enabled, editable;
  final List<FirewallRule> rules;
  final List<int> protectedPorts;
  final List<PortInfo> openPorts;
  FirewallStatus.fromJson(Map<String, dynamic> j)
      : backend = _s(j['backend']),
        backendDetail = _s(j['backend_detail']),
        defaultIncoming = _s(j['default_incoming']),
        note = _s(j['note']),
        enabled = _b(j['enabled']),
        editable = _b(j['editable']),
        rules = _list(j['rules'], FirewallRule.fromJson),
        protectedPorts = ((j['protected_ports'] as List?) ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
        openPorts = _list(j['open_ports'], PortInfo.fromJson);
}

class FirewallRuleSpec {
  String action, proto, port, source, comment;
  FirewallRuleSpec(
      {this.action = 'allow',
      this.proto = 'tcp',
      this.port = '',
      this.source = '',
      this.comment = ''});
  Map<String, dynamic> toJson() => {
        'action': action,
        'proto': proto,
        'port': port,
        'source': source,
        'comment': comment,
      };
}

class FirewallDryRun {
  final List<String> commands;
  final String warning;
  FirewallDryRun.fromJson(Map<String, dynamic> j)
      : commands = ((j['commands'] as List?) ?? []).map((e) => '$e').toList(),
        warning = _s(j['warning']);
}

class FirewallMutation {
  final bool ok;
  final String warning;
  FirewallMutation.fromJson(Map<String, dynamic> j)
      : ok = _b(j['ok']),
        warning = _s(j['warning']);
}

class RebootResult {
  final bool ok;
  final int screensQueued, nohupQueued;
  RebootResult.fromJson(Map<String, dynamic> j)
      : ok = _b(j['ok']),
        screensQueued = _i(j['screens_queued']),
        nohupQueued = _i(j['nohup_queued']);
}

class RestoreItemResult {
  final String name, error;
  final bool ok;
  RestoreItemResult.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        error = _s(j['error']),
        ok = _b(j['ok']);
}

class RestoreResult {
  final bool restored;
  final String restoredAt;
  final List<RestoreItemResult> screens, nohup;
  RestoreResult.fromJson(Map<String, dynamic> j)
      : restored = _b(j['restored']),
        restoredAt = _s(j['restored_at']),
        screens = _list(j['screens'], RestoreItemResult.fromJson),
        nohup = _list(j['nohup'], RestoreItemResult.fromJson);
  int get total => screens.length + nohup.length;
  int get failed =>
      screens.where((e) => !e.ok).length + nohup.where((e) => !e.ok).length;
}

/// One notification destination: Discord webhook URL, ntfy topic URL, or a
/// Telegram bot token plus chat id.
class WebhookTarget {
  String id, kind, url, chatId;
  WebhookTarget({this.id = '', this.kind = 'discord', this.url = '', this.chatId = ''});
  WebhookTarget.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        kind = _s(j['kind']),
        url = _s(j['url']),
        chatId = _s(j['chat_id']);
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'url': url,
        'chat_id': chatId,
      };
}

/// Webhook destinations plus the currently elected fleet watchers.
class WebhooksConfig {
  final List<WebhookTarget> targets;
  final Vps? primary, secondary;
  WebhooksConfig.fromJson(Map<String, dynamic> j)
      : targets = _list(j['targets'], WebhookTarget.fromJson),
        primary = j['primary'] is Map<String, dynamic>
            ? Vps.fromJson(j['primary'] as Map<String, dynamic>)
            : null,
        secondary = j['secondary'] is Map<String, dynamic>
            ? Vps.fromJson(j['secondary'] as Map<String, dynamic>)
            : null;
}

/// A command started detached with nohup. No terminal to reattach to, so the
/// agent remembers it — otherwise there would be no way to stop it later.
class NohupJob {
  final int pid;
  final String name, command, dir, logFile, started;
  final bool running;
  NohupJob.fromJson(Map<String, dynamic> j)
      : pid = _i(j['pid']),
        name = _s(j['name']),
        command = _s(j['command']),
        dir = _s(j['dir']),
        logFile = _s(j['log_file']),
        started = _s(j['started']),
        running = _b(j['running']);
}

/// One entry of a remote directory listing (screen command picker).
class FsEntry {
  final String name, path, mode;
  final bool isDir;
  final int size;

  /// Explorer-only fields; the screen picker's listing leaves them empty.
  final DateTime? modTime;
  final String owner;

  /// Symlink target, empty for anything else.
  final String link;

  /// Opaque file state, sent back on save so a file edited on the server in
  /// the meantime is not overwritten.
  final String version;

  FsEntry.fromJson(Map<String, dynamic> j)
      : name = _s(j['name']),
        path = _s(j['path']),
        mode = _s(j['mode']),
        isDir = _b(j['is_dir']),
        size = _i(j['size']),
        modTime = j['mtime'] == null ? null : DateTime.tryParse(j['mtime'] as String),
        owner = _s(j['owner']),
        link = _s(j['link']),
        version = _s(j['version']);
}

/// One chunk of a remote file; [data] is base64 on the wire.
class FsChunk {
  final String path, version, data;
  final int size, offset;
  final bool eof, binary;
  FsChunk.fromJson(Map<String, dynamic> j)
      : path = _s(j['path']),
        version = _s(j['version']),
        data = _s(j['data']),
        size = _i(j['size']),
        offset = _i(j['offset']),
        eof = _b(j['eof']),
        binary = _b(j['binary']);
}

class FsListing {
  final String path, parent;
  final List<FsEntry> entries;
  FsListing.fromJson(Map<String, dynamic> j)
      : path = _s(j['path']),
        parent = _s(j['parent']),
        entries = _list(j['entries'], FsEntry.fromJson);
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

  /// Local port parsed from [upstream], plus whether anything answers there.
  final int upstreamPort;
  final bool portInUse, upstreamHealthy;

  final bool redirectWww, forceHttps, webSocket, gzip, accessLog;
  final String basicAuthUser, basicAuthHash;
  final Map<String, String> headers;

  /// Where the site came from and whether the form may rewrite it.
  final bool managed, editable;

  /// Set when the block was written by hand in the raw editor. The fields above
  /// are then only a summary — the config is whatever is in [rawConfig].
  final bool rawEdited;
  final String readOnlyReason, kind, tlsMode, sourceFile, rawConfig;
  final List<String> domains;

  ProxySite.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        domain = _s(j['domain']),
        upstream = _s(j['upstream']),
        ssl = _s(j['ssl']),
        provider = _s(j['provider']),
        enabled = _b(j['enabled']),
        upstreamPort = _i(j['upstream_port']),
        portInUse = _b(j['port_in_use']),
        upstreamHealthy = _b(j['upstream_healthy']),
        redirectWww = _b(j['redirect_www']),
        forceHttps = _b(j['force_https']),
        webSocket = _b(j['websocket']),
        gzip = _b(j['gzip']),
        accessLog = _b(j['access_log']),
        basicAuthUser = _s(j['basic_auth_user']),
        basicAuthHash = _s(j['basic_auth_hash']),
        headers = (j['headers'] as Map?)?.map((k, v) => MapEntry(k as String, '$v')) ?? {},
        managed = _b(j['managed']),
        editable = _b(j['editable']),
        rawEdited = _b(j['raw_edited']),
        readOnlyReason = _s(j['read_only_reason']),
        kind = _s(j['kind']),
        tlsMode = _s(j['tls_mode']),
        sourceFile = _s(j['source_file']),
        rawConfig = _s(j['raw_config']),
        domains = ((j['domains'] as List?) ?? const []).map((e) => '$e').toList(),
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
  final String transport, wgEndpoint, wgTunnelIp, wgPublicKey;

  /// sha256 of the binary this agent is running, as `sha256:<hex>`. Empty for
  /// agents too old to report it. Compared against the release asset's digest
  /// to answer whether an update would actually change anything — a version
  /// number cannot, since a rebuild under the same tag keeps its number.
  final String agentDigest;

  /// The agent's GOARCH ("amd64", "arm64"). Empty for agents too old to report
  /// it. Decides which release asset this server is compared against.
  final String arch;

  /// Free-form grouping tags (#prod, #db). Empty when unset.
  final List<String> tags;

  /// Per-server alert threshold overrides. Null means "use globals".
  final VpsThresholds? thresholds;
  final double latitude, longitude;
  final int weight, agentPort;
  final DateTime createdAt, lastSeen;
  Vps.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        host = _s(j['host']),
        tailscaleName = _s(j['tailscale_name']),
        publicIp = _s(j['public_ip']),
        transport = _s(j['transport']),
        wgEndpoint = _s(j['wg_endpoint']),
        wgTunnelIp = _s(j['wg_tunnel_ip']),
        wgPublicKey = _s(j['wg_public_key']),
        location = _s(j['location']),
        status = _s(j['status']),
        agentVersion = _s(j['agent_version']),
        agentDigest = _s(j['agent_digest']),
        arch = _s(j['arch']),
        tags = (j['tags'] as List?)?.map((e) => '$e').toList() ?? const [],
        thresholds = j['thresholds'] is Map<String, dynamic>
            ? VpsThresholds.fromJson(j['thresholds'] as Map<String, dynamic>)
            : null,
        latitude = _d(j['latitude']),
        longitude = _d(j['longitude']),
        weight = _i(j['weight']),
        agentPort = _i(j['agent_port']),
        createdAt = _dt(j['created_at']),
        lastSeen = _dt(j['last_seen']);

  bool get isWireGuard => transport == 'wireguard';
  bool get isTailscale => !isWireGuard;

  bool get online => status == 'online' || status == 'high_load';

  /// True when agent reports stopped arriving (metrics/processes may be stale).
  bool get reportStale {
    if (!online) return true;
    return DateTime.now().difference(lastSeen.toLocal()).inSeconds > 12;
  }
}

/// Per-server alert threshold overrides. Zero means "use the global value".
class VpsThresholds {
  final double cpuHigh, memHigh, diskHigh;
  VpsThresholds({this.cpuHigh = 0, this.memHigh = 0, this.diskHigh = 0});
  VpsThresholds.fromJson(Map<String, dynamic> j)
      : cpuHigh = _d(j['cpu_high']),
        memHigh = _d(j['mem_high']),
        diskHigh = _d(j['disk_high']);
  Map<String, dynamic> toJson() => {
        'cpu_high': cpuHigh,
        'mem_high': memHigh,
        'disk_high': diskHigh,
      };
  bool get isCustom => cpuHigh > 0 || memHigh > 0 || diskHigh > 0;
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

class ConnectivityProbe {
  final String host, ip, ipClass, recommended, reason;
  final bool pingOk, wireguardOk;
  final double latencyMs;
  ConnectivityProbe.fromJson(Map<String, dynamic> j)
      : host = _s(j['host']),
        ip = _s(j['ip']),
        ipClass = _s(j['class']),
        recommended = _s(j['recommended']),
        reason = _s(j['reason']),
        pingOk = _b(j['ping_ok']),
        wireguardOk = _b(j['wireguard_ok']),
        latencyMs = _d(j['latency_ms']);
}

class WgPeerStatus {
  final String vpsId, name, endpoint, tunnelIp;
  final int lastHandshake, rxBytes, txBytes;
  WgPeerStatus.fromJson(Map<String, dynamic> j)
      : vpsId = _s(j['vps_id']),
        name = _s(j['name']),
        endpoint = _s(j['endpoint']),
        tunnelIp = _s(j['tunnel_ip']),
        lastHandshake = _i(j['last_handshake']),
        rxBytes = _i(j['rx_bytes']),
        txBytes = _i(j['tx_bytes']);
}

class WgStatus {
  final bool running;
  final String publicKey, error;
  final List<WgPeerStatus> peers;
  WgStatus.fromJson(Map<String, dynamic> j)
      : running = _b(j['running']),
        publicKey = _s(j['public_key']),
        error = _s(j['error']),
        peers = _list(j['peers'], WgPeerStatus.fromJson);
}

