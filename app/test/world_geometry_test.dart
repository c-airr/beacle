import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/screens/map/world_geometry.dart';

/// The border asset is a separate download that is easy to lose in a rebuild,
/// and a missing one degrades silently to "no borders" by design. These pin
/// both halves of the geometry so that silence is not mistaken for working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('land and country borders both load', () async {
    final geo = await WorldGeometry.load();

    expect(geo.landPath.computeMetrics().isNotEmpty, isTrue, reason: 'landmasses missing');
    expect(geo.borderPath.computeMetrics().isNotEmpty, isTrue, reason: 'country borders missing');
  });

  test('borders are open lines, not closed rings', () async {
    final geo = await WorldGeometry.load();
    final closed = geo.borderPath.computeMetrics().where((m) => m.isClosed).length;
    final total = geo.borderPath.computeMetrics().length;

    expect(total, greaterThan(100), reason: 'expected a few hundred boundary segments');
    // Closing a boundary line would stroke a chord straight back across the
    // country it belongs to.
    expect(closed, 0, reason: '$closed of $total border segments were closed');
  });

  test('projection maps lat/lon onto the world canvas', () {
    expect(WorldGeometry.project(0, 0), const Offset(WorldGeometry.worldW / 2, WorldGeometry.worldH / 2));
    expect(WorldGeometry.project(90, -180), Offset.zero);
    expect(WorldGeometry.project(-90, 180), const Offset(WorldGeometry.worldW, WorldGeometry.worldH));
  });

  test('borders sit inside the world canvas', () async {
    final geo = await WorldGeometry.load();
    final b = geo.borderPath.getBounds();

    expect(b.left, greaterThanOrEqualTo(-1));
    expect(b.top, greaterThanOrEqualTo(-1));
    expect(b.right, lessThanOrEqualTo(WorldGeometry.worldW + 1));
    expect(b.bottom, lessThanOrEqualTo(WorldGeometry.worldH + 1));
  });
}
