import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

/// World map geometry in "world coordinates": equirectangular projection onto
/// a 2000x1000 canvas. The Paths are built once and reused by the painter, so
/// panning/zooming only costs a canvas transform.
class WorldGeometry {
  static const double worldW = 2000, worldH = 1000;

  /// Filled landmasses (ne_110m_land).
  final Path landPath;

  /// Country boundaries (ne_110m_admin_0_boundary_lines_land). These are open
  /// lines rather than rings — closing them would draw a stroke back across
  /// each country.
  final Path borderPath;

  WorldGeometry._(this.landPath, this.borderPath);

  static WorldGeometry? _cached;

  static Offset project(double lat, double lon) =>
      Offset((lon + 180) / 360 * worldW, (90 - lat) / 180 * worldH);

  static void _addPoints(Path path, List points, {required bool close}) {
    if (points.isEmpty) return;
    final first = points.first as List;
    final p0 = project((first[1] as num).toDouble(), (first[0] as num).toDouble());
    path.moveTo(p0.dx, p0.dy);
    for (var i = 1; i < points.length; i++) {
      final pt = points[i] as List;
      final p = project((pt[1] as num).toDouble(), (pt[0] as num).toDouble());
      path.lineTo(p.dx, p.dy);
    }
    if (close) path.close();
  }

  /// Walks a GeoJSON FeatureCollection, appending every coordinate sequence.
  /// [depth] is how many list levels wrap the point arrays, which is what
  /// separates LineString from Polygon from MultiPolygon.
  static void _addFeatures(Path path, Map<String, dynamic> geo, {required bool close}) {
    for (final f in (geo['features'] as List? ?? const [])) {
      final g = (f as Map<String, dynamic>)['geometry'] as Map<String, dynamic>?;
      if (g == null) continue;
      final coords = g['coordinates'] as List?;
      if (coords == null) continue;
      switch (g['type'] as String?) {
        case 'LineString':
          _addPoints(path, coords, close: false);
        case 'MultiLineString':
        case 'Polygon':
          for (final part in coords) {
            _addPoints(path, part as List, close: close);
          }
        case 'MultiPolygon':
          for (final poly in coords) {
            for (final ring in poly as List) {
              _addPoints(path, ring as List, close: close);
            }
          }
      }
    }
  }

  static Future<WorldGeometry> load() async {
    if (_cached != null) return _cached!;

    final land = Path();
    _addFeatures(
      land,
      jsonDecode(await rootBundle.loadString('assets/world.json')) as Map<String, dynamic>,
      close: true,
    );

    final borders = Path();
    try {
      _addFeatures(
        borders,
        jsonDecode(await rootBundle.loadString('assets/world_borders.json')) as Map<String, dynamic>,
        close: false,
      );
    } catch (_) {
      // Borders are decoration: a missing or broken asset must not cost us the
      // whole map.
    }

    _cached = WorldGeometry._(land, borders);
    return _cached!;
  }
}
