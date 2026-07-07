import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../paths.dart';

/// Starts the bundled Go backend with the desktop app; shuts down on exit.
class EmbeddedBackend {
  EmbeddedBackend._();
  static final EmbeddedBackend instance = EmbeddedBackend._();

  Process? _process;

  Future<void> ensureRunning() async {
    await _stopStaleBackend();

    if (_process != null && await _healthy()) return;

    final bin = _findBinary();
    if (bin == null) {
      debugPrint('beacle: backend binary not found');
      return;
    }

    BeaclePaths.ensureDirs();
    _seedAgentBinaries(bin.parent.path);

    final args = ['-addr', ':8930', '-data', BeaclePaths.dataDir];

    debugPrint('beacle: starting backend (${BeaclePaths.dataDir})');
    _process = await Process.start(
      bin.path,
      args,
      workingDirectory: bin.parent.path,
    );

    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await _healthy()) {
        debugPrint('beacle: backend ready');
        return;
      }
    }
    debugPrint('beacle: backend did not become healthy in time');
  }

  /// Stops a leftover backend from a previous session so we never talk to stale API.
  Future<void> _stopStaleBackend() async {
    if (_process != null) return;
    if (!await _healthy()) return;

    debugPrint('beacle: stopping stale backend on :8930');
    try {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$localBackendUrl/api/shutdown'));
      req.headers.set('Content-Type', 'application/json');
      await req.close().timeout(const Duration(seconds: 2));
      client.close();
      await Future.delayed(const Duration(milliseconds: 400));
    } catch (_) {}

    if (await _healthy() && Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/IM', 'beacle-backend.exe', '/F'], runInShell: true);
        await Future.delayed(const Duration(milliseconds: 400));
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    if (_process == null) return;
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
  // Also try repo dist relative to executable (dev builds from Release/)
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
