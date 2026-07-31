import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../paths.dart';
import 'tailscale_exposure.dart';

/// Health payload of a backend already listening on the port.
class _BackendProbe {
  final int pid, agents;
  final String dataDir;
  const _BackendProbe(this.pid, this.agents, this.dataDir);

  /// Windows paths differ in case and separators between runs — compare loosely.
  bool servesDataDir(String dir) {
    String norm(String p) => p.replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();
    return dataDir.isNotEmpty && norm(dataDir) == norm(dir);
  }
}

/// Starts the bundled Go backend with the desktop app; shuts down on exit.
class EmbeddedBackend {
  EmbeddedBackend._();
  static final EmbeddedBackend instance = EmbeddedBackend._();

  Process? _process;
  Timer? _watchdog;
  bool _adopted = false;
  bool _stopping = false;
  bool _busy = false;
  int _restarts = 0;

  Future<void> ensureRunning() async {
    if (_busy) return;
    _busy = true;
    try {
      await _ensureRunning();
    } finally {
      _busy = false;
    }
  }

  Future<void> _ensureRunning() async {
    if (_process != null && await _healthy()) return;

    // A backend from an earlier run can still be alive: closing the window does
    // not always reach dispose(). That process already holds every agent's
    // WebSocket, so killing and replacing it would knock the whole fleet
    // offline for a full agent reconnect right as the panel opens. Adopt it.
    final running = await _probe();
    if (running != null && running.servesDataDir(BeaclePaths.dataDir)) {
      _adopted = true;
      debugPrint(
        'beacle: adopting running backend pid ${running.pid} (${running.agents} agents connected)',
      );
      await ensureBackendTailnetExposure();
      _startWatchdog();
      return;
    }
    if (running != null) {
      debugPrint('beacle: backend on :9930 uses ${running.dataDir}, replacing it');
    }

    await _stopStaleBackend();

    final bin = _findBinary();
    if (bin == null) {
      debugPrint('beacle: backend binary not found');
      return;
    }

    BeaclePaths.ensureDirs();
    _seedAgentBinaries(bin.parent.path);

    // Bind on all interfaces so Tailscale agents can reach us directly.
    final listenAddr = '0.0.0.0:9930';
    final args = ['-addr', listenAddr, '-data', BeaclePaths.dataDir];

    debugPrint('beacle: starting backend on $listenAddr (${BeaclePaths.dataDir})');
    _process = await Process.start(
      bin.path,
      args,
      workingDirectory: bin.parent.path,
    );

    final startedAt = DateTime.now();
    _process!.exitCode.then((code) async {
      _process = null;
      if (_stopping) return;
      // Nothing else supervises this process: without a restart the panel stays
      // dark and every agent keeps dialing a port that no longer answers.
      if (DateTime.now().difference(startedAt) > const Duration(seconds: 60)) {
        _restarts = 0;
      }
      if (_restarts >= 5) {
        debugPrint('beacle: backend keeps crashing ($code) — giving up');
        return;
      }
      _restarts++;
      debugPrint('beacle: backend exited unexpectedly ($code) — restart $_restarts');
      await Future.delayed(const Duration(seconds: 1));
      if (!_stopping) await ensureRunning();
    });

    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await _healthy()) {
        debugPrint('beacle: backend ready');
        await ensureBackendTailnetExposure(backendExe: bin.path);
        _startWatchdog();
        return;
      }
    }
    debugPrint('beacle: backend did not become healthy in time');
  }

  /// Covers the backend we adopted as well as the one we spawned: an adopted
  /// process has no exit handler here, and either way a dead backend means the
  /// panel is blind and every agent is dialing a port that no longer answers.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_stopping || _busy) return;
      if (await _healthy()) return;
      debugPrint('beacle: backend stopped answering — restarting');
      _adopted = false;
      await ensureRunning();
    });
  }

  Future<void> _stopStaleBackend() async {
    if (_process != null) return;

    await _requestShutdown();
    await Future.delayed(const Duration(milliseconds: 400));

    if (await _healthy() && Platform.isWindows) {
      debugPrint('beacle: stopping stale backend on :9930');
      try {
        await Process.run('taskkill', ['/IM', 'beacle-backend.exe', '/F'], runInShell: true);
        await Future.delayed(const Duration(milliseconds: 400));
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    if (_process == null && !_adopted) {
      await clearBackendTailnetExposure();
      return;
    }
    _stopping = true;
    await clearBackendTailnetExposure();
    await _requestShutdown();

    if (_process != null) {
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        _process!.kill();
        await _process!.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => 0);
      }
    }
    _process = null;
    _adopted = false;
    _stopping = false;
  }

  Future<void> _requestShutdown() async {
    try {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$localBackendUrl/api/shutdown'));
      req.headers.set('Content-Type', 'application/json');
      await req.close().timeout(const Duration(seconds: 2));
      client.close();
    } catch (_) {}
  }

  Future<bool> _healthy() async => (await _probe()) != null;

  /// Reads /api/health, which identifies the process behind the port.
  Future<_BackendProbe?> _probe() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('$localBackendUrl/api/health'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 2));
      client.close();
      final j = jsonDecode(body);
      if (j is! Map || j['ok'] != true) return null;
      return _BackendProbe(
        (j['pid'] as num?)?.toInt() ?? 0,
        (j['agents'] as num?)?.toInt() ?? 0,
        j['data_dir'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  File? _findBinary() {
    final candidates = <String>[
      BeaclePaths.backendBinary,
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}${BeaclePaths.backendBinaryName()}',
      '${Directory.current.path}${Platform.pathSeparator}backend${Platform.pathSeparator}${BeaclePaths.backendBinaryName()}',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    return null;
  }

  void _seedAgentBinaries(String backendDir) {
    final dest = '${BeaclePaths.dataDir}${Platform.pathSeparator}bin';
    Directory(dest).createSync(recursive: true);

    final sources = <String>[
      '$backendDir${Platform.pathSeparator}data${Platform.pathSeparator}bin',
      '${Directory.current.path}${Platform.pathSeparator}dist${Platform.pathSeparator}agent',
    ];
    final exeParent = File(Platform.resolvedExecutable).parent.path;
    sources.addAll([
      '$exeParent${Platform.pathSeparator}data${Platform.pathSeparator}bin',
      '$exeParent${Platform.pathSeparator}..${Platform.pathSeparator}..${Platform.pathSeparator}..${Platform.pathSeparator}..${Platform.pathSeparator}dist${Platform.pathSeparator}agent',
    ]);

    for (final src in sources) {
      if (!Directory(src).existsSync()) continue;
      for (final f in Directory(src).listSync(recursive: true)) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (!name.contains('beacle-agent') && name != 'VERSION') continue;
        final out = File('$dest${Platform.pathSeparator}$name');
        if (!out.existsSync()) f.copySync(out.path);
      }
    }
  }
}
