import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../shell.dart';
import 'world_geometry.dart';

/// Infrastructure map — exact VPS coordinates, latency links, click-to-inspect.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _Marker {
  _Marker(this.vps, this.world);
  final Vps vps;
  final Offset world;
  Offset screen = Offset.zero;
}

class _MapScreenState extends State<MapScreen> {
  WorldGeometry? geo;
  double scale = 0.55;
  Offset offset = Offset.zero;
  bool _initialised = false;

  Vps? hovered;
  Vps? panelVps;

  @override
  void initState() {
    super.initState();
    WorldGeometry.load().then((g) {
      if (mounted) setState(() => geo = g);
    });
  }

  Offset _toScreen(Offset world) => world * scale + offset;

  void _fit(Size size) {
    scale = math.max(size.width / WorldGeometry.worldW, 0.18);
    offset = Offset(
      (size.width - WorldGeometry.worldW * scale) / 2,
      (size.height - WorldGeometry.worldH * scale) / 2,
    );
  }

  List<_Marker> _markers(List<Vps> vpsList) {
    return vpsList
        .where((v) => v.latitude != 0 || v.longitude != 0)
        .map((v) => _Marker(v, WorldGeometry.project(v.latitude, v.longitude)))
        .toList()
      ..forEach((m) => m.screen = _toScreen(m.world));
  }

  double _radius(Vps v) {
    final cpu = context.read<AppState>().snapshots[v.id]?.metrics.cpuPercent ?? 0;
    return 7 + math.min(cpu / 100 * 4, 4) + (v.isHub ? 2 : 0);
  }

  _Marker? _hit(List<_Marker> markers, Offset pos) {
    for (final m in markers.reversed) {
      if ((m.screen - pos).distance <= _radius(m.vps) + 10) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (geo == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return LayoutBuilder(builder: (ctx, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (!_initialised) {
        _fit(size);
        _initialised = true;
      }
      final markers = _markers(state.vpsList);
      final unplaced = state.vpsList.where((v) => v.latitude == 0 && v.longitude == 0).length;

      return Stack(
        children: [
          Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                final worldBefore = (e.localPosition - offset) / scale;
                setState(() {
                  scale = (scale * (e.scrollDelta.dy > 0 ? 0.9 : 1.12)).clamp(0.15, 8.0);
                  offset = e.localPosition - worldBefore * scale;
                });
              }
            },
            child: MouseRegion(
              onHover: (e) {
                final hit = _hit(markers, e.localPosition)?.vps;
                if (hit != hovered) setState(() => hovered = hit);
              },
              child: GestureDetector(
                onPanUpdate: (d) => setState(() => offset += d.delta),
                onTapUp: (d) {
                  final hit = _hit(markers, d.localPosition);
                  setState(() => panelVps = hit?.vps);
                },
                onSecondaryTapUp: (_) => setState(() => panelVps = null),
                child: CustomPaint(
                  size: size,
                  painter: _MapPainter(
                    geo: geo!,
                    scale: scale,
                    offset: offset,
                    markers: markers,
                    radius: _radius,
                    links: state.links,
                    vpsById: {for (final v in state.vpsList) v.id: v},
                    hovered: hovered,
                    selectedId: panelVps?.id,
                  ),
                ),
              ),
            ),
          ),

          // header
          Positioned(
            left: 20,
            top: 18,
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Infrastructure', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    '${markers.length} nodes · ${state.links.length} links'
                    '${unplaced > 0 ? ' · $unplaced unplaced' : ''}',
                    style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                  ),
                ],
              ),
            ),
          ),

          // zoom controls
          Positioned(
            left: 20,
            bottom: 20,
            child: GlassCard(
              padding: const EdgeInsets.all(6),
              child: Column(
                children: [
                  _mapBtn(Icons.add, () => setState(() => scale = (scale * 1.25).clamp(0.15, 8.0))),
                  const SizedBox(height: 4),
                  _mapBtn(Icons.remove, () => setState(() => scale = (scale / 1.25).clamp(0.15, 8.0))),
                  const SizedBox(height: 4),
                  _mapBtn(Icons.fit_screen, () => setState(() => _fit(size))),
                ],
              ),
            ),
          ),

