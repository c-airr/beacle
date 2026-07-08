import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backend/embedded_backend.dart';
import 'paths.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/shell.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'user_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BeaclePaths.ensureDirs();
  if (!File(BeaclePaths.stateFile).existsSync()) {
    File(BeaclePaths.stateFile).writeAsStringSync(
      '{"vps":{},"links":{},"alerts":[],"actions":[]}',
    );
  }

  await EmbeddedBackend.instance.ensureRunning();
  runApp(const BeacleApp());
}

class BeacleApp extends StatefulWidget {
  const BeacleApp({super.key});

  @override
  State<BeacleApp> createState() => _BeacleAppState();
}

class _BeacleAppState extends State<BeacleApp> with WidgetsBindingObserver {
  late final AppState state = AppState();
  late final UserConfig userConfig = UserConfigStore.load();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (userConfig.onboardingComplete) {
      state.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    EmbeddedBackend.instance.stop();
    state.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (!userConfig.onboardingComplete) return;
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        state.bumpActivity();
      case AppLifecycleState.inactive:
        // Lost focus (e.g. alt-tab). Keep WS alive but slow down slightly.
        state.enterEcoMode();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        state.enterSleepMode();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        title: 'Beacle',
        debugShowCheckedModeBanner: false,
        theme: beacleTheme(),
        home: userConfig.onboardingComplete ? const AppShell() : const OnboardingScreen(),
      ),
    );
  }
}
