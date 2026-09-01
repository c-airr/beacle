import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';

/// One line on a chart.
class ChartSeries {
  final String label;
  final Color color;

  /// Pulls this series' value out of a sample. Returning null drops the point,
  /// which is how a metric the host does not report leaves a gap rather than a
  /// line along zero.
  final double? Function(MetricSample) value;

  /// Formats a value for the axis and the tooltip.
  final String Function(double) format;

  const ChartSeries({
    required this.label,
    required this.color,
    required this.value,
    required this.format,
  });
}

/// Colours for history charts, validated against the panel's dark surface for
/// lightness band, chroma, contrast and colour-vision separation. The pair that
/// shares a plot — network in and out — is the one that had to pass the
/// separation check; the rest each own a chart to themselves.
class ChartColors {
  ChartColors._();
  static const cpu = Color(0xFF0284C7);
  static const ram = Color(0xFF7C3AED);
  static const netIn = Color(0xFF0891B2);
  static const netOut = Color(0xFFEA580C);
}

/// A pannable, zoomable time-series chart over recorded history.
///
/// Built for the question "what was this server doing while I was asleep", so
/// it is navigable rather than a static picture: drag to scroll back through
/// time, Ctrl+scroll to zoom, and hover for exact values at a moment. A bare
/// wheel is left to the page, which is scrolling past this chart rather than
/// through it.
///
/// A stretch with no samples is drawn as an outage band rather than joined up.
/// The agent stops reporting when it dies or the host goes away, so the missing
/// data *is* the record of the incident — a line drawn straight through it
/// would erase the very thing you came to look for.
class MetricChart extends StatefulWidget {
  final String title;
  final List<MetricSample> samples;
  final List<ChartSeries> series;

  /// Fixed upper bound for the axis, e.g. 100 for a percentage. Null scales to
  /// the data.
  final double? maxY;

  /// Window currently shown. Panning and zooming report changes through
  /// [onWindowChanged] so the parent can fetch more history.
  final DateTime from;
  final DateTime to;
  final void Function(DateTime from, DateTime to)? onWindowChanged;

  /// Bounds of what actually exists, so scrolling stops at the edge of the
  /// record instead of drifting into empty weeks.
  final DateTime? boundsFirst;
  final DateTime? boundsLast;

  /// Stretches when the panel was closed. Drawn differently from an outage
  /// because they say nothing about the server: nobody was recording, which
  /// is not the same as nothing to record.
  final List<PanelDowntime> panelDown;

  final double height;

