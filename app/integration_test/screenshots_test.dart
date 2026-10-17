// README screenshots on a made-up fleet, so no real host, IP or domain ends
// up in the repo. Runs in a real window, so text gets the system's fonts:
//   BEACLE_SCREENSHOTS=<folder> APPDATA=<empty folder> flutter test integration_test/screenshots_test.dart -d windows
// APPDATA keeps the test away from this machine's real settings.json.
// main() is never called, so no backend is started or stopped.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:beacle/api/api_client.dart';
import 'package:beacle/paths.dart';
import 'package:beacle/screens/shell.dart';
import 'package:beacle/state/app_state.dart';
import 'package:beacle/widgets/history_panel.dart';
import 'package:beacle/widgets/themed_app.dart';

final _now = DateTime.now();
String _ago(Duration d) => DateTime.now().subtract(d).toUtc().toIso8601String();

const _gb = 1024 * 1024 * 1024;

Map<String, dynamic> _vps(String id, String name, String location, double lat, double lon,
        {String status = 'online', List<String> tags = const [], String arch = 'amd64', int days = 40}) =>
    {
      'id': id,
      'name': name,
      'host': name,
      'tailscale_name': name,
      'public_ip': '${id == 'lab' ? '198.51.100' : '203.0.113'}.${10 + id.codeUnitAt(0) % 40}',
      'location': location,
      'status': status,
      'agent_version': '2.2.0',
      'arch': arch,
      'tags': tags,
      'latitude': lat,
      'longitude': lon,
      'last_seen': _ago(const Duration(seconds: 2)),
      'created_at': _ago(Duration(days: days)),
    };

// Getters: rebuilt on each fetch, so last_seen stays a second old for the whole run.
List<Map<String, dynamic>> get _fleet => [
  _vps('web', 'web-1', 'Frankfurt am Main, Germany', 50.11, 8.68, tags: ['prod']),
  _vps('db', 'db-1', 'Helsinki, Finland', 60.17, 24.94, tags: ['prod', 'db'], days: 39),
  _vps('edge', 'edge-ams', 'Amsterdam, Netherlands', 52.37, 4.9, tags: ['edge'], days: 38),
  _vps('lab', 'homelab', 'Warsaw, Poland', 52.23, 21.01, arch: 'arm64', days: 37),
  _vps('sg', 'edge-sgp', 'Singapore', 1.29, 103.85, tags: ['edge'], days: 36),
  _vps('ci', 'ci-runner', 'Ashburn, United States', 39.04, -77.49, status: 'offline', days: 35),
];

Map<String, dynamic> _metrics(String host, double cpu, double mem, double disk,
        {int cores = 4, int memGb = 8, int diskGb = 80, int rx = 0, int tx = 0, String arch = 'x86_64'}) =>
    {
      'hostname': host,
      'os': 'Ubuntu 24.04.1 LTS',
      'kernel': '6.8.0-45-generic',
      'arch': arch,
      'cpu_model': arch == 'aarch64' ? 'Cortex-A76' : 'AMD EPYC 7763 64-Core Processor',
      'cpu_percent': cpu,
      'cpu_cores': cores,
      'cpu_per_core': [for (var i = 0; i < cores; i++) (cpu + (i * 7 % 11) - 5).clamp(0.5, 100)],
      'mem_percent': mem,
      'mem_percent_cached': (mem + 18).clamp(0, 100),
      'mem_total_bytes': memGb * _gb,
      'mem_used_bytes': (memGb * _gb * mem / 100).round(),
      'mem_cached_bytes': (memGb * _gb * 0.18).round(),
      'swap_total_bytes': 2 * _gb,
      'swap_used_bytes': 120 * 1024 * 1024,
      'load1': cpu / 25,
      'load5': cpu / 28,
      'load15': cpu / 30,
      'uptime_seconds': 3600 * 24 * 23 + 3600 * 5,
      'disks': [
        {
          'mount': '/',
          'filesystem': 'ext4',
          'total_bytes': diskGb * _gb,
          'used_bytes': (diskGb * _gb * disk / 100).round(),
          'used_percent': disk,
          if (disk > 85) 'full_at': _now.add(const Duration(days: 4, hours: 6)).toUtc().toIso8601String(),
        },
        {'mount': '/boot/efi', 'filesystem': 'vfat', 'total_bytes': 1 * _gb, 'used_bytes': 6 * 1024 * 1024, 'used_percent': 0.6},
      ],
      'network': [
        {'interface': 'eth0', 'rx_bytes': 812 * _gb, 'tx_bytes': 344 * _gb, 'rx_per_sec': rx, 'tx_per_sec': tx},
        {'interface': 'tailscale0', 'rx_bytes': 3 * _gb, 'tx_bytes': 2 * _gb, 'rx_per_sec': 2100, 'tx_per_sec': 3400},
      ],
      'plugins': {'temps.cpu_temp': 38 + cpu / 3},
    };

