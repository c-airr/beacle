import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// How the SSH and Files tools open: in their own OS window, sliding out to
/// the right of the current screen (the window grows to make room), or in the
/// main content area. Chosen separately for each tool.
enum SshDisplayMode { separateWindow, splitView, fullscreen }

extension SshDisplayModeWire on SshDisplayMode {
  String get wire => switch (this) {
        SshDisplayMode.separateWindow => 'separate_window',
        SshDisplayMode.splitView => 'split_view',
        SshDisplayMode.fullscreen => 'fullscreen',
      };
  static SshDisplayMode fromWire(String? v) => switch (v) {
        'split_view' => SshDisplayMode.splitView,
        'separate_window' => SshDisplayMode.separateWindow,
        _ => SshDisplayMode.fullscreen,
      };
}

class UserConfig {
  bool onboardingComplete;
  SshDisplayMode sshDisplayMode;
  SshDisplayMode filesDisplayMode;

  UserConfig({
    this.onboardingComplete = false,
    this.sshDisplayMode = SshDisplayMode.fullscreen,
    this.filesDisplayMode = SshDisplayMode.fullscreen,
  });

  factory UserConfig.fromJson(Map<String, dynamic> j) {
    final ssh = SshDisplayModeWire.fromWire(j['ssh_display_mode'] as String?);
    return UserConfig(
      onboardingComplete: j['onboarding_complete'] == true,
      sshDisplayMode: ssh,
      // Configs from before the file explorer only have the SSH choice made
      // during setup; it carries over until Files gets its own.
      filesDisplayMode: j.containsKey('files_display_mode')
          ? SshDisplayModeWire.fromWire(j['files_display_mode'] as String?)
          : ssh,
    );
  }

  Map<String, dynamic> toJson() => {
        'onboarding_complete': onboardingComplete,
        'ssh_display_mode': sshDisplayMode.wire,
        'files_display_mode': filesDisplayMode.wire,
      };
}

class UserSettings {
  Map<String, dynamic> raw;

  UserSettings([Map<String, dynamic>? data]) : raw = data ?? {};

  static UserSettings load() {
    try {
      final f = File(BeaclePaths.settingsFile);
      if (!f.existsSync()) return UserSettings();
      return UserSettings(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return UserSettings();
    }
  }

  void save() {
    BeaclePaths.ensureDirs();
    File(BeaclePaths.settingsFile).writeAsStringSync(jsonEncode(raw));
  }
}

class SavedServer {
  final String id, name, tailscaleName, tailscaleIp;
  SavedServer({required this.id, required this.name, required this.tailscaleName, required this.tailscaleIp});

  factory SavedServer.fromJson(Map<String, dynamic> j) => SavedServer(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        tailscaleName: j['tailscale_name'] as String? ?? '',
        tailscaleIp: j['tailscale_ip'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tailscale_name': tailscaleName,
        'tailscale_ip': tailscaleIp,
      };
}

class ServersStore {
  List<SavedServer> servers;

  ServersStore([List<SavedServer>? list]) : servers = list ?? [];

  static ServersStore load() {
    try {
      final f = File(BeaclePaths.serversFile);
      if (!f.existsSync()) return ServersStore();
      final list = (jsonDecode(f.readAsStringSync()) as List?) ?? [];
      return ServersStore(list.map((e) => SavedServer.fromJson(e as Map<String, dynamic>)).toList());
    } catch (_) {
      return ServersStore();
    }
  }

  void save() {
    BeaclePaths.ensureDirs();
    File(BeaclePaths.serversFile).writeAsStringSync(jsonEncode(servers.map((s) => s.toJson()).toList()));
  }

  void add(SavedServer s) {
    servers.add(s);
    save();
  }
}

class UserConfigStore {
  static UserConfig load() {
    try {
      final f = File(BeaclePaths.configFile);
      if (!f.existsSync()) return UserConfig();
      return UserConfig.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return UserConfig();
    }
  }

  static void save(UserConfig cfg) {
    BeaclePaths.ensureDirs();
    File(BeaclePaths.configFile).writeAsStringSync(jsonEncode(cfg.toJson()));
  }

  /// Wipes user data for a fresh first-run experience.
  static void resetAll() {
    for (final p in [
      BeaclePaths.configFile,
      BeaclePaths.serversFile,
      BeaclePaths.settingsFile,
      BeaclePaths.stateFile,
    ]) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
    BeaclePaths.ensureDirs();
    File(BeaclePaths.stateFile).writeAsStringSync(
      jsonEncode({'vps': {}, 'links': {}, 'alerts': [], 'actions': []}),
    );
  }
}
