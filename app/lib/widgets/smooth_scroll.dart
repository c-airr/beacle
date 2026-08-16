import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Mouse-wheel scrolling tuned like an editor timeline: most of the movement
/// happens immediately, then eases gently into the final position.
///
/// Flutter desktop normally applies each wheel tick as an instant jump.
/// This stays dependency-free, accumulates quick ticks into one target and
/// gives the innermost scroll view first refusal for nested lists/dialogs.
const _duration = Duration(milliseconds: 340);
const _scrollSpeed = 1.45;
const _curve = Curves.easeOutCubic;

typedef _SmoothBuilder = Widget Function(
  BuildContext context,
  ScrollController controller,
  ScrollPhysics physics,
);

class _SmoothMouseScroll extends StatefulWidget {
  final Axis axis;
  final _SmoothBuilder builder;

  const _SmoothMouseScroll({required this.axis, required this.builder});

  @override
  State<_SmoothMouseScroll> createState() => _SmoothMouseScrollState();
}

class _SmoothMouseScrollState extends State<_SmoothMouseScroll> {
  final ScrollController _controller = ScrollController();
  bool _directManipulation = false;
  double? _target;
  int _direction = 0;

  ScrollPhysics get _physics => _directManipulation
      ? const ClampingScrollPhysics()
      : const NeverScrollableScrollPhysics();

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    // Pointer signals bubble through nested scrollables. Registering with the
    // resolver means only the first (innermost) Smooth* view moves.
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (resolved is PointerScrollEvent) _animateWheel(resolved);
    });
  }

  void _animateWheel(PointerScrollEvent event) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final raw = widget.axis == Axis.vertical
        ? event.scrollDelta.dy
        : (event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
            ? event.scrollDelta.dx
            : event.scrollDelta.dy);
    if (raw == 0) return;

    final direction = raw.sign.toInt();
    final current = position.pixels;
    // Changing direction should react immediately instead of finishing the
    // previous animation first.
    if (_direction != direction || _target == null) _target = current;
    _direction = direction;
    _target = math.max(
      position.minScrollExtent,
      math.min(position.maxScrollExtent, _target! + raw * _scrollSpeed),
    );

    _controller.animateTo(_target!, duration: _duration, curve: _curve);
  }

  void _setDirectManipulation(bool value) {
    if (_directManipulation == value) return;
    setState(() => _directManipulation = value);
    if (value && _controller.hasClients) {
      _target = _controller.position.pixels;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      // Scrollbar dragging and touch remain direct; only wheel/trackpad signals
      // receive the editor-style easing.
      onPointerDown: (_) => _setDirectManipulation(true),
      onPointerUp: (_) => _setDirectManipulation(false),
      onPointerCancel: (_) => _setDirectManipulation(false),
      child: widget.builder(context, _controller, _physics),
    );
  }
}

class SmoothListView extends StatelessWidget {
  final Axis scrollDirection;
  final bool reverse;
  final bool shrinkWrap;
  final EdgeInsetsGeometry? padding;
  final List<Widget>? children;
  final int? itemCount;
  final IndexedWidgetBuilder? itemBuilder;

  const SmoothListView({
    super.key,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.shrinkWrap = false,
    this.padding,
    this.children = const <Widget>[],
  })  : itemCount = null,
        itemBuilder = null;

  const SmoothListView.builder({
    super.key,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.shrinkWrap = false,
    this.padding,
    required int this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
  }) : children = null;

  @override
  Widget build(BuildContext context) {
    return _SmoothMouseScroll(
      axis: scrollDirection,
      builder: (context, controller, physics) {
        if (itemBuilder != null) {
          return ListView.builder(
            scrollDirection: scrollDirection,
            reverse: reverse,
            controller: controller,
            physics: physics,
            shrinkWrap: shrinkWrap,
            padding: padding,
            itemCount: itemCount,
            itemBuilder: itemBuilder!,
          );
        }
        return ListView(
          scrollDirection: scrollDirection,
          reverse: reverse,
          controller: controller,
          physics: physics,
          shrinkWrap: shrinkWrap,
          padding: padding,
          children: children!,
        );
      },
    );
  }
}

class SmoothSingleChildScrollView extends StatelessWidget {
  final Axis scrollDirection;
  final bool reverse;
  final EdgeInsetsGeometry? padding;
  final Widget? child;

  const SmoothSingleChildScrollView({
    super.key,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.padding,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return _SmoothMouseScroll(
      axis: scrollDirection,
      builder: (context, controller, physics) => SingleChildScrollView(
        scrollDirection: scrollDirection,
        reverse: reverse,
        controller: controller,
        physics: physics,
        padding: padding,
        child: child,
      ),
    );
  }
}
