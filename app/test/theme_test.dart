import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/theme.dart';

void main() {
  tearDown(() => applyPalette(BeaclePalette.dark));

  test('theme mode survives settings.json and falls back to dark', () {
    for (final m in AppThemeMode.values) {
      expect(AppThemeModeWire.fromWire(m.wire), m);
    }
    expect(AppThemeModeWire.fromWire(null), AppThemeMode.dark);
    expect(AppThemeModeWire.fromWire('sepia'), AppThemeMode.dark);
  });

  test('switching the palette switches every colour and the Material theme', () {
    applyPalette(BeaclePalette.light);
    expect(BeacleColors.isDark, isFalse);
    expect(BeacleColors.bg, BeaclePalette.light.bg);
    expect(BeacleColors.text, BeaclePalette.light.text);
    expect(beacleTheme().brightness, Brightness.light);

    applyPalette(BeaclePalette.dark);
    expect(BeacleColors.bg, BeaclePalette.dark.bg);
    expect(beacleTheme().brightness, Brightness.dark);
  });

  test('the light theme is not white', () {
    // The point of it: a pale grey that does not glare. Nothing large is
    // pure white, and text is not pure black.
    const p = BeaclePalette.light;
    for (final c in [p.bg, p.panel, p.card, p.surface, p.surfaceHi]) {
      expect(c, isNot(const Color(0xFFFFFFFF)));
      expect(c.computeLuminance(), lessThan(0.92));
    }
    expect(p.text, isNot(const Color(0xFF000000)));
  });

  testWidgets('switching repaints widgets already on screen', (tester) async {
    await tester.pumpWidget(Builder(builder: (_) => ColoredBox(color: BeacleColors.bg)));
    expect(tester.widget<ColoredBox>(find.byType(ColoredBox)).color, BeaclePalette.dark.bg);

    applyPalette(BeaclePalette.light);
    await tester.pump();
    expect(tester.widget<ColoredBox>(find.byType(ColoredBox)).color, BeaclePalette.light.bg);
  });
}
