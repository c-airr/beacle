import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../shell.dart';
import 'world_geometry.dart';

/// Aesthetic infrastructure map — no free pan/zoom.
/// Left continent list zooms the camera; map clicks only open VPS cards (worldwide by default).
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _Marker {
  _Marker(this.vps, this.world, this.continent);
  final Vps vps;
  final Offset world;
  final String continent;
}

class _ContinentDef {
  const _ContinentDef(this.name, this.minLat, this.maxLat, this.minLon, this.maxLon);
  final String name;
  final double minLat, maxLat, minLon, maxLon;

  Rect get worldRect {
    final tl = WorldGeometry.project(maxLat, minLon);
    final br = WorldGeometry.project(minLat, maxLon);
    return Rect.fromPoints(tl, br);
  }
}

/// Display order matches the product brief.
const _continents = <_ContinentDef>[
  _ContinentDef('Europe', 35, 72, -25, 45),
  _ContinentDef('North America', 15, 75, -170, -50),
  _ContinentDef('Asia', -10, 55, 60, 180),
  _ContinentDef('South America', -55, 15, -85, -30),
  _ContinentDef('Africa', -35, 38, -20, 55),
  _ContinentDef('Oceania', -50, 0, 110, 180),
];

String _continentFor(Vps v) {
  final lat = v.latitude;
  final lon = v.longitude;
  if (lat == 0 && lon == 0) return 'Unknown';
  for (final c in _continents) {
    if (lat >= c.minLat && lat <= c.maxLat && lon >= c.minLon && lon <= c.maxLon) {
      return c.name;
    }
  }
  // Soft fallbacks for edge cases
  if (lat >= -10 && lat <= 55 && lon >= 60) return 'Asia';
  if (lat >= 15 && lon <= -50) return 'North America';
  if (lat < 15 && lon <= -30 && lon >= -90) return 'South America';
  if (lat < 38 && lon >= -20 && lon < 60) return 'Africa';
  return 'Europe';
}

class _Camera {
  const _Camera(this.scale, this.origin);
  final double scale;
  final Offset origin;

  static _Camera fitWorld(Size viewport) {
    final scale = math.min(viewport.width / WorldGeometry.worldW, viewport.height / WorldGeometry.worldH) * 0.9;
    final origin = Offset(
      (viewport.width - WorldGeometry.worldW * scale) / 2,
      (viewport.height - WorldGeometry.worldH * scale) / 2,
    );
    return _Camera(scale, origin);
  }

  static _Camera fitRect(Size viewport, Rect worldRect, {double padding = 56}) {
    final w = math.max(worldRect.width, 80);
    final h = math.max(worldRect.height, 80);
    final availW = math.max(viewport.width - padding * 2, 1);
    final availH = math.max(viewport.height - padding * 2, 1);
    final scale = math.min(availW / w, availH / h).clamp(0.35, 3.2);
    final origin = Offset(
      viewport.width / 2 - worldRect.center.dx * scale,
      viewport.height / 2 - worldRect.center.dy * scale,
    );
    return _Camera(scale, origin);
  }

  _Camera lerp(_Camera other, double t) => _Camera(
        ui.lerpDouble(scale, other.scale, t)!,
        Offset.lerp(origin, other.origin, t)!,
      );
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  WorldGeometry? geo;
  Vps? panelVps;
  String? selectedContinent;

