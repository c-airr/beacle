import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'paths.dart';
import 'tray.dart';
import 'user_config.dart';

/// The audible half of an alert. A panel that only flashes a badge is a panel
/// you have to be looking at, which defeats the point of running it on a second
/// monitor.
///
/// Plays a short Beacle WAV (assets/sounds/) through the native tray channel
/// (`PlaySound` with SND_FILENAME). Volume is applied by rewriting PCM samples
/// into a cached copy — PlaySound has no gain knob, and we refuse audio plugins
/// (symlink / Developer Mode tax on Windows builds).
class AlertSound {
  AlertSound._();

  static const _key = 'alert_sound';
  static const _volumeKey = 'alert_sound_volume';
  static Future<void>? _ensureFuture;

  /// On by default. Someone who wants silence turns it off once; someone who
  /// misses an outage because the panel was quiet does not get that time back.
  static bool get enabled => UserSettings.load().raw[_key] != false;

  static void setEnabled(bool on) {
    final s = UserSettings.load();
    s.raw[_key] = on;
    s.save();
  }

  /// 0–100. Default 70 — full blast is harsh on a second monitor at night.
  static int get volumePercent {
    final v = UserSettings.load().raw[_volumeKey];
    if (v is int) return v.clamp(0, 100);
    if (v is num) return v.round().clamp(0, 100);
    return 70;
  }

  static void setVolumePercent(int percent) {
    final s = UserSettings.load();
    s.raw[_volumeKey] = percent.clamp(0, 100);
    s.save();
  }

  /// The Linux embedder has no PlaySound equivalent wired up yet.
  static bool get supported => Platform.isWindows;

  /// Plays once for a new alert. Severity is passed in so this stays the only
  /// place deciding what is worth interrupting someone for.
  static void play(String severity) {
    if (!enabled || !supported) return;
    if (severity == 'info') return; // info is for reading, not for hearing
    if (volumePercent <= 0) return;
    // Fire-and-forget: a failed chime must never block the toast.
    _playAsync(severity);
  }

  static Future<void> _playAsync(String severity) async {
    try {
      await _ensureCached();
      final name = severity == 'critical' ? 'alert_critical.wav' : 'alert.wav';
      final path = await _scaledPath(name, volumePercent);
      if (path == null) return;
      await Tray.playFile(path);
    } catch (_) {
      // Sound is best-effort. The toast is already on screen.
    }
  }

  /// Copy the bundled WAVs into AppData once so the native PlaySound call can
  /// take a plain filesystem path (assets live inside the Flutter asset bundle).
  static Future<void> _ensureCached() {
    return _ensureFuture ??= () async {
      BeaclePaths.ensureDirs();
      final dir = Directory('${BeaclePaths.cacheDir}${Platform.pathSeparator}sounds');
      dir.createSync(recursive: true);
      for (final name in ['alert.wav', 'alert_critical.wav']) {
        final dest = File('${dir.path}${Platform.pathSeparator}$name');
        if (dest.existsSync() && dest.lengthSync() > 64) continue;
        final data = await rootBundle.load('assets/sounds/$name');
        await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }();
  }

  /// Returns a WAV at [percent] loudness. 100 reuses the master file; anything
  /// lower writes `alert_70.wav` beside it (one file per volume step used).
  static Future<String?> _scaledPath(String name, int percent) async {
    final dir = Directory('${BeaclePaths.cacheDir}${Platform.pathSeparator}sounds');
    final master = File('${dir.path}${Platform.pathSeparator}$name');
    if (!master.existsSync()) return null;
    if (percent >= 100) return master.path;

    final scaled = File('${dir.path}${Platform.pathSeparator}${percent}_$name');
    if (scaled.existsSync() && scaled.lengthSync() > 64) return scaled.path;

    final bytes = await master.readAsBytes();
    final out = _scaleWavPcm16(bytes, percent / 100.0);
    if (out == null) return master.path;
    await scaled.writeAsBytes(out, flush: true);
    return scaled.path;
  }

  /// Scales 16-bit PCM in a standard PCM WAV. Returns null if the file is not
  /// a layout we understand — caller falls back to the unscaled master.
  static Uint8List? _scaleWavPcm16(Uint8List src, double gain) {
    if (src.length < 44) return null;
    // "RIFF....WAVEfmt "
    if (src[0] != 0x52 || src[8] != 0x57 || src[12] != 0x66) return null;
    final audioFormat = src[20] | (src[21] << 8);
    final bits = src[34] | (src[35] << 8);
    if (audioFormat != 1 || bits != 16) return null;

    // Find the "data" chunk (not always at offset 36 — keep it simple for our
    // generated files, which put data at 36).
    var dataAt = 36;
    if (src[36] == 0x64 && src[37] == 0x61) {
      dataAt = 44;
    } else {
      return null;
    }
    if (dataAt >= src.length) return null;

    final out = Uint8List.fromList(src);
    final bd = ByteData.sublistView(out);
    for (var i = dataAt; i + 1 < out.length; i += 2) {
      final sample = bd.getInt16(i, Endian.little);
      bd.setInt16(i, (sample * gain).round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }
}
