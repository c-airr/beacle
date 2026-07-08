import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Forwards pointer/scroll activity to [AppState.bumpActivity] for adaptive refresh.
class ActivityScope extends StatelessWidget {
  final Widget child;
  const ActivityScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    void bump() => context.read<AppState>().bumpActivity();
    return Listener(
      onPointerDown: (_) => bump(),
      onPointerSignal: (_) => bump(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          bump();
          return false;
        },
        child: child,
      ),
    );
  }
}