Map<String, dynamic> _container(String name, String image, {String state = 'running', String status = 'Up 6 days', String project = '', List<int> ports = const []}) => {
      'id': name.hashCode.toRadixString(16).padLeft(12, '0'),
      'name': name,
      'image': image,
      'state': state,
      'status': status,
      'compose_project': project,
      'compose_service': project.isEmpty ? '' : name.split('-').last,
      'ports': [for (final p in ports) {'private_port': p, 'public_port': p, 'protocol': 'tcp', 'ip': '0.0.0.0'}],
    };

Map<String, dynamic> _stats(String name, double cpu, int memMb) =>
    {'id': name.hashCode.toRadixString(16).padLeft(12, '0'), 'name': name, 'cpu_percent': cpu, 'mem_usage_bytes': memMb << 20, 'mem_limit_bytes': 8 * _gb, 'mem_percent': memMb / 81.92, 'pids': 12};

Map<String, dynamic> _unit(String name, String desc, {String active = 'active', String sub = 'running', int pid = 0}) =>
    {'name': name, 'description': desc, 'load_state': 'loaded', 'active_state': active, 'sub_state': sub, 'enabled': 'enabled', 'main_pid': pid};

Map<String, dynamic> _site(String domain, int port, {bool healthy = true, int certDays = 62}) => {
      'id': domain,
      'domain': domain,
      'domains': [domain],
      'upstream': 'localhost:$port',
      'upstream_port': port,
      'port_in_use': healthy,
      'upstream_healthy': healthy,
      'ssl': 'active',
      'provider': 'caddy',
      'enabled': true,
      'managed': true,
      'editable': true,
      'force_https': true,
      'gzip': true,
      'kind': 'reverse_proxy',
      'tls_mode': 'auto',
      'cert_not_after': _now.add(Duration(days: certDays)).toUtc().toIso8601String(),
      'cert_issuer': "Let's Encrypt",
    };

