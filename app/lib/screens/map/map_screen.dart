import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../shell.dart';
import 'world_geometry.dart';

/// Static infrastructure map — regional summary, click VPS for details.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _Marker {
  _Marker(this.vps, this.world);
  final Vps vps;
  final Offset world;
}

String _regionFor(Vps v) {
  final lat = v.latitude;
  final lon = v.longitude;
  if (lat == 0 && lon == 0) return 'Unknown';
  if (lat >= -10 && lat <= 55 && lon >= 60 && lon <= 180) return 'Asia';
  if (lat >= -55 && lat <= 15 && lon >= -20 && lon <= 55) return 'Africa';
  if (lat >= -50 && lat <= 15 && lon >= -85 && lon <= -30) return 'South America';
  if (lat >= 15 && lat <= 75 && lon >= -170 && lon <= -50) return 'North America';
  if (lat >= -50 && lat <= 0 && lon >= 110 && lon <= 180) return 'Australia & Oceania';
  if (lat >= 35 && lat <= 72 && lon >= -25 && lon <= 45) return 'Europe';
  if (lat >= -35 && lat < 35 && lon >= -20 && lon < 60) return 'Africa';
  return 'Europe';
}

Map<String, int> _regionCounts(List<Vps> vps) {
  final counts = <String, int>{
    'Europe': 0,
    'North America': 0,
    'South America': 0,
    'Asia': 0,
    'Africa': 0,
    'Australia & Oceania': 0,
  };
  for (final v in vps) {
    final r = _regionFor(v);
    if (counts.containsKey(r)) {
      counts[r] = counts[r]! + 1;
    }
  }
  return counts;
}

class _MapScreenState extends State<MapScreen> {
  WorldGeometry? geo;
  Vps? panelVps;

  static const _scale = 0.52;

  @override
  void initState() {
    super.initState();
    WorldGeometry.load().then((g) {
      if (mounted) setState(() => geo = g);
    });
  }

  List<_Marker> _markers(List<Vps> vpsList, Size size) {
    final ox = (size.width - WorldGeometry.worldW * _scale) / 2;
    final oy = (size.height - WorldGeometry.worldH * _scale) / 2;
    return vpsList
        .where((v) => v.latitude != 0 || v.longitude != 0)
        .map((v) => _Marker(v, WorldGeometry.project(v.latitude, v.longitude)))
        .toList();
  }

  Offset _screen(_Marker m, Size size) {
    final ox = (size.width - WorldGeometry.worldW * _scale) / 2;
    final oy = (size.height - WorldGeometry.worldH * _scale) / 2;
    return m.world * _scale + Offset(ox, oy);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (geo == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return LayoutBuilder(builder: (ctx, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final markers = _markers(state.vpsList, size);
      final regions = _regionCounts(state.vpsList);

      return Stack(
        children: [
          GestureDetector(
            onTapUp: (d) {
              for (final m in markers.reversed) {
                if ((_screen(m, size) - d.localPosition).distance < 12) {
                  setState(() => panelVps = m.vps);
                  return;
                }
              }
              setState(() => panelVps = null);
            },
            child: CustomPaint(
              size: size,
              painter: _StaticMapPainter(
                geo: geo!,
                scale: _scale,
                size: size,
                markers: markers,
                selectedId: panelVps?.id,
              ),
            ),
          ),
          Positioned(
            left: 20,
            top: 18,
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in regions.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('${e.key} — ${e.value} VPS',
                          style: const TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                    ),
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

  Widget _sidePanel(AppState state, Vps v) {
    final snap = state.snapshots[v.id];
    final m = snap?.metrics;
    return GlassCard(
      width: 300,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
            child: Row(
              children: [
                StatusDot(v.status),
                const SizedBox(width: 8),
                Expanded(child: Text(v.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
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
                Text(v.host, style: const TextStyle(fontSize: 12, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                if (v.tailscaleName.isNotEmpty)
                  Text(v.tailscaleName, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                const SizedBox(height: 14),
                if (m != null) ...[
                  MetricBar(label: 'CPU', percent: m.cpuPercent),
                  const SizedBox(height: 10),
                  MetricBar(label: 'RAM', percent: m.memPercent),
                ] else
                  const Text('Waiting for agent…', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                const SizedBox(height: 18),
                SmallButton('Open server', icon: Icons.arrow_forward, onPressed: () => AppShell.of(context).goToServer(v.id)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticMapPainter extends CustomPainter {
  final WorldGeometry geo;
  final double scale;
  final Size size;
  final List<_Marker> markers;
  final String? selectedId;

  _StaticMapPainter({
    required this.geo,
    required this.scale,
    required this.size,
    required this.markers,
    required this.selectedId,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    canvas.drawRect(Offset.zero & canvasSize, Paint()..color = BeacleColors.bg);
    final ox = (size.width - WorldGeometry.worldW * scale) / 2;
    final oy = (size.height - WorldGeometry.worldH * scale) / 2;
    canvas.save();
    canvas.translate(ox, oy);
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

    for (final m in markers) {
      final pos = m.world * scale + Offset(ox, oy);
      final color = BeacleColors.statusColor(m.vps.status);
      final hot = m.vps.id == selectedId;
      canvas.drawCircle(pos, hot ? 9 : 7, Paint()..color = color.withValues(alpha: 0.15));
      canvas.drawCircle(pos, hot ? 7 : 5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_StaticMapPainter old) => old.markers.length != markers.length || old.selectedId != selectedId;
}
