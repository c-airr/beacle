import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// How the panel picks its palette. `system` follows the OS setting and
/// switches with it.
enum AppThemeMode { dark, light, system }

extension AppThemeModeWire on AppThemeMode {
  String get wire => name;

  static AppThemeMode fromWire(String? v) =>
      AppThemeMode.values.firstWhere((m) => m.name == v, orElse: () => AppThemeMode.dark);
}

/// Every colour the panel paints with, for one theme.
class BeaclePalette {
  final Brightness brightness;
  final Color bg, surface, surfaceHi, glass, glassHi, border, borderGlow, hover, glow;
  final Color text, textDim, accent, ok, warn, err;
  final Color panel, panelBorder, card, cardBorder;

  /// Drop shadows under popups.
  final Color shadow;

  /// Map: land, its outline (outer and inner stroke), country borders, the
  /// halo around a selected continent, and the server-cluster rings.
  final Color mapLand, mapCoast, mapCoastInner, mapBorder, mapFocus, mapClusterBg, mapRing, mapSpoke, mapTip;

  const BeaclePalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.glass,
    required this.glassHi,
    required this.border,
    required this.borderGlow,
    required this.hover,
    required this.glow,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.ok,
    required this.warn,
    required this.err,
    required this.panel,
    required this.panelBorder,
    required this.card,
    required this.cardBorder,
    required this.shadow,
    required this.mapLand,
    required this.mapCoast,
    required this.mapCoastInner,
    required this.mapBorder,
    required this.mapFocus,
    required this.mapClusterBg,
    required this.mapRing,
    required this.mapSpoke,
    required this.mapTip,
  });

  bool get isDark => brightness == Brightness.dark;

  /// Linear / Vercel-inspired dark palette with subtle glass layers.
  static const dark = BeaclePalette(
    brightness: Brightness.dark,
    bg: Color(0xFF050505),
    surface: Color(0xFF0C0C0C),
    surfaceHi: Color(0xFF141414),
    glass: Color(0xCC101010),
    glassHi: Color(0xE6181818),
    border: Color(0xFF222222),
    borderGlow: Color(0xFF333333),
    hover: Color(0x10FFFFFF),
    glow: Color(0xFFFFFFFF),
    text: Color(0xFFF4F4F5),
    textDim: Color(0xFF71717A),
    accent: Color(0xFFE4E4E7),
    ok: Color(0xFF4ADE80),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFF87171),
    panel: Color(0xFF0A0A0B),
    panelBorder: Color(0xFF1A1A1C),
    card: Color(0xFF111113),
    cardBorder: Color(0xFF1F1F23),
    shadow: Color(0x8A000000),
    mapLand: Color(0xFF111111),
    mapCoast: Color(0xFF555555),
    mapCoastInner: Color(0xFF2E2E2E),
    mapBorder: Color(0xFF3A3A3A),
    mapFocus: Color(0x14FFFFFF),
    mapClusterBg: Color(0x73141414),
    mapRing: Color(0x38FFFFFF),
    mapSpoke: Color(0x28FFFFFF),
    mapTip: Color(0xEB1E1E1E),
  );

  /// Light, but not white: a cool paper grey with the cards a shade lighter
  /// and text a soft near-black, so a bright screen at night does not glare.
  /// Status colours are a step darker than in the dark theme to keep their
  /// contrast on a pale background.
  static const light = BeaclePalette(
    brightness: Brightness.light,
    bg: Color(0xFFDFE2E6),
    surface: Color(0xFFEDEFF2),
    surfaceHi: Color(0xFFE4E7EB),
    glass: Color(0xCCECEEF1),
    glassHi: Color(0xF2F3F4F6),
    border: Color(0xFFCDD2D9),
    borderGlow: Color(0xFFB3BAC4),
    hover: Color(0x0D1B2330),
    glow: Color(0xFF1B2330),
    text: Color(0xFF22272E),
    textDim: Color(0xFF656D78),
    accent: Color(0xFF3B4350),
    ok: Color(0xFF1E8A4C),
    warn: Color(0xFFB7700D),
    err: Color(0xFFD03B3B),
    panel: Color(0xFFE9EBEE),
    panelBorder: Color(0xFFD4D8DE),
    card: Color(0xFFF2F3F5),
    cardBorder: Color(0xFFD9DDE3),
    shadow: Color(0x2E1B2330),
    mapLand: Color(0xFFCCD1D8),
    mapCoast: Color(0xFF9AA2AD),
    mapCoastInner: Color(0xFFBCC2CA),
    mapBorder: Color(0xFFB4BAC3),
    mapFocus: Color(0x141B2330),
    mapClusterBg: Color(0x99E9EBEE),
    mapRing: Color(0x4D1B2330),
    mapSpoke: Color(0x331B2330),
    mapTip: Color(0xF2F3F4F6),
  );
}

/// The colours of the current theme. Widgets read them while building, so
/// switching the palette and rebuilding (see [applyPalette]) repaints the
/// whole panel without losing what is open on it.
class BeacleColors {
  static BeaclePalette _p = BeaclePalette.dark;

