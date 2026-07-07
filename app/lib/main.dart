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

class _BeacleAppState extends State<BeacleApp> {
  late final AppState state = AppState();
  late final UserConfig userConfig = UserConfigStore.load();

  @override
  void initState() {
    super.initState();
    if (userConfig.onboardingComplete) {
      state.start();
    }
  }

  @override
  void dispose() {
    EmbeddedBackend.instance.stop();
    state.dispose();
    super.dispose();
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
