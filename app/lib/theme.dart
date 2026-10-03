import 'package:flutter/material.dart';

/// Linear / Vercel-inspired dark palette with subtle glass layers.
class BeacleColors {
  static const bg = Color(0xFF050505);
  static const surface = Color(0xFF0C0C0C);
  static const surfaceHi = Color(0xFF141414);
  static const glass = Color(0xCC101010);
  static const glassHi = Color(0xE6181818);
  static const border = Color(0xFF222222);
  static const borderGlow = Color(0xFF333333);
  static const hover = Color(0x10FFFFFF);
  static const glow = Color(0xFFFFFFFF);
  static const text = Color(0xFFF4F4F5);
  static const textDim = Color(0xFF71717A);
  static const accent = Color(0xFFE4E4E7);
  static const ok = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
  static const err = Color(0xFFF87171);

  /// The content area floats as one rounded panel beside the sidebar; cards
  /// sit on it a step lighter, with hairline edges instead of hard borders.
  static const panel = Color(0xFF0A0A0B);
  static const panelBorder = Color(0xFF1A1A1C);
  static const card = Color(0xFF111113);
  static const cardBorder = Color(0xFF1F1F23);

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

/// Corner radii, from small controls up to the content panel.
class BeacleRadius {
  static const control = 10.0;
  static const card = 14.0;
  static const dialog = 16.0;
  static const panel = 16.0;
}

ThemeData beacleTheme() {
  final base = ThemeData.dark(useMaterial3: true);
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
        side: const BorderSide(color: BeacleColors.cardBorder),
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
      side: const BorderSide(color: BeacleColors.borderGlow, width: 1.5),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      indicator: const UnderlineTabIndicator(
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
        side: const BorderSide(color: BeacleColors.cardBorder),
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
      labelStyle: const TextStyle(color: BeacleColors.textDim, fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: const BorderSide(color: BeacleColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: const BorderSide(color: BeacleColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BeacleRadius.control),
        borderSide: const BorderSide(color: BeacleColors.borderGlow),
      ),
      isDense: true,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: BeacleColors.glassHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      textStyle: const TextStyle(color: BeacleColors.text, fontSize: 11),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(BeacleColors.border),
      radius: const Radius.circular(4),
    ),
  );
}