  static BeaclePalette get palette => _p;
  static bool get isDark => _p.isDark;

  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surfaceHi => _p.surfaceHi;
  static Color get glass => _p.glass;
  static Color get glassHi => _p.glassHi;
  static Color get border => _p.border;
  static Color get borderGlow => _p.borderGlow;
  static Color get hover => _p.hover;
  static Color get glow => _p.glow;
  static Color get text => _p.text;
  static Color get textDim => _p.textDim;
  static Color get accent => _p.accent;
  static Color get ok => _p.ok;
  static Color get warn => _p.warn;
  static Color get err => _p.err;
  static Color get shadow => _p.shadow;

  /// The content area floats as one rounded panel beside the sidebar; cards
  /// sit on it a step lighter, with hairline edges instead of hard borders.
  static Color get panel => _p.panel;
  static Color get panelBorder => _p.panelBorder;
  static Color get card => _p.card;
  static Color get cardBorder => _p.cardBorder;

  static Color statusColor(String status) {
    switch (status) {
      case 'online':
        return ok;
      case 'high_load':
        return warn;
      // The machine is up, its agent is not. Amber, because it is degraded
      // rather than gone — red here would read as "the server died".
      case 'agent_down':
        return warn;
      // Deliberate transitions, not outages: restarting pulses white while
      // the box is expected back, powered_off sits dim until it returns.
      case 'restarting':
        return accent;
      case 'powered_off':
        return textDim;
      case 'offline':
        return err;
      default:
        return textDim;
    }
  }
}

/// Picks the palette for [mode]; `system` asks the OS.
BeaclePalette paletteFor(AppThemeMode mode) => switch (mode) {
      AppThemeMode.dark => BeaclePalette.dark,
      AppThemeMode.light => BeaclePalette.light,
      AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light
            ? BeaclePalette.light
            : BeaclePalette.dark,
    };

/// Switches to [p] and rebuilds and repaints every widget on screen. Widgets
/// read [BeacleColors] directly rather than through an inherited theme, so
/// they are marked dirty by hand; state (open tabs, terminals, scroll
/// positions) is kept. Returns whether anything changed.
bool applyPalette(BeaclePalette p) {
  if (identical(p, BeacleColors._p)) return false;
  BeacleColors._p = p;
  void visit(Element e) {
    e.markNeedsBuild();
    if (e is RenderObjectElement) e.renderObject.markNeedsPaint();
    e.visitChildren(visit);
  }

  void rebuildAll() => WidgetsBinding.instance.rootElement?.visitChildren(visit);
  // Called while the tree is building (the first frame reading the saved
  // theme), marking widgets dirty would trip the framework: wait for the
  // frame to end. Anything built from here on reads the new palette anyway.
  if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    SchedulerBinding.instance.addPostFrameCallback((_) => rebuildAll());
  } else {
    rebuildAll();
  }
  return true;
}

/// Corner radii, from small controls up to the content panel.
class BeacleRadius {
  static const control = 10.0;
  static const card = 14.0;
  static const dialog = 16.0;
  static const panel = 16.0;
}

ThemeData beacleTheme() {
  final base = BeacleColors.isDark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: BeacleColors.bg,
    colorScheme: base.colorScheme.copyWith(
      surface: BeacleColors.surface,
      primary: BeacleColors.text,
      secondary: BeacleColors.textDim,
      error: BeacleColors.err,
    ),
    dividerColor: BeacleColors.border,
    cardColor: BeacleColors.surface,
    hoverColor: BeacleColors.hover,
    textTheme: base.textTheme.apply(
      bodyColor: BeacleColors.text,
      displayColor: BeacleColors.text,
      fontFamily: 'Segoe UI',
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: BeacleColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.dialog),
        side: BorderSide(color: BeacleColors.cardBorder),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BeacleColors.text,
        foregroundColor: BeacleColors.bg,
        disabledBackgroundColor: BeacleColors.surfaceHi,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BeacleColors.text,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: BeacleColors.borderGlow, width: 1.5),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      indicator: UnderlineTabIndicator(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        borderSide: BorderSide(color: BeacleColors.text, width: 2),
      ),
      overlayColor: WidgetStateProperty.all(BeacleColors.hover),
      splashBorderRadius: BorderRadius.circular(BeacleRadius.control),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: BeacleColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: BeacleColors.cardBorder),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BeacleRadius.control)),
    ),
    snackBarTheme: SnackBarThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BeacleColors.surfaceHi,
      labelStyle: TextStyle(color: BeacleColors.textDim, fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: BorderSide(color: BeacleColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: BorderSide(color: BeacleColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: BorderSide(color: BeacleColors.borderGlow),
      ),
      isDense: true,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: BeacleColors.glassHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      textStyle: TextStyle(color: BeacleColors.text, fontSize: 11),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(BeacleColors.border),
      radius: const Radius.circular(4),
    ),
  );
}