  const MetricChart({
    super.key,
    required this.title,
    required this.samples,
    required this.series,
    required this.from,
    required this.to,
    this.maxY,
    this.onWindowChanged,
    this.boundsFirst,
    this.boundsLast,
    this.panelDown = const [],
    this.height = 150,
  });

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart> {
  Offset? _hover;

  Duration get _span => widget.to.difference(widget.from);

  void _pan(double dx, double width) {
    if (widget.onWindowChanged == null || width <= 0) return;
    // Dragging right moves the window back in time, the way a filmstrip does.
    final shift = Duration(
        microseconds: -(dx / width * _span.inMicroseconds).round());
    _moveWindow(widget.from.add(shift), widget.to.add(shift));
  }

  void _zoom(double delta) {
    if (widget.onWindowChanged == null) return;
    final factor = delta > 0 ? 1.25 : 0.8;
    final centre = widget.from.add(_span ~/ 2);
    var half = Duration(microseconds: (_span.inMicroseconds * factor / 2).round());

    // Below a few minutes there is nothing left to see — samples are a minute
    // apart — and past the retention window there is nothing left to load.
    const minHalf = Duration(minutes: 5);
    const maxHalf = Duration(days: 7);
    if (half < minHalf) half = minHalf;
    if (half > maxHalf) half = maxHalf;

    _moveWindow(centre.subtract(half), centre.add(half));
  }

  void _moveWindow(DateTime from, DateTime to) {
    final first = widget.boundsFirst;
    final last = widget.boundsLast ?? DateTime.now();
    final span = to.difference(from);

    // Clamp against the ends of the record, keeping the span so the chart does
    // not squash as it hits a wall.
    if (first != null && from.isBefore(first)) {
      from = first;
      to = first.add(span);
    }
    final ceiling = last.add(const Duration(minutes: 1));
    if (to.isAfter(ceiling)) {
      to = ceiling;
      from = ceiling.subtract(span);
    }
    widget.onWindowChanged!(from, to);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(widget.title,
                style: const TextStyle(
                    fontSize: 11,
                    color: BeacleColors.textDim,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4)),
            const Spacer(),
            // A legend is only meaningful once two things share the plot; with
            // one series the title already names it.
            if (widget.series.length > 1)
              Row(
                children: [
                  for (final s in widget.series) ...[
                    Container(width: 14, height: 2, color: s.color),
                    const SizedBox(width: 5),
                    Text(s.label,
                        style: const TextStyle(fontSize: 10, color: BeacleColors.textDim)),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: widget.height,
          child: LayoutBuilder(builder: (context, box) {
            return Listener(
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent) return;
                // Zoom only with Ctrl held. A bare wheel over the chart used to
                // zoom it *and* scroll the page underneath, because the event
                // reaches both — so the reader got a moving chart on a moving
                // page. Plain scrolling now belongs to the page, which is what
                // the hand expects while reading down a server.
                if (!HardwareKeyboard.instance.isControlPressed) return;
                // Registering with the resolver is what actually claims the
                // event: the scrollable would otherwise still act on it.
                GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                  _zoom((ev as PointerScrollEvent).scrollDelta.dy);
                });
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => _pan(d.delta.dx, box.maxWidth),
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  onHover: (e) => setState(() => _hover = e.localPosition),
                  onExit: (_) => setState(() => _hover = null),
                  child: CustomPaint(
                    size: Size(box.maxWidth, widget.height),
                    painter: _ChartPainter(
                      samples: widget.samples,
                      series: widget.series,
                      from: widget.from,
                      to: widget.to,
                      maxY: widget.maxY,
                      hover: _hover,
                      panelDown: widget.panelDown,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<MetricSample> samples;
  final List<ChartSeries> series;
  final DateTime from, to;
  final double? maxY;
  final Offset? hover;
  final List<PanelDowntime> panelDown;

  _ChartPainter({
    required this.samples,
    required this.series,
    required this.from,
    required this.to,
    required this.maxY,
    required this.hover,
    required this.panelDown,
  });

  static const _leftPad = 44.0;
  static const _bottomPad = 18.0;
  static const _topPad = 6.0;

  /// Wider than the sample interval, so ordinary jitter does not look like an
  /// outage, but narrow enough that a genuine gap shows up immediately.
  static const _gapAfter = Duration(minutes: 3);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_leftPad, _topPad, size.width, size.height - _bottomPad);
    if (plot.width <= 0 || plot.height <= 0) return;

    final spanUs = to.difference(from).inMicroseconds;
    if (spanUs <= 0) return;

    double xFor(DateTime t) =>
        plot.left + t.difference(from).inMicroseconds / spanUs * plot.width;

    // Upper bound: fixed for percentages, otherwise the tallest value in view
    // with headroom so the peak is not clipped to the frame.
    var top = maxY ?? 0;
    if (maxY == null) {
      for (final s in samples) {
        for (final ser in series) {
          final v = ser.value(s);
          if (v != null && v > top) top = v;
        }
      }
      top = top <= 0 ? 1 : top * 1.15;
    }

    double yFor(double v) => plot.bottom - (v / top).clamp(0, 1) * plot.height;

    _paintGrid(canvas, plot, top);
    _paintOutages(canvas, plot, xFor);

    for (final ser in series) {
      _paintSeries(canvas, plot, ser, xFor, yFor);
    }

    _paintTimeAxis(canvas, plot, xFor);
    if (hover != null) _paintHover(canvas, plot, size, xFor, yFor);
  }

  void _paintGrid(Canvas canvas, Rect plot, double top) {
    // Recessive: the grid orients, it does not compete with the data.
    final line = Paint()
      ..color = BeacleColors.border.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    for (var i = 0; i <= 4; i++) {
      final frac = i / 4;
      final y = plot.bottom - frac * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), line);

      final label = series.first.format(top * frac);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(fontSize: 9, color: BeacleColors.textDim),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.left - tp.width - 6, y - tp.height / 2));
    }
  }

  /// Shades stretches where nothing was recorded. This is the feature, not a
  /// rendering detail: a gap here is the server having been unreachable.
  ///
  /// Except when it is not. Samples are written by the panel, so a gap also
  /// appears whenever the panel was closed — and those were drawn in the same
  /// alarming red, which made every ordinary night look like an incident. A
  /// stretch the panel was away for is drawn in grey instead: it says nothing
  /// about the server, and claiming otherwise is worse than saying nothing.
  void _paintOutages(Canvas canvas, Rect plot, double Function(DateTime) xFor) {
    final outage = Paint()..color = BeacleColors.err.withValues(alpha: 0.07);
    final unknown = Paint()..color = BeacleColors.textDim.withValues(alpha: 0.10);

    void shade(DateTime a, DateTime b, Paint p) {
      final x1 = xFor(a).clamp(plot.left, plot.right);
      final x2 = xFor(b).clamp(plot.left, plot.right);
      if (x2 - x1 < 1) return;
      canvas.drawRect(Rect.fromLTRB(x1, plot.top, x2, plot.bottom), p);
    }

    // Panel-closed stretches first, so an outage band drawn over one still
    // reads as the stronger claim.
    for (final d in panelDown) {
      shade(d.from, d.to, unknown);
    }

    if (samples.length < 2) return;
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1].at, b = samples[i].at;
      if (b.difference(a) <= _gapAfter) continue;
      if (_coveredByPanelDowntime(a, b)) continue;
      shade(a, b, outage);
    }
  }

  /// Whether a gap is explained by the panel having been closed. Mostly it is
  /// covered outright; a little slack absorbs the minute either side where a
  /// sample landed just before shutdown or just after start.
  bool _coveredByPanelDowntime(DateTime a, DateTime b) {
    const slack = Duration(minutes: 2);
    for (final d in panelDown) {
      if (!d.from.subtract(slack).isAfter(a) && !d.to.add(slack).isBefore(b)) {
        return true;
      }
    }
    return false;
  }

  void _paintSeries(
    Canvas canvas,
    Rect plot,
    ChartSeries ser,
    double Function(DateTime) xFor,
    double Function(double) yFor,
  ) {
    final stroke = Paint()
      ..color = ser.color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // A gap breaks the path instead of being bridged, so an outage cannot be
    // mistaken for a flat, healthy stretch.
    Path? path;
    DateTime? prevAt;

    void flush() {
      if (path != null) canvas.drawPath(path!, stroke);
      path = null;
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final s in samples) {
      final v = ser.value(s);
      if (v == null) {
        flush();
        prevAt = null;
        continue;
      }
      final p = Offset(xFor(s.at), yFor(v));
      if (path == null || (prevAt != null && s.at.difference(prevAt).abs() > _gapAfter)) {
        flush();
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path!.lineTo(p.dx, p.dy);
      }
      prevAt = s.at;
    }
    flush();
    canvas.restore();
  }

  void _paintTimeAxis(Canvas canvas, Rect plot, double Function(DateTime) xFor) {
    final span = to.difference(from);
    // Label density follows the window: a day wants hours, a week wants days.
    final step = switch (span.inMinutes) {
      < 90 => const Duration(minutes: 15),
      < 360 => const Duration(hours: 1),
      < 1440 => const Duration(hours: 3),
      < 4320 => const Duration(hours: 12),
      _ => const Duration(days: 1),
    };

    var t = DateTime.fromMillisecondsSinceEpoch(
        (from.millisecondsSinceEpoch ~/ step.inMilliseconds) * step.inMilliseconds);
    if (t.isBefore(from)) t = t.add(step);

    final showDate = span.inHours >= 24;
    while (t.isBefore(to)) {
      final x = xFor(t);
      if (x >= plot.left && x <= plot.right) {
        final local = t.toLocal();
        final label = showDate
            ? '${local.day}/${local.month} ${local.hour.toString().padLeft(2, '0')}h'
            : '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(fontSize: 9, color: BeacleColors.textDim),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Keep the last label inside the frame instead of letting it overhang.
        final dx = math.min(x - tp.width / 2, plot.right - tp.width);
        tp.paint(canvas, Offset(math.max(dx, plot.left), plot.bottom + 5));
      }
      t = t.add(step);
    }
  }

  /// Crosshair plus a readout of every series at that moment. The reader aims
  /// at a time, not at a two-pixel line, so this snaps to the nearest sample.
  void _paintHover(
    Canvas canvas,
    Rect plot,
    Size size,
    double Function(DateTime) xFor,
    double Function(double) yFor,
  ) {
    if (samples.isEmpty) return;
    final hx = hover!.dx;
    if (hx < plot.left || hx > plot.right) return;

    MetricSample? nearest;
    var bestDist = double.infinity;
    for (final s in samples) {
      final d = (xFor(s.at) - hx).abs();
      if (d < bestDist) {
        bestDist = d;
        nearest = s;
      }
    }
    if (nearest == null || bestDist > 40) return;

    final x = xFor(nearest.at);
    canvas.drawLine(
      Offset(x, plot.top),
      Offset(x, plot.bottom),
      Paint()
        ..color = BeacleColors.textDim.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );

    for (final ser in series) {
      final v = ser.value(nearest);
      if (v == null) continue;
      final p = Offset(x, yFor(v));
      // A ring in the surface colour separates the marker from the line it
      // sits on.
      canvas.drawCircle(p, 4.5, Paint()..color = BeacleColors.surface);
      canvas.drawCircle(p, 3, Paint()..color = ser.color);
    }

    final local = nearest.at.toLocal();
    final when = '${local.day}/${local.month} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

    // Values lead, labels follow: here the reader has the series and wants the
    // number. Text keeps text colours; the series colour is carried by the key.
    final spans = <TextSpan>[
      TextSpan(
        text: when,
        style: const TextStyle(fontSize: 10, color: BeacleColors.textDim),
      ),
    ];
    for (final ser in series) {
      final v = ser.value(nearest);
      if (v == null) continue;
      spans.add(TextSpan(
        text: '\n${ser.format(v)}  ',
        style: const TextStyle(
            fontSize: 11, color: BeacleColors.text, fontWeight: FontWeight.w600),
      ));
      spans.add(TextSpan(
        text: ser.label,
        style: const TextStyle(fontSize: 10, color: BeacleColors.textDim),
      ));
    }

    final tp = TextPainter(
      text: TextSpan(children: spans),
      textDirection: TextDirection.ltr,
    )..layout();

    const pad = 7.0;
    var left = x + 12;
    if (left + tp.width + pad * 2 > size.width) left = x - tp.width - pad * 2 - 12;
    final rect = Rect.fromLTWH(
        left, plot.top + 4, tp.width + pad * 2, tp.height + pad * 2);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()..color = BeacleColors.glassHi,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()
        ..color = BeacleColors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(canvas, Offset(rect.left + pad, rect.top + pad));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.samples != samples ||
      old.from != from ||
      old.to != to ||
      old.hover != hover ||
      old.maxY != maxY;
}
