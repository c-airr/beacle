import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';

/// The MaterialApp of the main window and of the SSH / Files windows. Its
/// theme follows the palette AppState picked, and with "System" it follows
/// the OS switching between light and dark. The saved palette is put in
/// place before runApp (AppState.applyThemeMode), so the first frame is
/// already right.
class BeacleMaterialApp extends StatefulWidget {
  final Widget home;
  const BeacleMaterialApp({super.key, required this.home});

  @override
  State<BeacleMaterialApp> createState() => _BeacleMaterialAppState();
}

class _BeacleMaterialAppState extends State<BeacleMaterialApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => context.read<AppState>().applyThemeMode();

  @override
  Widget build(BuildContext context) {
    // Rebuilt only when the palette flips, not on every snapshot.
    return Selector<AppState, Brightness>(
      selector: (_, __) => BeacleColors.palette.brightness,
      builder: (_, __, ___) => MaterialApp(
        title: 'Beacle',
        debugShowCheckedModeBanner: false,
        theme: beacleTheme(),
        home: widget.home,
      ),
    );
  }
}