List<Map<String, dynamic>> get _snapshots => [
  {
    'vps': _fleet[0],
    'metrics': _metrics('web-1', 23, 41, 38, rx: 2400000, tx: 5100000),
    'docker': {
      'available': true,
      'version': '27.3.1',
      'containers': [
        _container('shop-web', 'ghcr.io/acme/shop:1.14', project: 'shop', ports: [3000]),
        _container('shop-api', 'ghcr.io/acme/shop-api:1.14', project: 'shop', ports: [8080]),
        _container('shop-worker', 'ghcr.io/acme/shop-api:1.14', project: 'shop'),
        _container('umami', 'ghcr.io/umami-software/umami:postgresql-latest', ports: [3001]),
        _container('uptime-kuma', 'louislam/uptime-kuma:1', ports: [3002]),
      ],
      'stats': [_stats('shop-web', 3.1, 182), _stats('shop-api', 11.4, 412), _stats('shop-worker', 4.2, 236), _stats('umami', 0.8, 148), _stats('uptime-kuma', 1.6, 121)],
      'compose': [
        {'name': 'shop', 'working_dir': '/srv/shop', 'config_file': '/srv/shop/compose.yml', 'services': ['web', 'api', 'worker'], 'running': 3, 'total': 3}
      ],
      'images': [
        {'id': 'sha256:1a', 'tags': ['ghcr.io/acme/shop:1.14'], 'size_bytes': 212 << 20},
        {'id': 'sha256:2b', 'tags': ['ghcr.io/acme/shop-api:1.14'], 'size_bytes': 96 << 20},
      ],
    },
    'services': {
      'systemd': [
        _unit('caddy.service', 'Caddy', pid: 812),
        _unit('docker.service', 'Docker Application Container Engine', pid: 640),
        _unit('beacle-agent.service', 'Beacle agent', pid: 701),
        _unit('tailscaled.service', 'Tailscale node agent', pid: 588),
        _unit('ssh.service', 'OpenBSD Secure Shell server', pid: 902),
        _unit('unattended-upgrades.service', 'Unattended Upgrades Shutdown', pid: 655),
      ],
      'screen': [
        {'pid': 21877, 'name': 'import', 'created': '10/14/2026 09:12:03 PM', 'command': 'python3 import_orders.py', 'running': true}
      ],
    },
    'proxy': {
      'provider': 'caddy',
      'version': 'v2.8.4',
      'running': true,
      'sites': [_site('shop.example.com', 3000), _site('api.example.com', 8080), _site('stats.example.com', 3001, certDays: 11), _site('status.example.com', 3002)],
    },
    'ports': [
      {'port': 22, 'protocol': 'tcp', 'listen_addr': '0.0.0.0', 'process_name': 'sshd', 'healthy': true},
      {'port': 443, 'protocol': 'tcp', 'listen_addr': '0.0.0.0', 'process_name': 'caddy', 'healthy': true},
      {'port': 3000, 'protocol': 'tcp', 'listen_addr': '127.0.0.1', 'process_name': 'docker-proxy', 'healthy': true},
    ],
    'updated': _ago(const Duration(seconds: 2)),
  },
  {
    'vps': _fleet[1],
    'metrics': _metrics('db-1', 31, 72, 91, cores: 8, memGb: 32, diskGb: 320, rx: 1200000, tx: 900000),
    'docker': {
      'available': true,
      'containers': [
        _container('postgres', 'postgres:16', ports: [5432]),
        _container('redis', 'redis:7-alpine', ports: [6379]),
        _container('pgbackup', 'prodrigestivill/postgres-backup-local:16', state: 'exited', status: 'Exited (1) 3 hours ago'),
      ],
      'stats': [_stats('postgres', 18.2, 6120), _stats('redis', 1.1, 310)],
    },
    'services': {
      'systemd': [_unit('docker.service', 'Docker Application Container Engine', pid: 611), _unit('beacle-agent.service', 'Beacle agent', pid: 702), _unit('pg-dump.service', 'Nightly pg_dump to S3', active: 'failed', sub: 'failed')],
    },
    'updated': _ago(const Duration(seconds: 2)),
  },
  {
    'vps': _fleet[2],
    'metrics': _metrics('edge-ams', 7, 28, 22, cores: 2, memGb: 4, diskGb: 40, rx: 640000, tx: 1900000),
    'docker': {'available': true, 'containers': [_container('wireguard', 'linuxserver/wireguard', ports: [51820])], 'stats': [_stats('wireguard', 0.4, 18)]},
    'services': {'systemd': [_unit('caddy.service', 'Caddy', pid: 455), _unit('beacle-agent.service', 'Beacle agent', pid: 470)]},
    'proxy': {'provider': 'caddy', 'version': 'v2.8.4', 'running': true, 'sites': [_site('cdn.example.com', 8090), _site('old.example.com', 8091, healthy: false)]},
    'updated': _ago(const Duration(seconds: 2)),
  },
  {
    'vps': _fleet[3],
    'metrics': _metrics('homelab', 64, 58, 47, cores: 4, memGb: 8, diskGb: 1000, rx: 310000, tx: 120000, arch: 'aarch64'),
    'docker': {
      'available': true,
      'containers': [
        _container('jellyfin', 'jellyfin/jellyfin', ports: [8096]),
        _container('home-assistant', 'ghcr.io/home-assistant/home-assistant:stable', ports: [8123]),
        _container('pihole', 'pihole/pihole:latest', ports: [53]),
      ],
      'stats': [_stats('jellyfin', 48.0, 1210), _stats('home-assistant', 6.3, 540), _stats('pihole', 0.9, 88)],
    },
    'services': {'systemd': [_unit('beacle-agent.service', 'Beacle agent', pid: 512), _unit('docker.service', 'Docker Application Container Engine', pid: 498)]},
    'updated': _ago(const Duration(seconds: 2)),
  },
  {
    'vps': _fleet[4],
    'metrics': _metrics('edge-sgp', 4, 22, 18, cores: 2, memGb: 4, diskGb: 40, rx: 410000, tx: 880000),
    'services': {'systemd': [_unit('caddy.service', 'Caddy', pid: 433), _unit('beacle-agent.service', 'Beacle agent', pid: 450)]},
    'updated': _ago(const Duration(seconds: 2)),
  },
  {'vps': _fleet[5], 'updated': _ago(const Duration(hours: 3))},
];

