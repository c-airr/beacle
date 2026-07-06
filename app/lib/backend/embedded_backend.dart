import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../local_settings.dart';

/// Starts the bundled Go backend alongside the desktop app (local-first).
class EmbeddedBackend {
  EmbeddedBackend._();
  static final EmbeddedBackend instance = EmbeddedBackend._();

  Process? _process;
  bool _weStarted = false;

  Future<void> ensureRunning() async {
    if (await _healthy()) return;

    final bin = _findBinary();
    if (bin == null) {
      debugPrint('beacle: embedded backend binary not found');
      return;
    }

    final dataDir = _dataDir();
    Directory(dataDir).createSync(recursive: true);

    final publicUrl = await LocalSettings.resolveAgentPublicUrl();
    final args = ['-addr', ':8930', '-data', dataDir, '-base-url', publicUrl];

    debugPrint('beacle: starting embedded backend ($publicUrl)');
    _process = await Process.start(
      bin.path,
      args,
      workingDirectory: bin.parent.path,
    );
    _weStarted = true;

    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await _healthy()) return;
    }
    debugPrint('beacle: embedded backend did not become healthy in time');
  }

  Future<void> restart() async {
    await stop();
    await ensureRunning();
  }

  Future<void> stop() async {
    if (_process != null) {
      _process!.kill();
      await _process!.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => 0);
      _process = null;
    }
    _weStarted = false;
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
    final name = Platform.isWindows ? 'beacle-backend.exe' : 'beacle-backend';
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      '${exeDir.path}${Platform.pathSeparator}$name',
      '${Directory.current.path}${Platform.pathSeparator}backend${Platform.pathSeparator}$name',
      '${Directory.current.path}${Platform.pathSeparator}..${Platform.pathSeparator}backend${Platform.pathSeparator}$name',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    return null;
  }

  String _dataDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final bundled = '${exeDir.path}${Platform.pathSeparator}data';
    if (Directory(bundled).existsSync()) return bundled;
    return '${Directory.current.path}${Platform.pathSeparator}backend${Platform.pathSeparator}data';
  }
}