  late final AnimationController _camCtrl;
  late final CurvedAnimation _camCurve;
  _Camera _camFrom = const _Camera(0.5, Offset.zero);
  _Camera _camTo = const _Camera(0.5, Offset.zero);
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _camCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 780));
    _camCurve = CurvedAnimation(parent: _camCtrl, curve: Curves.easeInOutCubic);
    _camCtrl.value = 1;
    WorldGeometry.load().then((g) {
      if (mounted) setState(() => geo = g);
    });
  }

  @override
  void dispose() {
    _camCurve.dispose();
    _camCtrl.dispose();
    super.dispose();
  }

  _Camera get _camera {
    if (!_camCtrl.isAnimating && _camCtrl.value == 1) return _camTo;
    return _camFrom.lerp(_camTo, _camCurve.value);
  }

  void _animateCamera(_Camera target) {
    _camFrom = _camera;
    _camTo = target;
    _camCtrl.forward(from: 0);
  }

  void _ensureBaseCamera(Size size) {
    if (size == _lastSize || size.isEmpty) return;
    final prev = _lastSize;
    _lastSize = size;
    final world = _Camera.fitWorld(size);
    if (selectedContinent == null) {
      if (prev == Size.zero) {
        _camFrom = world;
        _camTo = world;
        _camCtrl.value = 1;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _animateCamera(world);
        });
      }
    } else {
      final def = _continents.firstWhere((c) => c.name == selectedContinent);
      final target = _Camera.fitRect(size, def.worldRect);
      if (prev == Size.zero) {
        _camFrom = target;
        _camTo = target;
        _camCtrl.value = 1;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _animateCamera(target);
        });
      }
    }
  }

  void _selectContinent(String name, Size size) {
    context.read<AppState>().bumpActivity();
    if (selectedContinent == name) {
      setState(() => selectedContinent = null);
      _animateCamera(_Camera.fitWorld(size));
      return;
    }
    final def = _continents.firstWhere((c) => c.name == name);
    setState(() => selectedContinent = name);
    _animateCamera(_Camera.fitRect(size, def.worldRect));
  }

  void _resetToWorld(Size size) {
    if (selectedContinent == null) return;
    setState(() => selectedContinent = null);
    _animateCamera(_Camera.fitWorld(size));
  }

  List<_Marker> _allMarkers(List<Vps> vpsList) {
    return vpsList
        .where((v) => v.latitude != 0 || v.longitude != 0)
        .map((v) => _Marker(v, WorldGeometry.project(v.latitude, v.longitude), _continentFor(v)))
        .toList();
  }

  Offset _screen(_Marker m, _Camera cam) => m.world * cam.scale + cam.origin;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (geo == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return LayoutBuilder(builder: (ctx, constraints) {
      final full = Size(constraints.maxWidth, constraints.maxHeight);
      const sideW = 176.0;
      final mapSize = Size(math.max(full.width - sideW, 1), full.height);
      _ensureBaseCamera(mapSize);

      final all = _allMarkers(state.vpsList);
      // Always show every VPS — continent list is zoom-only, not a filter.
      final markers = all;

      final counts = {for (final c in _continents) c.name: 0};
      for (final m in all) {
        if (counts.containsKey(m.continent)) {
          counts[m.continent] = counts[m.continent]! + 1;
        }
      }

      return AnimatedBuilder(
        animation: _camCtrl,
        builder: (context, _) {
          final cam = _camera;
          return Stack(
            children: [
              // Map sits to the right of the continent rail and is hard-clipped.
              Positioned(
                left: sideW,
                top: 0,
                right: 0,
                bottom: 0,
                child: ClipRect(
                  child: Stack(
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) {
                          for (final m in markers.reversed) {
                            if ((_screen(m, cam) - d.localPosition).distance < 14) {
                              context.read<AppState>().bumpActivity();
                              setState(() => panelVps = m.vps);
                              return;
                            }
                          }
                          context.read<AppState>().bumpActivity();
                          setState(() => panelVps = null);
                          _resetToWorld(mapSize);
                        },
                        child: CustomPaint(
                          size: mapSize,
                          painter: _MapPainter(
                            geo: geo!,
                            camera: cam,
                            markers: markers,
                            selectedId: panelVps?.id,
                            focusContinent: selectedContinent,
                          ),
                        ),
                      ),
                      if (panelVps != null)
                        Positioned(
                          right: 16,
                          top: 14,
                          child: _VpsMapCard(
                            vps: panelVps!,
                            snap: state.snapshots[panelVps!.id],
                            onClose: () => setState(() => panelVps = null),
                            onStats: () => AppShell.of(context).goToServer(panelVps!.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Continent rail — painted above the map, opaque background.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: sideW,
                child: Material(
                  color: BeacleColors.bg,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 14, 8, 14),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: GlassCard(
                        padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(12, 2, 12, 10),
                              child: Text(
                                'CONTINENTS',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                  color: BeacleColors.textDim,
                                ),
                              ),
                            ),
                            for (final c in _continents)
                              _ContinentRow(
                                name: c.name,
                                count: counts[c.name] ?? 0,
                                selected: selectedContinent == c.name,
                                onTap: () => _selectContinent(c.name, mapSize),
                              ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              child: Divider(height: 1, color: BeacleColors.border),
                            ),
                            _ContinentRow(
                              name: 'World',
                              count: all.length,
                              selected: selectedContinent == null,
                              dim: selectedContinent != null,
                              onTap: () {
                                context.read<AppState>().bumpActivity();
                                setState(() => selectedContinent = null);
                                _animateCamera(_Camera.fitWorld(mapSize));
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    });
  }
}

class _ContinentRow extends StatefulWidget {
  final String name;
  final int count;
  final bool selected;
  final bool dim;
  final VoidCallback onTap;
  const _ContinentRow({
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
    this.dim = false,
  });

  @override
  State<_ContinentRow> createState() => _ContinentRowState();
}

class _ContinentRowState extends State<_ContinentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? BeacleColors.glassHi
                : active
                    ? BeacleColors.hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.selected ? Border.all(color: BeacleColors.borderGlow) : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                    color: widget.dim ? BeacleColors.textDim : BeacleColors.text,
                  ),
                ),
              ),
              Text(
                '${widget.count}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.count > 0 ? BeacleColors.text : BeacleColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VpsMapCard extends StatelessWidget {
  final Vps vps;
  final VpsSnapshot? snap;
  final VoidCallback onClose;
  final VoidCallback onStats;
  const _VpsMapCard({
    required this.vps,
    required this.snap,
    required this.onClose,
    required this.onStats,
  });

  @override
  Widget build(BuildContext context) {
    final m = snap?.metrics;
    return Material(
      color: Colors.transparent,
      child: GlassCard(
        width: 280,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 6, 10),
              child: Row(
                children: [
                  StatusDot(vps.status, size: 9),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(vps.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16, color: BeacleColors.textDim),
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: BeacleColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vps.host, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                  if (vps.publicIp.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('public ${vps.publicIp}', style: const TextStyle(fontSize: 11, color: BeacleColors.textDim, fontFamily: 'Consolas')),
                  ],
                  if (vps.location.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(vps.location, style: const TextStyle(fontSize: 11, color: BeacleColors.textDim)),
                  ],
                  const SizedBox(height: 14),
                  if (m != null) ...[
                    MetricBar(label: 'CPU', percent: m.cpuPercent),
                    const SizedBox(height: 10),
                    MetricBar(label: 'RAM', percent: m.memPercent, detail: '${fmtBytes(m.memUsedBytes)} / ${fmtBytes(m.memTotalBytes)}'),
                    if (m.disks.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      MetricBar(label: 'Disk', percent: m.disks.first.usedPercent),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      '${m.cpuCores} cores · load ${m.load1.toStringAsFixed(2)} · up ${fmtUptime(m.uptimeSeconds)}',
                      style: const TextStyle(fontSize: 11, color: BeacleColors.textDim),
                    ),
                  ] else
                    const Text('Waiting for agent…', style: TextStyle(fontSize: 12, color: BeacleColors.textDim)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: SmallButton('Stats', icon: Icons.dns_outlined, onPressed: onStats),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  final WorldGeometry geo;
  final _Camera camera;
  final List<_Marker> markers;
  final String? selectedId;
  final String? focusContinent;

  _MapPainter({
    required this.geo,
    required this.camera,
    required this.markers,
    required this.selectedId,
    required this.focusContinent,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    // Hard clip — zoomed geometry must not spill into the continent sidebar.
    canvas.save();
    canvas.clipRect(Offset.zero & canvasSize);

    canvas.drawRect(Offset.zero & canvasSize, Paint()..color = BeacleColors.bg);

    canvas.save();
    canvas.translate(camera.origin.dx, camera.origin.dy);
    canvas.scale(camera.scale);

    // Soft focus ring when a continent is selected
    if (focusContinent != null) {
      final def = _continents.firstWhere((c) => c.name == focusContinent);
      final r = def.worldRect.inflate(28);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(40)),
        Paint()
          ..color = const Color(0x14FFFFFF)
          ..style = PaintingStyle.fill,
      );
    }

    // Land fill
    canvas.drawPath(geo.landPath, Paint()..color = const Color(0xFF111111));
    // Coastline / land outline sketches
    canvas.drawPath(
      geo.landPath,
      Paint()
        ..color = const Color(0xFF555555)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15 / camera.scale
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      geo.landPath,
      Paint()
        ..color = const Color(0xFF2E2E2E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.55 / camera.scale
        ..isAntiAlias = true,
    );
    canvas.restore();

    for (final m in markers) {
      final pos = m.world * camera.scale + camera.origin;
      final color = BeacleColors.statusColor(m.vps.status);
      final hot = m.vps.id == selectedId;
      canvas.drawCircle(pos, hot ? 11 : 8, Paint()..color = color.withValues(alpha: 0.18));
      canvas.drawCircle(pos, hot ? 7 : 5, Paint()..color = color);
      if (hot) {
        canvas.drawCircle(
          pos,
          7,
          Paint()
            ..color = BeacleColors.text
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.camera.scale != camera.scale ||
      old.camera.origin != camera.origin ||
      old.markers.length != markers.length ||
      old.selectedId != selectedId ||
      old.focusContinent != focusContinent;
}