          // latency legend
          if (state.links.isNotEmpty)
            Positioned(
              right: panelVps != null ? 340 : 20,
              bottom: 20,
              child: GlassCard(
                width: 260,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('LATENCY', style: TextStyle(fontSize: 10, color: BeacleColors.textDim, letterSpacing: 1.2)),
                    const SizedBox(height: 8),
                    for (final l in state.links.take(6)) _linkRow(state, l),
                    if (state.links.length > 6)
                      Text('+${state.links.length - 6} more', style: const TextStyle(fontSize: 10, color: BeacleColors.textDim)),
                  ],
                ),
              ),
            ),

          if (panelVps != null)
            Positioned(right: 0, top: 0, bottom: 0, child: _sidePanel(state, panelVps!)),
        ],
      );
    });
  }

  Widget _mapBtn(IconData icon, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 15, color: BeacleColors.textDim),
        ),
      );

  Widget _linkRow(AppState state, VpsLink l) {
    final vpsById = {for (final v in state.vpsList) v.id: v};
    final from = vpsById[l.fromVpsId]?.name ?? '?';
    final to = vpsById[l.toVpsId]?.name ?? '?';
    final color = switch (l.status) {
      'ok' => BeacleColors.ok,
      'degraded' => BeacleColors.warn,
      'down' => BeacleColors.err,
      _ => BeacleColors.textDim,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(Icons.circle, size: 6, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text('$from → $to', style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
          Text(
            l.status == 'unknown' ? '…' : '${l.latencyMs.toStringAsFixed(0)} ms',
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }

  Widget _sidePanel(AppState state, Vps v) {
    final snap = state.snapshots[v.id];
    final m = snap?.metrics;
    return GlassCard(
      width: 320,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusDot(v.status),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(v.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                      if (v.location.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 16),
                          child: Text(v.location, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: BeacleColors.textDim),
                  onPressed: () => setState(() => panelVps = null),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: BeacleColors.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                if (v.isHub)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: BeacleColors.glow.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: BeacleColors.borderGlow),
                    ),
                    child: const Text('HUB NODE', style: TextStyle(fontSize: 10, letterSpacing: 1.1, color: BeacleColors.accent)),
                  ),
                Text(v.host, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                Text(
                  '${v.latitude.toStringAsFixed(4)}, ${v.longitude.toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                ),
                const SizedBox(height: 16),
                if (m != null) ...[
                  MetricBar(label: 'CPU', percent: m.cpuPercent),
                  const SizedBox(height: 10),
                  MetricBar(label: 'RAM', percent: m.memPercent),
                  if (m.disks.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    MetricBar(label: 'Disk ${m.disks.first.mount}', percent: m.disks.first.usedPercent),
                  ],
                  const SizedBox(height: 14),
                  Text('Uptime ${fmtUptime(m.uptimeSeconds)}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                ] else
                  const Text('Waiting for agent…', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const SizedBox(height: 20),
                SmallButton('Open server', icon: Icons.arrow_forward, onPressed: () => AppShell.of(context).goToServer(v.id)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  final WorldGeometry geo;
  final double scale;
  final Offset offset;
  final List<_Marker> markers;
  final double Function(Vps) radius;
  final List<VpsLink> links;
  final Map<String, Vps> vpsById;
  final Vps? hovered;
  final String? selectedId;

  _MapPainter({
    required this.geo,
    required this.scale,
    required this.offset,
    required this.markers,
    required this.radius,
    required this.links,
    required this.vpsById,
    required this.hovered,
    required this.selectedId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = BeacleColors.bg);

    // subtle grid
    final grid = Paint()
      ..color = BeacleColors.border.withValues(alpha: 0.25)
      ..strokeWidth = 0.5;
    for (var x = 0.0; x < size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 48) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    canvas.drawPath(geo.landPath, Paint()..color = const Color(0xFF111111));
    canvas.drawPath(
      geo.landPath,
      Paint()
        ..color = const Color(0xFF2A2A2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 / scale,
    );
    canvas.restore();

    for (final l in links) {
      final from = vpsById[l.fromVpsId];
      final to = vpsById[l.toVpsId];
      if (from == null || to == null) continue;
      final a = WorldGeometry.project(from.latitude, from.longitude) * scale + offset;
      final b = WorldGeometry.project(to.latitude, to.longitude) * scale + offset;
      final color = switch (l.status) {
        'ok' => BeacleColors.ok,
        'degraded' => BeacleColors.warn,
        'down' => BeacleColors.err,
        _ => BeacleColors.textDim,
      };
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - (b - a).distance * 0.1);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, b.dx, b.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    for (final m in markers) {
      final v = m.vps;
      final r = radius(v);
      final pos = m.screen;
      final color = BeacleColors.statusColor(v.status);
      final isHot = hovered?.id == v.id || selectedId == v.id;

      canvas.drawCircle(pos, r + 8, Paint()..color = color.withValues(alpha: isHot ? 0.28 : 0.12));
      canvas.drawCircle(pos, r, Paint()..color = color);
      if (v.isHub) {
        canvas.drawCircle(
          pos,
          r + 3,
          Paint()
            ..color = BeacleColors.accent.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
      if (isHot) {
        canvas.drawCircle(
          pos,
          r + 5,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      _label(canvas, v.name, pos + Offset(r + 6, -6), isHot);
    }
  }

  void _label(Canvas canvas, String s, Offset pos, bool hot) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: hot ? BeacleColors.text : BeacleColors.textDim,
          fontSize: 11,
          fontWeight: hot ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.scale != scale ||
      old.offset != offset ||
      old.markers.length != markers.length ||
      old.hovered?.id != hovered?.id ||
      old.selectedId != selectedId ||
      old.links != links;
}