final _alerts = [
  {'id': 'a1', 'vps_id': 'db', 'vps_name': 'db-1', 'type': 'disk_high', 'severity': 'warning', 'message': 'Disk / at 91%', 'created_at': _ago(const Duration(minutes: 42))},
  {'id': 'a2', 'vps_id': 'ci', 'vps_name': 'ci-runner', 'type': 'agent_offline', 'severity': 'critical', 'message': 'VPS offline — confirmed by edge-ams', 'created_at': _ago(const Duration(hours: 3))},
  {'id': 'a3', 'vps_id': 'db', 'vps_name': 'db-1', 'type': 'service_failed', 'severity': 'warning', 'message': 'pg-dump.service failed', 'created_at': _ago(const Duration(hours: 5))},
  {'id': 'a4', 'vps_id': 'lab', 'vps_name': 'homelab', 'type': 'cpu_high', 'severity': 'warning', 'message': 'CPU 94% for 5 min', 'created_at': _ago(const Duration(hours: 9)), 'resolved': true},
  {'id': 'a5', 'vps_id': 'web', 'vps_name': 'web-1', 'type': 'cert_expiring', 'severity': 'warning', 'message': 'stats.example.com certificate expires in 11 days', 'created_at': _ago(const Duration(hours: 20))},
].reversed.toList();

final _actions = [
  {'id': 'x1', 'vps_id': 'web', 'vps_name': 'web-1', 'action': 'compose_up', 'detail': 'shop', 'ok': true, 'created_at': _ago(const Duration(minutes: 12))},
  {'id': 'x2', 'vps_id': 'lab', 'vps_name': 'homelab', 'action': 'container_restart', 'detail': 'jellyfin', 'ok': true, 'created_at': _ago(const Duration(minutes: 55))},
  {'id': 'x3', 'vps_id': 'edge', 'vps_name': 'edge-ams', 'action': 'proxy_reload', 'detail': 'cdn.example.com', 'ok': true, 'created_at': _ago(const Duration(hours: 2))},
  {'id': 'x4', 'vps_id': 'db', 'vps_name': 'db-1', 'action': 'systemd_restart', 'detail': 'pg-dump.service', 'ok': false, 'created_at': _ago(const Duration(hours: 5))},
  {'id': 'x5', 'vps_id': 'sg', 'vps_name': 'edge-sgp', 'action': 'agent_update', 'detail': '2.2.0', 'ok': true, 'created_at': _ago(const Duration(hours: 7))},
].reversed.toList();

/// A smooth day of load with a bump in the evening.
double _wave(int i, double base, double amp, int seed) =>
    (base + amp * sin(i / 60 + seed) + amp / 2 * sin(i / 9 + seed * 3) + (i > 1100 && i < 1180 ? amp * 2 : 0)).clamp(0.5, 99);

Map<String, dynamic> _history(String id) {
  final seed = id.codeUnitAt(0) % 7;
  final from = _now.subtract(const Duration(hours: 24));
  return {
    'first': _now.subtract(const Duration(days: 7)).toUtc().toIso8601String(),
    'last': _now.toUtc().toIso8601String(),
    'samples': [
      for (var i = 0; i < 24 * 60; i += 2)
        {
          'at': from.add(Duration(minutes: i)).toUtc().toIso8601String(),
          'cpu': _wave(i, 22, 9, seed),
          'mem': _wave(i, 44, 4, seed + 1),
          'disk': 38 + i / 1440,
          'load1': _wave(i, 0.9, 0.4, seed),
          'rx': (_wave(i, 30, 15, seed) * 80000).round(),
          'tx': (_wave(i, 40, 20, seed + 2) * 90000).round(),
        }
    ],
    'spikes': [
      {
        'at': from.add(const Duration(minutes: 1140)).toUtc().toIso8601String(),
        'metric': 'cpu',
        'value': 61,
        'baseline': 22,
        'top': [
          {'pid': 3121, 'name': 'node', 'user': 'app', 'cmd': 'node dist/server.js', 'cpu': 38.5, 'mem': 4.1}
        ]
      }
    ],
  };
}

