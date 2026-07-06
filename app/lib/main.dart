import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backend/embedded_backend.dart';
import 'screens/shell.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  @override
  void initState() {
    super.initState();
    state.start();
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
        home: const AppShell(),
      ),
    );
  }
}
