import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../paths.dart';
import 'tailscale_exposure.dart';

/// Starts the bundled Go backend with the desktop app; shuts down on exit.
class EmbeddedBackend {
  EmbeddedBackend._();
  static final EmbeddedBackend instance = EmbeddedBackend._();

  Process? _process;
  bool _stopping = false;

  Future<void> ensureRunning() async {
    if (_process != null && await _healthy()) return;

    await _stopStaleBackend();

    final bin = _findBinary();
    if (bin == null) {
      debugPrint('beacle: backend binary not found');
      return;
    }

    BeaclePaths.ensureDirs();
    _seedAgentBinaries(bin.parent.path);

    // Localhost only — tailnet agents reach us via `tailscale serve` on Windows.
    final listenAddr = Platform.isWindows ? '127.0.0.1:8930' : '0.0.0.0:8930';
    final args = ['-addr', listenAddr, '-data', BeaclePaths.dataDir];

    debugPrint('beacle: starting backend on $listenAddr (${BeaclePaths.dataDir})');
    _process = await Process.start(
      bin.path,
      args,
      workingDirectory: bin.parent.path,
    );

    _process!.exitCode.then((code) {
      if (!_stopping) {
        debugPrint('beacle: backend exited unexpectedly ($code)');
      }
      _process = null;
    });

    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await _healthy()) {
        debugPrint('beacle: backend ready');
        await ensureBackendTailnetExposure(backendExe: bin.path);
        return;
      }
    }
    debugPrint('beacle: backend did not become healthy in time');
  }

  Future<void> _stopStaleBackend() async {
    if (_process != null) return;

    try {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$localBackendUrl/api/shutdown'));
      req.headers.set('Content-Type', 'application/json');
      await req.close().timeout(const Duration(seconds: 2));
      client.close();
      await Future.delayed(const Duration(milliseconds: 400));
    } catch (_) {}

    if (await _healthy() && Platform.isWindows) {
      debugPrint('beacle: stopping stale backend on :8930');
      try {
        await Process.run('taskkill', ['/IM', 'beacle-backend.exe', '/F'], runInShell: true);
        await Future.delayed(const Duration(milliseconds: 400));
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await clearBackendTailnetExposure();
    if (_process == null) return;
    _stopping = true;
    try {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$localBackendUrl/api/shutdown'));
      req.headers.set('Content-Type', 'application/json');
      await req.close().timeout(const Duration(seconds: 2));
      client.close();
    } catch (_) {}

    try {
      await _process!.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      _process!.kill();
      await _process!.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => 0);
    }
    _process = null;
    _stopping = false;
  }

  Future<bool> _healthy() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('$localBackendUrl/api/health'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      client.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
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
        if (!out.existsSync() || f.lastModifiedSync().isAfter(out.lastModifiedSync())) {
          f.copySync(out.path);
        }
      }
    }
  }
}
