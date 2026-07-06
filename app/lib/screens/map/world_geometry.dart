import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

/// World map geometry in "world coordinates": equirectangular projection onto
/// a 2000x1000 canvas. The Path is built once and reused by the painter, so
/// panning/zooming only costs a canvas transform.
class WorldGeometry {
  static const double worldW = 2000, worldH = 1000;

  final Path landPath;
  WorldGeometry._(this.landPath);

  static WorldGeometry? _cached;

  static Offset project(double lat, double lon) =>
      Offset((lon + 180) / 360 * worldW, (90 - lat) / 180 * worldH);

  static Future<WorldGeometry> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString('assets/world.json');
    final geo = jsonDecode(raw) as Map<String, dynamic>;
    final path = Path();

    void addRing(List ring) {
      if (ring.isEmpty) return;
      final first = ring.first as List;
      final p0 = project((first[1] as num).toDouble(), (first[0] as num).toDouble());
      path.moveTo(p0.dx, p0.dy);
      for (var i = 1; i < ring.length; i++) {
        final pt = ring[i] as List;
        final p = project((pt[1] as num).toDouble(), (pt[0] as num).toDouble());
        path.lineTo(p.dx, p.dy);
      }
      path.close();
    }

    for (final f in (geo['features'] as List)) {
      final g = (f as Map<String, dynamic>)['geometry'] as Map<String, dynamic>;
      final type = g['type'] as String;
      final coords = g['coordinates'] as List;
      if (type == 'Polygon') {
        for (final ring in coords) {
          addRing(ring as List);
        }
      } else if (type == 'MultiPolygon') {
        for (final poly in coords) {
          for (final ring in poly as List) {
            addRing(ring as List);
          }
        }
      }
    }
    _cached = WorldGeometry._(path);
    return _cached!;
  }
}