final _processes = [
  {'pid': 3121, 'name': 'node', 'user': 'app', 'command': 'node dist/server.js', 'state': 'S', 'cpu_percent': 9.8, 'mem_percent': 4.1, 'mem_bytes': 330 << 20},
  {'pid': 812, 'name': 'caddy', 'user': 'caddy', 'command': '/usr/bin/caddy run --config /etc/caddy/Caddyfile', 'state': 'S', 'cpu_percent': 1.2, 'mem_percent': 0.6, 'mem_bytes': 48 << 20},
  {'pid': 640, 'name': 'dockerd', 'user': 'root', 'command': '/usr/bin/dockerd -H fd://', 'state': 'S', 'cpu_percent': 0.9, 'mem_percent': 1.1, 'mem_bytes': 92 << 20},
  {'pid': 701, 'name': 'beacle-agent', 'user': 'root', 'command': '/opt/beacle/beacle-agent', 'state': 'S', 'cpu_percent': 0.3, 'mem_percent': 0.3, 'mem_bytes': 24 << 20},
];

final _plugins = {
  'plugins': [
    {
      'id': 'temps',
      'name': 'Temperatures',
      'version': '1.0.0',
      'enabled': true,
      'source': 'zip',
      'permissions': {
        'read': ['/sys/class/thermal', '/sys/class/hwmon'],
        'exec': ['nvidia-smi']
      },
      'metrics': {
        'cpu_temp': {'label': 'CPU', 'unit': '°C', 'warn': 80, 'crit': 90},
        'gpu_temp': {'label': 'GPU', 'unit': '°C', 'warn': 85, 'crit': 95}
      },
    }
  ],
};

class _FakeApi extends ApiClient {
  _FakeApi() : super('');
  final unknown = <String>{};

  @override
  Future<dynamic> get(String path) async {
    final p = path.split('?').first;
    if (p == '/api/overview') {
      return {'vps': _fleet, 'snapshots': _snapshots, 'alerts': _alerts, 'actions': _actions, 'links': []};
    }
    if (p == '/api/alerts') return _alerts;
    if (p == '/api/plugins') return _plugins;
    if (p == '/api/vps') return _fleet;
    if (p == '/api/health') return {'ok': true};
    if (p == '/api/ssh/hosts') {
      return [
        {'id': 'h1', 'label': 'router', 'host': '192.168.1.1', 'user': 'admin', 'port': 22, 'has_password': true},
        {'id': 'h2', 'label': 'nas', 'host': 'nas.lan', 'user': 'alex', 'port': 2222, 'has_key': true},
      ];
    }
    if (p == '/api/tailscale/devices') {
      return [
        {'name': 'desktop', 'dns': 'desktop.tail0000.ts.net', 'ips': ['100.64.0.1'], 'os': 'windows', 'online': true, 'self': true},
        for (final (i, v) in _fleet.indexed)
          {'name': v['name'], 'dns': '${v['name']}.tail0000.ts.net', 'ips': ['100.64.0.${i + 10}'], 'os': 'linux', 'online': v['status'] == 'online'},
      ];
    }
    if (p == '/api/wireguard/status') return {'running': false};
    if (p == '/api/webhooks') {
      return {
        'targets': [
          {'id': 't1', 'kind': 'discord', 'url': 'https://discord.com/api/webhooks/000000000000000000/xxxxxxxxxxxxxxxx'},
          {'id': 't2', 'kind': 'ntfy', 'url': 'https://ntfy.sh/example-alerts'},
        ],
        'primary': _fleet[2],
        'secondary': _fleet[4],
      };
    }
    final m = RegExp(r'^/api/vps/(\w+)/(?:agent/)?(.*)$').firstMatch(p);
    if (m != null) {
      final id = m[1]!, rest = m[2]!;
      final snap = _snapshots.firstWhere((s) => (s['vps'] as Map)['id'] == id);
      if (rest == 'history') return _history(id);
      if (rest == 'system/processes' || rest == 'processes') return _processes;
      if (rest == 'ports') return snap['ports'] ?? [];
      if (rest == 'snapshot') return snap;
      if (rest == 'proxy') return snap['proxy'] ?? {};
      if (rest == 'terminal/users') return {'users': ['root', 'deploy'], 'main': 'deploy'};
      if (rest == 'services/screen') return (snap['services'] as Map?)?['screen'] ?? [];
      if (rest == 'services/nohup') {
        return [
          {'pid': 30211, 'name': 'sitemap', 'command': 'node scripts/sitemap.js', 'dir': '/srv/shop', 'log_file': '/srv/shop/nohup-sitemap.log', 'started': _ago(const Duration(hours: 2)), 'running': true}
        ];
      }
      if (rest == 'system/logs') {
        return [
          {'id': 'syslog', 'label': 'System log', 'path': '/var/log/syslog'},
          {'id': 'auth', 'label': 'Logins', 'path': '/var/log/auth.log'},
          {'id': 'caddy', 'label': 'Caddy', 'path': '/var/log/caddy/access.log'},
        ];
      }
      if (rest == 'system/updates') {
        return {
          'manager': 'apt',
          'checked_at': _ago(const Duration(minutes: 20)),
          'security_count': 2,
          'packages': [
            {'name': 'openssl', 'current': '3.0.13-0ubuntu3.3', 'latest': '3.0.13-0ubuntu3.4', 'security': true},
            {'name': 'libssl3t64', 'current': '3.0.13-0ubuntu3.3', 'latest': '3.0.13-0ubuntu3.4', 'security': true},
            {'name': 'docker-ce', 'current': '5:27.3.1-1', 'latest': '5:27.4.0-1'},
          ],
        };
      }
      if (rest == 'system/cron') {
        return {
          'cron_available': true,
          'entries': [
            {'id': 'c1', 'source': 'crontab', 'minute': '*/15', 'hour': '*', 'day_month': '*', 'month': '*', 'day_week': '*', 'user': '', 'command': 'cd /srv/shop && ./bin/sync-stock', 'editable': true},
            {'id': 'c2', 'source': 'crontab', 'minute': '30', 'hour': '3', 'day_month': '*', 'month': '*', 'day_week': '*', 'user': '', 'command': '/usr/local/bin/backup.sh >> /var/log/backup.log 2>&1', 'editable': true},
            {'id': 'c3', 'source': 'cron.d/certbot', 'minute': '0', 'hour': '*/12', 'day_month': '*', 'month': '*', 'day_week': '*', 'user': 'root', 'command': 'certbot -q renew', 'editable': false},
          ],
          'timers': [
            {'unit': 'apt-daily.timer', 'active': 'active', 'next': 'in 5h', 'last': '18h ago'},
            {'unit': 'logrotate.timer', 'active': 'active', 'next': 'in 9h', 'last': '15h ago'},
          ],
        };
      }
      if (rest == 'firewall/status') {
        return {
          'backend': 'ufw',
          'backend_detail': 'ufw 0.36.2',
          'enabled': true,
          'editable': true,
          'default_incoming': 'deny',
          'protected_ports': [22, 8931],
          'rules': [
            {'id': '1', 'action': 'allow', 'proto': 'tcp', 'port': '22', 'comment': 'ssh', 'protected': true},
            {'id': '2', 'action': 'allow', 'proto': 'tcp', 'port': '80', 'comment': 'http'},
            {'id': '3', 'action': 'allow', 'proto': 'tcp', 'port': '443', 'comment': 'https'},
            {'id': '4', 'action': 'allow', 'proto': 'tcp', 'port': '5432', 'source': '10.0.0.0/24', 'comment': 'postgres from the private network'},
            {'id': '5', 'action': 'deny', 'proto': 'tcp', 'port': '3000'},
          ],
          'open_ports': snap['ports'] ?? [],
        };
      }
      if (rest == 'fs/dir') {
        var dir = Uri.parse(path).queryParameters['path'] ?? '';
        if (dir.isEmpty) dir = '/srv/shop';
        final names = switch (dir) {
          '/' => ['etc/', 'home/', 'opt/', 'root/', 'srv/', 'var/'],
          '/srv' => ['backups/', 'shop/'],
          '/srv/shop' => ['bin/', 'public/', 'src/', '.env', 'compose.yml', 'nohup-sitemap.log', 'package.json', 'README.md'],
          _ => <String>[],
        };
        return {
          'path': dir,
          'entries': [
            for (final n in names)
              {
                'name': n.replaceAll('/', ''),
                'path': '${dir == '/' ? '' : dir}/${n.replaceAll('/', '')}',
                'is_dir': n.endsWith('/'),
                'size': n.endsWith('/') ? 4096 : 380 * n.length * n.length,
                'mode': n.endsWith('/') ? 'drwxr-xr-x' : '-rw-r--r--',
                'owner': 'deploy',
                'mtime': _ago(Duration(hours: n.length * 7)),
              },
          ],
        };
      }
    }
    unknown.add(p);
    throw ApiException('not in the screenshot fixture', 404, {'error': 'not found'});
  }
}

class _State extends AppState {
  final _api = _FakeApi();

  @override
  ApiClient get api => _api;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['BEACLE_SCREENSHOTS'];

  testWidgets('screenshots', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Directory(BeaclePaths.configDir).createSync(recursive: true);
    File(BeaclePaths.settingsFile).writeAsStringSync(jsonEncode({
      'wg_migrate_banner_dismissed': true,
      'ssh_snippets': [
        {'id': 's1', 'name': 'Disk usage', 'command': 'df -h /'},
        {'id': 's2', 'name': 'Last deploy log', 'command': 'journalctl -u shop --since today -n 50'},
        {'id': 's3', 'name': 'Restart shop', 'command': 'cd /srv/shop && docker compose up -d'},
      ],
    }));
    final state = _State()..connected = true;
    await state.refreshAll();
    final start = _now.subtract(const Duration(hours: 24));
    state.fleetHistory
      ..clear()
      ..addAll([
        for (var i = 0; i < 24 * 60; i += 2)
          FleetSample(
              at: start.add(Duration(minutes: i)),
              cpu: _wave(i, 24, 8, 1),
              ram: _wave(i, 46, 3, 2),
              netIn: _wave(i, 30, 14, 3) * 160000,
              netOut: _wave(i, 40, 18, 4) * 190000),
      ]);

    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const BeacleMaterialApp(home: AppShell()),
      ),
    ));

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> shot(String name) async {
      await state.refreshAll();
      await settle();
      await tester.runAsync(() async {
        final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await ro.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
      });
    }

    Future<void> nav(String label) async {
      await tester.tap(find.text(label).first);
      await settle();
    }

    Future<void> tab(String label) async {
      await tester.tap(find.text(label).last);
      await settle();
    }

    // Scrolls the screen's main list to the bottom.
    Future<void> scrollDown() async {
      final lists = find.byType(Scrollable).evaluate().map((e) => (e as StatefulElement).state as ScrollableState);
      final main = lists.where((s) => s.axisDirection == AxisDirection.down).reduce(
          (a, b) => a.position.maxScrollExtent >= b.position.maxScrollExtent ? a : b);
      main.position.jumpTo(main.position.maxScrollExtent);
      await settle();
    }

    await shot('overview');
    await scrollDown();
    await shot('overview-activity');
    await nav('Map');
    await shot('map');
    await nav('Servers');
    await shot('servers');
    // The detail list builds lazily: scroll it until the chart exists, then put it on top.
    final detail = find.ancestor(of: find.text('Connect with SSH'), matching: find.byType(Scrollable)).evaluate().firstWhere(
        (e) => ((e as StatefulElement).state as ScrollableState).axisDirection == AxisDirection.down);
    // SmoothListView takes no drags, so move its position directly.
    final pos = ((detail as StatefulElement).state as ScrollableState).position;
    while (find.byType(HistoryPanel).evaluate().isEmpty && pos.pixels < pos.maxScrollExtent) {
      pos.jumpTo(min(pos.pixels + 400, pos.maxScrollExtent));
      await tester.pump();
    }
    await tester.ensureVisible(find.byType(HistoryPanel));
    await settle();
    await shot('servers-history');
    await nav('Docker');
    await shot('docker');
    await tab('Images');
    await shot('docker-images');
    await tab('Compose');
    await shot('docker-compose');
    await nav('Services');
    await shot('services');
    await tab('processes');
    await shot('services-processes');
    await tab('cron');
    await shot('services-cron');
    await tab('firewall');
    await shot('services-firewall');
    await nav('Proxy');
    await shot('proxy');
    await nav('Alerts');
    await shot('alerts');
    await nav('SSH');
    await shot('ssh');
    await nav('Files');
    await shot('files');
    await nav('Settings');
    await shot('settings');
    for (final (label, name) in [
      ('Updates', 'settings-updates'),
      ('Status', 'settings-status'),
      ('Notifications', 'settings-notifications'),
      ('WireGuard', 'settings-wireguard'),
      ('Plugins', 'settings-plugins'),
    ]) {
      await tab(label);
      await shot(name);
    }

    // ignore: avoid_print
    print('paths with no fixture: ${state._api.unknown}');
    // Let the screens' refresh timers go before the binding checks for them.
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump(const Duration(seconds: 30));
  }, skip: out == null);
}
